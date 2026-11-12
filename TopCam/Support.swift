import Foundation
import Photos
import CoreMotion
import Vision
import UIKit
import CoreLocation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Salvar na galeria

enum PhotoSaver {
    static func savePhoto(main: Data?, raw: Data?, location: CLLocation? = nil, completion: @escaping (Bool) -> Void) {
        guard main != nil || raw != nil else { completion(false); return }
        PHPhotoLibrary.shared().performChanges({
            if let main {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: main, options: nil)
                request.location = location
            }
            if let raw {
                let request = PHAssetCreationRequest.forAsset()
                request.location = location
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "com.adobe.raw-image"
                request.addResource(with: .photo, data: raw, options: options)
            }
        }, completionHandler: { ok, _ in completion(ok) })
    }

    static func saveVideo(url: URL, location: CLLocation? = nil, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.location = location
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: url, options: options)
        }, completionHandler: { ok, _ in completion(ok) })
    }
}

// MARK: - Nível (celular reto) e vista de cima

final class LevelMonitor: ObservableObject {
    @Published var roll: Double = 0
    @Published var isFlat = false
    /// Ângulo para gravar a foto/vídeo na posição certa (90 = em pé, 0/180 = deitado).
    @Published var captureAngle: CGFloat = 90
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let g = motion?.gravity else { return }
            guard let self else { return }
            self.isFlat = g.z < -0.96
            // Só muda a orientação quando o celular está bem inclinado (evita ficar trocando).
            if abs(g.z) < 0.8 {
                if abs(g.y) > abs(g.x) + 0.15 {
                    self.captureAngle = g.y < 0 ? 90 : 270
                } else if abs(g.x) > abs(g.y) + 0.15 {
                    self.captureAngle = g.x > 0 ? 0 : 180
                }
            }
            // Inclinação em relação ao horizonte, conforme a posição em que o celular está.
            switch self.captureAngle {
            case 0: self.roll = atan2(-g.y, g.x) * 180 / .pi
            case 180: self.roll = atan2(g.y, -g.x) * 180 / .pi
            case 270: self.roll = atan2(-g.x, g.y) * 180 / .pi
            default: self.roll = atan2(g.x, -g.y) * 180 / .pi
            }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

// MARK: - Detecção de cena

final class SceneDetector {
    private let queue = DispatchQueue(label: "topcam.scene", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var lastRun = Date.distantPast
    private var lastCandidate: Look?

    var onResult: ((Look, String) -> Void)?

    private static let foodWords = ["food", "burger", "sandwich", "meal", "dish", "fries", "pizza",
                                    "dessert", "bread", "meat", "drink", "beverage", "cake", "snack",
                                    "fruit", "salad", "coffee", "cheese"]
    private static let landscapeWords = ["sky", "mountain", "beach", "sea", "ocean", "outdoor", "tree",
                                         "forest", "field", "sunset", "sunrise", "nature", "landscape",
                                         "water", "lake", "river", "cloud", "grass", "garden", "park"]
    private static let productWords = ["bottle", "shoe", "watch", "phone", "cup", "glasses", "jewelry",
                                       "bag", "clothing", "cosmetic", "perfume", "toy", "book", "car",
                                       "furniture", "lamp", "tool", "electronics"]
    private static let animalWords = ["dog", "cat", "animal", "bird", "pet", "horse"]
    private static let placeWords = ["building", "structure", "house", "storefront", "architecture",
                                     "street", "shop", "restaurant", "interior", "room", "office", "city"]

    func analyze(_ image: CIImage, iso: Float, context: CIContext) {
        lock.lock()
        if busy || Date().timeIntervalSince(lastRun) < 1.5 { lock.unlock(); return }
        busy = true
        lastRun = Date()
        lock.unlock()

        // Cópia pequena da imagem: libera o quadro da câmera na hora (sem travar o visor).
        let scale = 384 / max(image.extent.width, image.extent.height)
        let tiny = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(tiny, from: tiny.extent) else {
            lock.lock(); busy = false; lock.unlock()
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
            let classify = VNClassifyImageRequest()
            let faces = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            try? handler.perform([classify, faces])

            let labels = (classify.results ?? [])
                .filter { $0.confidence > 0.25 }
                .map { $0.identifier.lowercased() }
            let hasFace = !(faces.results ?? []).isEmpty
            let isDark = iso > 1000

            func matches(_ words: [String]) -> Bool {
                labels.contains { label in words.contains { label.contains($0) } }
            }

            let result: (Look, String)
            if isDark {
                result = (.noite, "Pouca luz")
            } else if hasFace {
                result = (.retrato, "Pessoa detectada")
            } else if matches(Self.foodWords) {
                result = (.comida, "Comida detectada")
            } else if matches(Self.animalWords) {
                result = (.vivo, "Animal detectado")
            } else if matches(Self.productWords) {
                result = (.produto, "Objeto detectado")
            } else if matches(Self.landscapeWords) {
                result = (.paisagem, "Paisagem detectada")
            } else if matches(Self.placeWords) {
                result = (.natural, "Ambiente detectado")
            } else {
                result = (.natural, "Cena geral")
            }
            // Só troca o look se a mesma cena aparecer 2 vezes seguidas.
            let confirmed = self.lastCandidate == result.0
            self.lastCandidate = result.0
            if confirmed {
                DispatchQueue.main.async { self.onResult?(result.0, result.1) }
            }
        }
    }
}

// MARK: - Espaço livre

enum Storage {
    static func availableBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

// MARK: - Miniatura

enum Thumbnail {
    static func make(from image: CIImage, context: CIContext, maxSide: CGFloat = 200) -> UIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = maxSide / max(extent.width, extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}


// MARK: - Localização (opcional, para a galeria organizar por lugar)

final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
    }

