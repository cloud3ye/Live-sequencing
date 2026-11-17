import AVFoundation
import Photos
import UIKit

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

    func build(localIdentifiers: [String], gallery: Bool = false) async {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var assets: [PHAsset] = []
        for i in 0..<result.count { assets.append(result.object(at: i)) }
        await build(from: assets, gallery: gallery)
    }

    /// gallery: frame the video like the Photos app, with the sliding thumbnail strip.
    func build(from assets: [PHAsset], gallery: Bool = false) async {
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
                    let thumbnail = gallery ? await ClipStitcher.thumbnail(for: asset) : nil
                    clips.append(.init(url: url, date: asset.creationDate ?? .distantPast,
                                       thumbnail: thumbnail))
                } else {
                    skipped += 1
                }
            }
            guard clips.count > 1 else {
                message = "Need at least two Live Photos with motion (found \(clips.count), \(skipped) unreadable)."
                return
            }

            let output = try await ClipStitcher.stitch(clips, trimOverlaps: trimOverlaps, gallery: gallery)
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: output)
                }
            } catch {
                throw ClipStitcher.BuildError.step("Saving to Photos", error)
            }
            message = "Saved a \(gallery ? "gallery " : "")video from \(clips.count) Live Photos to Photos."
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
        var thumbnail: CGImage? = nil   // the still photo, for gallery mode
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

    /// Small greyscale "fingerprints" of each frame in part of a clip, for comparing pictures.
    static func fingerprints(asset: AVAsset, track: AVAssetTrack,
                             timeRange: CMTimeRange) -> [(time: CMTime, pixels: [Float])] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.timeRange = timeRange
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var result: [(time: CMTime, pixels: [Float])] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pixels = grid(of: buffer)
            if !pixels.isEmpty {
                result.append((CMSampleBufferGetPresentationTimeStamp(sample), pixels))
            }
        }
        return result
    }

    /// Average brightness over a 24 x 24 grid of small patches.
    static func grid(of buffer: CVPixelBuffer, size: Int = 24) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var out: [Float] = []
        out.reserveCapacity(size * size)
        for gy in 0..<size {
            for gx in 0..<size {
                let cx = (gx * 2 + 1) * width / (size * 2)
                let cy = (gy * 2 + 1) * height / (size * 2)
                var sum = 0
                for dy in 0..<4 {
                    for dx in 0..<4 {
                        let x = min(width - 1, cx + dx * 2)
                        let y = min(height - 1, cy + dy * 2)
                        let offset = y * rowBytes + x * 4
                        sum += Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                    }
                }
                out.append(Float(sum) / 48)
            }
        }
        return out
    }

    static func difference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total: Float = 0
        for k in 0..<a.count { total += abs(a[k] - b[k]) }
        return total / Float(a.count)
    }

    /// How far into the next clip to start (seconds) so it picks up right after the
    /// previous clip's last frame. Nil when no clearly matching picture is found.
    static func matchedStart(previousAsset: AVAsset, previousTrack: AVAssetTrack, previousRange: CMTimeRange,
                             nextAsset: AVAsset, nextTrack: AVAssetTrack, nextRange: CMTimeRange,
                             guess: Double) -> Double? {
        let tail = CMTimeRange(start: CMTimeMaximum(previousRange.start,
                                                    previousRange.end - CMTime(seconds: 0.3, preferredTimescale: 600)),
                               end: previousRange.end)
        guard let reference = fingerprints(asset: previousAsset, track: previousTrack, timeRange: tail).last?.pixels
        else { return nil }

        let duration = nextRange.duration.seconds
        let low = max(0, guess - 0.8)
        let high = min(duration, guess + 0.8)
        guard high > low else { return nil }
        let window = CMTimeRange(start: nextRange.start + CMTime(seconds: low, preferredTimescale: 600),
                                 end: nextRange.start + CMTime(seconds: high, preferredTimescale: 600))
        let frames = fingerprints(asset: nextAsset, track: nextTrack, timeRange: window)
        guard frames.count >= 3 else { return nil }

        let diffs = frames.map { difference($0.pixels, reference) }
        guard let best = diffs.indices.min(by: { diffs[$0] < diffs[$1] }) else { return nil }
        let sortedDiffs = diffs.sorted()
        let median = sortedDiffs[sortedDiffs.count / 2]
        // Only trust a match that clearly stands out (or is near-identical).
        guard diffs[best] < 4 || diffs[best] < median * 0.5 else { return nil }

        // Start on the frame after the match, so the matched moment isn't shown twice.
        let startTime = best + 1 < frames.count
            ? frames[best + 1].time
            : frames[best].time + CMTime(value: 1, timescale: 60)
        return max(0, (startTime - nextRange.start).seconds)
    }

    /// Turns a clip upright, then scales and centres it to exactly fill the output frame.
    static func fit(_ transform: CGAffineTransform, naturalSize: CGSize,
                    into renderSize: CGSize) -> CGAffineTransform {
        fit(transform, naturalSize: naturalSize, into: CGRect(origin: .zero, size: renderSize), fill: true)
    }

    /// Turns a clip upright, then scales it to fill (or fit inside) a rectangle, centred on it.
    static func fit(_ transform: CGAffineTransform, naturalSize: CGSize,
                    into rect: CGRect, fill: Bool) -> CGAffineTransform {
        let box = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard box.width > 0, box.height > 0 else { return transform }
        let sx = rect.width / box.width, sy = rect.height / box.height
        let scale = fill ? max(sx, sy) : min(sx, sy)
        return transform
            .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.minX + (rect.width - box.width * scale) / 2,
                                             y: rect.minY + (rect.height - box.height * scale) / 2))
    }

    // MARK: Gallery mode

    /// The Photos app's full-screen layout, measured from an iPhone screen recording and
    /// scaled to a 1080 x 2340 frame. Photo and strip only: none of the buttons or text.
    enum Gallery {
        static let canvas = CGSize(width: 1080, height: 2340)
        /// The photo fills the width, centred on the same line as in Photos (top-left origin).
        static let photoArea = CGRect(x: 0, y: 1174 - 720, width: 1080, height: 1440)
        static let stripCentreFromTop: CGFloat = 2053
        static let thumbSize = CGSize(width: 54, height: 80)
        static let currentWidth: CGFloat = 80      // the current photo is shown wider
        static let gap: CGFloat = 8
        static let currentGap: CGFloat = 35        // extra space either side of the current photo
        static let cornerRadius: CGFloat = 7
        static let slideDuration = 0.3             // seconds for the strip to move to the next photo
    }

    /// The Live Photo's still, small and upright, for the gallery strip.
    static func thumbnail(for asset: PHAsset) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let image: UIImage? = await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 240),
                                                  contentMode: .aspectFill, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image)
            }
        }
        guard let image else { return nil }
        // Redraw so the picture is upright whatever orientation it was stored in.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    /// Where each thumbnail sits (centre x, width) when photo number current is selected.
    static func stripLayout(count: Int, current: Int) -> [(x: CGFloat, width: CGFloat)] {
        let middle = Gallery.canvas.width / 2
        let pitch = Gallery.thumbSize.width + Gallery.gap
        return (0..<count).map { j in
            if j == current { return (middle, Gallery.currentWidth) }
            let offset = Gallery.currentWidth / 2 + Gallery.currentGap
                + CGFloat(abs(j - current) - 1) * pitch + Gallery.thumbSize.width / 2
            return (j > current ? middle + offset : middle - offset, Gallery.thumbSize.width)
        }
    }

    /// The thumbnail strip, sliding to each photo as the video reaches it.
    /// These layers use a bottom-left origin, as the video export requires.
    static func galleryStrip(thumbnails: [CGImage?], switchTimes: [Double], duration: Double) -> CALayer {
        let canvas = Gallery.canvas
        let stripHeight: CGFloat = 120
        let container = CALayer()
        container.frame = CGRect(x: 0, y: canvas.height - Gallery.stripCentreFromTop - stripHeight / 2,
                                 width: canvas.width, height: stripHeight)
        // Fade the strip out at both edges, as Photos does.
        let fade = CAGradientLayer()
        fade.frame = container.bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor,
                       UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.locations = [0.05, 0.1, 0.9, 0.95]
        container.mask = fade

        let count = thumbnails.count
        guard count > 0, duration > 0 else { return container }
        let layouts = (0..<count).map { stripLayout(count: count, current: $0) }

        // Keyframes: hold on each photo, then slide to the next one around its switch time.
        let linear = CAMediaTimingFunction(name: .linear)
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        var times: [Double] = [0]
        var states: [Int] = [0]
        var easing: [CAMediaTimingFunction] = []
        for k in 1..<max(count, 1) {
            let switchTime = switchTimes[k]
            let before = switchTime - switchTimes[k - 1]
            let after = (k + 1 < count ? switchTimes[k + 1] : duration) - switchTime
            let slide = max(0.001, min(Gallery.slideDuration, before * 0.8, after * 0.8))
            times += [switchTime - slide / 2, switchTime + slide / 2]
            states += [k - 1, k]
            easing += [linear, ease]
        }
        times.append(duration)
        states.append(count - 1)
        easing.append(linear)
        let keyTimes = times.map { NSNumber(value: min(max($0 / duration, 0), 1)) }

        for j in 0..<count {
            let thumb = CALayer()
            let start = layouts[0][j]
            thumb.bounds = CGRect(x: 0, y: 0, width: start.width, height: Gallery.thumbSize.height)
            thumb.position = CGPoint(x: start.x, y: stripHeight / 2)
            thumb.contents = thumbnails[j]
            thumb.contentsGravity = .resizeAspectFill
            thumb.masksToBounds = true
            thumb.cornerRadius = Gallery.cornerRadius
            thumb.backgroundColor = UIColor(white: 0.15, alpha: 1).cgColor
            if count > 1 {
                let slideX = CAKeyframeAnimation(keyPath: "position.x")
                slideX.values = states.map { layouts[$0][j].x }
                let resize = CAKeyframeAnimation(keyPath: "bounds.size.width")
                resize.values = states.map { layouts[$0][j].width }
                for animation in [slideX, resize] {
                    animation.keyTimes = keyTimes
                    animation.timingFunctions = easing
                    animation.calculationMode = .linear
                    animation.beginTime = AVCoreAnimationBeginTimeAtZero
                    animation.duration = duration
                    animation.isRemovedOnCompletion = false
                    animation.fillMode = .both
                    thumb.add(animation, forKey: animation.keyPath)
                }
            }
            container.addSublayer(thumb)
        }
        return container
    }

    static func stitch(_ clips: [Clip], trimOverlaps: Bool, gallery: Bool = false) async throws -> URL {
        struct Loaded {
            let asset: AVURLAsset       // must stay alive while its tracks are used
            let video: AVAssetTrack
            let audio: AVAssetTrack?
            let range: CMTimeRange      // the clip's real video range
            let absoluteStart: Double   // real-world time (seconds) of the clip's first frame
            let thumbnail: CGImage?
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
                                     range: range, absoluteStart: start, thumbnail: clip.thumbnail))
            } catch {
                continue // skip a clip that can't be read
            }
        }
        loaded.sort { $0.absoluteStart < $1.absoluteStart }
        guard !loaded.isEmpty else { throw BuildError.noVideo }

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
            let naturalSize: CGSize
            let timeRange: CMTimeRange   // where it sits in the final video
            let fadeIn: CMTime           // how much of its start overlaps the previous clip
            let thumbnail: CGImage?
        }
        let fadeLength = 0.1             // seconds: about 3 frames
        let timescale: CMTimeScale = 600
        var placed: [Placed] = []

        var cursor = CMTime.zero
        var shownUntil: Double? = nil   // real-world time already covered by earlier clips
        var previous: Loaded? = nil     // the last clip actually used
        for (i, clip) in loaded.enumerated() {
            // Start each clip where the previous one ended on the real-world clock,
            // so overlapping moments are shown once and nothing replays.
            var skip = 0.0
            if trimOverlaps, let shownUntil {
                skip = max(0, shownUntil - clip.absoluteStart)
            }
            // Timestamps are only accurate to a few tenths of a second, so refine the
            // cut by finding the picture in this clip that matches the previous clip's
            // last frame, and start just after it.
            if trimOverlaps, let previous,
               let matched = matchedStart(previousAsset: previous.asset, previousTrack: previous.video,
                                          previousRange: previous.range,
                                          nextAsset: clip.asset, nextTrack: clip.video,
                                          nextRange: clip.range, guess: skip) {
                skip = matched
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
            let naturalSize = (try? await clip.video.load(.naturalSize)) ?? .zero
            previous = clip
            placed.append(Placed(track: track, transform: transform, naturalSize: naturalSize,
                                 timeRange: CMTimeRange(start: insertAt, duration: source.duration),
                                 fadeIn: fadeIn, thumbnail: clip.thumbnail))

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

        // The output frame: the first clip's size, turned upright, or in gallery mode
        // a phone-shaped frame with the photo where Photos shows it.
        let upright = CGRect(origin: .zero, size: placed[0].naturalSize).applying(placed[0].transform)
        let renderSize = gallery ? Gallery.canvas
            : CGSize(width: (abs(upright.width) / 2).rounded() * 2,
                     height: (abs(upright.height) / 2).rounded() * 2)
        // Each clip's own rotation data can leave it offset, so place every clip
        // explicitly: turned upright, scaled to fill the frame (or, in gallery mode,
        // to fit the photo area), and centred.
        let fittedTransforms = placed.map {
            gallery ? fit($0.transform, naturalSize: $0.naturalSize, into: Gallery.photoArea, fill: false)
                    : fit($0.transform, naturalSize: $0.naturalSize, into: renderSize)
        }

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
                layer.setTransform(fittedTransforms[i], at: soloStart)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
            if i + 1 < placed.count, nextFade > .zero {
                let next = placed[i + 1]
                let dissolve = CMTimeRange(start: soloEnd, duration: nextFade)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = dissolve
                let outgoing = AVMutableVideoCompositionLayerInstruction(assetTrack: p.track)
                outgoing.setTransform(fittedTransforms[i], at: dissolve.start)
                outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: dissolve)
                let incoming = AVMutableVideoCompositionLayerInstruction(assetTrack: next.track)
                incoming.setTransform(fittedTransforms[i + 1], at: dissolve.start)
                instruction.layerInstructions = [outgoing, incoming]
                instructions.append(instruction)
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        // A fine 60 fps grid, so each original frame lands almost exactly when it was
        // recorded and the Live Photos keep their natural, uneven pacing.
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.renderSize = renderSize

        if gallery {
            // Each photo becomes the current one halfway through the dissolve into it.
            let switchTimes: [Double] = placed.enumerated().map { i, p in
                i == 0 ? 0 : p.timeRange.start.seconds + p.fadeIn.seconds / 2
            }
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: renderSize)
            parent.backgroundColor = UIColor.black.cgColor
            let videoLayer = CALayer()
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            parent.addSublayer(galleryStrip(thumbnails: placed.map(\.thumbnail),
                                            switchTimes: switchTimes,
                                            duration: composition.duration.seconds))
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parent)
        }

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
