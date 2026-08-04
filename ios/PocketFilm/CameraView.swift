import AVFoundation
import AVKit
import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var lookStore = LookStore.shared
    @StateObject private var pipeline = PreviewPipeline()
    @AppStorage("showGrid") private var showGrid = false
    @AppStorage("showPerfHUD") private var showPerfHUD = false
    @State private var showManualPanel = false
    @State private var showReview = false
    @State private var flashOpacity: Double = 0
    @State private var pinchBaseZoom: Double = 1

    private struct Reticle { let point: CGPoint; let id: UUID }
    @State private var reticle: Reticle?
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
        .onChange(of: camera.lens) {
            pinchBaseZoom = camera.zoom
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
        ZStack {
            Color.black
            if camera.permissionDenied {
                permissionView
            } else {
                previewArea
                if !pipeline.hasFrame {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Opening camera…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Color.white
                .opacity(flashOpacity)
                .allowsHitTesting(false)

            VStack {
                topBar
                if showPerfHUD { perfHUD }
                Spacer()
                if camera.isCapturing {
                    ProgressView()
                        .tint(.white)
                        .padding(.bottom, 18)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 4)
        .onCameraCaptureEvent { event in
            if event.phase == .ended { shoot() }
        }
    }

    /// The camera frame at its true 3:4 aspect — what you see is exactly what gets
    /// captured. No hidden crop; the full wide selfie field of view is visible.
    private var previewArea: some View {
        GeometryReader { pgeo in
            ZStack {
                MetalPreviewView(pipeline: pipeline)
                    .onTapGesture(coordinateSpace: .local) { point in
                        // Full frame is visible, so the mapping to the sensor's
                        // landscape point-of-interest space is direct; the front
                        // preview is mirrored, so un-mirror its axis.
                        let nx = point.x / pgeo.size.width
                        let ny = point.y / pgeo.size.height
                        let p = camera.isFrontCamera
                            ? CGPoint(x: ny, y: nx)
                            : CGPoint(x: ny, y: 1 - nx)
                        camera.focusAndExpose(at: p)
                        Haptics.tap()

                        let id = UUID()
                        withAnimation(.easeOut(duration: 0.15)) {
                            reticle = Reticle(point: point, id: id)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                            if reticle?.id == id {
                                withAnimation(.easeOut(duration: 0.3)) { reticle = nil }
                            }
                        }
                    }
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                camera.setZoom(pinchBaseZoom * value.magnification)
                            }
                            .onEnded { _ in
                                pinchBaseZoom = camera.zoom
                                camera.lens = camera.activeChip
                            }
                    )

                if showGrid { gridOverlay }

                if let reticle {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.yellow.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 74, height: 74)
                        .position(reticle.point)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 1.35).combined(with: .opacity))
                }
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .onLongPressGesture {
                    showPerfHUD.toggle()
                    Haptics.tap()
                }

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
                let active = camera.activeChip == lens
                Button {
                    camera.selectLens(lens)
                    Haptics.tap()
                } label: {
                    Text(active ? zoomLabel(camera.displayZoom) : lens.rawValue)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(active ? Color.orange : Color.white.opacity(0.08),
                                    in: Capsule())
                        .foregroundStyle(active ? .black : .white)
                }
            }
            Button {
                camera.naturalMode.toggle()
                Haptics.tap()
            } label: {
                Text(camera.naturalMode ? (camera.rawAvailable ? "RAW+" : "NATURAL") : "STD")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(camera.naturalMode ? Color.orange.opacity(0.22) : Color.white.opacity(0.07),
                                in: Capsule())
                    .foregroundStyle(camera.naturalMode ? .orange : .white.opacity(0.6))
            }
            .padding(.leading, 6)
        }
    }

    private var perfHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            let ms = pipeline.frameMs
            Text(String(format: "preview  %.0f ms/frame  (~%.0f fps)", ms, ms > 0 ? 1000 / ms : 0))
            Text(String(format: "open → camera   %.2fs", PerfClock.sessionRunning ?? 0))
            Text(String(format: "camera → frame  %.2fs",
                        max(0, (PerfClock.firstFrame ?? 0) - (PerfClock.sessionRunning ?? 0))))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.yellow)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .allowsHitTesting(false)
    }

    private func zoomLabel(_ z: Double) -> String {
        let rounded = (z * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))x" : String(format: "%.1fx", rounded)
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
