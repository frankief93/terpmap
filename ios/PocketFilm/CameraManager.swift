import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// Owns the AVCaptureSession, device configuration, manual controls, and photo capture.
final class CameraManager: NSObject, ObservableObject {

    enum Lens: String, CaseIterable, Identifiable {
        case ultraWide = "0.5x"
        case wide = "1x"
        case tele2x = "2x"
        var id: String { rawValue }
    }

    // MARK: - Published state (main thread)

    @Published var isRunning = false
    @Published var permissionDenied = false
    @Published var isFrontCamera = false
    @Published var lens: Lens = .wide
    @Published var availableLenses: [Lens] = [.wide]
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var isCapturing = false
    @Published var captures: [Capture] = []   // this session's shots, newest last
    @Published var errorMessage: String?

    struct Capture: Identifiable {
        let id = UUID()
        let url: URL
        let thumbnail: UIImage
    }

    override init() {
        super.init()
        // Session shots live in a temp dir (Photos has the real copies); clear leftovers.
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.sessionDirectory,
                                                                    includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    // Natural mode: Bayer RAW DNG + fast minimally-processed HEIF, saved as a pair.
    @Published var naturalMode = true
    @Published var rawAvailable = false

    // Full sensor resolution (48MP where supported). Slower per shot, bigger files.
    @Published var fullResolution = false

    func applyResolution() {
        sessionQueue.async { [weak self] in self?.refreshOutputDimensions() }
    }

    // Manual exposure. When `manualExposure` is false the device runs full auto.
    @Published var manualExposure = false
    @Published var shutterSeconds: Double = 1.0 / 60.0
    @Published var iso: Double = 100
    @Published var evBias: Double = 0
    @Published var manualWB = false
    @Published var wbTemperature: Double = 5200
    @Published var wbTint: Double = 0
    @Published var manualFocus = false
    @Published var focusPosition: Double = 0.5  // 0 = near, 1 = far
    @Published var supportsManualFocus = true   // fixed-focus front cameras can't

    // Device capability ranges, refreshed on device switch.
    @Published var isoRange: ClosedRange<Double> = 34...3000
    @Published var shutterRange: ClosedRange<Double> = 0.00002...0.5
    @Published var maxZoom: Double = 6
    @Published var zoom: Double = 1

    // MARK: - Session plumbing

    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "pocketfilm.session")
    private var currentInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice? { currentInput?.device }
    private var inFlightCaptures: [Int64: CaptureContext] = [:]

