import SwiftUI
import MetalKit
import CoreImage

/// Desenha a imagem da câmera, já com o look aplicado, usando a GPU.
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let ciContext: CIContext
    private let commandQueue: MTLCommandQueue
    private let lock = NSLock()
    private var latestImage: CIImage?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    weak var view: MTKView?

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal não disponível")
        }
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    /// Chamado pela câmera a cada quadro (de qualquer thread).
    func display(_ image: CIImage) {
        lock.lock()
        latestImage = image
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.view?.setNeedsDisplay()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let image = latestImage
        lock.unlock()

        guard let image,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let size = view.drawableSize
        guard size.width > 0, size.height > 0, image.extent.width > 0, image.extent.height > 0 else { return }

        // Preenche a tela inteira (aspect fill), centralizado.
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        var scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (size.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let dy = (size.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        scaled = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        let bounds = CGRect(origin: .zero, size: size)
        let background = CIImage(color: .black).cropped(to: bounds)
        let finalImage = scaled.composited(over: background)

        ciContext.render(finalImage,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: bounds,
                         colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct MetalPreview: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.backgroundColor = .black
        view.delegate = renderer
        renderer.view = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
