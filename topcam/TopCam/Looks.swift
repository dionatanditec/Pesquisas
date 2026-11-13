import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import simd

/// Os looks (filtros) do TopCam. Todos feitos com Core Image, rodando na GPU.
enum Look: String, CaseIterable, Identifiable {
    case original, natural, vivo, retrato, paisagem, produto, comida, noite, pb
    case cinema, filme, dourado, neon, lut

    var id: String { rawValue }

    /// Looks que aparecem no seletor (o "Meu LUT" só aparece depois de importar um).
    static var available: [Look] {
        allCases.filter { $0 != .lut || LUTStore.shared.hasLUT }
    }

    var title: String {
        switch self {
        case .original: return "Original"
        case .natural: return "Natural"
        case .vivo: return "Vivo"
        case .retrato: return "Retrato"
        case .paisagem: return "Paisagem"
        case .produto: return "Produto"
        case .comida: return "Comida"
        case .noite: return "Noite"
        case .pb: return "P&B"
        case .cinema: return "Cinema"
        case .filme: return "Filme"
        case .dourado: return "Dourado"
        case .neon: return "Neon"
        case .lut: return "Meu LUT"
        }
    }

    /// Explicação curta que aparece embaixo do look escolhido.
    var subtitle: String {
        switch self {
        case .original: return "Original: sem nenhum ajuste, do jeito que a câmera viu"
        case .natural: return "Natural: serve para tudo, luz equilibrada e cor fiel"
        case .vivo: return "Vivo: cores fortes, para eventos, festas, animais e redes"
        case .retrato: return "Retrato: pessoas e casais, pele natural e suave"
        case .paisagem: return "Paisagem: céu, natureza e lugares, recupera o céu"
        case .produto: return "Produto: objetos, roupas e loja, limpo e nítido"
        case .comida: return "Comida: pratos e lanches, quente e com textura"
        case .noite: return "Noite: pouca luz, tira ruído e o amarelo das lâmpadas"
        case .pb: return "P&B: preto e branco com contraste, clássico"
        case .cinema: return "Cinema: sombras azuladas e pele quente, cara de filme"
        case .filme: return "Filme: cor suave, pretos lavados e grão fino, analógico"
        case .dourado: return "Dourado: fim de tarde, ótimo para pessoas e casais"
        case .neon: return "Neon: cidade à noite e luzes coloridas, sem estourar"
        case .lut: return "Meu LUT: o look de cinema que você importou (\(LUTStore.shared.name ?? ".cube"))"
        }
    }

    /// Cor da bolinha no seletor de looks.
    var swatch: Color {
        switch self {
        case .original: return Color(red: 0.42, green: 0.40, blue: 0.38)
        case .natural: return Color(red: 0.78, green: 0.66, blue: 0.52)
        case .vivo: return Color(red: 0.93, green: 0.45, blue: 0.25)
        case .retrato: return Color(red: 0.79, green: 0.60, blue: 0.53)
        case .paisagem: return Color(red: 0.25, green: 0.55, blue: 0.70)
        case .produto: return Color(red: 0.88, green: 0.88, blue: 0.86)
        case .comida: return Color(red: 0.71, green: 0.38, blue: 0.16)
        case .noite: return Color(red: 0.24, green: 0.21, blue: 0.31)
        case .pb: return Color(red: 0.15, green: 0.15, blue: 0.15)
        case .cinema: return Color(red: 0.13, green: 0.42, blue: 0.45)
        case .filme: return Color(red: 0.62, green: 0.58, blue: 0.46)
        case .dourado: return Color(red: 0.92, green: 0.68, blue: 0.27)
        case .neon: return Color(red: 0.62, green: 0.22, blue: 0.85)
        case .lut: return Color(red: 0.35, green: 0.35, blue: 0.55)
        }
    }

