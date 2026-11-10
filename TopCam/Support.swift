import Foundation
import Photos
import CoreMotion
import Vision
import UIKit

// MARK: - Salvar na galeria

enum PhotoSaver {
    static func savePhoto(main: Data?, raw: Data?, completion: @escaping (Bool) -> Void) {
        guard main != nil || raw != nil else { completion(false); return }
        PHPhotoLibrary.shared().performChanges({
            if let main {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: main, options: nil)
            }
            if let raw {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "com.adobe.raw-image"
                request.addResource(with: .photo, data: raw, options: options)
            }
        }, completionHandler: { ok, _ in completion(ok) })
    }

    static func saveVideo(url: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
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
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let g = motion?.gravity else { return }
            self?.roll = atan2(g.x, -g.y) * 180 / .pi
            self?.isFlat = g.z < -0.96
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

    func analyze(_ pixelBuffer: CVPixelBuffer, iso: Float) {
        lock.lock()
        if busy || Date().timeIntervalSince(lastRun) < 1.2 { lock.unlock(); return }
        busy = true
        lastRun = Date()
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
            let classify = VNClassifyImageRequest()
            let faces = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
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
            DispatchQueue.main.async { self.onResult?(result.0, result.1) }
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
