import SwiftUI

/// Pro controls: real camera exposure (shutter/ISO/EV/WB/focus) and look dials.
struct ManualPanel: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var lookStore: LookStore
    @State private var tab: Tab = .exposure

    enum Tab: String, CaseIterable {
        case exposure = "Exposure"
        case look = "Look"
        case capture = "Capture"
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            switch tab {
            case .exposure: exposureControls
            case .look: lookControls
            case .capture: captureControls
            }
        }
        .padding(.vertical, 8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    // MARK: - Real exposure

    private var exposureControls: some View {
        VStack(spacing: 6) {
            Toggle(isOn: $camera.manualExposure) {
                Label("Manual shutter + ISO", systemImage: "camera.aperture")
                    .font(.footnote)
            }
            .tint(.orange)
            .padding(.horizontal, 16)
            .onChange(of: camera.manualExposure) { camera.applyExposure() }

            if camera.manualExposure {
                DialRow(label: "Shutter", value: $camera.shutterSeconds,
                        range: camera.shutterRange, display: shutterLabel(camera.shutterSeconds),
                        logarithmic: true) { camera.applyExposure() }
                DialRow(label: "ISO", value: $camera.iso,
                        range: camera.isoRange, display: "\(Int(camera.iso))",
                        logarithmic: true) { camera.applyExposure() }
            } else {
                DialRow(label: "EV", value: $camera.evBias, range: -3...3,
                        display: String(format: "%+.1f", camera.evBias)) { camera.applyExposure() }
            }

            Toggle(isOn: $camera.manualWB) {
                Label("Manual white balance", systemImage: "thermometer.sun")
                    .font(.footnote)
            }
            .tint(.orange)
            .padding(.horizontal, 16)
            .onChange(of: camera.manualWB) { camera.applyWhiteBalance() }

            if camera.manualWB {
                DialRow(label: "Kelvin", value: $camera.wbTemperature, range: 2500...9000,
                        display: "\(Int(camera.wbTemperature))K") { camera.applyWhiteBalance() }
                DialRow(label: "Tint", value: $camera.wbTint, range: -100...100,
                        display: String(format: "%+.0f", camera.wbTint)) { camera.applyWhiteBalance() }
            }

            if camera.supportsManualFocus {
                Toggle(isOn: $camera.manualFocus) {
                    Label("Manual focus", systemImage: "scope").font(.footnote)
                }
                .tint(.orange)
                .padding(.horizontal, 16)
                .onChange(of: camera.manualFocus) { camera.applyFocus() }

                if camera.manualFocus {
                    DialRow(label: "Focus", value: $camera.focusPosition, range: 0...1,
                            display: camera.focusPosition < 0.15 ? "NEAR" :
                                     camera.focusPosition > 0.85 ? "FAR" :
                                     String(format: "%.2f", camera.focusPosition)) { camera.applyFocus() }
                }
            }
        }
    }

    private func shutterLabel(_ seconds: Double) -> String {
        seconds >= 0.25 ? String(format: "%.1fs", seconds) : "1/\(Int((1.0 / seconds).rounded()))"
    }

    // MARK: - Look dials (post-processing)

    private var lookControls: some View {
        let look = lookStore.effectiveLook
        return VStack(spacing: 6) {
            DialRow(label: "Push", value: bindOverride(\.ev, current: look.ev), range: -1.5...1.5,
                    display: String(format: "%+.2f", look.ev))
            DialRow(label: "Contrast", value: bindOverride(\.contrast, current: look.contrast), range: -0.5...0.6,
                    display: "\(Int(look.contrast * 100))")
            DialRow(label: "Color", value: bindOverride(\.saturation, current: look.saturation), range: 0...2,
                    display: "\(Int(look.saturation * 100))%")
            DialRow(label: "Warmth", value: bindOverride(\.warmth, current: look.warmth), range: -0.5...0.5,
                    display: "\(Int(look.warmth * 100))")
            DialRow(label: "Fade", value: bindOverride(\.fade, current: look.fade), range: 0...0.4,
                    display: "\(Int(look.fade * 250))")
            DialRow(label: "Grain", value: bindOverride(\.grain, current: look.grain), range: 0...1,
                    display: "\(Int(look.grain * 100))")
            DialRow(label: "Halation", value: bindOverride(\.halation, current: look.halation), range: 0...1,
                    display: "\(Int(look.halation * 100))")
            DialRow(label: "Vignette", value: bindOverride(\.vignette, current: look.vignette), range: 0...1,
                    display: "\(Int(look.vignette * 100))")
        }
    }

    private func bindOverride(_ keyPath: WritableKeyPath<LookStore.Overrides, Double?>,
                              current: Double) -> Binding<Double> {
        Binding(
            get: { LookStore.shared.overrides[keyPath: keyPath] ?? current },
            set: { newValue in
                LookStore.shared.overrides[keyPath: keyPath] = newValue
                LookStore.shared.objectWillChange.send()
            }
        )
    }

    // MARK: - Capture settings

    private var captureControls: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $camera.naturalMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Natural capture", systemImage: "leaf")
                        .font(.footnote.weight(.semibold))
                    Text(camera.rawAvailable
                         ? "Minimal processing + RAW (DNG) saved with every shot."
                         : "Minimal Apple processing for a more film-like image.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.orange)
            .padding(.horizontal, 16)

            Toggle(isOn: $camera.fullResolution) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Full resolution (48MP)", systemImage: "sparkles.rectangle.stack")
                        .font(.footnote.weight(.semibold))
                    Text("Maximum detail. Slower per shot, much bigger files.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.orange)
            .padding(.horizontal, 16)
            .onChange(of: camera.fullResolution) { camera.applyResolution() }

            Text("Off = full Apple computational pipeline (Smart HDR, fusion). On = closer to a single, honest exposure.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Slider row

struct DialRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    var logarithmic = false
    var onChanged: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Slider(value: sliderBinding, in: sliderRange)
                .tint(.orange)
                .onChange(of: value) { onChanged?() }
            Text(display)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }

    private var sliderRange: ClosedRange<Double> {
        logarithmic ? log10(range.lowerBound)...log10(range.upperBound) : range
    }

    private var sliderBinding: Binding<Double> {
        if logarithmic {
            return Binding(
                get: { log10(max(value, range.lowerBound)) },
                set: { value = min(max(pow(10, $0), range.lowerBound), range.upperBound) }
            )
        }
        return $value
    }
}

/// Horizontal film-look chips.
struct LookPickerBar: View {
    @ObservedObject var lookStore: LookStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilmLook.all) { look in
                    Button {
                        lookStore.select(look)
                        Haptics.tap()
                    } label: {
                        Text(look.name)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(lookStore.selectedLook.id == look.id
                                        ? Color.orange : Color.white.opacity(0.07),
                                        in: Capsule())
                            .foregroundStyle(lookStore.selectedLook.id == look.id ? .black : .white)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
