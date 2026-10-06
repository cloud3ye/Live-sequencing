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
        guard let videoOut = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.noVideo }
        let audioOut = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid)
        videoOut.preferredTransform = try await first.video.load(.preferredTransform)

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
            let timescale: CMTimeScale = 600
            let startTime = clip.range.start + CMTime(seconds: skip, preferredTimescale: timescale)
            // Never ask for more than the clip actually has (rounding can overshoot).
            let range = CMTimeRange(start: startTime,
                                    duration: CMTimeMaximum(.zero, clip.range.end - startTime))
            guard range.duration.seconds > 0.03 else { continue }
            shownUntil = max(shownUntil ?? -.infinity, clip.absoluteEnd)
            do {
                try videoOut.insertTimeRange(range, of: clip.video, at: cursor)
            } catch {
                throw BuildError.step("Joining clip \(i + 1)", error)
            }
            if let audio = clip.audio, let audioOut {
                // Clip the audio to what the audio track really contains.
                if let audioRange = try? await audio.load(.timeRange) {
                    let usable = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                    if usable.duration > .zero {
                        try? audioOut.insertTimeRange(usable, of: audio,
                                                      at: cursor + (usable.start - range.start))
                    }
                }
            }
            cursor = cursor + range.duration
        }

        // An empty audio track makes the export fail, so drop it if nothing went in.
        if let audioOut, audioOut.segments.isEmpty {
            composition.removeTrack(audioOut)
        }

        // Try best quality first, then a straight copy if that preset won't work.
        var lastError: Error = BuildError.exportFailed
        for preset in [AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough] {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LiveSequence-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            export.outputURL = outputURL
            export.outputFileType = .mov
            await export.export()
            if export.status == .completed { return outputURL }
            lastError = export.error ?? BuildError.exportFailed
        }
        throw BuildError.step("Exporting the video", lastError)
    }
}