    func apply(to image: CIImage, detail k: Float = 1) -> CIImage {
        switch self {
        case .original:
            return image
        case .natural:
            return image
                .vibrance(0.15)
                .highlightShadow(highlight: 0.92, shadow: 0.12)
                .sCurve(0.5)
                .sharpen(0.25, radius: 1.6 * k)
        case .vivo:
            return image
                .vibrance(0.45)
                .colorControls(saturation: 1.06)
                .sCurve(1.0)
                .sharpen(0.3, radius: 1.6 * k)
        case .retrato:
            return image
                .warm(0.03)
                .vibrance(0.15)
                .colorControls(saturation: 0.98, contrast: 0.96)
                .highlightShadow(highlight: 0.85, shadow: 0.2)
        case .paisagem:
            return image
                .highlightShadow(highlight: 0.8, shadow: 0.2)
                .vibrance(0.4)
                .sCurve(0.8)
                .sharpen(0.5, radius: 1.6 * k)
        case .produto:
            return image
                .exposure(0.1)
                .vibrance(0.12)
                .colorControls(contrast: 1.06)
                .sharpen(0.6, radius: 1.6 * k)
        case .comida:
            return image
                .warm(0.06)
                .vibrance(0.35)
                .colorControls(saturation: 1.05, contrast: 1.12)
                .highlightShadow(highlight: 0.9, shadow: 0.15)
                .sharpen(0.4, radius: 1.6 * k)
        case .noite:
            return image
                .denoise(level: 0.02, sharpness: 0.5)
                .warm(-0.07)
                .highlightShadow(highlight: 1.0, shadow: 0.35)
                .vibrance(0.15)
                .colorControls(contrast: 1.05)
        case .pb:
            return image
                .colorControls(saturation: 0, contrast: 1.15)
                .sharpen(0.35, radius: 1.6 * k)
        case .cinema:
            return ColorCube.apply(image, name: "cinema", transform: CubeLooks.cinema)
                .highlightShadow(highlight: 0.9, shadow: 0.1)
                .vignette(0.25)
                .sharpen(0.25, radius: 1.6 * k)
        case .filme:
            return ColorCube.apply(image, name: "filme", transform: CubeLooks.filme)
                .vignette(0.35)
                .grain(0.07, scale: CGFloat(k))
        case .dourado:
            return ColorCube.apply(image, name: "dourado", transform: CubeLooks.dourado)
                .highlightShadow(highlight: 0.85, shadow: 0.15)
                .vignette(0.2)
        case .neon:
            return ColorCube.apply(image, name: "neon", transform: CubeLooks.neon)
                .denoise(level: 0.015, sharpness: 0.5)
                .highlightShadow(highlight: 0.75, shadow: 0.1)
        case .lut:
            return LUTStore.shared.apply(image)
        }
    }
}

enum LookEngine {
    /// Aplica o look com intensidade de 0 a 1 (mistura com a imagem original).
    static func render(_ image: CIImage, look: Look, intensity: Float) -> CIImage {
        guard look != .original, intensity > 0.001 else { return image }
        // Nitidez proporcional à resolução (evita halo em 24/48 MP).
        let k = Float(max(1, max(image.extent.width, image.extent.height) / 3000))
        let filtered = look.apply(to: image, detail: k).cropped(to: image.extent)
        if intensity >= 0.999 { return filtered }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = filtered
        mix.time = intensity
        return mix.outputImage?.cropped(to: image.extent) ?? filtered
    }
}

// MARK: - Looks de cinema feitos com tabela de cor (cubo 3D)

enum CubeLooks {
    typealias RGB = SIMD3<Float>

    static func lum(_ c: RGB) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    static func mix(_ a: RGB, _ b: RGB, _ t: Float) -> RGB { a + (b - a) * t }
    static func saturate(_ c: RGB, _ s: Float) -> RGB { mix(RGB(repeating: lum(c)), c, s) }
    static func smooth(_ c: RGB) -> RGB {
        let x = simd_clamp(c, RGB(repeating: 0), RGB(repeating: 1))
        return x * x * (RGB(repeating: 3) - 2 * x)
    }