    var onPhotoSaved: ((UIImage) -> Void)?

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureAndRun() } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private var configured = false

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configureSession()
                self.configured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
                DispatchQueue.main.async { self.isRunning = self.session.isRunning }
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        attachDevice(position: .back, lens: .wide)

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
        updateConnections(front: false)
        refreshCapabilities()

        // Defer the heavy photo-pipeline upgrades (48MP dimensions + the responsive
        // capture stack, a "lengthy reconfiguration" per the SDK) until after the
        // preview is live — doing them up front costs seconds of black screen.
        sessionQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.upgradePhotoPipeline()
        }
    }

    private func upgradePhotoPipeline() {
        session.beginConfiguration()
        // iOS 17+ responsive-capture stack: ring-buffer zero shutter lag, overlapped
        // capture/processing, and adaptive pacing under rapid fire. Order matters —
        // each tier requires the previous one.
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
        if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = true }
        session.commitConfiguration()
        refreshOutputDimensions()
        refreshCapabilities()
    }

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// Portrait-lock both outputs; mirror the preview (never the photo) for the front camera.
    /// Connections only exist after commitConfiguration, so call this after every commit.
    private func updateConnections(front: Bool) {
        // Ask the device for its portrait angle instead of hardcoding 90 — front
        // sensors on newer hardware (iPhone 17 era) are mounted differently.
        var angle: CGFloat = 90
        if let device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinator = coordinator
            angle = coordinator.videoRotationAngleForHorizonLevelCapture
        }
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            guard let connection else { continue }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        if let preview = videoOutput.connection(with: .video) {
            preview.automaticallyAdjustsVideoMirroring = false
            preview.isVideoMirrored = front
        }
        if let photo = photoOutput.connection(with: .video) {
            photo.automaticallyAdjustsVideoMirroring = false
            photo.isVideoMirrored = false
        }
    }

    // MARK: - Device selection

    private func bestDevice(position: AVCaptureDevice.Position, lens: Lens) -> AVCaptureDevice? {
        if position == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        // Physical devices only: virtual (fused) cameras disable Bayer RAW capture.
        switch lens {
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .wide, .tele2x:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    /// Must be called with the session configuration open or from sessionQueue.
    private func attachDevice(position: AVCaptureDevice.Position, lens: Lens) {
        guard let device = bestDevice(position: position, lens: lens) else { return }
        if let existing = currentInput {
            session.removeInput(existing)
            currentInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = "Camera unavailable: \(error.localizedDescription)" }
            return
        }

        // Always set zoom explicitly: 1x and 2x share the same physical device, and
        // videoZoomFactor persists across input swaps — without this, leaving 2x
        // stays silently zoomed.
        do {
            try device.lockForConfiguration()
            let target: CGFloat = (lens == .tele2x && position == .back)
                ? min(2.0, device.activeFormat.videoMaxZoomFactor)
                : 1.0
            device.videoZoomFactor = target
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoom = Double(target) }
        } catch { }
    }

    private func refreshOutputDimensions() {
        guard let device else { return }
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        func pixels(_ d: CMVideoDimensions) -> Int64 { Int64(d.width) * Int64(d.height) }
        let pick: CMVideoDimensions?
        if fullResolution {
            pick = dims.max { pixels($0) < pixels($1) }
        } else {
            // Balanced default: largest option up to ~24MP. 48MP HEICs take
            // noticeably longer to filter and encode.
            pick = dims.filter { pixels($0) <= 26_000_000 }.max { pixels($0) < pixels($1) }
                ?? dims.min { pixels($0) < pixels($1) }
        }
        if let pick {
            photoOutput.maxPhotoDimensions = pick
        }
    }

    private func refreshCapabilities() {
        guard let device else { return }
        let format = device.activeFormat
        let minISO = Double(format.minISO), maxISO = Double(format.maxISO)
        let minDur = max(format.minExposureDuration.seconds, 0.00002)
        let maxDur = min(format.maxExposureDuration.seconds, 1.0)
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let lenses = availableBackLenses()
        let manualFocusOK = device.isLockingFocusWithCustomLensPositionSupported
        DispatchQueue.main.async {
            self.isoRange = minISO...maxISO
            self.shutterRange = minDur...maxDur
            self.maxZoom = min(Double(format.videoMaxZoomFactor), 10)
            self.rawAvailable = !rawTypes.isEmpty
            self.availableLenses = self.isFrontCamera ? [.wide] : lenses
            self.supportsManualFocus = manualFocusOK
            if !manualFocusOK { self.manualFocus = false }
        }
    }

    private func availableBackLenses() -> [Lens] {
        var lenses: [Lens] = []
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            lenses.append(.ultraWide)
        }
        lenses.append(.wide)
        // 2x is only a quality crop when the main sensor is 48MP-class; on 12MP
        // mains it would be a mushy ~3MP digital zoom, so hide it there.
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           wide.activeFormat.supportedMaxPhotoDimensions.contains(where: { $0.width >= 7000 }) {
            lenses.append(.tele2x)
        }
        return lenses
    }

    /// Which chip should light up, based on the actual camera state — pinching
    /// between 1x and 2x moves the highlight even though no chip was tapped.
    var activeChip: Lens {
        if isFrontCamera { return .wide }
        if lens == .ultraWide { return .ultraWide }
        return zoom >= 1.75 ? .tele2x : .wide
    }

    /// Zoom in iPhone-convention units: the ultra-wide's native 1.0 shows as 0.5x.
    var displayZoom: Double {
        (lens == .ultraWide ? 0.5 : 1.0) * zoom
    }

    func selectLens(_ newLens: Lens) {
        let wasUltraWide = lens == .ultraWide
        lens = newLens
        guard !isFrontCamera else { return }
        if !wasUltraWide && newLens != .ultraWide {
            // 1x and 2x share the same physical camera — a zoom change, not a
            // device swap, so it's instant.
            setZoom(newLens == .tele2x ? 2 : 1)
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.attachDevice(position: .back, lens: newLens)
            self.session.commitConfiguration()
            self.updateConnections(front: false)
            self.refreshOutputDimensions()
            self.refreshCapabilities()
            self.reapplyManualSettings()
        }
    }

    func flipCamera() {
        let toFront = !isFrontCamera
        isFrontCamera = toFront
        if toFront { lens = .wide }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.attachDevice(position: toFront ? .front : .back, lens: self.lens)
            self.session.commitConfiguration()
            self.updateConnections(front: toFront)
            self.refreshOutputDimensions()
            self.refreshCapabilities()
            self.reapplyManualSettings()
        }
    }

    // MARK: - Manual controls

    func applyExposure() {
        let manual = manualExposure
        let duration = shutterSeconds
        let isoValue = iso
        let bias = evBias
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if manual, device.isExposureModeSupported(.custom) {
                    let dur = CMTime(seconds: min(max(duration, device.activeFormat.minExposureDuration.seconds),
                                                  device.activeFormat.maxExposureDuration.seconds),
                                     preferredTimescale: 1_000_000)
                    let clampedISO = Float(min(max(isoValue, Double(device.activeFormat.minISO)),
                                               Double(device.activeFormat.maxISO)))
                    device.setExposureModeCustom(duration: dur, iso: clampedISO, completionHandler: nil)
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    let clamped = Float(min(max(bias, Double(device.minExposureTargetBias)),
                                            Double(device.maxExposureTargetBias)))
                    device.setExposureTargetBias(clamped, completionHandler: nil)
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func applyWhiteBalance() {
        let manual = manualWB
        let temp = Float(wbTemperature)
        let tint = Float(wbTint)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if manual, device.isWhiteBalanceModeSupported(.locked) {
                    var gains = device.deviceWhiteBalanceGains(
                        for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temp, tint: tint))
                    let maxGain = device.maxWhiteBalanceGain
                    gains.redGain = min(max(gains.redGain, 1), maxGain)
                    gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                    gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func applyFocus() {
        let manual = manualFocus
        let position = Float(focusPosition)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if manual, device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    private func reapplyManualSettings() {
        if manualExposure { applyExposure() }
        if manualWB { applyWhiteBalance() }
        if manualFocus { applyFocus() }
    }

    func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.manualExposure = false
                    self.manualFocus = false
                }
            } catch { }
        }
    }

    func setZoom(_ factor: Double) {
        let clamped = min(max(factor, 1), maxZoom)
        zoom = clamped
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = CGFloat(clamped)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    // MARK: - Capture

    private struct CaptureContext {
        var look: FilmLook
        var rawData: Data?
        var processedData: Data?
    }

    func capturePhoto(look: FilmLook) {
        guard !isCapturing else { return }
        isCapturing = true
        let wantRaw = naturalMode && rawAvailable && !isFrontCamera
        let flash = flashMode

        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Bayer RAW requires zoom to be exactly 1.0 — the SDK throws otherwise.
            // When zoomed (2x chip or pinch), quietly fall back to processed-only.
            let zoomNeutral = (self.device?.videoZoomFactor ?? 1) == 1
            let useRaw = wantRaw && zoomNeutral
            let settings: AVCapturePhotoSettings
            if useRaw, let rawType = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: rawType,
                                                      processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
                }
            } else if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            // Natural mode keeps Apple's multi-frame fusion light; standard mode lets it work.
            settings.photoQualityPrioritization = self.naturalMode ? .speed : .quality
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            self.inFlightCaptures[settings.uniqueID] = CaptureContext(look: look)
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            if let error { DispatchQueue.main.async { self.errorMessage = "Capture failed: \(error.localizedDescription)" } }
            return
        }
        let id = photo.resolvedSettings.uniqueID
        sessionQueue.async { [weak self] in
            guard let self, var ctx = self.inFlightCaptures[id] else { return }
            if photo.isRawPhoto {
                ctx.rawData = data
            } else {
                ctx.processedData = data
            }
            self.inFlightCaptures[id] = ctx
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let id = resolvedSettings.uniqueID
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let ctx = self.inFlightCaptures.removeValue(forKey: id)
            // Re-arm the shutter as soon as the sensor is done; processing continues below.
            DispatchQueue.main.async { self.isCapturing = false }
            guard let ctx else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                self.finishCapture(ctx)
            }
        }
    }

    private func finishCapture(_ ctx: CaptureContext) {
        guard let processed = ctx.processedData else {
            // The HEIF leg failed; salvage the RAW so the shot isn't lost.
            if let raw = ctx.rawData {
                PhotoLibrarySaver.saveRawOnly(raw) { [weak self] success, error in
                    DispatchQueue.main.async {
                        if !success { self?.errorMessage = error ?? "Could not save RAW to Photos." }
                    }
                }
            }
            return
        }

        let styled = PhotoProcessor.applyLook(ctx.look, toImageData: processed)
        let finalData = styled ?? processed
        // Thumbnail + temp file happen here, off the main thread; the gallery keeps
        // only a URL and a small thumbnail in memory, never full-res data.
        let thumbnail = Self.downsampledImage(finalData, maxPixel: 400)
        let fileURL = Self.writeSessionFile(finalData)

        PhotoLibrarySaver.save(processedData: finalData, rawData: ctx.rawData) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if !success {
                    self.errorMessage = error ?? "Could not save to Photos."
                }
                if let thumbnail, let fileURL {
                    self.captures.append(Capture(url: fileURL, thumbnail: thumbnail))
                    if self.captures.count > 50 {
                        self.captures.removeFirst(self.captures.count - 50)
                    }
                    self.onPhotoSaved?(thumbnail)
                }
            }
        }
    }

    static let sessionDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketFilmSession", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func writeSessionFile(_ data: Data) -> URL? {
        let url = sessionDirectory.appendingPathComponent("\(UUID().uuidString).heic")
        do { try data.write(to: url); return url } catch { return nil }
    }

    private static func downsampledImage(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}
