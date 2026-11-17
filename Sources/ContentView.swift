import SwiftUI
import AVFoundation
import Photos
import CoreMotion

struct ContentView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "livephoto") }
            SequencesView()
                .tabItem { Label("Sequences", systemImage: "film.stack") }
        }
    }
}

// MARK: - Capture tab

struct CaptureView: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var builder = VideoBuilder()
    @AppStorage("galleryMode") private var galleryMode = false
    @State private var showGapSettings = false
    @StateObject private var level = LevelModel()
    @State private var isZoomDialShown = false
    @State private var zoomActivity = 0       // bumps on each zoom touch, to restart the hide timer
    @State private var zoomDragStart: CGFloat?
    @State private var pinchStartZoom: CGFloat = 1
    @State private var focusPoint: CGPoint?   // where the yellow square is, in screen points
    @State private var focusActivity = 0      // bumps on each touch, to restart the hide timer

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(
                camera: camera,
                onTap: { viewPoint, cameraPoint in
                    camera.setExposureBias(0)
                    camera.focusAndExpose(at: cameraPoint, lock: false)
                    showFocusSquare(at: viewPoint)
                },
                onLongPress: { viewPoint, cameraPoint in
                    camera.setExposureBias(0)
                    camera.focusAndExpose(at: cameraPoint, lock: true)
                    showFocusSquare(at: viewPoint)
                },
                onVerticalDrag: { distance in
                    // Like the Camera app: once the square is showing, drag up to brighten.
                    guard focusPoint != nil else { return }
                    camera.setExposureBias(camera.exposureBias - Float(distance / 150))
                    focusActivity += 1
                },
                onPinch: { state, scale in
                    if state == .began { pinchStartZoom = camera.zoom }
                    camera.setZoom(pinchStartZoom * scale)
                    showZoomDial()
                }
            )
            .ignoresSafeArea()
            .overlay {
                ZStack {
                    GridLines()
                    if let deviation = level.deviation {
                        LevelIndicator(deviation: deviation)
                    }
                    if let focusPoint {
                        FocusSquare(locked: camera.isAEAFLocked, bias: camera.exposureBias)
                            .position(focusPoint)
                    }
                }
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }

            VStack {
                topBar
                Spacer()
            }

            VStack(spacing: 10) {
                if camera.isRunningSequence {
                    pill("Capturing · \(camera.savedThisSequence.count) saved")
                }
                if let problem = camera.setupProblem {
                    VStack(spacing: 8) {
                        Text(problem)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                        if camera.needsSettings {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                if !camera.status.isEmpty { pill(camera.status) }
                if builder.isBuilding { pill("Building video…") }
                if let message = builder.message { pill(message) }

                if showGapSettings {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Random gap between shots")
                            .font(.callout.weight(.semibold))
                        gapSlider("Shortest", value: $camera.minGap)
                        gapSlider("Longest", value: $camera.maxGap)
                        Text("Clips last about 3 s, so gaps longer than that leave jumps between them: choppier.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                zoomControl

                HStack(alignment: .center) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showGapSettings.toggle() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("Random gap")
                                Image(systemName: showGapSettings ? "chevron.down" : "slider.horizontal.3")
                            }
                            .font(.caption)
                            Text("\(camera.gapRange.lowerBound, specifier: "%.1f")–\(camera.gapRange.upperBound, specifier: "%.1f")s")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if camera.isRunningSequence, let gap = camera.lastGap {
                                Text("Next in \(gap, specifier: "%.1f")s")
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 150, alignment: .leading)

                    Spacer()

                    Button { camera.toggleSequence() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                            RoundedRectangle(cornerRadius: camera.isRunningSequence ? 6 : 30)
                                .fill(camera.isRunningSequence ? .red : .white)
                                .frame(width: camera.isRunningSequence ? 30 : 58,
                                       height: camera.isRunningSequence ? 30 : 58)
                        }
                        .animation(.easeInOut(duration: 0.2), value: camera.isRunningSequence)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Make video") {
                            Task {
                                await builder.build(localIdentifiers: camera.savedThisSequence,
                                                    gallery: galleryMode)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(camera.isRunningSequence || camera.inFlight > 0
                                  || camera.savedThisSequence.count < 2 || builder.isBuilding)
                        Toggle(isOn: $galleryMode) {
                            Text("Gallery").font(.caption)
                        }
                        .fixedSize()
                    }
                    .frame(width: 150, alignment: .trailing)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding()
        }
        .task { await camera.start() }
        // The yellow square fades after a few seconds without touches, unless locked.
        .task(id: focusActivity) {
            guard focusActivity > 0 else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, !camera.isAEAFLocked {
                withAnimation(.easeOut(duration: 0.3)) { focusPoint = nil }
            }
        }
        .onChange(of: camera.focusResets) { focusPoint = nil }
        // The zoom dial goes back to the lens buttons shortly after you let go.
        .task(id: zoomActivity) {
            guard zoomActivity > 0 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled, zoomDragStart == nil {
                withAnimation(.easeOut(duration: 0.25)) { isZoomDialShown = false }
            }
        }
        // Coming back from Settings (or the background) retries the camera.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await camera.start() }
        }
        .onAppear { level.start() }
        .onDisappear {
            camera.stopSequence()
            level.stop()
        }
    }

    private func showFocusSquare(at point: CGPoint) {
        focusPoint = point
        focusActivity += 1
    }

    /// AE/AF LOCK label and exposure readout, along the top like the Camera app.
    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 38, height: 38)   // balances the exposure readout

            Spacer()

            if camera.isAEAFLocked {
                Button { camera.resetFocusAndExposure() } label: {
                    Text("AE/AF LOCK")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 4))
                }
            }

            Spacer()

            // Shows the exposure adjustment when it isn't zero; tap to reset it.
            Button { camera.setExposureBias(0) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plusminus.circle")
                    Text(String(format: "%+.1f", camera.exposureBias))
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(camera.exposureBias == 0 ? Color.white : Color.yellow)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .opacity(camera.exposureBias == 0 ? 0 : 1)
            .disabled(camera.exposureBias == 0)
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Lens buttons (.5, 1, 2, 3...) like the Camera app. Tap one to jump to it; drag
    /// sideways on them, or pinch the preview, for the zoom dial.
    private var zoomControl: some View {
        HStack(spacing: 6) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let active = preset == activeZoomPreset
                Button { camera.setZoom(preset, animated: true) } label: {
                    Text(active ? zoomLabel(camera.zoom) + "×" : zoomLabel(preset, short: true))
                        .font(.system(size: active ? 13 : 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(active ? Color.yellow : Color.white)
                        .frame(width: active ? 40 : 32, height: active ? 40 : 32)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(isZoomDialShown ? 0.001 : 1)
        .overlay(alignment: .bottom) {
            if isZoomDialShown {
                ZoomDial(zoom: camera.zoom, range: camera.zoomRange, presets: camera.zoomPresets)
                    .frame(width: 360, height: 110)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { drag in
                    let start = zoomDragStart ?? camera.zoom
                    if zoomDragStart == nil { zoomDragStart = start }
                    // Drag left to zoom in, as on the Camera app's dial.
                    camera.setZoom(start * exp(-drag.translation.width / 140))
                    showZoomDial()
                }
                .onEnded { _ in
                    zoomDragStart = nil
                    zoomActivity += 1
                }
        )
    }

    private var activeZoomPreset: CGFloat {
        camera.zoomPresets.last(where: { $0 <= camera.zoom + 0.05 }) ?? camera.zoomPresets.first ?? 1
    }

    private func showZoomDial() {
        if !isZoomDialShown {
            withAnimation(.easeOut(duration: 0.15)) { isZoomDialShown = true }
        }
        zoomActivity += 1
    }

    private func gapSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 60, alignment: .leading)
            Slider(value: value, in: CameraModel.gapLimits, step: 0.1)
            Text("\(value.wrappedValue, specifier: "%.1f")s")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CameraModel
    /// Point on screen, and the same point in camera coordinates (0...1).
    var onTap: @MainActor (CGPoint, CGPoint) -> Void = { _, _ in }
    var onLongPress: @MainActor (CGPoint, CGPoint) -> Void = { _, _ in }
    /// Vertical movement since the last call, in points (negative is up).
    var onVerticalDrag: @MainActor (CGFloat) -> Void = { _ in }
    /// Pinch state and scale since the pinch began.
    var onPinch: @MainActor (UIGestureRecognizer.State, CGFloat) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        // Show the whole 4:3 photo, as the Camera app does, so framing and the grid match it.
        view.previewLayer.videoGravity = .resizeAspect
        camera.attachPreview(view.previewLayer)

        let coordinator = context.coordinator
        let longPress = UILongPressGestureRecognizer(target: coordinator,
                                                     action: #selector(Coordinator.longPressed(_:)))
        longPress.minimumPressDuration = 0.6
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: longPress)
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CameraPreview
        init(parent: CameraPreview) { self.parent = parent }

        private func points(_ gesture: UIGestureRecognizer) -> (view: CGPoint, camera: CGPoint)? {
            guard let view = gesture.view as? PreviewView else { return nil }
            let point = gesture.location(in: view)
            return (point, view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let p = points(gesture) else { return }
            parent.onTap(p.view, p.camera)
        }

        @objc func longPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let p = points(gesture) else { return }
            parent.onLongPress(p.view, p.camera)
        }

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            let move = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            parent.onVerticalDrag(move.y)
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            parent.onPinch(gesture.state, gesture.scale)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Rule-of-thirds grid over the 4:3 photo area, like the Camera app's Grid setting.
struct GridLines: View {
    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height >= geo.size.width
            let ratio: CGFloat = portrait ? 3.0 / 4.0 : 4.0 / 3.0       // width / height
            let width = min(geo.size.width, geo.size.height * ratio)
            let height = width / ratio
            let frame = CGRect(x: (geo.size.width - width) / 2, y: (geo.size.height - height) / 2,
                               width: width, height: height)
            Path { path in
                for i in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: frame.minY))
                    path.addLine(to: CGPoint(x: x, y: frame.maxY))
                    let y = frame.minY + frame.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: frame.minX, y: y))
                    path.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.6)
        }
    }
}

