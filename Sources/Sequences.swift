import AVFoundation
import Photos

struct LiveSequence: Identifiable {
    let id = UUID()
    let assets: [PHAsset]
    var start: Date { assets.first?.creationDate ?? .distantPast }
}

/// Finds runs of Live Photos in the library taken within maxGap seconds of each other.
@MainActor
final class SequenceLibrary: ObservableObject {
    @Published var sequences: [LiveSequence] = []
    @Published var maxGap: Double = 4
    @Published var status = ""

    func load() async {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            status = "Photos access is off. Turn it on in Settings."
            return
        }
        status = ""

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0",
                                        PHAssetMediaSubtype.photoLive.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)

        let gap = maxGap
        var groups: [[PHAsset]] = []
        var current: [PHAsset] = []
        var last: Date?

        for i in 0..<result.count {
            let asset = result.object(at: i)
            // Skip ones with Live turned off or a Loop/Bounce/Long Exposure effect.
            guard asset.playbackStyle == .livePhoto, let date = asset.creationDate else { continue }
            if let last, date.timeIntervalSince(last) <= gap {
                current.append(asset)
            } else {
                if current.count > 1 { groups.append(current) }
                current = [asset]
            }
            last = date
        }
        if current.count > 1 { groups.append(current) }

        sequences = groups.reversed().map { LiveSequence(assets: $0) }
        if sequences.isEmpty { status = "No sequences found with this gap." }
    }
}

/// Joins the original Live Photo motion clips into one video, untouched
/// (same frame rate, blur and sound), and saves it to Photos.
@MainActor
final class VideoBuilder: ObservableObject {
    @Published var isBuilding = false
    @Published var message: String?
    @Published var trimOverlaps = true

    func build(localIdentifiers: [String]) async {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var assets: [PHAsset] = []
        for i in 0..<result.count { assets.append(result.object(at: i)) }
        await build(from: assets)
    }

    func build(from assets: [PHAsset]) async {
        isBuilding = true
        message = nil
        defer { isBuilding = false }

        do {
            let sorted = assets.sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
            var clips: [ClipStitcher.Clip] = []
            var skipped = 0
            for asset in sorted {
                // One unreadable clip shouldn't sink the whole video.
                if let url = try? await ClipStitcher.pairedVideo(for: asset) {
                    clips.append(.init(url: url, date: asset.creationDate ?? .distantPast))
                } else {
                    skipped += 1
                }
            }
            guard clips.count > 1 else {
                message = "Need at least two Live Photos with motion (found \(clips.count), \(skipped) unreadable)."
                return
            }

            let output = try await ClipStitcher.stitch(clips, trimOverlaps: trimOverlaps)
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: output)
                }
            } catch {
                throw ClipStitcher.BuildError.step("Saving to Photos", error)
            }
            message = "Saved a video from \(clips.count) Live Photos to Photos."
                + (skipped > 0 ? " (\(skipped) skipped)" : "")
        } catch {
            message = "Couldn't build the video. \(ClipStitcher.describe(error))"
        }
    }
}

enum ClipStitcher {
    struct Clip {
        let url: URL
        let date: Date
    }

    enum BuildError: LocalizedError {
        case noVideo, exportFailed
        case step(String, Error)
        var errorDescription: String? {
            switch self {
            case .noVideo: return "No motion clips could be read."
            case .exportFailed: return "Export didn't finish."
            case .step(let name, let error): return "\(name) failed: \(ClipStitcher.describe(error))"
            }
        }
    }

    /// Error text with its domain and code, so a vague iOS message can be traced.
    static func describe(_ error: Error) -> String {
        if let build = error as? BuildError { return build.errorDescription ?? "Unknown error" }
        let ns = error as NSError
        var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }

