import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers

extension Color {
    static let topAccent = Color(red: 1.0, green: 0.643, blue: 0.106)
    static let topPanel = Color(red: 0.03, green: 0.03, blue: 0.035).opacity(0.9)
    static let topSecondary = Color(red: 0.725, green: 0.706, blue: 0.675)
    static let topRec = Color(red: 0.898, green: 0.196, blue: 0.176)
    static let topLevel = Color(red: 0.29, green: 0.87, blue: 0.5)
}

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var level = LevelMonitor()
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    @State private var showSettings = false
    @State private var showReview = false
    @State private var timerSeconds = 0
    @State private var countdown = 0
    @State private var pinchStart: CGFloat?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                MetalPreview(renderer: camera.renderer)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            handleTap(value.location, size: geo.size, lock: false)
                        }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.6)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onEnded { value in
                                if case .second(true, let drag?) = value {
                                    handleTap(drag.startLocation, size: geo.size, lock: true)
                                }
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { scale in
                                if pinchStart == nil { pinchStart = camera.displayZoom }
                                camera.setDisplayZoom((pinchStart ?? 1) * scale)
                            }
                            .onEnded { _ in pinchStart = nil }
                    )
                    .overlay {
                        if let fp = focusPoint {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.topAccent, lineWidth: 1.5)
                                .frame(width: 84, height: 84)
                                .position(fp)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if camera.mode != .video, camera.frameAspect != .off || camera.showSafeArea {
                            let f = camera.renderer.frameInView
                            FrameGuideOverlay(ratio: camera.frameAspect.ratio, safeArea: camera.showSafeArea)
                                .frame(width: geo.size.width * f.width, height: geo.size.height * f.height)
                                .position(x: geo.size.width * f.midX, y: geo.size.height * f.midY)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if camera.showGrid {
                            let f = camera.renderer.frameInView
                            GridOverlay()
                                .frame(width: geo.size.width * f.width, height: geo.size.height * f.height)
                                .position(x: geo.size.width * f.midX, y: geo.size.height * f.midY)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .ignoresSafeArea()

            LevelIndicator(roll: level.roll, isFlat: level.isFlat)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                statusRow.padding(.top, 8)
                Spacer()
                if focusPoint != nil && !camera.isManual {
                    brightnessRow.padding(.horizontal, 40).padding(.bottom, 10)
                }
                zoomSelector.padding(.bottom, 12)
                bottomPanel
            }

            if countdown > 0 {
                Text("\(countdown)")
                    .font(.system(size: 120, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(radius: 10)
                    .allowsHitTesting(false)
            }

            if let toast = camera.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.bottom, 360)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if camera.permissionDenied {
                PermissionView()
            }
        }
        .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.94))
        .modifier(HardwareShutter(action: shutterPressed))
        .onAppear {
            camera.start()
            level.start()
            camera.updateOverlays()
        }
        .onChange(of: level.captureAngle) { _, angle in camera.captureAngle = angle }
        .onChange(of: camera.mode) { _, _ in camera.updateOverlays() }
        .onChange(of: camera.showZebra) { _, _ in camera.updateOverlays() }
        .onChange(of: camera.showPeaking) { _, _ in camera.updateOverlays() }
        .onChange(of: camera.showHistogram) { _, _ in camera.updateOverlays() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            if phase == .background { camera.stop() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showReview) {
            ReviewView(camera: camera)
        }
        .animation(.easeInOut(duration: 0.2), value: camera.toast)
    }

    // MARK: - Toque, disparo e temporizador

    private func handleTap(_ location: CGPoint, size: CGSize, lock: Bool) {
        let f = camera.renderer.frameInView
        let x = (location.x / max(size.width, 1) - f.minX) / max(f.width, 0.01)
        let y = (location.y / max(size.height, 1) - f.minY) / max(f.height, 0.01)
        guard (0...1).contains(x), (0...1).contains(y) else { return }
        let p = CGPoint(x: x, y: y)
        if lock {
            camera.lockFocusAndExposure(at: p)
        } else {
            camera.focus(at: p)
        }
        focusPoint = location
        focusToken += 1
        let token = focusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + (lock ? 4 : 3)) {
            if focusToken == token { focusPoint = nil }
        }
    }

    private func shutterPressed() {
        if camera.mode == .video {
            camera.toggleRecording()
            return
        }
        guard countdown == 0 else { return }
        if timerSeconds == 0 {
            camera.capturePhoto()
        } else {
            countdown = timerSeconds
            tick()
        }
    }

    private func tick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard countdown > 0 else { return }
            countdown -= 1
            if countdown == 0 {
                camera.capturePhoto()
            } else {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                tick()
            }
        }
    }

    // MARK: - Barra de cima

    private var topBar: some View {
        HStack(spacing: 10) {
            if camera.mode == .video {
                RoundIconButton(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                                label: "Lanterna", tint: camera.torchOn ? .topAccent : .white) {
                    camera.setTorch(!camera.torchOn)
                }
            } else if camera.flashSupported {
                RoundIconButton(systemName: camera.flash.symbol, label: "Flash \(camera.flash.rawValue)",
                                tint: camera.flash == .off ? .white : .topAccent) {
                    let all = FlashChoice.allCases
                    let i = all.firstIndex(of: camera.flash) ?? 0
                    camera.flash = all[(i + 1) % all.count]
                    camera.showToast("Flash: \(camera.flash.rawValue)")
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            Spacer()
            HStack(spacing: 8) {
                if camera.mode == .video {
                    if camera.isRecording {
                        HStack(spacing: 8) {
                            Circle().fill(.white).frame(width: 8, height: 8)
                            Text(timeString(camera.recordingSeconds))
                                .font(.system(size: 15, weight: .bold).monospacedDigit())
                        }
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Capsule().fill(Color.topRec))
                    } else {
                        Pill(text: camera.quality == .max ? "4K" : "1080p", highlighted: camera.quality == .max) {
                            camera.setQuality(camera.quality == .max ? .social : .max)
                        }
                        Pill(text: "\(camera.frameRate) fps", highlighted: false) {
                            let options = [24, 30, 60]
                            let i = options.firstIndex(of: camera.frameRate) ?? 1
                            camera.setFrameRate(options[(i + 1) % options.count])
                        }
                    }
                } else {
                    Pill(text: "\(camera.photoMegapixels) MP", highlighted: false) {
                        let options = camera.availableMegapixels
                        guard !options.isEmpty else { return }
                        let i = options.firstIndex(of: camera.photoMegapixels) ?? -1
                        camera.photoMegapixels = options[(i + 1) % options.count]
                    }
                    if camera.rawSupported {
                        Pill(text: "RAW", highlighted: camera.rawEnabled) { camera.rawEnabled.toggle() }
                    }
                    Pill(text: timerSeconds == 0 ? "⏱ off" : "⏱ \(timerSeconds)s", highlighted: timerSeconds > 0) {
                        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
                    }
                }
            }
            Spacer()
            RoundIconButton(systemName: "slider.horizontal.3", label: "Ajustes") {
                showSettings = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            if camera.aeafLocked {
                Text("AE/AF TRAVADO")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.1, green: 0.07, blue: 0.02))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Capsule().fill(Color.topAccent))
            }
            if camera.blurOn, camera.mode != .video {
                Text("FUNDO f/\(apertureText(camera.blurAperture))")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .overlay(Capsule().stroke(Color.topAccent, lineWidth: 1))
            }
            if camera.autoScene, camera.mode != .pro, !camera.detectedScene.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Color.topAccent)
                    Text(camera.detectedScene)
                    Text("·").foregroundStyle(Color.topSecondary)
                    Text("Look \(camera.look.title)").foregroundStyle(Color.topAccent).fontWeight(.semibold)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(Color.black.opacity(0.55)))
            }
        }
    }

    private var brightnessRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min").font(.system(size: 14))
            Slider(value: Binding(get: { Double(camera.exposureBias) },
                                  set: { camera.setExposureBias(Float($0)) }),
                   in: Double(camera.biasRange.lowerBound)...Double(camera.biasRange.upperBound))
                .tint(Color.topAccent)
            Image(systemName: "sun.max.fill").font(.system(size: 14))
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    @ViewBuilder
    private var zoomSelector: some View {
        if !camera.isFront {
            HStack(spacing: 4) {
                ForEach(camera.zoomPresets) { preset in
                    let active = abs(camera.zoomFactor - preset.factor) < 0.05
                    Button {
                        camera.selectZoom(preset)
                    } label: {
                        Text(active ? preset.label : preset.label.replacingOccurrences(of: "×", with: ""))
                            .font(.system(size: active ? 13 : 12, weight: active ? .bold : .semibold))
                            .foregroundStyle(active ? Color.topAccent : .white)
                            .frame(width: 44, height: 36)
                            .background(Capsule().fill(active ? Color.white.opacity(0.16) : .clear))
                    }
                    .accessibilityLabel("Zoom \(preset.label)")
                }
                if !camera.zoomPresets.contains(where: { abs(camera.zoomFactor - $0.factor) < 0.05 }) {
                    Text(String(format: "%.1f×", camera.displayZoom))
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.topAccent)
                        .frame(width: 52, height: 36)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
        }
    }

    // MARK: - Painel de baixo

    private var bottomPanel: some View {
        VStack(spacing: 16) {
            if camera.mode == .pro {
                ProControls(camera: camera)
            } else {
                if camera.mode == .photo { blurRow }
                intensityRow
                looksRow
                Text(camera.look.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.topSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            if camera.mode == .video {
                Text("Cabem \(durationString(minutes: camera.minutesLeft)) de vídeo · \(camera.quality.rawValue) · \(camera.frameRate) fps")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.topSecondary)
            }

            modeSwitcher
            shutterRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(Color.topPanel)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var intensityRow: some View {
        HStack(spacing: 12) {
            Text("Intensidade").font(.system(size: 13, weight: .semibold))
            Slider(value: $camera.intensity, in: 0...1)
                .tint(Color.topAccent)
            Text("\(Int(camera.intensity * 100))%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.topAccent)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// Desfocar o fundo: deixa a pessoa, o casal ou o objeto nítido.
    private var blurRow: some View {
        HStack(spacing: 12) {
            ToggleChip(title: camera.blurOn ? "Fundo ✓" : "Desfocar fundo", isOn: $camera.blurOn)
            if camera.blurOn {
                Slider(value: Binding(get: { 17.4 - camera.blurAperture },
                                      set: { camera.blurAperture = ((17.4 - $0) * 10).rounded() / 10 }),
                       in: 1.4...16)
                    .tint(Color.topAccent)
                Text("f/\(apertureText(camera.blurAperture))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.topAccent)
                    .frame(width: 46, alignment: .trailing)
            } else {
                Spacer()
            }
        }
    }

    private var looksRow: some View {
        LooksPicker(selected: camera.look) { look in
            camera.autoScene = false
            camera.look = look
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 28) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    camera.setMode(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(camera.mode == mode ? Color.topAccent : Color.topSecondary)
                        .padding(.vertical, 6)
                }
                .disabled(camera.isRecording)
            }
        }
    }

    private var shutterRow: some View {
        HStack {
            Button {
                if camera.hasReview { showReview = true } else { camera.openPhotos() }
            } label: {
                Group {
                    if let thumb = camera.lastThumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Color(red: 0.2, green: 0.2, blue: 0.21)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.7), lineWidth: 2))
            }
            .accessibilityLabel("Ver a última foto")

            Spacer()

            Button(action: shutterPressed) {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 80, height: 80)
                    if camera.mode == .video {
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 8).fill(Color.topRec).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(Color.topRec).frame(width: 64, height: 64)
                        }
                    } else {
                        Circle().fill(Color.white).frame(width: 64, height: 64)
                    }
                }
            }
            .accessibilityLabel(camera.mode == .video ? (camera.isRecording ? "Parar gravação" : "Gravar") : "Tirar foto")

            Spacer()

            RoundIconButton(systemName: "arrow.triangle.2.circlepath", label: "Virar câmera", size: 52) {
                camera.flipCamera()
            }
            .disabled(camera.isRecording)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Formatação

    private func apertureText(_ f: Double) -> String {
        f >= 10 ? String(format: "%.0f", f) : String(format: "%.1f", f)
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func durationString(minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)min" }
        return "\(minutes) min"
    }
}

// MARK: - Botões de volume e Controle da Câmera (iOS 18+)

struct HardwareShutter: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended { action() }
            }
        } else {
            content
        }
    }
}

