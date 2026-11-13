import AVFoundation
import CoreImage

/// Grava o vídeo já com o look aplicado (HEVC), quadro a quadro.
/// Todos os métodos devem ser chamados na fila de dados da câmera.
final class VideoRecorder {
    enum State { case idle, waitingFirstFrame, recording, finishing }

    private(set) var state: State = .idle
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var audioSettings: [String: Any]?
    private var transform: CGAffineTransform = .identity
    private var frameRate = 30
    private let queue: DispatchQueue

    var isActive: Bool { state == .waitingFirstFrame || state == .recording }

    var onFinished: ((URL?) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(audioSettings: [String: Any]?, transform: CGAffineTransform, frameRate: Int) {
        guard state == .idle else { return }
        self.audioSettings = audioSettings
        self.transform = transform
        self.frameRate = frameRate
        state = .waitingFirstFrame
    }

    func appendVideo(_ image: CIImage, sampleBuffer: CMSampleBuffer, context: CIContext) {
        guard state == .waitingFirstFrame || state == .recording else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if state == .waitingFirstFrame {
            let width = Int(image.extent.width)
            let height = Int(image.extent.height)
            guard setupWriter(width: width, height: height), let writer, writer.startWriting() else {
                reset()
                onFinished?(nil)
                return
            }
            writer.startSession(atSourceTime: time)
            state = .recording
        }

        guard let adaptor, let videoInput, videoInput.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        context.render(image, to: buffer)
        adaptor.append(buffer, withPresentationTime: time)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    func stop() {
        guard state == .recording, let writer else {
            reset()
            onFinished?(nil)
            return
        }
        state = .finishing
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let url = outputURL
        writer.finishWriting { [weak self] in
            guard let self else { return }
            let ok = writer.status == .completed
            self.queue.async {
                self.reset()
                self.onFinished?(ok ? url : nil)
            }
        }
    }

    private func setupWriter(width: Int, height: Int) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopCam-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }

        // ~26 Mbps em 4K (≈ 190 MB/min) e ~8 Mbps em 1080p (≈ 60 MB/min).
        let isUHD = width * height >= 3_000_000
        let base = isUHD ? 26_000_000 : 8_000_000
        let bitrate = base * max(frameRate, 24) / 30
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        // Gira o vídeo quando foi gravado com o celular deitado.
        vInput.transform = transform
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput,
                                                           sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(vInput) else { return false }
        writer.add(vInput)

        if let audioSettings {
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) {
                writer.add(aInput)
                self.audioInput = aInput
            }
        }

        self.writer = writer
        self.videoInput = vInput
        self.adaptor = adaptor
        self.outputURL = url
        return true
    }

    private func reset() {
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        outputURL = nil
        state = .idle
    }
}
