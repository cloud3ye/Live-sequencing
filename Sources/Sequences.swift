import AVFoundation
import Photos

struct LiveSequence: Identifiable {
    let id = UUID()
    let assets: [PHAsset]
    var start: Date { assets.first?.creationDate ?? .distantPast }
}

/// Finds runs of Live Photos in the library taken within `maxGap` seconds of each other.
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
            for asset in sorted {
                if let url = try await ClipStitcher.pairedVideo(for: asset) {
                    clips.append(.init(url: url, date: asset.creationDate ?? .distantPast))
                }
            }
            guard clips.count > 1 else {
                message = "Need at least two Live Photos with motion."
                return
            }

            let output = try await ClipStitcher.stitch(clips, trimOverlaps: trimOverlaps)
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: output)
            }
            message = "Saved a video from \(clips.count) Live Photos to Photos."
        } catch {
            message = "Couldn't build the video: \(error.localizedDescription)"
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
        var errorDescription: String? {
            switch self {
            case .noVideo: return "No motion clips could be read."
            case .exportFailed: return "Export didn't finish."
            }
        }
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

    static func stitch(_ clips: [Clip], trimOverlaps: Bool) async throws -> URL {
        struct Loaded {
            let video: AVAssetTrack
            let audio: AVAssetTrack?
            let start: CMTime
            let duration: Double
            let date: Date
        }

        var loaded: [Loaded] = []
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let range = try await video.load(.timeRange)
            loaded.append(Loaded(video: video, audio: audio, start: range.start,
                                 duration: range.duration.seconds, date: clip.date))
        }
        guard let first = loaded.first else { throw BuildError.noVideo }

        let composition = AVMutableComposition()
        guard let videoOut = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.noVideo }
        let audioOut = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid)
        videoOut.preferredTransform = try await first.video.load(.preferredTransform)

        var cursor = CMTime.zero
        for (i, clip) in loaded.enumerated() {
            var length = clip.duration
            // Each clip runs roughly half before and half after its shutter moment.
            // If the next clip starts before this one ends, cut this one there so
            // the same moment isn't shown twice.
            if trimOverlaps, i + 1 < loaded.count {
                let next = loaded[i + 1]
                let thisStart = clip.date.timeIntervalSince1970 - clip.duration / 2
                let nextStart = next.date.timeIntervalSince1970 - next.duration / 2
                let gap = nextStart - thisStart
                if gap > 0.2 { length = min(length, gap) }
            }
            let range = CMTimeRange(start: clip.start,
                                    duration: CMTime(seconds: length, preferredTimescale: 600))
            try videoOut.insertTimeRange(range, of: clip.video, at: cursor)
            if let audio = clip.audio {
                try? audioOut?.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = cursor + range.duration
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveSequence-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality)
        else { throw BuildError.exportFailed }
        export.outputURL = outputURL
        export.outputFileType = .mov
        await export.export()
        if let error = export.error { throw error }
        guard export.status == .completed else { throw BuildError.exportFailed }
        return outputURL
    }
}
