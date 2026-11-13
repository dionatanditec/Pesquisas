import AVFoundation
import CoreImage
import CoreLocation
import Photos
import UIKit
import Combine

enum CaptureMode: String, CaseIterable, Identifiable {
    case pro = "PRO", photo = "FOTO", video = "VÍDEO"
    var id: String { rawValue }
}

enum ProParam: String, CaseIterable, Identifiable {
    case iso = "ISO", shutter = "VELOC.", wb = "BRANCO", tint = "TINT", focus = "FOCO", ev = "EV"
    var id: String { rawValue }
}

enum QualityProfile: String, CaseIterable, Identifiable {
    case social = "Redes · 1080p"
    case max = "Auto Máx · 4K"
    var id: String { rawValue }
    var megabytesPerMinute: Double { self == .max ? 190 : 60 }
}

enum FlashChoice: String, CaseIterable, Identifiable {
    case off = "Desligado", auto = "Automático", on = "Ligado"
    var id: String { rawValue }
    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }
    var symbol: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .auto: return "bolt.badge.automatic.fill"
        case .on: return "bolt.fill"
        }
    }
}

struct ZoomPreset: Identifiable, Equatable {
    let label: String
    let factor: CGFloat
    var id: String { label }
}

/// O "motor" da câmera: sessão, fotos, vídeos, zoom, controles manuais e looks.
final class CameraModel: NSObject, ObservableObject {
    // MARK: Estado da tela (as escolhas ficam salvas no aparelho)
    @Published var mode: CaptureMode = .photo
    @Published var look: Look = .natural { didSet { updateRenderSettings(); Prefs.set(look.rawValue, "look") } }
    @Published var intensity: Double = 0.8 { didSet { updateRenderSettings(); Prefs.set(intensity, "intensity") } }
    @Published var autoScene = true { didSet { Prefs.set(autoScene, "autoScene") } }
    @Published var showGrid = false { didSet { Prefs.set(showGrid, "showGrid") } }
    @Published var rawEnabled = false { didSet { Prefs.set(rawEnabled, "raw") } }
    @Published var flash: FlashChoice = .off { didSet { Prefs.set(flash.rawValue, "flash") } }
    @Published var photoMegapixels = 24 { didSet { Prefs.set(photoMegapixels, "mp") } }
    @Published var frameRate = 30 { didSet { Prefs.set(frameRate, "fps") } }
    @Published var useLocation = true { didSet { Prefs.set(useLocation, "location"); useLocation ? location.start() : location.stop() } }
    @Published var keepHDR = true { didSet { Prefs.set(keepHDR, "hdr") } }
    @Published var quality: QualityProfile = .max

    @Published var detectedScene = ""
    @Published var zoomPresets: [ZoomPreset] = [ZoomPreset(label: "1×", factor: 1)]
    @Published var zoomFactor: CGFloat = 1
    @Published var wideFactor: CGFloat = 1
    @Published var isFront = false
    @Published var rawSupported = false
    @Published var flashSupported = false
    @Published var torchOn = false
    @Published var availableMegapixels: [Int] = [12]
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var lastThumbnail: UIImage?
    @Published var minutesLeft = 0
    @Published var toast: String?
    @Published var permissionDenied = false
    @Published var aeafLocked = false
    @Published var hasReview = false

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
    @Published var showHistogram = true
    @Published var showZebra = false
    @Published var showPeaking = false
    @Published var histogram: [Float] = []
    @Published var tint: Float = 0
    @Published var focusA: Float?
    @Published var focusB: Float?