    /// Sombras azul-petróleo, pele e luzes alaranjadas (teal & orange).
    static func cinema(_ c: RGB) -> RGB {
        let l = lum(c)
        var o = c
        o += RGB(-0.05, 0.01, 0.06) * ((1 - l) * (1 - l))
        o += RGB(0.06, 0.02, -0.05) * (l * l)
        o = saturate(o, 1.05)
        return mix(o, smooth(o), 0.3)
    }

    /// Filme analógico: pretos lavados, cor suave, meio-tons quentes.
    static func filme(_ c: RGB) -> RGB {
        var o = saturate(c, 0.82)
        o = mix(o, smooth(o), 0.25)
        o = RGB(repeating: 0.05) + o * 0.9
        return o + RGB(0.015, 0.005, -0.015)
    }

    /// Luz dourada de fim de tarde.
    static func dourado(_ c: RGB) -> RGB {
        let l = lum(c)
        var o = c + RGB(0.06, 0.03, -0.05) * (0.3 + 0.7 * l)
        o = saturate(o, 1.08)
        return mix(o, smooth(o), 0.2)
    }

    /// Noite colorida: cores fortes, sombras azul-magenta, pretos firmes.
    static func neon(_ c: RGB) -> RGB {
        let l = lum(c)
        var o = saturate(c, 1.35)
        o += RGB(0.03, -0.01, 0.06) * ((1 - l) * (1 - l) * (1 - l))
        o = mix(o, smooth(o), 0.3)
        return simd_max(o - RGB(repeating: 0.02), RGB(repeating: 0)) / 0.98
    }

    /// Falsa cor (igual às câmeras de cinema): mostra a exposição por cores.
    static func falseColor(_ c: RGB) -> RGB {
        let l = lum(c)
        if l < 0.025 { return RGB(0.45, 0.1, 0.6) }      // roxo: preto sem detalhe
        if l < 0.10 { return RGB(0.1, 0.3, 0.9) }        // azul: sombra escura
        if l >= 0.38 && l < 0.44 { return RGB(0.2, 0.8, 0.3) }  // verde: cinza médio / pele escura
        if l >= 0.52 && l < 0.58 { return RGB(1, 0.5, 0.7) }    // rosa: pele clara
        if l >= 0.97 { return RGB(1, 0.1, 0.1) }          // vermelho: estourado
        return RGB(repeating: l * 0.85)
    }
}

enum ColorCube {
    static let size = 32
    private static var cache: [String: Data] = [:]
    private static let lock = NSLock()

    static func data(_ name: String, transform: (SIMD3<Float>) -> SIMD3<Float>) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let d = cache[name] { return d }
        let n = size
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        let zero = SIMD3<Float>(repeating: 0), one = SIMD3<Float>(repeating: 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let c = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(n - 1)
                    let o = simd_clamp(transform(c), zero, one)
                    values.append(o.x)
                    values.append(o.y)
                    values.append(o.z)
                    values.append(1)
                }
            }
        }
        let d = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cache[name] = d
        return d
    }

    static func apply(_ image: CIImage, name: String, transform: (SIMD3<Float>) -> SIMD3<Float>) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(size)
        filter.cubeData = data(name, transform: transform)
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return filter.outputImage ?? image
    }
}

// MARK: - LUT importado (.cube), igual ao Blackmagic

