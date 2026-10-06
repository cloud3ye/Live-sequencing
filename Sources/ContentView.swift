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

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(camera: camera)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                if camera.isRunningSequence {
                    pill("Capturing · \(camera.savedThisSequence.count) saved")
                }
                if !camera.status.isEmpty { pill(camera.status) }
                if builder.isBuilding { pill("Building video…") }
                if let message = builder.message { pill(message) }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Random gap")
                            .font(.caption)
                        Text("\(camera.gapRange.lowerBound, specifier: "%.1f")–\(camera.gapRange.upperBound, specifier: "%.1f")s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if camera.isRunningSequence, let gap = camera.lastGap {
                            Text("Next in \(gap, specifier: "%.1f")s")
                                .font(.caption.monospacedDigit())
                        }
                    }
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

                    Button("Make video") {
                        Task { await builder.build(localIdentifiers: camera.savedThisSequence) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(camera.isRunningSequence || camera.inFlight > 0
                              || camera.savedThisSequence.count < 2 || builder.isBuilding)
                    .frame(width: 150, alignment: .trailing)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding()
        }
        .task { await camera.start() }
        .onDisappear { camera.stopSequence() }
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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attachPreview(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Sequences tab

struct SequencesView: View {
    @StateObject private var library = SequenceLibrary()
    @StateObject private var builder = VideoBuilder()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper("Max gap between photos: \(library.maxGap, specifier: "%.1f")s",
                            value: $library.maxGap, in: 1...10, step: 0.5)
                    Toggle("Trim overlapping footage", isOn: $builder.trimOverlaps)
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
                                Task { await builder.build(from: sequence.assets) }
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
