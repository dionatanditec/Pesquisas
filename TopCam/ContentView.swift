import SwiftUI
import UIKit
import AVKit

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
                intensityRow
                looksRow
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
                ForEach(Look.allCases) { look in
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
        case .wb: return 2500...9000
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

// MARK: - Revisão da última foto (antes/depois e trocar o look)

struct ReviewView: View {
    @ObservedObject var camera: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var look: Look = .natural
    @State private var intensity: Double = 0.8
    @State private var image: UIImage?
    @State private var original: UIImage?
    @State private var showOriginal = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
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
                        }
                        Spacer()
                    }
                    .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in showOriginal = true }
                        .onEnded { _ in showOriginal = false }
                )

                Text("Segure a foto para ver o antes")
                    .font(.footnote).foregroundStyle(Color.topSecondary)

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
                    refresh()
                }

                Button {
                    camera.saveReviewVersion(look: look, intensity: intensity)
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
        .onAppear {
            look = camera.look
            intensity = camera.intensity
            original = camera.reviewPreview(look: .original, intensity: 0)
            refresh()
        }
    }

    private func refresh() {
        let l = look, i = intensity
        DispatchQueue.global(qos: .userInitiated).async {
            let img = camera.reviewPreview(look: l, intensity: i)
            DispatchQueue.main.async { image = img }
        }
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @ObservedObject var camera: CameraModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Tela") {
                    Toggle("Linhas de grade", isOn: $camera.showGrid)
                    Toggle("Look automático pela cena", isOn: $camera.autoScene)
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
                    Text("Cabem cerca de \(camera.minutesLeft) minutos de vídeo nessa qualidade.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Modo Pro") {
                    Toggle("Histograma", isOn: $camera.showHistogram)
                    Toggle("Zebra (luz estourada)", isOn: $camera.showZebra)
                    Toggle("Realce de foco", isOn: $camera.showPeaking)
                }
                Section("Galeria") {
                    Toggle("Salvar a localização", isOn: $camera.useLocation)
                }
                Section {
                    Text("TopCam 1.1 · uso pessoal\nDica: botões de volume e Controle da Câmera também tiram foto.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
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
