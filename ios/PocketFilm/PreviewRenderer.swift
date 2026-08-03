import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

/// Receives camera frames and renders them with the live look applied, via Metal.
final class PreviewPipeline: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let renderQueue = DispatchQueue(label: "pocketfilm.preview")
    private(set) var currentImage: CIImage?
    var look: FilmLook = FilmLook.all[0]
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
        var image = CIImage(cvPixelBuffer: buffer)
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > previewMaxEdge {
            let s = previewMaxEdge / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        currentImage = LookEngine.shared.apply(look, to: image, forPreview: true)
        DispatchQueue.main.async { [weak self] in
            self?.mtkView?.setNeedsDisplay()
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