/// Zoom as the Camera app writes it: "1", "2", "0.5", "1.4" (or ".5" on a lens button).
func zoomLabel(_ value: CGFloat, short: Bool = false) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded == rounded.rounded() { return String(format: "%.0f", rounded) }
    let text = String(format: "%.1f", rounded)
    return short && rounded < 1 ? String(text.dropFirst()) : text
}

/// The Camera app's zoom dial: an arc of ticks that turns as you zoom, with the
/// lens positions marked and the current zoom above.
struct ZoomDial: View {
    let zoom: CGFloat
    let range: ClosedRange<CGFloat>
    let presets: [CGFloat]

    var body: some View {
        Canvas { context, size in
            let radius = size.width * 1.1
            let top: CGFloat = 40
            let centre = CGPoint(x: size.width / 2, y: top + radius)
            let spread: CGFloat = 0.5              // how far the dial turns per step in zoom
            let maxAngle: CGFloat = 0.6
            func angle(_ value: CGFloat) -> CGFloat { (log(value) - log(zoom)) * spread }
            func point(_ a: CGFloat, _ r: CGFloat) -> CGPoint {
                CGPoint(x: centre.x + r * sin(a), y: centre.y - r * cos(a))
            }

            // Dark band behind the ticks.
            var band = Path()
            band.addArc(center: centre, radius: radius + 8, startAngle: .radians(-.pi / 2 - maxAngle),
                        endAngle: .radians(-.pi / 2 + maxAngle), clockwise: false)
            band.addArc(center: centre, radius: radius - 34, startAngle: .radians(-.pi / 2 + maxAngle),
                        endAngle: .radians(-.pi / 2 - maxAngle), clockwise: true)
            band.closeSubpath()
            context.fill(band, with: .color(.black.opacity(0.5)))

            // Ticks: fine steps below 2x, coarser above; the lens positions are labelled.
            var value = (range.lowerBound * 10).rounded(.up) / 10
            while value <= range.upperBound + 0.001 {
                let a = angle(value)
                if abs(a) < maxAngle {
                    let isPreset = presets.contains { abs($0 - value) < 0.05 }
                    let whole = abs(value - value.rounded()) < 0.05
                    let length: CGFloat = isPreset ? 12 : (whole ? 8 : 5)
                    var tick = Path()
                    tick.move(to: point(a, radius - 6))
                    tick.addLine(to: point(a, radius - 6 - length))
                    context.stroke(tick, with: .color(.white.opacity(isPreset ? 1 : 0.6)),
                                   lineWidth: isPreset ? 1.5 : 1)
                    if isPreset {
                        context.draw(Text(zoomLabel(value)).font(.caption2.weight(.semibold))
                                        .foregroundColor(.white),
                                     at: point(a, radius - 28))
                    }
                }
                value += value < 2 ? 0.1 : (value < 10 ? 0.5 : 1)
                value = (value * 10).rounded() / 10
            }

            // Centre marker and the current zoom.
            var marker = Path()
            marker.move(to: point(0, radius + 6))
            marker.addLine(to: point(0, radius - 22))
            context.stroke(marker, with: .color(.yellow), lineWidth: 2)
            context.draw(Text(zoomLabel(zoom) + "×").font(.footnote.weight(.bold)).foregroundColor(.yellow),
                         at: CGPoint(x: size.width / 2, y: 16))
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }
}

/// The Camera app's level: a line that turns with the horizon and goes solid yellow when straight.
struct LevelIndicator: View {
    let deviation: Double   // radians away from level

