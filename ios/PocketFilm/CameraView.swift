import AVFoundation
import AVKit
import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var lookStore = LookStore.shared
    @StateObject private var pipeline = PreviewPipeline()
    @AppStorage("showGrid") private var showGrid = false
    @State private var showManualPanel = false
    @State private var showReview = false
    @State private var flashOpacity: Double = 0
    @State private var pinchBaseZoom: Double = 1
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            viewfinder
            controlDeck
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .onAppear {
            pipeline.attach(to: camera.videoOutput)
            pipeline.look = lookStore.effectiveLook
            camera.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else if phase == .background { camera.stop() }
        }
        .onReceive(lookStore.objectWillChange) { _ in
            DispatchQueue.main.async { pipeline.look = lookStore.effectiveLook }
        }
        .sheet(isPresented: $showReview) {
            ReviewSheet(camera: camera)
        }
        .alert("Something went wrong", isPresented: .init(
            get: { camera.errorMessage != nil },
            set: { if !$0 { camera.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                if camera.permissionDenied {
                    permissionView
                } else {
                    MetalPreviewView(pipeline: pipeline)
                        .onTapGesture(coordinateSpace: .local) { point in
                            // Convert view point to device point-of-interest (0..1, landscape sensor space).
                            let p = CGPoint(x: point.y / geo.size.height, y: 1 - point.x / geo.size.width)
                            camera.focusAndExpose(at: p)
                            Haptics.tap()
                        }
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    camera.setZoom(pinchBaseZoom * value.magnification)
                                }
                                .onEnded { _ in pinchBaseZoom = camera.zoom }
                        )
                }

                if showGrid { gridOverlay }

                Color.white
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)

                VStack {
                    topBar
                    Spacer()
                    if camera.isCapturing {
                        ProgressView()
                            .tint(.white)
                            .padding(.bottom, 18)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 4)
        .onCameraCaptureEvent { event in
            if event.phase == .ended { shoot() }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                camera.flashMode = camera.flashMode == .off ? .on : (camera.flashMode == .on ? .auto : .off)
                Haptics.tap()
            } label: {
                Image(systemName: camera.flashMode == .off ? "bolt.slash"
                      : camera.flashMode == .on ? "bolt.fill" : "bolt.badge.automatic")
                    .chipStyle()
            }

            Spacer()

            Text(lookStore.selectedLook.name.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.black.opacity(0.45), in: Capsule())

            Spacer()

            Button {
                showGrid.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: "grid").chipStyle(active: showGrid)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .foregroundStyle(.white)
    }

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.3), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.on.rectangle").font(.largeTitle)
            Text("PocketFilm needs the camera").font(.headline)
            Text("Everything stays on your device. Enable camera access in Settings.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .foregroundStyle(.white)
    }

    // MARK: - Control deck

    private var controlDeck: some View {
        VStack(spacing: 10) {
            LookPickerBar(lookStore: lookStore)

            if showManualPanel {
                ManualPanel(camera: camera, lookStore: lookStore)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                Button {
                    if !camera.captures.isEmpty { showReview = true }
                } label: {
                    Group {
                        if let thumb = camera.captures.last?.thumbnail {
                            Image(uiImage: thumb).resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06))
                        }
                    }
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2)))
                }

                Spacer()

                shutterButton

                Spacer()

                VStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy) { showManualPanel.toggle() }
                        Haptics.tap()
                    } label: {
                        Image(systemName: "dial.high").chipStyle(active: showManualPanel)
                    }
                    Button {
                        camera.flipCamera()
                        Haptics.tap()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").chipStyle()
                    }
                }
            }
            .padding(.horizontal, 26)

            lensBar
        }
        .padding(.vertical, 12)
        .foregroundStyle(.white)
    }

    private var shutterButton: some View {
        Button(action: shoot) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(.white).frame(width: 60, height: 60)
                    .scaleEffect(camera.isCapturing ? 0.8 : 1)
                    .animation(.spring(duration: 0.2), value: camera.isCapturing)
            }
        }
        .disabled(camera.isCapturing)
    }

    private var lensBar: some View {
        HStack(spacing: 10) {
            ForEach(camera.availableLenses) { lens in
                Button {
                    camera.selectLens(lens)
                    Haptics.tap()
                } label: {
                    Text(lens.rawValue)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(camera.lens == lens ? Color.orange : Color.white.opacity(0.08),
                                    in: Capsule())
                        .foregroundStyle(camera.lens == lens ? .black : .white)
                }
            }
            if camera.naturalMode {
                Text(camera.rawAvailable ? "RAW+" : "NATURAL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.leading, 6)
            }
        }
    }

    private func shoot() {
        guard !camera.isCapturing else { return }
        Haptics.shutter()
        withAnimation(.easeIn(duration: 0.05)) { flashOpacity = 0.85 }
        withAnimation(.easeOut(duration: 0.25).delay(0.06)) { flashOpacity = 0 }
        camera.capturePhoto(look: lookStore.effectiveLook)
    }
}

// MARK: - Small helpers

extension Image {
    func chipStyle(active: Bool = false) -> some View {
        self
            .font(.system(size: 16, weight: .medium))
            .frame(width: 42, height: 42)
            .background(active ? Color.orange.opacity(0.9) : Color.black.opacity(0.45), in: Circle())
            .foregroundStyle(active ? .black : .white)
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func shutter() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
