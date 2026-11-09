import AVFoundation
import CoreImage
import Photos
import UIKit
import Combine

enum CaptureMode: String, CaseIterable, Identifiable {
    case pro = "PRO", photo = "FOTO", video = "VÍDEO"
    var id: String { rawValue }
}

enum LensChoice: String, CaseIterable, Identifiable {
    case ultraWide = "0,5", wide = "1×", tele = "Tele"
    var id: String { rawValue }
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .tele: return .builtInTelephotoCamera
        }
    }
}

enum ProParam: String, CaseIterable, Identifiable {
    case iso = "ISO", shutter = "VELOC.", wb = "BRANCO", focus = "FOCO", ev = "EV"
    var id: String { rawValue }
}

enum QualityProfile: String, CaseIterable, Identifiable {
    case social = "Redes · 1080p"
    case max = "Auto Máx · 4K"
    var id: String { rawValue }
    var megabytesPerMinute: Double { self == .max ? 190 : 60 }
}

/// O "motor" da câmera: sessão, fotos, vídeos, controles manuais e looks.
final class CameraModel: NSObject, ObservableObject {
    // MARK: Estado da tela
    @Published var mode: CaptureMode = .photo
    @Published var look: Look = .smash { didSet { updateRenderSettings() } }
    @Published var intensity: Double = 0.8 { didSet { updateRenderSettings() } }
    @Published var autoScene = true
    @Published var detectedScene = ""
    @Published var lens: LensChoice = .wide
    @Published var availableLenses: [LensChoice] = [.wide]
    @Published var isFront = false
    @Published var rawEnabled = false
    @Published var rawSupported = false
    @Published var showGrid = false
    @Published var quality: QualityProfile = .max
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var lastThumbnail: UIImage?
    @Published var minutesLeft = 0
    @Published var toast: String?
    @Published var permissionDenied = false

    // MARK: Modo Pro
    @Published var proParam: ProParam = .iso
    @Published var isManual = false
    @Published var iso: Float = 100
    @Published var shutterSeconds: Double = 1.0 / 60.0
    @Published var whiteBalance: Float = 5000
    @Published var focus: Float = 0.5
    @Published var exposureBias: Float = 0
    @Published var isoRange: ClosedRange<Float> = 32...3200
    @Published var shutterRange: ClosedRange<Double> = (1.0 / 8000.0)...(1.0 / 4.0)
    @Published var biasRange: ClosedRange<Float> = -3...3

    let session = AVCaptureSession()
    let renderer = PreviewRenderer()

    private let sessionQueue = DispatchQueue(label: "topcam.session")
    private let dataQueue = DispatchQueue(label: "topcam.data", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var inFlightPhotos: [Int64: PhotoCaptureProcessor] = [:]
    private lazy var recorder = VideoRecorder(queue: dataQueue)
    private let sceneDetector = SceneDetector()
    private var configured = false

    private let settingsLock = NSLock()
    private var renderLook: Look = .smash
    private var renderIntensity: Float = 0.8

    private var recordTimer: Timer?
    private var pollTimer: Timer?

    var ciContext: CIContext { renderer.ciContext }

    override init() {
        super.init()
        sceneDetector.onResult = { [weak self] suggested, label in
            guard let self, self.autoScene, self.mode != .pro else { return }
            self.detectedScene = label
            if self.look != suggested { self.look = suggested }
        }
        recorder.onFinished = { [weak self] url in
            guard let url else {
                DispatchQueue.main.async { self?.showToast("Não consegui gravar o vídeo") }
                return
            }
            PhotoSaver.saveVideo(url: url) { ok in
                DispatchQueue.main.async {
                    self?.showToast(ok ? "Vídeo salvo na galeria" : "Não consegui salvar o vídeo")
                    self?.refreshStorage()
                }
            }
        }
    }

    // MARK: - Início

    func start() {
        Task {
            let camera = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard camera else {
                await MainActor.run { self.permissionDenied = true }
                return
            }
            self.sessionQueue.async {
                if !self.configured {
                    self.configure(withMicrophone: mic)
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
            }
            await MainActor.run {
                self.refreshStorage()
                self.startPolling()
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure(withMicrophone mic: Bool) {
        session.beginConfiguration()

        let lenses = LensChoice.allCases.filter {
            AVCaptureDevice.default($0.deviceType, for: .video, position: .back) != nil
        }
        DispatchQueue.main.async { self.availableLenses = lenses.isEmpty ? [.wide] : lenses }

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            setDevice(device)
        }

        if mic, let micDevice = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: micDevice), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if audioInput != nil, session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        applyPresetLocked()
        configurePhotoOutput()
        configureConnections()
        session.commitConfiguration()
    }

    private func setDevice(_ device: AVCaptureDevice) {
        let old = videoInput
        if let old { session.removeInput(old) }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            if let old, session.canAddInput(old) { session.addInput(old) }
            return
        }
        session.addInput(input)
        videoInput = input
        updateRanges(for: device)
    }

    private func applyPresetLocked() {
        let wanted: AVCaptureSession.Preset
        switch mode {
        case .video: wanted = quality == .max ? .hd4K3840x2160 : .hd1920x1080
        case .photo, .pro: wanted = .photo
        }
        if session.canSetSessionPreset(wanted) {
            session.sessionPreset = wanted
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
    }

    private func configurePhotoOutput() {
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let device = videoInput?.device,
           let biggest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
               Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
           }) {
            photoOutput.maxPhotoDimensions = biggest
        }
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }
        let rawOK = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        DispatchQueue.main.async {
            self.rawSupported = rawOK
            if !rawOK { self.rawEnabled = false }
        }
    }