    /// Copies a Live Photo's motion clip out of the library to a temp file.
    static func pairedVideo(for asset: PHAsset) async throws -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the edited clip (e.g. trimmed in Photos), else the original.
        guard let resource = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo }) else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true // fetch from iCloud if needed

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return url
    }

    /// The moment the still photo was taken, inside a Live Photo's motion clip.
    /// iOS stores it as a "still-image-time" metadata marker in the clip.
    static func stillImageTime(in asset: AVURLAsset) async -> CMTime? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata) else { return nil }
        for track in tracks {
            guard let reader = try? AVAssetReader(asset: asset) else { continue }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            while let group = adaptor.nextTimedMetadataGroup() {
                let isStill = group.items.contains {
                    $0.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time"
                }
                if isStill {
                    reader.cancelReading()
                    return group.timeRange.start
                }
            }
        }
        return nil
    }

    static func stitch(_ clips: [Clip], trimOverlaps: Bool) async throws -> URL {
        struct Loaded {
            let asset: AVURLAsset       // must stay alive while its tracks are used
            let video: AVAssetTrack
            let audio: AVAssetTrack?
            let range: CMTimeRange      // the clip's real video range
            let absoluteStart: Double   // real-world time (seconds) of the clip's first frame
            var duration: Double { range.duration.seconds }
            var absoluteEnd: Double { absoluteStart + duration }
        }

        var loaded: [Loaded] = []
        for clip in clips {
            do {
                let asset = AVURLAsset(url: clip.url)
                guard let video = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let audio = try await asset.loadTracks(withMediaType: .audio).first
                let range = try await video.load(.timeRange)
                let duration = range.duration.seconds
                guard duration > 0.05 else { continue }
                // Where the photo itself sits inside the clip. Live Photo clips record
                // this exactly; fall back to the middle only if it's missing.
                var photoOffset = duration / 2
                if let still = await stillImageTime(in: asset) {
                    photoOffset = min(max((still - range.start).seconds, 0), duration)
                }
                let start = clip.date.timeIntervalSince1970 - photoOffset
                loaded.append(Loaded(asset: asset, video: video, audio: audio,
                                     range: range, absoluteStart: start))
            } catch {
                continue // skip a clip that can't be read
            }
        }
        loaded.sort { $0.absoluteStart < $1.absoluteStart }
        guard let first = loaded.first else { throw BuildError.noVideo }

        let composition = AVMutableComposition()
        // Two video tracks, used alternately, so each clip can overlap the
        // previous one briefly and dissolve into it.
        guard let trackA = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid),
              let trackB = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.noVideo }
        let videoTracks = [trackA, trackB]
        let audioOut = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid)

        struct Placed {
            let track: AVMutableCompositionTrack
            let transform: CGAffineTransform
            let timeRange: CMTimeRange   // where it sits in the final video
            let fadeIn: CMTime           // how much of its start overlaps the previous clip
        }
        let fadeLength = 0.1             // seconds: about 3 frames
        let timescale: CMTimeScale = 600
        var placed: [Placed] = []

        var cursor = CMTime.zero
        var shownUntil: Double? = nil   // real-world time already covered by earlier clips
        for (i, clip) in loaded.enumerated() {
            // Start each clip where the previous one ended on the real-world clock,
            // so overlapping moments are shown once and nothing replays.
            var skip = 0.0
            if trimOverlaps, let shownUntil {
                skip = max(0, shownUntil - clip.absoluteStart)
            }
            guard skip < clip.duration - 0.05 else { continue } // fully covered already
            let startTime = clip.range.start + CMTime(seconds: skip, preferredTimescale: timescale)
            guard clip.range.end > startTime else { continue }
            let own = CMTimeRange(start: startTime, end: clip.range.end)
            guard own.duration.seconds > 0.03 else { continue }
            shownUntil = max(shownUntil ?? -.infinity, clip.absoluteEnd)

            // Borrow a few frames from just before the cut so this clip can
            // dissolve in over the end of the previous one.
            var fadeIn = CMTime.zero
            if let prev = placed.last {
                let available = (startTime - clip.range.start).seconds
                let prevSolo = (prev.timeRange.duration - prev.fadeIn).seconds
                let f = min(fadeLength, available, prevSolo / 2, own.duration.seconds / 2)
                if f > 0.02 { fadeIn = CMTime(seconds: f, preferredTimescale: timescale) }
            }
            let source = CMTimeRange(start: startTime - fadeIn, end: clip.range.end)
            let insertAt = cursor - fadeIn
            let track = videoTracks[placed.count % 2]
            do {
                try track.insertTimeRange(source, of: clip.video, at: insertAt)
            } catch {
                throw BuildError.step("Joining clip \(i + 1)", error)
            }
            let transform = (try? await clip.video.load(.preferredTransform)) ?? .identity
            placed.append(Placed(track: track, transform: transform,
                                 timeRange: CMTimeRange(start: insertAt, duration: source.duration),
                                 fadeIn: fadeIn))

            // Sound follows the cuts directly (no overlap), so it never doubles up.
            if let audio = clip.audio, let audioOut {
                if let audioRange = try? await audio.load(.timeRange) {
                    let usable = CMTimeRangeGetIntersection(own, otherRange: audioRange)
                    if usable.duration > .zero {
                        try? audioOut.insertTimeRange(usable, of: audio,
                                                      at: cursor + (usable.start - own.start))
                    }
                }
            }
            cursor = insertAt + source.duration
        }
        guard !placed.isEmpty else { throw BuildError.noVideo }

        // Empty tracks make the export fail, so drop any that got nothing.
        if let audioOut, audioOut.segments.isEmpty { composition.removeTrack(audioOut) }
        if trackB.segments.isEmpty { composition.removeTrack(trackB) }

        // Describe what's on screen at every moment: one clip on its own, or
        // two clips during a dissolve (the outgoing one fading out on top).
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (i, p) in placed.enumerated() {
            let soloStart = p.timeRange.start + p.fadeIn
            let nextFade = i + 1 < placed.count ? placed[i + 1].fadeIn : .zero
            let soloEnd = p.timeRange.end - nextFade
            if soloEnd > soloStart {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: soloStart, end: soloEnd)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: p.track)
                layer.setTransform(p.transform, at: soloStart)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
            if i + 1 < placed.count, nextFade > .zero {
                let next = placed[i + 1]
                let dissolve = CMTimeRange(start: soloEnd, duration: nextFade)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = dissolve
                let outgoing = AVMutableVideoCompositionLayerInstruction(assetTrack: p.track)
                outgoing.setTransform(p.transform, at: dissolve.start)
                outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: dissolve)
                let incoming = AVMutableVideoCompositionLayerInstruction(assetTrack: next.track)
                incoming.setTransform(next.transform, at: dissolve.start)
                instruction.layerInstructions = [outgoing, incoming]
                instructions.append(instruction)
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let naturalSize = (try? await first.video.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(placed[0].transform)
        videoComposition.renderSize = CGSize(width: abs(rotated.width), height: abs(rotated.height))

        // Try best quality first, then a fixed-size export if that preset won't work.
        var lastError: Error = BuildError.exportFailed
        for preset in [AVAssetExportPresetHighestQuality, AVAssetExportPreset1920x1080] {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LiveSequence-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            export.outputURL = outputURL
            export.outputFileType = .mov
            export.videoComposition = videoComposition
            await export.export()
            if export.status == .completed { return outputURL }
            lastError = export.error ?? BuildError.exportFailed
        }
        throw BuildError.step("Exporting the video", lastError)
    }
}
