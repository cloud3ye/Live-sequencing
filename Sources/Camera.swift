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
    /// Each gap between shutter presses is picked at random between these two.
    /// Set on the Capture screen and remembered between launches.
    @Published var minGap: Double = UserDefaults.standard.object(forKey: "minGap") as? Double ?? 0.8 {
        didSet {
            if minGap > maxGap { maxGap = minGap }
            UserDefaults.standard.set(minGap, forKey: "minGap")
        }
    }
    @Published var maxGap: Double = UserDefaults.standard.object(forKey: "maxGap") as? Double ?? 2.2 {
        didSet {
            if maxGap < minGap { minGap = maxGap }
            UserDefaults.standard.set(maxGap, forKey: "maxGap")
        }
    }
    /// The limits the sliders allow, in seconds.
    static let gapLimits: ClosedRange<Double> = 0.3...6.0
    var gapRange: ClosedRange<Double> { min(minGap, maxGap)...max(minGap, maxGap) }
    @Published var lastGap: Double?
    @Published var savedThisSequence: [String] = [] // Photos local identifiers
    @Published var inFlight = 0
    @Published var status = ""
    /// Why the camera couldn't start. Stays on screen until it's fixed.
    @Published var setupProblem: String?
    /// True when the fix is a permission switch in Settings.
    @Published var needsSettings = false
    private var runtimeErrorObserver: NSObjectProtocol?
    private var subjectAreaObserver: NSObjectProtocol?

    /// Exposure compensation in EV, like the Camera app's sun slider.
    @Published var exposureBias: Float = 0
    /// AE/AF lock, set by a long press, as in the Camera app.
    @Published var isAEAFLocked = false
    /// Goes up each time focus and exposure return to automatic for the whole scene.
    @Published var focusResets = 0
    static let biasLimits: ClosedRange<Float> = -2...2

    // MARK: Setup

    /// Safe to call repeatedly (e.g. every time the app comes back to the front).
    func start() async {
        if configured {
            if !session.isRunning {
                let runningSession = self.session
                sessionQueue.async { runningSession.startRunning() }
            }
            await checkPhotosAccess()
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                setProblem("Camera access is off for LiveSequence.", settings: true)
                return
            }
        case .denied, .restricted:
            setProblem("Camera access is off for LiveSequence.", settings: true)
            return
        default:
            break
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        // Start the camera first, so the preview never waits on the Photos prompt.
        setupProblem = nil
        needsSettings = false
        configureSession()

        await checkPhotosAccess()
    }

    /// Photos access is only needed to save, so it's asked for separately
    /// and never blocks the camera.
    func checkPhotosAccess() async {
        var photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if photos == .notDetermined {
            photos = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        if photos == .authorized || photos == .limited {
            if needsSettings { setupProblem = nil; needsSettings = false }
        } else if setupProblem == nil {
            setProblem("Photos access is off, so Live Photos can't be saved.", settings: true)
        }
    }

    private func setProblem(_ text: String, settings: Bool = false) {
        setupProblem = text
        needsSettings = settings
    }

    private func configureSession() {
        session.beginConfiguration()
        // Clear anything left from an earlier failed attempt.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .photo

        let device = Self.bestBackCamera()
        guard let device else {
            setProblem("No camera found on this device.")
            session.commitConfiguration()
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            setProblem("Couldn't open the camera: \(error.localizedDescription)")
            session.commitConfiguration()
            return
        }
        guard session.canAddInput(input) else {
            setProblem("Couldn't connect to the camera.")
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoDevice = device
        setUpZoom(for: device)

        // After a tap, the Camera app goes back to automatic when the scene changes.
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isAEAFLocked else { return }
                self.resetFocusAndExposure()
            }
        }

        // Microphone gives the Live Photos their sound, same as the Camera app.
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        guard session.canAddOutput(photoOutput) else {
            setProblem("Couldn't set up photo capture.")
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        enableLivePhotosIfSupported()

        session.commitConfiguration()
        configured = true
        setupRotation()

        // Report camera failures instead of silently showing a black screen.
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            Task { @MainActor in
                self?.setProblem("Camera stopped: \(error?.localizedDescription ?? "unknown error")")
            }
        }

        let runningSession = self.session
        sessionQueue.async {
            runningSession.startRunning()
            DispatchQueue.main.async { [weak self] in self?.afterSessionStarted() }
        }
    }

    private func enableLivePhotosIfSupported() {
        guard photoOutput.isLivePhotoCaptureSupported else { return }
        photoOutput.isLivePhotoCaptureEnabled = true
        // Auto-trimming cuts motion it thinks is unwanted. Off = full clips,
        // which keeps neighbouring Live Photos overlapping.
        photoOutput.isLivePhotoAutoTrimmingEnabled = false
    }

    /// Some devices only report Live Photo support once the camera is running,
    /// so check again here before giving up.
    private func afterSessionStarted() {
        guard session.isRunning else {
            setProblem("The camera didn't start. Close the app fully and reopen it.")
            return
        }
        if !photoOutput.isLivePhotoCaptureEnabled {
            session.beginConfiguration()
            enableLivePhotosIfSupported()
            session.commitConfiguration()
        }
        if !photoOutput.isLivePhotoCaptureEnabled {
            setProblem("Live Photos aren't supported by this camera setup.")
        }
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

    // MARK: Zoom (like the Camera app)

    /// Zoom in the Camera app's numbers: 1 = main camera, 0.5 = ultra wide, 3 or 5 = telephoto.
    @Published var zoom: CGFloat = 1
    /// The lens buttons to show, e.g. [0.5, 1, 2, 3].
    @Published var zoomPresets: [CGFloat] = [1]
    @Published var zoomRange: ClosedRange<CGFloat> = 1...1
    /// Camera-app zoom = the camera's own zoom factor x this.
    private var zoomMultiplier: CGFloat = 1

    /// The Camera app's back camera: one that switches between ultra wide, wide and
    /// telephoto as you zoom, on phones that have them.
    static func bestBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera,
                                                    .builtInDualCamera, .builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
        }
        return AVCaptureDevice.default(for: .video)
    }

    private func setUpZoom(for device: AVCaptureDevice) {
        // Zoom factors where the next lens takes over (e.g. 2 = main camera, 6 = 3x telephoto).
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let multiplier: CGFloat = hasUltraWide ? 1 / (switchOvers.first ?? 2) : 1
        zoomMultiplier = multiplier
        let minZoom = device.minAvailableVideoZoomFactor * multiplier
        var presets: [CGFloat] = [1]
        if minZoom < 0.9 { presets.append((minZoom * 10).rounded() / 10) }
        presets += switchOvers.map { ($0 * multiplier * 10).rounded() / 10 }.filter { $0 > 1.1 }
        let longestLens = presets.max() ?? 1
        let maxZoom = min(device.maxAvailableVideoZoomFactor * multiplier, max(10, longestLens * 5))
        if maxZoom >= 2, !presets.contains(where: { abs($0 - 2) < 0.3 }) { presets.append(2) }
        zoomPresets = Array(Set(presets)).filter { $0 >= minZoom - 0.01 && $0 <= maxZoom }.sorted()
        zoomRange = minZoom...max(minZoom, maxZoom)
        setZoom(1)
    }

    /// Sets the zoom in Camera-app numbers. animated: a quick glide, as when tapping a lens button.
    func setZoom(_ value: CGFloat, animated: Bool = false) {
        let clamped = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        zoom = clamped
        guard let device = videoDevice else { return }
        let factor = clamped / zoomMultiplier
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let target = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if animated {
                device.ramp(toVideoZoomFactor: target, withRate: 10)
            } else {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = target
            }
        }
    }

    // MARK: Focus and exposure (like the Camera app)

    /// Tap: focus and expose on a point, then keep adjusting.
    /// Long press: focus and expose there once, then hold (AE/AF lock).
    /// The point is in camera coordinates, 0...1 on each axis.
    func focusAndExpose(at point: CGPoint, lock: Bool) {
        isAEAFLocked = lock
        applyFocusAndExposure(at: point, lock: lock, followScene: !lock)
    }

    /// Back to the default: focus and exposure follow the whole scene.
    func resetFocusAndExposure() {
        isAEAFLocked = false
        setExposureBias(0)
        applyFocusAndExposure(at: CGPoint(x: 0.5, y: 0.5), lock: false, followScene: false)
        focusResets += 1
    }

    private func applyFocusAndExposure(at point: CGPoint, lock: Bool, followScene: Bool) {
        guard let device = videoDevice else { return }
        let point = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            // "Auto" modes adjust once and then hold; "continuous" modes keep adjusting.
            let focusMode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) {
                device.focusPointOfInterest = point
                device.focusMode = focusMode
            }
            let exposureMode: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = point
                device.exposureMode = exposureMode
            }
            device.isSubjectAreaChangeMonitoringEnabled = followScene
        }
    }

    /// Brighter or darker, in EV (clamped to -2...+2, like the Camera app).
    func setExposureBias(_ value: Float) {
        var clamped = min(max(value, Self.biasLimits.lowerBound), Self.biasLimits.upperBound)
        if abs(clamped) < 0.05 { clamped = 0 }   // snap back to exactly zero
        exposureBias = clamped
        guard let device = videoDevice else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let bias = min(max(clamped, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(bias, completionHandler: nil)
        }
    }

    // MARK: Sequence capture

    func toggleSequence() {
        isRunningSequence ? stopSequence() : startSequence()
    }

    func startSequence() {
        // Keep the real setup problem on screen rather than replacing it.
        guard setupProblem == nil else { return }
        guard photoOutput.isLivePhotoCaptureEnabled else {
            setProblem("Live Photos aren't ready yet. Try again in a moment.")
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
