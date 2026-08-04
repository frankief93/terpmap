import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

/// Receives camera frames and renders them with the live look applied, via Metal.
final class PreviewPipeline: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published private(set) var hasFrame = false
    @Published private(set) var frameMs: Double = 0   // smoothed inter-frame time

    private var lastFrameAt: CFAbsoluteTime = 0
    private var frameDeltaEMA: Double = 0
    private var framesSincePublish = 0

    private let renderQueue = DispatchQueue(label: "pocketfilm.preview")
    private let stateLock = NSLock()

    // currentImage is written on renderQueue and read on main (draw); look is the
    // reverse. Both go through the lock — unsynchronized access is a real race.
    private var _currentImage: CIImage?
    var currentImage: CIImage? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _currentImage
    }

    private var _look: FilmLook = FilmLook.all[0]
    var look: FilmLook {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _look }
        set { stateLock.lock(); _look = newValue; stateLock.unlock() }
    }

    // Coalesce redraw requests: during app launch the main thread is busy and
    // per-frame setNeedsDisplay calls pile into a backlog that plays out as a
    // slideshow. One pending request at a time is enough.
    private var displayRequestPending = false

    weak var mtkView: MTKView?

    /// Long edge of the preview image fed through the filter chain. Filtering at
    /// full sensor resolution 30x/second is what makes a live preview crawl.
    private let previewMaxEdge: CGFloat = 1600

    func attach(to output: AVCaptureVideoDataOutput) {
        output.setSampleBufferDelegate(self, queue: renderQueue)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if lastFrameAt > 0 {
            let delta = now - lastFrameAt
            frameDeltaEMA = frameDeltaEMA == 0 ? delta : frameDeltaEMA * 0.9 + delta * 0.1
        }
        lastFrameAt = now
        framesSincePublish += 1
        if framesSincePublish >= 15 {
            framesSincePublish = 0
            let ms = frameDeltaEMA * 1000
            DispatchQueue.main.async { [weak self] in self?.frameMs = ms }
        }

        var image = CIImage(cvPixelBuffer: buffer)
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > previewMaxEdge {
            let s = previewMaxEdge / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let rendered = LookEngine.shared.apply(look, to: image, forPreview: true)
        stateLock.lock()
        _currentImage = rendered
        let shouldRequest = !displayRequestPending
        displayRequestPending = true
        stateLock.unlock()
        guard shouldRequest else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); self.displayRequestPending = false; self.stateLock.unlock()
            if !self.hasFrame {
                self.hasFrame = true
                PerfClock.firstFrame = Date().timeIntervalSince(PerfClock.appStart)
            }
            self.mtkView?.setNeedsDisplay()
        }
    }
}

/// SwiftUI wrapper around an MTKView driven by the preview pipeline.
struct MetalPreviewView: UIViewRepresentable {
    let pipeline: PreviewPipeline

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.backgroundColor = .black
        view.delegate = context.coordinator
        pipeline.mtkView = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) { }

    func makeCoordinator() -> Renderer { Renderer(pipeline: pipeline) }

    final class Renderer: NSObject, MTKViewDelegate {
        private let pipeline: PreviewPipeline
        private let ciContext: CIContext
        private let commandQueue: MTLCommandQueue?
        private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

        init(pipeline: PreviewPipeline) {
            self.pipeline = pipeline
            let device = MTLCreateSystemDefaultDevice()
            self.commandQueue = device?.makeCommandQueue()
            if let device {
                self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            } else {
                self.ciContext = CIContext()
            }
            super.init()

            // Warm up: run the full filter chain (halation included) through this
            // context on a dummy image so the GPU kernels compile now, not during
            // the first seconds of live preview.
            let context = ciContext
            DispatchQueue.global(qos: .userInitiated).async {
                let dummy = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
                let warmed = LookEngine.shared.apply(FilmLook.all[1], to: dummy)
                _ = context.createCGImage(warmed, from: warmed.extent)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            guard let image = pipeline.currentImage,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer()
            else { return }

            let drawableSize = view.drawableSize
            let scale = max(drawableSize.width / image.extent.width,
                            drawableSize.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let originX = (scaled.extent.width - drawableSize.width) / 2 + scaled.extent.origin.x
            let originY = (scaled.extent.height - drawableSize.height) / 2 + scaled.extent.origin.y
            let cropped = scaled.cropped(to: CGRect(x: originX, y: originY,
                                                    width: drawableSize.width, height: drawableSize.height))
            let positioned = cropped.transformed(by: CGAffineTransform(translationX: -originX, y: -originY))

            ciContext.render(positioned,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: colorSpace)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