    var body: some View {
        let isLevel = abs(deviation) < Double.pi / 180
        ZStack {
            HStack(spacing: 96) {
                Rectangle().frame(width: 34, height: 1.5)
                Rectangle().frame(width: 34, height: 1.5)
            }
            Rectangle()
                .frame(width: isLevel ? 96 : 84, height: 1.5)
                .rotationEffect(.radians(isLevel ? 0 : -deviation))
        }
        .foregroundStyle(isLevel ? Color.yellow : Color.white)
        .shadow(color: .black.opacity(0.4), radius: 1)
        .animation(.easeOut(duration: 0.15), value: isLevel)
    }
}

/// Reads the phone's tilt for the level, like the Camera app's Level setting.
@MainActor
final class LevelModel: ObservableObject {
    /// How far from level, in radians; nil when tilted a lot or held flat.
    @Published var deviation: Double?
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            Task { @MainActor in self?.update(gravity) }
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }

    private func update(_ g: CMAcceleration) {
        // Pointing straight up or down: no horizon to level against.
        guard abs(g.z) < 0.8 else {
            if deviation != nil { deviation = nil }
            return
        }
        let angle = atan2(g.x, -g.y)
        let nearest = (angle / (.pi / 2)).rounded() * (.pi / 2)
        let offset = angle - nearest
        // Like the Camera app, only show it when the phone is close to level.
        let newValue: Double? = abs(offset) < 10 * .pi / 180 ? offset : nil
        if let old = deviation, let new = newValue, abs(old - new) < 0.002 { return }
        if deviation == nil && newValue == nil { return }
        deviation = newValue
    }
}

