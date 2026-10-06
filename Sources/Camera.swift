import AVFoundation
import Photos
import UIKit

/// Runs the camera and fires real Live Photos on a timer so the motion clips overlap
/// and form one unbroken sequence.
@MainActor
final class CameraModel: ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var processors: [Int64: LivePhotoCaptureProcessor] = [:]
    private var timer: Timer?
    private var videoDevice: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var configured = false

    @Published var isRunningSequence = false
    /// Each gap between shutter presses is picked at random from this range.
    let gapRange: ClosedRange<Double> = 0.8...3.0
    @Published var lastGap: Double?
    @Published var savedThisSequence: [String] = [] // Photos local identifiers
    @Published var inFlight = 0
    @Published var status = ""

    // MARK: Setup

    func start() async {
        guard !configured else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "Camera access is off. Turn it on in Settings."
            return
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        let photos = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if photos != .authorized && photos != .limited {
            status = "Photos access is off, so Live Photos can't be saved."
        }
        configureSession()
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            status = "No camera available."
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoDevice = device

        // Microphone gives the Live Photos their sound, same as the Camera app.
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        guard session.canAddOutput(photoOutput) else {
            status = "Can't set up photo capture."
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced

        if photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = true
            // Auto-trimming cuts motion it thinks is unwanted. Off = full clips,
            // which keeps neighbouring Live Photos overlapping.
            photoOutput.isLivePhotoAutoTrimmingEnabled = false
        } else {
            status = "This camera doesn't support Live Photos."
        }

        session.commitConfiguration()
        configured = true
        setupRotation()

        let session = self.session
        sessionQueue.async { session.startRunning() }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        setupRotation()
    }

    private func setupRotation() {
        guard let device = videoDevice, let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        layer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                  options: [.new]) { [weak layer] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { layer?.connection?.videoRotationAngle = angle }
        }
    }

    // MARK: Sequence capture

    func toggleSequence() {
        isRunningSequence ? stopSequence() : startSequence()
    }

    func startSequence() {
        guard photoOutput.isLivePhotoCaptureEnabled else {
            status = "Live Photos aren't available on this camera."
            return
        }
        status = ""
        savedThisSequence = []
        isRunningSequence = true
        lastGap = nil
        capture()
        scheduleNext()
    }

    func stopSequence() {
        timer?.invalidate()
        timer = nil
        isRunningSequence = false
    }

    /// Picks a fresh random gap, waits that long, takes a shot, then repeats.
    private func scheduleNext() {
        guard isRunningSequence else { return }
        let gap = Double.random(in: gapRange)
        lastGap = gap
        timer = Timer.scheduledTimer(withTimeInterval: gap, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunningSequence else { return }
                self.capture()
                self.scheduleNext()
            }
        }
    }

    private func capture() {
        // Don't pile up captures if the device can't keep pace with the interval.
        guard processors.count < 4 else { return }

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .balanced
        settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        let processor = LivePhotoCaptureProcessor(id: settings.uniqueID) { [weak self] id, localID in
            Task { @MainActor in
                guard let self else { return }
                self.processors[id] = nil
                self.inFlight = self.processors.count
                if let localID { self.savedThisSequence.append(localID) }
            }
        }
        processors[settings.uniqueID] = processor
        inFlight = processors.count
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }
}

/// Collects the still and the motion clip for one Live Photo, then saves them
/// to Photos together so it stays a genuine Live Photo.
final class LivePhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let id: Int64
    private let completion: (Int64, String?) -> Void
    private var photoData: Data?
    private var movieURL: URL?
    private var captureDate = Date()

    init(id: Int64, completion: @escaping (Int64, String?) -> Void) {
        self.id = id
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        captureDate = Date() // closest moment to the shutter
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        photoData = photo.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime,
                     photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if error == nil { movieURL = outputFileURL }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard error == nil, let data = photoData else {
            completion(id, nil)
            return
        }
        let movie = movieURL
        let date = captureDate
        var placeholder: PHObjectPlaceholder?

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = date
            request.addResource(with: .photo, data: data, options: nil)
            if let movie {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .pairedVideo, fileURL: movie, options: options)
            }
            placeholder = request.placeholderForCreatedAsset
        }) { success, _ in
            self.completion(self.id, success ? placeholder?.localIdentifier : nil)
        }
    }
}
