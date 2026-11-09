import SwiftUI
import UIKit

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
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                MetalPreview(renderer: camera.renderer)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            let p = CGPoint(x: value.location.x / max(geo.size.width, 1),
                                            y: value.location.y / max(geo.size.height, 1))
                            camera.focus(at: p)
                            focusPoint = value.location
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { focusPoint = nil }
                        }
                    )
                    .overlay {
                        if let fp = focusPoint {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.topAccent, lineWidth: 1.5)
                                .frame(width: 90, height: 90)
                                .position(fp)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .ignoresSafeArea()

            if camera.showGrid {
                GridOverlay().allowsHitTesting(false).ignoresSafeArea()
            }

            LevelIndicator(roll: level.roll, isFlat: level.isFlat)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                sceneChip.padding(.top, 10)
                Spacer()
                lensSelector.padding(.bottom, 12)
                bottomPanel
            }

            if let toast = camera.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.bottom, 340)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if camera.permissionDenied {
                PermissionView()
            }
        }
        .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.94))
        .onAppear {
            camera.start()
            level.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            if phase == .background { camera.stop() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera)
                .presentationDetents([.medium, .large])
        }
        .animation(.easeInOut(duration: 0.2), value: camera.toast)
    }

    // MARK: - Barra de cima

    private var topBar: some View {
        HStack {
            RoundIconButton(systemName: camera.showGrid ? "grid.circle.fill" : "grid.circle",
                            label: "Linhas de grade") {
                camera.showGrid.toggle()
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
                        Pill(text: camera.quality == .max ? "4K · 30" : "1080p", highlighted: camera.quality == .max) {
                            camera.setQuality(camera.quality == .max ? .social : .max)
                        }
                        Pill(text: "HEVC", highlighted: false) {}
                    }
                } else {
                    Pill(text: "HEIF", highlighted: !camera.rawEnabled) { camera.rawEnabled = false }
                    if camera.rawSupported {
                        Pill(text: "RAW", highlighted: camera.rawEnabled) { camera.rawEnabled.toggle() }
                    }
                }
            }
            Spacer()
            RoundIconButton(systemName: "slider.horizontal.3", label: "Ajustes") {
                showSettings = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var sceneChip: some View {
        if camera.autoScene, camera.mode != .pro, !camera.detectedScene.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.topAccent)
                Text(camera.detectedScene)
                Text("·").foregroundStyle(Color.topSecondary)
                Text("Look \(camera.look.title)").foregroundStyle(Color.topAccent).fontWeight(.semibold)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(Color.black.opacity(0.55)))
        }
    }

    @ViewBuilder
    private var lensSelector: some View {
        if !camera.isFront, camera.availableLenses.count > 1 {
            HStack(spacing: 4) {
                ForEach(camera.availableLenses) { lens in
                    Button {
                        camera.selectLens(lens)
                    } label: {
                        Text(lens.rawValue)
                            .font(.system(size: camera.lens == lens ? 13 : 12, weight: camera.lens == lens ? .bold : .semibold))
                            .foregroundStyle(camera.lens == lens ? Color.topAccent : .white)
                            .frame(width: 46, height: 36)
                            .background(Capsule().fill(camera.lens == lens ? Color.white.opacity(0.16) : .clear))
                    }
                    .accessibilityLabel("Lente \(lens.rawValue)")
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
                Text("Cabem \(durationString(minutes: camera.minutesLeft)) de vídeo · \(camera.quality.rawValue)")
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(Look.allCases) { look in
                    Button {
                        camera.autoScene = false
                        camera.look = look
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(look.swatch)
                                .frame(width: 54, height: 54)
                                .overlay(
                                    Circle().stroke(camera.look == look ? Color.topAccent : Color.clear, lineWidth: 3)
                                )
                            Text(look.title)
                                .font(.system(size: 11, weight: camera.look == look ? .bold : .regular))
                                .foregroundStyle(camera.look == look ? Color.topAccent : Color.topSecondary)
                        }
                    }
                    .accessibilityLabel("Look \(look.title)")
                }
            }
            .padding(.horizontal, 2)
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
                camera.openPhotos()
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
            .accessibilityLabel("Abrir galeria")

            Spacer()

            Button {
                if camera.mode == .video {
                    camera.toggleRecording()
                } else {
                    camera.capturePhoto()
                }
            } label: {
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

// MARK: - Modo Pro

struct ProControls: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 14) {
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
                        .frame(maxWidth: .infinity, minHeight: 56)
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
                Section("Vídeo") {
                    Picker("Qualidade", selection: Binding(get: { camera.quality },
                                                           set: { camera.setQuality($0) })) {
                        ForEach(QualityProfile.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Cabem cerca de \(camera.minutesLeft) minutos de vídeo nessa qualidade.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Foto") {
                    if camera.rawSupported {
                        Toggle("Salvar também em RAW", isOn: $camera.rawEnabled)
                    } else {
                        Text("RAW não disponível neste iPhone/lente.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("TopCam 1.0 · uso pessoal")
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
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
        .offset(y: -40)
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
