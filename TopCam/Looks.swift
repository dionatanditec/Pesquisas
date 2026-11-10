import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Os looks (filtros) do TopCam. Todos feitos com Core Image, rodando na GPU.
enum Look: String, CaseIterable, Identifiable {
    case original, natural, vivo, retrato, paisagem, produto, comida, noite, pb

    var id: String { rawValue }

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
        }
    }

    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .original:
            return image
        case .natural:
            // Melhora leve para qualquer foto: luz equilibrada, cor fiel.
            return image
                .vibrance(0.15)
                .highlightShadow(highlight: 0.92, shadow: 0.12)
                .colorControls(contrast: 1.03)
                .sharpen(0.25)
        case .vivo:
            // Cores fortes e contraste: redes sociais, eventos, animais.
            return image
                .vibrance(0.45)
                .colorControls(saturation: 1.08, contrast: 1.1)
                .sharpen(0.3)
        case .retrato:
            // Pele natural, contraste suave.
            return image
                .warm(0.03)
                .vibrance(0.15)
                .colorControls(saturation: 0.98, contrast: 0.96)
                .highlightShadow(highlight: 0.85, shadow: 0.2)
        case .paisagem:
            // Recupera o céu, abre as sombras e realça verdes e azuis.
            return image
                .highlightShadow(highlight: 0.8, shadow: 0.2)
                .vibrance(0.4)
                .colorControls(contrast: 1.08)
                .sharpen(0.5)
        case .produto:
            // Limpo e fiel: objetos, roupas, loja, catálogo.
            return image
                .exposure(0.1)
                .vibrance(0.12)
                .colorControls(contrast: 1.06)
                .sharpen(0.6)
        case .comida:
            // Quente, contrastado, com textura.
            return image
                .warm(0.06)
                .vibrance(0.35)
                .colorControls(saturation: 1.05, contrast: 1.12)
                .highlightShadow(highlight: 0.9, shadow: 0.15)
                .sharpen(0.4)
        case .noite:
            // Corrige luz amarela, tira ruído e levanta as sombras.
            return image
                .denoise(level: 0.02, sharpness: 0.5)
                .warm(-0.07)
                .highlightShadow(highlight: 1.0, shadow: 0.35)
                .vibrance(0.15)
                .colorControls(contrast: 1.05)
        case .pb:
            // Preto e branco com contraste.
            return image
                .colorControls(saturation: 0, contrast: 1.15)
                .sharpen(0.35)
        }
    }
}

enum LookEngine {
    /// Aplica o look com intensidade de 0 a 1 (mistura com a imagem original).
    static func render(_ image: CIImage, look: Look, intensity: Float) -> CIImage {
        guard look != .original, intensity > 0.001 else { return image }
        let filtered = look.apply(to: image).cropped(to: image.extent)
        if intensity >= 0.999 { return filtered }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = filtered
        mix.time = intensity
        return mix.outputImage?.cropped(to: image.extent) ?? filtered
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

    func sharpen(_ amount: Float) -> CIImage {
        let f = CIFilter.sharpenLuminance()
        f.inputImage = self
        f.sharpness = amount
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
}