    // MARK: v1.2: desfoque de fundo, enquadramento e ferramentas do Blackmagic
    @Published var blurOn = false { didSet { Prefs.set(blurOn, "blurOn"); updateRenderSettings() } }
    @Published var blurAperture: Double = 2.8 { didSet { Prefs.set(blurAperture, "blurAperture"); updateRenderSettings() } }
    @Published var frameAspect: FrameAspect = .off { didSet { Prefs.set(frameAspect.rawValue, "aspect") } }
    @Published var cropOnSave = true { didSet { Prefs.set(cropOnSave, "cropOnSave") } }
    @Published var showSafeArea = false { didSet { Prefs.set(showSafeArea, "safeArea") } }
    @Published var showFalseColor = false { didSet { updateOverlays() } }
    @Published var zebraLevel: Double = 95 { didSet { Prefs.set(zebraLevel, "zebraLevel"); updateOverlays() } }
    @Published var peakColor: PeakColor = .green { didSet { Prefs.set(peakColor.rawValue, "peakColor"); updateOverlays() } }
    @Published var lockWBOnRecord = true { didSet { Prefs.set(lockWBOnRecord, "lockWB") } }
    @Published var cinemaShutter = false {
        didSet {
            Prefs.set(cinemaShutter, "cinemaShutter")
            if !cinemaShutter, mode == .video, !isManual { restoreAutoExposure() }
        }
    }
    @Published var lutName: String?

    /// Posição do celular no momento da foto/vídeo (90 = em pé, 0/180 = deitado).
    var captureAngle: CGFloat = 90

    var displayZoom: CGFloat { zoomFactor / max(wideFactor, 0.01) }

    let session = AVCaptureSession()
    let renderer = PreviewRenderer()
    let location = LocationProvider()

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
    private var observers: [NSObjectProtocol] = []

    private let settingsLock = NSLock()
    private var renderLook: Look = .natural
    private var renderIntensity: Float = 0.8
    private var overlayZebra = false
    private var overlayPeaking = false
    private var overlayHistogram = false
    private var overlayFalseColor = false
    private var overlayZebraLevel: Float = 0.95
    private var overlayPeakColor = CIColor(red: 0.22, green: 1, blue: 0.42)
    private var renderBlur = false
    private var renderAperture: Double = 2.8
    private var lastHistogram = Date.distantPast

    // Máscara do assunto no visor (atualizada algumas vezes por segundo, fora da fila da câmera).
    private var liveMask: CIImage?
    private var maskBusy = false
    private var lastMaskTime = Date.distantPast
    private let maskQueue = DispatchQueue(label: "topcam.mask", qos: .userInitiated)
    private var wbLockedForRecording = false

    // Última foto, para a tela de revisão (trocar o look depois).
    private var lastPhotoData: Data?
    private var lastPhotoMetadata: [String: Any] = [:]
    private var lastPhotoLocation: CLLocation?

    private var recordTimer: Timer?
    private var pollTimer: Timer?

    var ciContext: CIContext { renderer.ciContext }