    func stop() { manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }
}

// MARK: - Ferramentas do Modo Pro (histograma, zebra, realce de foco)

enum ProOverlays {
    /// Histograma de luminância com 64 barras (0 a 1).
    static func histogram(of image: CIImage, context: CIContext) -> [Float] {
        let bins = 64
        let f = CIFilter.areaHistogram()
        f.inputImage = image
        f.extent = image.extent
        f.count = bins
        f.scale = 1
        guard let out = f.outputImage else { return [] }
        var data = [Float](repeating: 0, count: bins * 4)
        data.withUnsafeMutableBytes { ptr in
            context.render(out, toBitmap: ptr.baseAddress!, rowBytes: bins * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf, colorSpace: nil)
        }
        var lum = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            lum[i] = 0.2126 * data[i * 4] + 0.7152 * data[i * 4 + 1] + 0.0722 * data[i * 4 + 2]
        }
        let maxV = max(lum.max() ?? 1, 0.0001)
        return lum.map { $0 / maxV }
    }

    private static func luminanceMask(_ image: CIImage) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        let l = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        m.rVector = l; m.gVector = l; m.bVector = l
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    /// Listras sobre as áreas com luz estourada.
    static func zebra(_ image: CIImage) -> CIImage {
        let t = CIFilter.colorThreshold()
        t.inputImage = luminanceMask(image)
        t.threshold = 0.95
        guard let mask = t.outputImage else { return image }
        let stripes = CIFilter.stripesGenerator()
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.6)
        stripes.width = Float(max(4, image.extent.width / 120))
        guard let pattern = stripes.outputImage?
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: image.extent) else { return image }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = pattern
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }

    /// Contorno verde nas partes que estão em foco.
    static func focusPeaking(_ image: CIImage) -> CIImage {
        let edges = CIFilter.edges()
        edges.inputImage = luminanceMask(image)
        edges.intensity = 6
        guard let e = edges.outputImage else { return image }
        let t = CIFilter.colorThreshold()
        t.inputImage = luminanceMask(e)
        t.threshold = 0.35
        guard let mask = t.outputImage else { return image }
        let green = CIImage(color: CIColor(red: 0.22, green: 1, blue: 0.42)).cropped(to: image.extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = green
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }
}

// MARK: - Preferências salvas no aparelho

enum Prefs {
    static let d = UserDefaults.standard
    static func string(_ k: String) -> String? { d.string(forKey: k) }
    static func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    static func set(_ v: Any?, _ k: String) { d.set(v, forKey: k) }
}