// MARK: - Seletor de looks

struct LooksPicker: View {
    let selected: Look
    let onSelect: (Look) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(Look.available) { look in
                    Button {
                        onSelect(look)
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(look.swatch)
                                .frame(width: 54, height: 54)
                                .overlay(Circle().stroke(selected == look ? Color.topAccent : Color.clear, lineWidth: 3))
                            Text(look.title)
                                .font(.system(size: 11, weight: selected == look ? .bold : .regular))
                                .foregroundStyle(selected == look ? Color.topAccent : Color.topSecondary)
                        }
                    }
                    .accessibilityLabel("Look \(look.title)")
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Modo Pro

struct ProControls: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if camera.showHistogram {
                    HistogramView(values: camera.histogram)
                        .frame(height: 34)
                }
                ToggleChip(title: "Zebra", isOn: $camera.showZebra)
                ToggleChip(title: "Foco", isOn: $camera.showPeaking)
                ToggleChip(title: "Cor", isOn: $camera.showFalseColor)
            }

            if camera.proParam == .wb {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<Self.wbPresets.count, id: \.self) { i in
                            Button {
                                camera.setWhiteBalancePreset(Self.wbPresets[i].1)
                            } label: {
                                Text("\(Self.wbPresets[i].0) \(Int(Self.wbPresets[i].1))K")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).frame(height: 30)
                                    .background(Capsule().fill(Color.white.opacity(0.1)))
                            }
                        }
                    }
                }
            } else if camera.proParam == .focus {
                HStack(spacing: 8) {
                    rackButton(slot: 0, value: camera.focusA)
                    rackButton(slot: 1, value: camera.focusB)
                    Text("Segure para salvar · toque para ir")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.topSecondary)
                }
            }

            HStack(spacing: 6) {
                ForEach(ProParam.allCases) { param in
                    Button {
                        camera.proParam = param
                    } label: {
                        VStack(spacing: 2) {
                            Text(param.rawValue).font(.system(size: 10))
                                .foregroundStyle(camera.proParam == param ? Color.topAccent : Color.topSecondary)
                            Text(valueText(param))
                                .font(.system(size: 14, weight: .bold).monospacedDigit())
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(camera.proParam == param ? Color.topAccent : .white)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(camera.proParam == param ? Color.topAccent.opacity(0.12) : Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(camera.proParam == param ? Color.topAccent : .clear, lineWidth: 1.5)
                        )
                    }
                }
            }

            HStack(spacing: 12) {
                Slider(value: sliderBinding, in: sliderRange)
                    .tint(Color.topAccent)
                Button {
                    camera.resetToAuto()
                } label: {
                    Text("AUTO")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(camera.isManual ? .white : Color(red: 0.1, green: 0.07, blue: 0.02))
                        .frame(width: 56, height: 36)
                        .background(Capsule().fill(camera.isManual ? Color.white.opacity(0.14) : Color.topAccent))
                }
            }
        }
    }

    static let wbPresets: [(String, Float)] = [("Sol", 5500), ("Nublado", 6500), ("Sombra", 7500),
                                               ("Incand.", 3200), ("Fluor.", 4000)]

    private func rackButton(slot: Int, value: Float?) -> some View {
        let name = slot == 0 ? "A" : "B"
        return Text(value == nil ? "Foco \(name) +" : "Ir \(name)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(value == nil ? .white : Color(red: 0.1, green: 0.07, blue: 0.02))
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(value == nil ? Color.white.opacity(0.1) : Color.topAccent))
            .onTapGesture {
                if let value { camera.rackFocus(to: value) } else { camera.saveFocusPoint(slot) }
            }
            .onLongPressGesture(minimumDuration: 0.5) { camera.saveFocusPoint(slot) }
    }

    private func valueText(_ param: ProParam) -> String {
        let prefix = camera.isManual ? "" : "A "
        switch param {
        case .iso:
            return prefix + "\(Int(camera.iso))"
        case .shutter:
            let s = camera.shutterSeconds
            if s >= 1 { return prefix + String(format: "%.1fs", s) }
            return prefix + "1/\(Int((1 / max(s, 0.0001)).rounded()))"
        case .wb:
            return camera.isManual ? "\(Int(camera.whiteBalance))K" : "AWB"
        case .tint:
            return camera.isManual ? String(format: "%+.0f", camera.tint) : "A"
        case .focus:
            return camera.isManual ? String(format: "%.2f", camera.focus) : "AF"
        case .ev:
            return String(format: "%+.1f", camera.exposureBias)
        }
    }

    private var sliderRange: ClosedRange<Double> {
        switch camera.proParam {
        case .iso: return Double(camera.isoRange.lowerBound)...Double(camera.isoRange.upperBound)
        case .shutter: return 0...1
        case .wb: return 2500...10000
        case .tint: return -50...50
        case .focus: return 0...1
        case .ev: return Double(camera.biasRange.lowerBound)...Double(camera.biasRange.upperBound)
        }
    }

    /// Velocidade usa escala logarítmica para ficar fácil de ajustar.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: {
                switch camera.proParam {
                case .iso: return Double(camera.iso)
                case .shutter:
                    let lo = camera.shutterRange.lowerBound, hi = camera.shutterRange.upperBound
                    let s = min(max(camera.shutterSeconds, lo), hi)
                    return log(s / lo) / log(hi / lo)
                case .wb: return Double(camera.whiteBalance)
                case .tint: return Double(camera.tint)
                case .focus: return Double(camera.focus)
                case .ev: return Double(camera.exposureBias)
                }
            },
            set: { value in
                if camera.proParam == .shutter {
                    let lo = camera.shutterRange.lowerBound, hi = camera.shutterRange.upperBound
                    camera.setManualValue(lo * pow(hi / lo, value))
                } else {
                    camera.setManualValue(value)
                }
            }
        )
    }
}