final class LUTStore {
    static let shared = LUTStore()
    private let lock = NSLock()
    private var cube: (size: Int, data: Data)?
    private(set) var name: String?

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("meu-look.cube")
    }

    init() {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            cube = Self.parse(text)
            name = Prefs.string("lutName")
        }
    }

    var hasLUT: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cube != nil
    }

    func importCube(from url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8), let parsed = Self.parse(text) else { return false }
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        lock.lock()
        cube = parsed
        lock.unlock()
        name = url.deletingPathExtension().lastPathComponent
        Prefs.set(name, "lutName")
        return true
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        lock.lock()
        cube = nil
        lock.unlock()
        name = nil
        Prefs.set(nil, "lutName")
    }

    func apply(_ image: CIImage) -> CIImage {
        lock.lock()
        let c = cube
        lock.unlock()
        guard let c else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(c.size)
        filter.cubeData = c.data
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return filter.outputImage ?? image
    }

    static func parse(_ text: String) -> (size: Int, data: Data)? {
        var size = 0
        var values: [Float] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(parts.last ?? "") ?? 0
                continue
            }
            if let first = line.first, first.isLetter { continue }
            let numbers = parts.compactMap { Float($0) }
            if numbers.count >= 3 {
                values.append(numbers[0])
                values.append(numbers[1])
                values.append(numbers[2])
                values.append(1)
            }
        }
        guard size >= 2, size <= 128, values.count == size * size * size * 4 else { return nil }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return (size, data)
    }
}

// MARK: - Atalhos de filtros

extension CIImage {
    func colorControls(saturation: Float = 1, brightness: Float = 0, contrast: Float = 1) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = self
        f.saturation = saturation
        f.brightness = brightness
        f.contrast = contrast
        return f.outputImage ?? self
    }

    func vibrance(_ amount: Float) -> CIImage {
        let f = CIFilter.vibrance()
        f.inputImage = self
        f.amount = amount
        return f.outputImage ?? self
    }

    func highlightShadow(highlight: Float, shadow: Float) -> CIImage {
        let f = CIFilter.highlightShadowAdjust()
        f.inputImage = self
        f.highlightAmount = highlight
        f.shadowAmount = shadow
        return f.outputImage ?? self
    }

    func sharpen(_ amount: Float, radius: Float = 1.6) -> CIImage {
        let f = CIFilter.sharpenLuminance()
        f.inputImage = self
        f.sharpness = amount
        f.radius = radius
        return f.outputImage ?? self
    }

    /// Curva de tons em S suave (contraste "de revista" sem estourar).
    func sCurve(_ strength: CGFloat) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = self
        f.point0 = CGPoint(x: 0, y: 0)
        f.point1 = CGPoint(x: 0.25, y: 0.25 - 0.06 * strength)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: 0.75 + 0.05 * strength)
        f.point4 = CGPoint(x: 1, y: 1)
        return f.outputImage ?? self
    }

    func exposure(_ ev: Float) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = self
        f.ev = ev
        return f.outputImage ?? self
    }

    func denoise(level: Float, sharpness: Float) -> CIImage {
        let f = CIFilter.noiseReduction()
        f.inputImage = self
        f.noiseLevel = level
        f.sharpness = sharpness
        return f.outputImage ?? self
    }

    /// Positivo = mais quente (mais vermelho, menos azul). Negativo = mais frio.
    func warm(_ amount: CGFloat) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = self
        f.rVector = CIVector(x: 1 + amount, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: 1 + amount * 0.3, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: 1 - amount, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? self
    }

    /// Escurece levemente as bordas, levando o olhar para o centro.
    func vignette(_ intensity: Float) -> CIImage {
        let e = extent
        let f = CIFilter.vignetteEffect()
        f.inputImage = self
        f.center = CGPoint(x: e.midX, y: e.midY)
        f.radius = Float(max(e.width, e.height)) * 0.62
        f.intensity = intensity
        f.falloff = 0.6
        return f.outputImage?.cropped(to: e) ?? self
    }

    /// Grão de filme fino, proporcional à resolução.
    func grain(_ amount: CGFloat, scale: CGFloat) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return self }
        let g = CIVector(x: 0, y: amount, z: 0, w: 0)
        let tinted = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": g, "inputGVector": g, "inputBVector": g,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.5 - amount / 2, y: 0.5 - amount / 2, z: 0.5 - amount / 2, w: 1)
        ])
        let sized = tinted
            .transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = sized
        blend.backgroundImage = self
        return blend.outputImage?.cropped(to: extent) ?? self
    }
}
