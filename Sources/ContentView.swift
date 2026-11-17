import SwiftUI
import AVFoundation
import Photos

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
    @AppStorage("showGrid") private var showGrid = false
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
                }
            )
            .ignoresSafeArea()
            .overlay {
                ZStack {
                    if showGrid { GridLines() }
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
        // Coming back from Settings (or the background) retries the camera.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await camera.start() }
        }
        .onDisappear { camera.stopSequence() }
    }

    private func showFocusSquare(at point: CGPoint) {
        focusPoint = point
        focusActivity += 1
    }

    /// Grid switch, AE/AF LOCK label and exposure readout, along the top like the Camera app.
    private var topBar: some View {
        HStack {
            Button { showGrid.toggle() } label: {
                Image(systemName: "grid")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(showGrid ? Color.yellow : Color.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(showGrid ? "Hide grid" : "Show grid")

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
