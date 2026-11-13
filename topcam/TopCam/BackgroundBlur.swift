import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// Opções do desfoque de fundo (abertura simulada, como numa lente de verdade).
struct BlurOptions {
    /// f/1.4 = muito desfoque · f/16 = quase nada.
    var aperture: Double
    /// true = deixa o fundo nítido e desfoca o assunto ("focar outro lugar").
    var focusOnBackground: Bool = false
}

/// Máscaras do assunto: uma por pessoa (até 4) ou por objeto (comida, pet, produto).
struct SubjectMasks {
    let instances: [Int]
    let masks: [Int: CIImage]
    let labelMap: [UInt8]
    let mapWidth: Int
    let mapHeight: Int
    let peopleMode: Bool

    /// Qual pessoa/objeto está no ponto tocado (0 a 1, origem no canto de cima).
    func instance(at p: CGPoint) -> Int? {
        guard mapWidth > 0, mapHeight > 0 else { return nil }
        let x = min(max(Int(p.x * CGFloat(mapWidth)), 0), mapWidth - 1)
        let y = min(max(Int(p.y * CGFloat(mapHeight)), 0), mapHeight - 1)
        let v = Int(labelMap[y * mapWidth + x])
        return v == 0 ? nil : v
    }

    func combined(_ selected: Set<Int>) -> CIImage? {
        var out: CIImage?
        for i in selected.sorted() {
            guard let m = masks[i] else { continue }
            if let current = out {
                out = m.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: current])
            } else {
                out = m
            }
        }
        return out
    }

    var all: CIImage? { combined(Set(instances)) }
}

enum BackgroundBlur {
    /// Separa o assunto do fundo. Primeiro procura pessoas; se não achar, pega o assunto principal.
    static func segment(_ image: CIImage, maxSide: CGFloat, context: CIContext, perInstance: Bool = true) -> SubjectMasks? {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let scale = min(1, maxSide / max(e.width, e.height))
        let small = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
        return segment(cgImage: cg, perInstance: perInstance)
    }

    static func segment(cgImage: CGImage, perInstance: Bool) -> SubjectMasks? {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        var observation: VNInstanceMaskObservation?
        var peopleMode = true

        let people = VNGeneratePersonInstanceMaskRequest()
        try? handler.perform([people])
        if let first = people.results?.first, !first.allInstances.isEmpty {
            observation = first
        } else {
            peopleMode = false
            let subject = VNGenerateForegroundInstanceMaskRequest()
            try? handler.perform([subject])
            if let first = subject.results?.first, !first.allInstances.isEmpty {
                observation = first
            }
        }
        guard let obs = observation else { return nil }

        var masks: [Int: CIImage] = [:]
        let ids = obs.allInstances.sorted()
        if perInstance {
            for i in ids {
                if let buffer = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: handler) {
                    masks[i] = CIImage(cvPixelBuffer: buffer)
                }
            }
        } else if let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
            // Visor ao vivo: uma máscara só, mais rápido.
            let first = ids.first ?? 1
            return SubjectMasks(instances: [first], masks: [first: CIImage(cvPixelBuffer: buffer)],
                                labelMap: [], mapWidth: 0, mapHeight: 0, peopleMode: peopleMode)
        }

        // Mapa de quem é quem, para escolher tocando na foto.
        let map = obs.instanceMask
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var labels = [UInt8](repeating: 0, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(map) {
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    labels[y * w + x] = p[y * rowBytes + x]
                }
            }
        }
        return SubjectMasks(instances: ids, masks: masks, labelMap: labels,
                            mapWidth: w, mapHeight: h, peopleMode: peopleMode)
    }

    /// Desfoca o fundo (ou o assunto) com bordas suaves, como lente de abertura grande.
    static func apply(to image: CIImage, mask: CIImage, options: BlurOptions) -> CIImage {
        let ext = image.extent
        let ms = mask.extent
        guard ext.width > 0, ms.width > 0, ms.height > 0 else { return image }
        let maxSide = max(ext.width, ext.height)

        // Máscara no tamanho da foto, com borda suave (cabelo e ombros sem cara de recorte).
        let subject = mask
            .transformed(by: CGAffineTransform(translationX: -ms.minX, y: -ms.minY))
            .transformed(by: CGAffineTransform(scaleX: ext.width / ms.width, y: ext.height / ms.height))
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(maxSide) * 0.0022)
            .cropped(to: ext)
        let inverted = subject.applyingFilter("CIColorInvert")
        let sharpMask = options.focusOnBackground ? inverted : subject
        let blurMask = options.focusOnBackground ? subject : inverted

        let strength = 8.0 / max(options.aperture, 1.0)
        let radius = Float(min(Double(maxSide) * 0.006 * strength, Double(maxSide) * 0.03))
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = image.clampedToExtent()
        blur.mask = blurMask
        blur.radius = radius
        guard let blurred = blur.outputImage?.cropped(to: ext) else { return image }

        // Assunto 100% nítido por cima do fundo desfocado.
        let keep = CIFilter.blendWithMask()
        keep.inputImage = image
        keep.backgroundImage = blurred
        keep.maskImage = sharpMask
        return keep.outputImage?.cropped(to: ext) ?? blurred
    }
}

/// Enquadramentos prontos para redes sociais (corte ao salvar).
enum FrameAspect: String, CaseIterable, Identifiable {
    case off = "Livre"
    case feed = "4:5 Feed"
    case story = "9:16 Reels/Stories"
    case square = "1:1 Quadrado"
    case classic = "2:3 Clássico"

    var id: String { rawValue }

    /// Lado menor ÷ lado maior.
    var ratio: CGFloat? {
        switch self {
        case .off: return nil
        case .feed: return 4.0 / 5.0
        case .story: return 9.0 / 16.0
        case .square: return 1
        case .classic: return 2.0 / 3.0
        }
    }

    var short: String {
        switch self {
        case .off: return "Livre"
        case .feed: return "4:5"
        case .story: return "9:16"
        case .square: return "1:1"
        case .classic: return "2:3"
        }
    }

    /// Corta no centro, seguindo a posição da foto (em pé ou deitada).
    static func crop(_ image: CIImage, ratio r: CGFloat) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let target = e.width <= e.height ? r : 1 / r   // largura ÷ altura
        var rect = e
        if e.width / e.height > target {
            let w = e.height * target
            rect = CGRect(x: e.midX - w / 2, y: e.minY, width: w, height: e.height)
        } else {
            let h = e.width / target
            rect = CGRect(x: e.minX, y: e.midY - h / 2, width: e.width, height: h)
        }
        let r2 = rect.integral.intersection(e)
        return image.cropped(to: r2).transformed(by: CGAffineTransform(translationX: -r2.minX, y: -r2.minY))
    }
}

enum PeakColor: String, CaseIterable, Identifiable {
    case green = "Verde", red = "Vermelho", blue = "Azul", white = "Branco"
    var id: String { rawValue }
    var ciColor: CIColor {
        switch self {
        case .green: return CIColor(red: 0.22, green: 1, blue: 0.42)
        case .red: return CIColor(red: 1, green: 0.2, blue: 0.2)
        case .blue: return CIColor(red: 0.25, green: 0.55, blue: 1)
        case .white: return CIColor(red: 1, green: 1, blue: 1)
        }
    }
}