struct HistogramView: View {
    let values: [Float]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let w = geo.size.width, h = geo.size.height
                path.move(to: CGPoint(x: 0, y: h))
                for (i, v) in values.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(values.count - 1)
                    path.addLine(to: CGPoint(x: x, y: h - h * CGFloat(min(max(v, 0), 1))))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()
            }
            .fill(Color.white.opacity(0.75))
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        .accessibilityLabel("Histograma")
    }
}

struct ToggleChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color(red: 0.1, green: 0.07, blue: 0.02) : .white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(isOn ? Color.topAccent : Color.white.opacity(0.1)))
        }
    }
}

// MARK: - Revisão da última foto (antes/depois, trocar o look e desfocar o fundo)

struct ReviewView: View {
    @ObservedObject var camera: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var look: Look = .natural
    @State private var intensity: Double = 0.8
    @State private var image: UIImage?
    @State private var original: UIImage?
    @State private var showOriginal = false
    @State private var blurOn = false
    @State private var aperture: Double = 2.8
    @State private var focusBackground = false
    @State private var masks: SubjectMasks?
    @State private var selected: Set<Int> = []
    @State private var analyzing = false
    @State private var hint = ""

    private var mask: CIImage? { masks?.combined(selected) }
    private var blurOptions: BlurOptions? {
        blurOn && mask != nil ? BlurOptions(aperture: aperture, focusOnBackground: focusBackground) : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack {
                        Color.black
                        if let shown = showOriginal ? original : image {
                            Image(uiImage: shown).resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                        VStack {
                            HStack {
                                Text(showOriginal ? "Antes" : "Depois")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.black.opacity(0.6)))
                                Spacer()
                                Text("Segure: antes")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Color.black.opacity(0.6)))
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in showOriginal = true }
                                            .onEnded { _ in showOriginal = false }
                                    )
                            }
                            Spacer()
                        }
                        .padding(10)
                    }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in handleTap(value.location, size: geo.size) })
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(hint.isEmpty ? look.subtitle : hint)
                    .font(.footnote).foregroundStyle(Color.topSecondary)
                    .lineLimit(2).multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    ToggleChip(title: blurOn ? "Fundo ✓" : "Desfocar fundo", isOn: $blurOn)
                    if blurOn {
                        Slider(value: Binding(get: { 17.4 - aperture },
                                              set: { aperture = ((17.4 - $0) * 10).rounded() / 10 }),
                               in: 1.4...16, onEditingChanged: { editing in if !editing { refresh() } })
                            .tint(Color.topAccent)
                        Text(String(format: "f/%.1f", aperture))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.topAccent)
                            .frame(width: 48, alignment: .trailing)
                    } else {
                        Spacer()
                    }
                }

                HStack(spacing: 12) {
                    Text("Intensidade").font(.system(size: 13, weight: .semibold))
                    Slider(value: $intensity, in: 0...1, onEditingChanged: { editing in
                        if !editing { refresh() }
                    })
                    .tint(Color.topAccent)
                    Text("\(Int(intensity * 100))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.topAccent)
                        .frame(width: 42, alignment: .trailing)
                }

                LooksPicker(selected: look) { newLook in
                    look = newLook
                    hint = ""
                    refresh()
                }

                Button {
                    camera.saveReviewVersion(look: look, intensity: intensity, blur: blurOptions, mask: blurOptions == nil ? nil : mask)
                    dismiss()
                } label: {
                    Text("Salvar como nova foto")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(red: 0.1, green: 0.07, blue: 0.02))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.topAccent))
                }
            }
            .padding(16)
            .background(Color(red: 0.05, green: 0.05, blue: 0.06))
            .navigationTitle("Última foto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Galeria") { camera.openPhotos() } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color.topAccent)
        .onChange(of: blurOn) { _, on in
            if on { analyze() } else { hint = ""; refresh() }
        }
        .onAppear {
            look = camera.look
            intensity = camera.intensity
            aperture = camera.blurAperture
            original = camera.reviewPreview(look: .original, intensity: 0)
            refresh()
        }
    }

    /// Procura as pessoas (ou o assunto) uma vez; depois é só tocar para escolher.
    private func analyze() {
        if masks != nil { updateHint(); refresh(); return }
        analyzing = true
        hint = "Procurando pessoas e o assunto…"
        DispatchQueue.global(qos: .userInitiated).async {
            let found = camera.reviewMasks()
            DispatchQueue.main.async {
                analyzing = false
                masks = found
                selected = Set(found?.instances ?? [])
                updateHint()
                refresh()
            }
        }
    }

    private func updateHint() {
        guard let masks else {
            hint = "Não achei um assunto nesta foto para separar do fundo."
            return
        }
        if masks.peopleMode {
            let n = masks.instances.count
            hint = n > 1
                ? "\(n) pessoas. Toque em alguém para tirar ou pôr no foco. Toque no fundo para focar lá."
                : "Pessoa no foco. Toque no fundo para focar lá."
        } else {
            hint = "Assunto no foco. Toque no fundo para focar lá."
        }
    }

    private func handleTap(_ location: CGPoint, size: CGSize) {
        guard blurOn, let masks, let shown = image, shown.size.width > 0, shown.size.height > 0 else { return }
        // Área que a foto ocupa dentro do quadro (encaixada).
        let scale = min(size.width / shown.size.width, size.height / shown.size.height)
        let w = shown.size.width * scale, h = shown.size.height * scale
        let x0 = (size.width - w) / 2, y0 = (size.height - h) / 2
        let p = CGPoint(x: (location.x - x0) / w, y: (location.y - y0) / h)
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }

        if let id = masks.instance(at: p) {
            if focusBackground {
                focusBackground = false
            } else if selected.contains(id) {
                if selected.count > 1 { selected.remove(id) }
            } else {
                selected.insert(id)
            }
            hint = masks.peopleMode ? "\(selected.count) no foco. Toque para escolher quem fica nítido." : "Assunto no foco."
        } else {
            focusBackground.toggle()
            hint = focusBackground ? "Foco no fundo: o assunto ficou desfocado. Toque nele para voltar." : "Foco no assunto."
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refresh()
    }

    private func refresh() {
        let l = look, i = intensity, b = blurOptions, m = mask
        DispatchQueue.global(qos: .userInitiated).async {
            let img = camera.reviewPreview(look: l, intensity: i, blur: b, mask: m)
            DispatchQueue.main.async { image = img }
        }
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @ObservedObject var camera: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var importLUT = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Tela") {
                    Toggle("Linhas de grade", isOn: $camera.showGrid)
                    Toggle("Look automático pela cena", isOn: $camera.autoScene)
                }
                Section {
                    Picker("Enquadramento", selection: $camera.frameAspect) {
                        ForEach(FrameAspect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Salvar a foto já cortada", isOn: $camera.cropOnSave)
                    Toggle("Área segura do Instagram", isOn: $camera.showSafeArea)
                } header: {
                    Text("Redes sociais")
                } footer: {
                    Text("4:5 é o tamanho do feed; 9:16 é Reels e Stories. A área segura mostra onde os botões do Instagram ficam por cima.")
                }
                Section {
                    Toggle("Desfocar fundo nas fotos", isOn: $camera.blurOn)
                    HStack {
                        Text("Abertura")
                        Slider(value: $camera.blurAperture, in: 1.4...16, step: 0.1)
                        Text(String(format: "f/%.1f", camera.blurAperture)).monospacedDigit()
                    }
                } header: {
                    Text("Fundo")
                } footer: {
                    Text("f/1.4 desfoca muito; f/16 quase nada. Depois da foto, toque na miniatura para escolher quem fica nítido.")
                }
                Section("Foto") {
                    Picker("Resolução", selection: $camera.photoMegapixels) {
                        ForEach(camera.availableMegapixels, id: \.self) { Text("\($0) MP").tag($0) }
                    }
                    Picker("Flash", selection: $camera.flash) {
                        ForEach(FlashChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Brilho HDR (iOS 18+)", isOn: $camera.keepHDR)
                    if camera.rawSupported {
                        Toggle("Salvar também em RAW", isOn: $camera.rawEnabled)
                    } else {
                        Text("RAW não disponível neste iPhone/lente.").foregroundStyle(.secondary)
                    }
                }
                Section("Vídeo") {
                    Picker("Qualidade", selection: Binding(get: { camera.quality },
                                                           set: { camera.setQuality($0) })) {
                        ForEach(QualityProfile.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Quadros por segundo", selection: Binding(get: { camera.frameRate },
                                                                     set: { camera.setFrameRate($0) })) {
                        ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Toggle("Travar o branco ao gravar", isOn: $camera.lockWBOnRecord)
                    Toggle("Obturador de cinema (sem piscar no LED)", isOn: $camera.cinemaShutter)
                    Text("Cabem cerca de \(camera.minutesLeft) minutos de vídeo nessa qualidade. O obturador de cinema usa 1/60 (ou 1/120 em 60 fps): movimento natural e sem faixas na luz de 60 Hz.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Histograma", isOn: $camera.showHistogram)
                    Toggle("Zebra (luz estourada)", isOn: $camera.showZebra)
                    HStack {
                        Text("Nível da zebra")
                        Slider(value: $camera.zebraLevel, in: 75...100, step: 5)
                        Text("\(Int(camera.zebraLevel))%").monospacedDigit()
                    }
                    Toggle("Realce de foco", isOn: $camera.showPeaking)
                    Picker("Cor do realce", selection: $camera.peakColor) {
                        ForEach(PeakColor.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Falsa cor", isOn: $camera.showFalseColor)
                } header: {
                    Text("Modo Pro")
                } footer: {
                    Text("Falsa cor: rosa = pele clara bem exposta, verde = cinza médio/pele escura, vermelho = estourado, azul/roxo = escuro demais.")
                }
                Section {
                    if let name = camera.lutName {
                        Text("LUT atual: \(name)")
                        Button("Remover LUT", role: .destructive) { camera.removeLUT() }
                    }
                    Button(camera.lutName == nil ? "Importar LUT (.cube)" : "Trocar LUT (.cube)") { importLUT = true }
                } header: {
                    Text("Looks de cinema")
                } footer: {
                    Text("Use LUTs feitos para Rec.709. Ele vira o look \u{201C}Meu LUT\u{201D}.")
                }
                Section("Galeria") {
                    Toggle("Salvar a localização", isOn: $camera.useLocation)
                }
                Section {
                    Text("TopCam 1.2 · uso pessoal\nDica: botões de volume e Controle da Câmera também tiram foto.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importLUT,
                          allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .data]) { result in
                if case .success(let url) = result { camera.importLUT(url) }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .tint(Color.topAccent)
    }
}

// MARK: - Componentes

struct RoundIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 44
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .accessibilityLabel(label)
    }
}

struct Pill: View {
    let text: String
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: highlighted ? .bold : .semibold))
                .foregroundStyle(highlighted ? Color.topAccent : .white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .overlay(Capsule().stroke(highlighted ? Color.topAccent : .clear, lineWidth: 1))
        }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
    }
}

struct LevelIndicator: View {
    let roll: Double
    let isFlat: Bool

    var body: some View {
        Group {
            if isFlat {
                Label("Vista de cima", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.topLevel)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
            } else if abs(roll) < 12 {
                let ok = abs(roll) < 1
                HStack(spacing: 8) {
                    Rectangle().frame(width: 60, height: 2)
                    Text("\(Int(roll.rounded()))°").font(.system(size: 11, weight: .semibold))
                    Rectangle().frame(width: 60, height: 2)
                }
                .foregroundStyle(ok ? Color.topLevel : Color.white.opacity(0.8))
                .rotationEffect(.degrees(ok ? 0 : -roll))
            }
        }
        .offset(y: -60)
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(Color.topAccent)
            Text("O TopCam precisa da câmera")
                .font(.title3.bold())
            Text("Libere o acesso à câmera nos Ajustes do iPhone para começar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.topSecondary)
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.topAccent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - Guias de enquadramento (4:5, 9:16...) e área segura

struct FrameGuideOverlay: View {
    let ratio: CGFloat?
    let safeArea: Bool

    var body: some View {
        GeometryReader { geo in
            let full = CGRect(origin: .zero, size: geo.size)
            let inner = Self.fit(ratio, in: full)
            ZStack {
                if ratio != nil {
                    Path { p in
                        p.addRect(full)
                        p.addRect(inner)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Rectangle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        .frame(width: inner.width, height: inner.height)
                        .position(x: inner.midX, y: inner.midY)
                }
                if safeArea {
                    Rectangle()
                        .stroke(Color.topAccent.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .frame(width: inner.width * 0.80, height: inner.height * 0.66)
                        .position(x: inner.minX + inner.width * 0.44, y: inner.minY + inner.height * 0.45)
                }
            }
        }
    }

    static func fit(_ ratio: CGFloat?, in r: CGRect) -> CGRect {
        guard let a = ratio, r.height > 0 else { return r }
        if r.width / r.height > a {
            let w = r.height * a
            return CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
        }
        let h = r.width / a
        return CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
    }
}
