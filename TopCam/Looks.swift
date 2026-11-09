import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Os looks (filtros) do TopCam. Todos feitos com Core Image, rodando na GPU.
enum Look: String, CaseIterable, Identifiable {
    case original, smash, delivery, noite, retrato, fachada

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .smash: return "Smash"
        case .delivery: return "Delivery"
        case .noite: return "Noite"
        case .retrato: return "Retrato"
        case .fachada: return "Fachada"
        }
    }

    /// Cor da bolinha no seletor de looks.
    var swatch: Color {
        switch self {
        case .original: return Color(red: 0.42, green: 0.33, blue: 0.27)
        case .smash: return Color(red: 0.71, green: 0.38, blue: 0.16)
        case .delivery: return Color(red: 0.85, green: 0.71, blue: 0.55)
        case .noite: return Color(red: 0.24, green: 0.21, blue: 0.31)
        case .retrato: return Color(red: 0.79, green: 0.60, blue: 0.53)
        case .fachada: return Color(red: 0.30, green: 0.45, blue: 0.62)
        }
    }

    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .original:
            return image
        case .smash:
            // Quente, contrastado, com textura: para lanches, carnes e pão.
            return image
                .warm(0.06)
                .vibrance(0.35)
                .colorControls(saturation: 1.05, contrast: 1.12)
                .highlightShadow(highlight: 0.9, shadow: 0.15)
                .sharpen(0.4)
        case .delivery:
            // Claro e fiel: foto de cardápio e delivery.
            return image
                .exposure(0.15)
                .warm(0.02)
                .vibrance(0.25)
                .colorControls(contrast: 1.04)
                .sharpen(0.3)
        case .noite:
            // Corrige luz amarela, tira ruído e levanta as sombras.
            return image
                .denoise(level: 0.02, sharpness: 0.5)
                .warm(-0.07)
                .highlightShadow(highlight: 1.0, shadow: 0.35)
                .vibrance(0.15)
                .colorControls(contrast: 1.05)
        case .retrato:
            // Pele natural, contraste suave.
            return image
                .warm(0.03)
                .vibrance(0.15)
                .colorControls(saturation: 0.98, contrast: 0.96)
                .highlightShadow(highlight: 0.85, shadow: 0.2)
        case .fachada:
            // Cores vivas e detalhe para fachadas e ambientes.
            return image
                .vibrance(0.45)
                .colorControls(contrast: 1.12)
                .sharpen(0.6)
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