    override init() {
        super.init()
        // Carrega as escolhas salvas.
        if let l = Prefs.string("look"), let saved = Look(rawValue: l) { look = saved }
        intensity = Prefs.double("intensity", 0.8)
        autoScene = Prefs.bool("autoScene", true)
        showGrid = Prefs.bool("showGrid", false)
        rawEnabled = Prefs.bool("raw", false)
        if let f = Prefs.string("flash"), let saved = FlashChoice(rawValue: f) { flash = saved }
        photoMegapixels = Prefs.int("mp", 24)
        frameRate = Prefs.int("fps", 30)
        useLocation = Prefs.bool("location", true)
        keepHDR = Prefs.bool("hdr", true)
        blurOn = Prefs.bool("blurOn", false)
        blurAperture = Prefs.double("blurAperture", 2.8)
        if let a = Prefs.string("aspect"), let saved = FrameAspect(rawValue: a) { frameAspect = saved }
        cropOnSave = Prefs.bool("cropOnSave", true)
        showSafeArea = Prefs.bool("safeArea", false)
        zebraLevel = Prefs.double("zebraLevel", 95)
        if let c = Prefs.string("peakColor"), let saved = PeakColor(rawValue: c) { peakColor = saved }
        lockWBOnRecord = Prefs.bool("lockWB", true)
        cinemaShutter = Prefs.bool("cinemaShutter", false)
        lutName = LUTStore.shared.name
        if look == .lut && !LUTStore.shared.hasLUT { look = .natural }
        updateRenderSettings()

        sceneDetector.onResult = { [weak self] suggested, label in
            guard let self, self.autoScene, self.mode != .pro else { return }
            self.detectedScene = label
            if self.look != suggested { self.look = suggested }
        }
        recorder.onFinished = { [weak self] url in
            guard let self else { return }
            guard let url else {
                DispatchQueue.main.async { self.showToast("Não consegui gravar o vídeo") }
                return
            }
            let loc = self.useLocation ? self.location.lastLocation : nil
            PhotoSaver.saveVideo(url: url, location: loc) { ok in
                DispatchQueue.main.async {
                    self.showToast(ok ? "Vídeo salvo na galeria" : "Não consegui salvar o vídeo")
                    self.refreshStorage()
                }
            }
        }
        observeSystem()
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
                if self.useLocation { self.location.start() }
                self.refreshStorage()
                self.startPolling()
            }
        }
    }

    func stop() {
        if isRecording { stopRecording() }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.stopRecording()
            self.showToast("Gravação interrompida e salva")
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical {
                if self.mode == .video, self.quality == .max, !self.isRecording {
                    self.setQuality(.social)
                    self.showToast("iPhone quente: vídeo em 1080p")
                } else {
                    self.showToast("iPhone quente: dê uma pausa se puder")
                }
            }
        })
    }

    private func configure(withMicrophone mic: Bool) {
        session.beginConfiguration()

        if let device = Self.bestBackCamera() {
            setDevice(device)
        }

        if mic, let micDevice = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: micDevice), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        // YUV: metade dos dados do BGRA, visor mais rápido.
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if audioInput != nil, session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        applyPresetLocked()
        configurePhotoOutput()
        configureConnections()
        session.commitConfiguration()
        applyFrameRate()
        setInitialZoom()
    }

    /// Câmera virtual da Apple (tripla/dupla): zoom suave e macro automático.
    private static func bestBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera,
                                                   .builtInDualCamera, .builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
        }
        return nil
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
        updateZoomPresets(for: device)
        let flashOK = device.hasFlash
        DispatchQueue.main.async {
            self.flashSupported = flashOK
            self.torchOn = false
        }
    }

    private func updateZoomPresets(for device: AVCaptureDevice) {
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let types = device.constituentDevices.map { $0.deviceType }
        let hasUltra = types.contains(.builtInUltraWideCamera)
        let hasTele = types.contains(.builtInTelephotoCamera)
        let wide: CGFloat = hasUltra ? (switches.first ?? 1) : 1
        let maxZoom = min(device.maxAvailableVideoZoomFactor, wide * 15)
        var presets: [ZoomPreset] = []
        if hasUltra { presets.append(ZoomPreset(label: "0,5", factor: 1)) }
        presets.append(ZoomPreset(label: "1×", factor: wide))
        let tele = hasTele ? switches.last : nil
        if wide * 2 <= maxZoom, (tele ?? .greatestFiniteMagnitude) > wide * 2.2 {
            presets.append(ZoomPreset(label: "2×", factor: wide * 2))
        }
        if let tele, tele > wide {
            let x = (tele / wide)
            let label = x.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(x))×" : String(format: "%.1f×", x)
            presets.append(ZoomPreset(label: label, factor: tele))
        }
        DispatchQueue.main.async {
            self.wideFactor = wide
            self.zoomPresets = presets
        }
    }

    private func setInitialZoom() {
        sessionQueue.async {
            guard let device = self.videoInput?.device, device.position == .back else { return }
            let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            let hasUltra = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
            let wide: CGFloat = hasUltra ? (switches.first ?? 1) : 1
            self.applyZoom(wide, ramp: false)
        }
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
        guard let device = videoInput?.device else { return }
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        if let biggest = dims.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = biggest
        }
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }
        let rawOK = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let mps = Array(Set(dims.map { Self.bucket(megapixels: Double(Int($0.width) * Int($0.height)) / 1_000_000) })).sorted()
        DispatchQueue.main.async {
            self.rawSupported = rawOK
            if !rawOK { self.rawEnabled = false }
            self.availableMegapixels = mps.isEmpty ? [12] : mps
        }
    }

    private static func bucket(megapixels mp: Double) -> Int {
        if mp > 36 { return 48 }
        if mp > 18 { return 24 }
        return 12
    }

    private func photoDimensions(for megapixels: Int) -> CMVideoDimensions? {
        guard let dims = videoInput?.device.activeFormat.supportedMaxPhotoDimensions, !dims.isEmpty else { return nil }
        let matching = dims.filter { Self.bucket(megapixels: Double(Int($0.width) * Int($0.height)) / 1_000_000) == megapixels }
        if let m = matching.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) { return m }
        return dims.min(by: {
            abs(Double(Int($0.width) * Int($0.height)) / 1e6 - Double(megapixels)) <
            abs(Double(Int($1.width) * Int($1.height)) / 1e6 - Double(megapixels))
        })
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

    /// 24, 30 ou 60 quadros por segundo no vídeo.
    private func applyFrameRate() {
        sessionQueue.async {
            guard self.mode == .video, let device = self.videoInput?.device else { return }
            let fps = Double(self.frameRate)
            let targetWidth: Int32 = self.quality == .max ? 3840 : 1920
            func supports(_ f: AVCaptureDevice.Format) -> Bool {
                f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps - 0.01 && $0.minFrameRate <= fps + 0.01 }
            }
            do { try device.lockForConfiguration() } catch { return }
            if !supports(device.activeFormat) {
                let candidates = device.formats.filter {
                    CMVideoFormatDescriptionGetDimensions($0.formatDescription).width == targetWidth && supports($0)
                }
                if let format = candidates.last {
                    device.activeFormat = format
                } else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async { self.showToast("\(self.frameRate) fps não disponível nesta qualidade") }
                    return
                }
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        }
    }

    private func reconfigure() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.applyPresetLocked()
            self.configurePhotoOutput()
            self.configureConnections()
            self.session.commitConfiguration()
            if let d = self.videoInput?.device { self.updateRanges(for: d) }
        }
        applyFrameRate()
    }

    // MARK: - Modo, zoom, câmera frontal, qualidade

    func setMode(_ newMode: CaptureMode) {
        guard !isRecording, newMode != mode else { return }
        if torchOn { setTorch(false) }
        let wasVideo = mode == .video
        mode = newMode
        if newMode != .pro && isManual { resetToAuto() }
        if wasVideo && cinemaShutter && !isManual { restoreAutoExposure() }
        updateRenderSettings()
        updateOverlays()
        reconfigure()
    }

    func setQuality(_ newQuality: QualityProfile) {
        guard !isRecording else { return }
        quality = newQuality
        refreshStorage()
        reconfigure()
    }

    func setFrameRate(_ fps: Int) {
        guard !isRecording else { return }
        frameRate = fps
        reconfigure()
    }

    func selectZoom(_ preset: ZoomPreset) {
        sessionQueue.async { self.applyZoom(preset.factor, ramp: true) }
    }

    /// Zoom pela pinça, em "vezes" (1 = lente principal).
    func setDisplayZoom(_ display: CGFloat) {
        let factor = display * wideFactor
        sessionQueue.async { self.applyZoom(factor, ramp: false) }
    }

    private func applyZoom(_ factor: CGFloat, ramp: Bool) {
        guard let device = videoInput?.device else { return }
        let maxZoom = min(device.maxAvailableVideoZoomFactor, max(wideFactor, 1) * 15)
        let f = min(max(factor, device.minAvailableVideoZoomFactor), maxZoom)
        do {
            try device.lockForConfiguration()
            if ramp {
                device.ramp(toVideoZoomFactor: f, withRate: 6)
            } else {
                device.videoZoomFactor = f
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = f }
        } catch {}
    }

    func flipCamera() {
        guard !isRecording else { return }
        isFront.toggle()
        let front = isFront
        sessionQueue.async {
            let device = front
                ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                : Self.bestBackCamera()
            guard let device else { return }
            self.session.beginConfiguration()
            self.setDevice(device)
            self.applyPresetLocked()
            self.configurePhotoOutput()
            self.configureConnections()
            self.session.commitConfiguration()
            if !front { self.setInitialZoom() } else { DispatchQueue.main.async { self.zoomFactor = 1; self.wideFactor = 1 } }
        }
        applyFrameRate()
        DispatchQueue.main.async { self.isManual = false; self.aeafLocked = false }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.videoInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.torchOn = on }
            } catch {}
        }
    }

    // MARK: - Foto

    func capturePhoto() {
        let wantRaw = rawEnabled && rawSupported
        settingsLock.lock()
        let look = renderLook
        let intensity = renderIntensity
        settingsLock.unlock()
        let angle = captureAngle
        let flashMode = flash.avMode
        let megapixels = photoMegapixels
        let keepHDR = self.keepHDR
        let loc = useLocation ? location.lastLocation : nil
        let blur: BlurOptions? = blurOn ? BlurOptions(aperture: blurAperture) : nil
        let aspect: CGFloat? = cropOnSave ? frameAspect.ratio : nil

        sessionQueue.async {
            if let connection = self.photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
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
                if let dims = self.photoDimensions(for: megapixels) {
                    settings.maxPhotoDimensions = dims
                }
                settings.photoQualityPrioritization = .quality
            }
            if self.photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(look: look, intensity: intensity, keepHDR: keepHDR,
                                                  blur: blur, aspect: aspect,
                                                  location: loc, context: self.ciContext) { [weak self] result in
                DispatchQueue.main.async {
                    if let thumb = result.thumbnail { self?.lastThumbnail = thumb }
                    if let data = result.processedData {
                        self?.lastPhotoData = data
                        self?.lastPhotoMetadata = result.metadata
                        self?.lastPhotoLocation = loc
                        self?.hasReview = true
                    }
                    self?.showToast(result.message)
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

    // MARK: - Revisão: trocar o look da última foto

    static let reviewSide: CGFloat = 1400

    private func reviewBase() -> CIImage? {
        guard let data = lastPhotoData,
              let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let scale = min(1, Self.reviewSide / max(image.extent.width, image.extent.height))
        return image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Separa pessoas/assunto da última foto (para escolher quem fica nítido).
    func reviewMasks() -> SubjectMasks? {
        guard let base = reviewBase() else { return nil }
        return BackgroundBlur.segment(base, maxSide: Self.reviewSide, context: ciContext)
    }

    func reviewPreview(look: Look, intensity: Double, blur: BlurOptions? = nil, mask: CIImage? = nil) -> UIImage? {
        guard var image = reviewBase() else { return nil }
        if let blur, let mask { image = BackgroundBlur.apply(to: image, mask: mask, options: blur) }
        let result = LookEngine.render(image, look: look, intensity: Float(intensity))
        guard let cg = ciContext.createCGImage(result, from: result.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    func saveReviewVersion(look: Look, intensity: Double, blur: BlurOptions? = nil, mask: CIImage? = nil) {
        guard let data = lastPhotoData else { return }
        let meta = lastPhotoMetadata
        let loc = lastPhotoLocation
        let keepHDR = self.keepHDR
        let context = ciContext
        let aspect: CGFloat? = cropOnSave ? frameAspect.ratio : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let encoded = PhotoCaptureProcessor.encode(data: data, metadata: meta, look: look,
                                                       intensity: Float(intensity), keepHDR: keepHDR, context: context,
                                                       blur: blur, mask: mask, aspect: aspect, skipSegmentation: blur != nil && mask == nil)
            PhotoSaver.savePhoto(main: encoded.data, raw: nil, location: loc) { ok in
                DispatchQueue.main.async {
                    if let t = encoded.thumbnail { self.lastThumbnail = t }
                    self.showToast(ok ? "Nova versão salva (\(look.title))" : "Não consegui salvar")
                }
            }
        }
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
        let rotation = (captureAngle - 90) * .pi / 180
        let fps = frameRate
        if lockWBOnRecord && !isManual { setWhiteBalanceLock(true) }
        dataQueue.async {
            self.recorder.start(audioSettings: audioSettings,
                                transform: CGAffineTransform(rotationAngle: rotation),
                                frameRate: fps)
        }
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

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        recordTimer = nil
        dataQueue.async { self.recorder.stop() }
        if wbLockedForRecording { setWhiteBalanceLock(false) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Foco e exposição pelo toque

    /// `point` vai de 0 a 1 dentro da imagem (em pé). Toque destrava o AE/AF.
    func focus(at point: CGPoint) {
        guard !isManual else { return }
        let poi = CGPoint(x: point.y, y: 1 - point.x)
        DispatchQueue.main.async { self.aeafLocked = false }
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = poi
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = poi
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Toque longo: foca e trava foco + exposição.
    func lockFocusAndExposure(at point: CGPoint) {
        guard !isManual else { return }
        focus(at: point)
        sessionQueue.asyncAfter(deadline: .now() + 0.6) {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.aeafLocked = true
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
            } catch {}
        }
    }

    /// Brilho rápido (funciona no automático).
    func setExposureBias(_ value: Float) {
        exposureBias = value
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Controles manuais (Modo Pro)

    func setManualValue(_ value: Double) {
        if proParam == .ev {
            setExposureBias(Float(value))
            return
        }
        isManual = true
        switch proParam {
        case .iso: iso = Float(value)
        case .shutter: shutterSeconds = value
        case .wb: whiteBalance = Float(value)
        case .tint: tint = Float(value)
        case .focus: focus = Float(value)
        case .ev: break
        }
        let param = proParam
        let iso = self.iso, shutter = self.shutterSeconds, wb = self.whiteBalance
        let tint = self.tint
        let focus = self.focus
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
                case .wb, .tint:
                    Self.lockWhiteBalance(device, temperature: wb, tint: tint)
                case .focus:
                    if device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition: focus, completionHandler: nil)
                    }
                case .ev:
                    break
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Branco em Kelvin + tint (verde/magenta), igual ao Blackmagic. Chamar com o aparelho travado.
    private static func lockWhiteBalance(_ device: AVCaptureDevice, temperature: Float, tint: Float) {
        guard device.isWhiteBalanceModeSupported(.locked) else { return }
        let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint)
        var gains = device.deviceWhiteBalanceGains(for: tt)
        let maxGain = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1), maxGain)
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
    }

    /// Presets de branco: Sol, Nublado, Sombra, Incandescente, Fluorescente.
    func setWhiteBalancePreset(_ kelvin: Float) {
        proParam = .wb
        tint = 0
        setManualValue(Double(kelvin))
    }

    /// Trava o branco durante a gravação (a cor não muda no meio do vídeo).
    private func setWhiteBalanceLock(_ lock: Bool) {
        wbLockedForRecording = lock
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if lock, device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                } else if !lock, device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Rack focus (passa o foco suavemente de um ponto salvo para outro)

    func saveFocusPoint(_ slot: Int) {
        let value = videoInput?.device.lensPosition ?? focus
        if slot == 0 { focusA = value } else { focusB = value }
        showToast("Foco \(slot == 0 ? "A" : "B") salvo")
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    func rackFocus(to target: Float, seconds: Double = 1.2) {
        isManual = true
        let start = videoInput?.device.lensPosition ?? focus
        let steps = 36
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * Double(i) / Double(steps)) {
                let t = Float(i) / Float(steps)
                let eased = t * t * (3 - 2 * t)
                let value = start + (target - start) * eased
                self.focus = value
                self.sessionQueue.async {
                    guard let device = self.videoInput?.device, device.isLockingFocusWithCustomLensPositionSupported else { return }
                    do {
                        try device.lockForConfiguration()
                        device.setFocusModeLocked(lensPosition: value, completionHandler: nil)
                        device.unlockForConfiguration()
                    } catch {}
                }
            }
        }
    }

    // MARK: - Obturador de cinema (180°) sem piscar na luz de LED (60 Hz)

    private func adjustCinemaExposure() {
        let fps = Double(frameRate)
        sessionQueue.async {
            guard let device = self.videoInput?.device, device.isExposureModeSupported(.custom) else { return }
            let target = fps > 30 ? 1.0 / 120.0 : 1.0 / 60.0
            let format = device.activeFormat
            var iso = device.iso
            if device.exposureMode == .custom {
                let offset = device.exposureTargetOffset
                guard abs(offset) > 0.12 else { return }
                iso *= powf(2, -offset * 0.6)
            } else {
                iso *= Float(CMTimeGetSeconds(device.exposureDuration) / target)
            }
            iso = min(max(iso, format.minISO), format.maxISO)
            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(duration: CMTime(seconds: target, preferredTimescale: 1_000_000),
                                             iso: iso, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func restoreAutoExposure() {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - LUT

    func importLUT(_ url: URL) {
        if LUTStore.shared.importCube(from: url) {
            lutName = LUTStore.shared.name
            autoScene = false
            look = .lut
            showToast("LUT importado: \(lutName ?? "")")
        } else {
            showToast("Arquivo .cube inválido")
        }
    }

    func removeLUT() {
        LUTStore.shared.remove()
        lutName = nil
        if look == .lut { look = .natural }
    }

    func resetToAuto() {
        isManual = false
        tint = 0
        aeafLocked = false
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
            guard let self, let device = self.videoInput?.device else { return }
            if !self.isManual {
                self.iso = device.iso
                self.shutterSeconds = CMTimeGetSeconds(device.exposureDuration)
                self.focus = device.lensPosition
            }
            if !device.isRampingVideoZoom { self.zoomFactor = device.videoZoomFactor }
            if self.mode == .video, self.cinemaShutter, !self.isManual { self.adjustCinemaExposure() }
        }
    }

    // MARK: - Utilidades

    func updateOverlays() {
        settingsLock.lock()
        overlayZebra = mode == .pro && showZebra
        overlayPeaking = mode == .pro && showPeaking
        overlayHistogram = mode == .pro && showHistogram
        overlayFalseColor = mode == .pro && showFalseColor
        overlayZebraLevel = Float(zebraLevel / 100)
        overlayPeakColor = peakColor.ciColor
        settingsLock.unlock()
    }

    private func updateRenderSettings() {
        settingsLock.lock()
        renderLook = look
        renderIntensity = Float(intensity)
        renderBlur = blurOn && mode != .video
        renderAperture = blurAperture
        if !renderBlur { liveMask = nil }
        settingsLock.unlock()
    }

    func refreshStorage() {
        let bytes = Double(Storage.availableBytes())
        let perMinute = quality.megabytesPerMinute * Double(frameRate) / 30.0
        minutesLeft = Int(bytes / (perMinute * 1_000_000))
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
            let zebra = overlayZebra, peaking = overlayPeaking, wantHistogram = overlayHistogram
            let falseColor = overlayFalseColor, zebraLevel = overlayZebraLevel, peakColor = overlayPeakColor
            let blurOn = renderBlur, aperture = renderAperture, mask = liveMask
            settingsLock.unlock()

            let source = CIImage(cvPixelBuffer: pixelBuffer)

            // Visor leve: aplica o look já no tamanho da tela (menos calor e bateria).
            let previewScale = min(1, 960 / max(source.extent.width, source.extent.height))
            let small = source.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
            var base = small
            if blurOn {
                if let mask { base = BackgroundBlur.apply(to: small, mask: mask, options: BlurOptions(aperture: aperture)) }
                updateLiveMask(from: small)
            }
            var preview = LookEngine.render(base, look: look, intensity: intensity)
            if falseColor { preview = ProOverlays.falseColor(preview) }
            if peaking { preview = ProOverlays.focusPeaking(preview, color: peakColor) }
            if zebra { preview = ProOverlays.zebra(preview, level: zebraLevel) }
            renderer.display(preview)

            // Gravação em resolução cheia, só quando está gravando.
            if recorder.isActive {
                let full = LookEngine.render(source, look: look, intensity: intensity)
                recorder.appendVideo(full, sampleBuffer: sampleBuffer, context: ciContext)
            }

            if wantHistogram, Date().timeIntervalSince(lastHistogram) > 0.4 {
                lastHistogram = Date()
                let tiny = small.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
                let h = ProOverlays.histogram(of: LookEngine.render(tiny, look: look, intensity: intensity), context: ciContext)
                DispatchQueue.main.async { self.histogram = h }
            }

            let iso = videoInput?.device.iso ?? 100
            sceneDetector.analyze(small, iso: iso, context: ciContext)
        } else if output === audioOutput {
            recorder.appendAudio(sampleBuffer)
        }
    }

    /// Recalcula a máscara do assunto no visor ~4 vezes por segundo, sem travar a câmera.
    private func updateLiveMask(from image: CIImage) {
        settingsLock.lock()
        if maskBusy || Date().timeIntervalSince(lastMaskTime) < 0.25 { settingsLock.unlock(); return }
        maskBusy = true
        lastMaskTime = Date()
        settingsLock.unlock()

        let scale = 512 / max(image.extent.width, image.extent.height)
        let tiny = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(tiny, from: tiny.extent) else {
            settingsLock.lock(); maskBusy = false; settingsLock.unlock()
            return
        }
        maskQueue.async {
            let mask = BackgroundBlur.segment(cgImage: cg, perInstance: false)?.all
            self.settingsLock.lock()
            if self.renderBlur { self.liveMask = mask }
            self.maskBusy = false
            self.settingsLock.unlock()
        }
    }
}

// MARK: - Processamento da foto

struct PhotoResult {
    var thumbnail: UIImage?
    var processedData: Data?
    var metadata: [String: Any]
    var message: String
}

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let look: Look
    private let intensity: Float
    private let keepHDR: Bool
    private let blur: BlurOptions?
    private let aspect: CGFloat?
    private let location: CLLocation?
    private let context: CIContext
    private let completion: (PhotoResult) -> Void
    private var processedData: Data?
    private var metadata: [String: Any] = [:]
    private var rawData: Data?

    init(look: Look, intensity: Float, keepHDR: Bool, blur: BlurOptions?, aspect: CGFloat?,
         location: CLLocation?, context: CIContext,
         completion: @escaping (PhotoResult) -> Void) {
        self.look = look
        self.intensity = intensity
        self.keepHDR = keepHDR
        self.blur = blur
        self.aspect = aspect
        self.location = location
        self.context = context
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            rawData = data
        } else {
            processedData = data
            metadata = photo.metadata
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(PhotoResult(thumbnail: nil, processedData: nil, metadata: [:], message: "Erro na foto: \(error.localizedDescription)"))
            return
        }
        let processed = processedData
        let meta = metadata
        let raw = rawData
        let look = self.look, intensity = self.intensity, keepHDR = self.keepHDR
        let blur = self.blur, aspect = self.aspect
        let context = self.context, loc = self.location, completion = self.completion
        DispatchQueue.global(qos: .userInitiated).async {
            var encoded: (data: Data?, thumbnail: UIImage?) = (nil, nil)
            if let processed {
                encoded = Self.encode(data: processed, metadata: meta, look: look, intensity: intensity,
                                      keepHDR: keepHDR, context: context, blur: blur, aspect: aspect)
            }
            let hasRaw = raw != nil
            PhotoSaver.savePhoto(main: encoded.data, raw: raw, location: loc) { ok in
                let message = ok ? (hasRaw ? "Foto + RAW salvas" : "Foto salva") : "Não consegui salvar na galeria"
                completion(PhotoResult(thumbnail: encoded.thumbnail, processedData: processed, metadata: meta, message: message))
            }
        }
    }

    /// Aplica o look, mantém os dados da foto (EXIF) e o brilho HDR da Apple quando possível.
    static func encode(data: Data, metadata: [String: Any], look: Look, intensity: Float,
                       keepHDR: Bool, context: CIContext,
                       blur: BlurOptions? = nil, mask: CIImage? = nil, aspect: CGFloat? = nil,
                       skipSegmentation: Bool = false) -> (data: Data?, thumbnail: UIImage?) {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return (nil, nil) }

        // Dados da câmera sem a orientação (a imagem já está na posição certa).
        var props = metadata
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        // Desfoque de fundo: acha a pessoa/assunto e desfoca o resto.
        var subject = mask
        if blur != nil, subject == nil, !skipSegmentation {
            subject = BackgroundBlur.segment(image, maxSide: 1536, context: context)?.all
        }
        func finish(_ input: CIImage) -> CIImage {
            var out = input
            if let blur, let subject { out = BackgroundBlur.apply(to: out, mask: subject, options: blur) }
            out = LookEngine.render(out, look: look, intensity: intensity)
            if let aspect { out = FrameAspect.crop(out, ratio: aspect) }
            return out
        }

        let result = finish(image).settingProperties(props)
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        var options: [CIImageRepresentationOption: Any] = [:]

        if keepHDR, #available(iOS 18.0, *),
           let hdr = CIImage(data: data, options: [.applyOrientationProperty: true, .expandToHDR: true]) {
            options[.hdrImage] = finish(hdr)
        }

        let out = context.heifRepresentation(of: result, format: .RGBA8, colorSpace: colorSpace, options: options)
            ?? context.jpegRepresentation(of: result, colorSpace: colorSpace, options: [:])
        return (out, Thumbnail.make(from: result, context: context))
    }
}
