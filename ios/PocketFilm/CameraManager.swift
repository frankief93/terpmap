import AVFoundation
import CoreImage
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
        let data: Data
        let thumbnail: UIImage
    }

    // Natural mode: Bayer RAW DNG + fast minimally-processed HEIF, saved as a pair.
    @Published var naturalMode = true
    @Published var rawAvailable = false

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
        refreshOutputDimensions()
        refreshCapabilities()
    }

    /// Portrait-lock both outputs; mirror the preview (never the photo) for the front camera.
    /// Connections only exist after commitConfiguration, so call this after every commit.
    private func updateConnections(front: Bool) {
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            guard let connection else { continue }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
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

        // Prefer the format supporting the largest still (48MP on the 15 Plus main camera).
        do {
            try device.lockForConfiguration()
            if lens == .tele2x {
                device.videoZoomFactor = min(2.0, device.activeFormat.videoMaxZoomFactor)
            }
            device.unlockForConfiguration()
        } catch { }
    }

    private func refreshOutputDimensions() {
        guard let device else { return }
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        // Balanced default: largest option up to ~24MP. 48MP HEICs take seconds to
        // filter and encode; worth a settings toggle later, not the default.
        let balanced = dims
            .filter { Int64($0.width) * Int64($0.height) <= 26_000_000 }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        if let pick = balanced ?? dims.first {
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
        DispatchQueue.main.async {
            self.isoRange = minISO...maxISO
            self.shutterRange = minDur...maxDur
            self.maxZoom = min(Double(format.videoMaxZoomFactor), 10)
            self.rawAvailable = !rawTypes.isEmpty
            self.availableLenses = self.isFrontCamera ? [.wide] : lenses
        }
    }

    private func availableBackLenses() -> [Lens] {
        var lenses: [Lens] = []
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            lenses.append(.ultraWide)
        }
        lenses.append(.wide)
        lenses.append(.tele2x)   // digital 2x crop on the 48MP sensor
        return lenses
    }

    func selectLens(_ newLens: Lens) {
        lens = newLens
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
            let settings: AVCapturePhotoSettings
            if wantRaw, let rawType = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
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
        guard let processed = ctx.processedData else { return }

        let styled = PhotoProcessor.applyLook(ctx.look, toImageData: processed)
        let finalData = styled ?? processed

        PhotoLibrarySaver.save(processedData: finalData, rawData: ctx.rawData) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if !success {
                    self.errorMessage = error ?? "Could not save to Photos."
                }
                if let image = UIImage(data: finalData) {
                    let thumb = image.preparingThumbnail(of: CGSize(width: 400, height: 400)) ?? image
                    self.captures.append(Capture(data: finalData, thumbnail: thumb))
                    if self.captures.count > 50 {
                        self.captures.removeFirst(self.captures.count - 50)
                    }
                    self.onPhotoSaved?(image)
                }
            }
        }
    }
}