/// The Camera app's yellow focus square, with the sun showing the exposure adjustment.
struct FocusSquare: View {
    let locked: Bool
    let bias: Float

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.yellow, lineWidth: locked ? 2 : 1.2)
                .frame(width: 76, height: 76)
            // Sun on a short line beside the square; it rises as the picture gets brighter.
            ZStack {
                Rectangle()
                    .fill(Color.yellow.opacity(0.8))
                    .frame(width: 1, height: 70)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.yellow)
                    .background(Circle().fill(Color.black.opacity(0.001)).frame(width: 20, height: 20))
                    .offset(y: CGFloat(-bias) * 15)
            }
            .offset(x: 54)
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
    }
}

// MARK: - Sequences tab

struct SequencesView: View {
    @StateObject private var library = SequenceLibrary()
    @StateObject private var builder = VideoBuilder()
    @AppStorage("galleryMode") private var galleryMode = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper("Max gap between photos: \(library.maxGap, specifier: "%.1f")s",
                            value: $library.maxGap, in: 1...10, step: 0.5)
                    Toggle("Trim overlapping footage", isOn: $builder.trimOverlaps)
                    Toggle(isOn: $galleryMode) {
                        Text("Gallery mode")
                        Text("Frames the video like the Photos app, with the photo strip sliding along the bottom.")
                    }
                }
                if let message = builder.message {
                    Section { Text(message) }
                }
                Section("Sequences") {
                    if !library.status.isEmpty {
                        Text(library.status).foregroundStyle(.secondary)
                    }
                    ForEach(library.sequences) { sequence in
                        HStack(spacing: 12) {
                            Thumbnail(asset: sequence.assets[0])
                            VStack(alignment: .leading) {
                                Text(sequence.start.formatted(date: .abbreviated, time: .shortened))
                                Text("\(sequence.assets.count) Live Photos")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Make video") {
                                Task { await builder.build(from: sequence.assets, gallery: galleryMode) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(builder.isBuilding)
                        }
                    }
                }
            }
            .navigationTitle("Sequences")
            .overlay {
                if builder.isBuilding {
                    ProgressView("Building video…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task { await library.load() }
            .refreshable { await library.load() }
            .onChange(of: library.maxGap) { Task { await library.load() } }
        }
    }
}

struct Thumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: CGSize(width: 150, height: 150),
                                                  contentMode: .aspectFill,
                                                  options: options) { result, _ in
                image = result
            }
        }
    }
}
