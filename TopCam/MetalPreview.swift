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
    /// Retângulo (normalizado 0-1, origem no topo) onde a imagem aparece na tela.
    private(set) var frameInView = CGRect(x: 0, y: 0.11, width: 1, height: 0.75)
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

        // Mostra o quadro inteiro (o que você vê é o que sai), alinhado perto do topo.
        let scale = min(size.width / image.extent.width, size.height / image.extent.height)
        var scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let topOffset = min(size.height * 0.11, max(0, size.height - scaled.extent.height))
        let dx = (size.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let dy = size.height - topOffset - scaled.extent.height - scaled.extent.origin.y
        scaled = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        lock.lock()
        // Guarda onde a imagem ficou na tela (0-1), para o toque de foco e as guias.
        frameInView = CGRect(x: (size.width - scaled.extent.width) / 2 / size.width,
                             y: topOffset / size.height,
                             width: scaled.extent.width / size.width,
                             height: scaled.extent.height / size.height)
        lock.unlock()

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