    private func configureConnections() {
        let front = videoInput?.device.position == .front
        for output in [videoOutput as AVCaptureOutput, photoOutput as AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = front
            }
        }
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoStabilizationSupported,
           let format = videoInput?.device.activeFormat {
            if mode == .video {
                connection.preferredVideoStabilizationMode =
                    format.isVideoStabilizationModeSupported(.cinematicExtended) ? .cinematicExtended : .auto
            } else {
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }

    private func reconfigure() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.applyPresetLocked()
            self.configurePhotoOutput()
            self.configureConnections()
            self.session.commitConfiguration()
        }
    }

    // MARK: - Modo, lente, câmera frontal, qualidade

    func setMode(_ newMode: CaptureMode) {
        guard !isRecording, newMode != mode else { return }
        mode = newMode
        if newMode != .pro && isManual { resetToAuto() }
        reconfigure()
    }

    func setQuality(_ newQuality: QualityProfile) {
        guard !isRecording else { return }
        quality = newQuality
        refreshStorage()
        reconfigure()
    }

    func selectLens(_ choice: LensChoice) {
        guard !isRecording else { return }
        lens = choice
        isFront = false
        switchDevice(type: choice.deviceType, position: .back)
    }

    func flipCamera() {
        guard !isRecording else { return }
        isFront.toggle()
        if isFront {
            switchDevice(type: .builtInWideAngleCamera, position: .front)
        } else {
            switchDevice(type: lens.deviceType, position: .back)
        }
    }

    private func switchDevice(type: AVCaptureDevice.DeviceType, position: AVCaptureDevice.Position) {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(type, for: .video, position: position) else { return }
            self.session.beginConfiguration()
            self.setDevice(device)
            self.applyPresetLocked()
            self.configurePhotoOutput()
            self.configureConnections()
            self.session.commitConfiguration()
        }
        DispatchQueue.main.async { self.isManual = false }
    }

    // MARK: - Foto

    func capturePhoto() {
        let wantRaw = rawEnabled && rawSupported
        settingsLock.lock()
        let look = renderLook
        let intensity = renderIntensity
        settingsLock.unlock()

        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            var isProRAW = false
            let hevc = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
            let processed: [String: Any] = [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg]

            if wantRaw, let rawFormat = self.preferredRawFormat() {
                isProRAW = AVCapturePhotoOutput.isAppleProRAWPixelFormat(rawFormat)
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: processed)
            } else {
                settings = AVCapturePhotoSettings(format: processed)
            }

            if !wantRaw || isProRAW {
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .quality
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(look: look, intensity: intensity, context: self.ciContext) { [weak self] thumb, message in
                DispatchQueue.main.async {
                    if let thumb { self?.lastThumbnail = thumb }
                    self?.showToast(message)
                    self?.refreshStorage()
                }
                self?.sessionQueue.async { self?.inFlightPhotos[id] = nil }
            }
            self.inFlightPhotos[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func preferredRawFormat() -> OSType? {
        let formats = photoOutput.availableRawPhotoPixelFormatTypes
        return formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? formats.first
    }

    // MARK: - Vídeo

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard mode == .video else { return }
        if Storage.availableBytes() < 500_000_000 {
            showToast("Sem espaço para gravar. Libere espaço no iPhone.")
            return
        }
        if quality == .max && Storage.availableBytes() < 5_000_000_000 {
            setQuality(.social)
            showToast("Pouco espaço: mudei para 1080p")
        }
        let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
        dataQueue.async { self.recorder.start(audioSettings: audioSettings) }
        isRecording = true
        recordingSeconds = 0
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingSeconds += 1
            if self.recordingSeconds % 10 == 0 {
                self.refreshStorage()
                if Storage.availableBytes() < 300_000_000 {
                    self.stopRecording()
                    self.showToast("Espaço acabando: gravação salva")
                }
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        recordTimer = nil
        dataQueue.async { self.recorder.stop() }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Foco por toque

    /// `point` vai de 0 a 1 na tela (em pé).
    func focus(at point: CGPoint) {
        guard !isManual else { return }
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            let poi = CGPoint(x: point.y, y: 1 - point.x)
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = poi
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = poi
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Controles manuais (Modo Pro)

    func setManualValue(_ value: Double) {
        isManual = true
        switch proParam {
        case .iso: iso = Float(value)
        case .shutter: shutterSeconds = value
        case .wb: whiteBalance = Float(value)
        case .focus: focus = Float(value)
        case .ev: exposureBias = Float(value)
        }
        let param = proParam
        let iso = self.iso, shutter = self.shutterSeconds, wb = self.whiteBalance
        let focus = self.focus, bias = self.exposureBias
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                switch param {
                case .iso, .shutter:
                    if device.isExposureModeSupported(.custom) {
                        let format = device.activeFormat
                        let clampedISO = min(max(iso, format.minISO), format.maxISO)
                        let minS = CMTimeGetSeconds(format.minExposureDuration)
                        let maxS = CMTimeGetSeconds(format.maxExposureDuration)
                        let seconds = min(max(shutter, minS), maxS)
                        let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
                        device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
                    }
                case .wb:
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: wb, tint: 0)
                        var gains = device.deviceWhiteBalanceGains(for: tt)
                        let maxGain = device.maxWhiteBalanceGain
                        gains.redGain = min(max(gains.redGain, 1), maxGain)
                        gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                        gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                    }
                case .focus:
                    if device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition: focus, completionHandler: nil)
                    }
                case .ev:
                    let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
                    device.setExposureTargetBias(clamped, completionHandler: nil)
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func resetToAuto() {
        isManual = false
        exposureBias = 0
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                device.setExposureTargetBias(0, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func updateRanges(for device: AVCaptureDevice) {
        let format = device.activeFormat
        let minISO = format.minISO, maxISO = format.maxISO
        let minS = max(CMTimeGetSeconds(format.minExposureDuration), 1.0 / 16000.0)
        let maxS = min(CMTimeGetSeconds(format.maxExposureDuration), 1.0 / 4.0)
        let minB = max(device.minExposureTargetBias, -3), maxB = min(device.maxExposureTargetBias, 3)
        DispatchQueue.main.async {
            if minISO < maxISO { self.isoRange = minISO...maxISO }
            if minS < maxS { self.shutterRange = minS...maxS }
            if minB < maxB { self.biasRange = minB...maxB }
        }
    }

    /// Atualiza ISO/velocidade mostrados quando está no automático.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, !self.isManual, let device = self.videoInput?.device else { return }
            self.iso = device.iso
            self.shutterSeconds = CMTimeGetSeconds(device.exposureDuration)
            self.focus = device.lensPosition
        }
    }

    // MARK: - Utilidades

    private func updateRenderSettings() {
        settingsLock.lock()
        renderLook = look
        renderIntensity = Float(intensity)
        settingsLock.unlock()
    }

    func refreshStorage() {
        let bytes = Double(Storage.availableBytes())
        minutesLeft = Int(bytes / (quality.megabytesPerMinute * 1_000_000))
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    func openPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Quadros da câmera

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            settingsLock.lock()
            let look = renderLook
            let intensity = renderIntensity
            settingsLock.unlock()

            let source = CIImage(cvPixelBuffer: pixelBuffer)
            let filtered = LookEngine.render(source, look: look, intensity: intensity)
            renderer.display(filtered)
            recorder.appendVideo(filtered, sampleBuffer: sampleBuffer, context: ciContext)

            let iso = videoInput?.device.iso ?? 100
            sceneDetector.analyze(pixelBuffer, iso: iso)
        } else if output === audioOutput {
            recorder.appendAudio(sampleBuffer)
        }
    }
}

// MARK: - Processamento da foto

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let look: Look
    private let intensity: Float
    private let context: CIContext
    private let completion: (UIImage?, String) -> Void
    private var processedData: Data?
    private var rawData: Data?

    init(look: Look, intensity: Float, context: CIContext, completion: @escaping (UIImage?, String) -> Void) {
        self.look = look
        self.intensity = intensity
        self.context = context
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            rawData = data
        } else {
            processedData = data
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(nil, "Erro na foto: \(error.localizedDescription)")
            return
        }
        var finalData: Data?
        var thumb: UIImage?
        if let data = processedData,
           let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            let result = LookEngine.render(image, look: look, intensity: intensity)
            let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            finalData = context.heifRepresentation(of: result, format: .RGBA8, colorSpace: colorSpace, options: [:])
                ?? context.jpegRepresentation(of: result, colorSpace: colorSpace, options: [:])
            thumb = Thumbnail.make(from: result, context: context)
        }
        let hasRaw = rawData != nil
        PhotoSaver.savePhoto(main: finalData, raw: rawData) { [completion] ok in
            completion(thumb, ok ? (hasRaw ? "Foto + RAW salvas" : "Foto salva") : "Não consegui salvar na galeria")
        }
    }
}
