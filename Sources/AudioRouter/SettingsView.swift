import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var router: AudioRouter
    @EnvironmentObject private var look: Appearance

    var body: some View {
        Form {
            audioSection
            latencySection
            appearanceSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(.rubber)
        .font(Theme.mono(11.5))
        .foregroundStyle(Theme.text)
        .frame(width: 640, height: 820)
        .id(look.themeVersion)
        .frostedWindow()
        .onAppear { router.refreshDeviceInfo() }
    }

    // MARK: Audio

    private var rate: Double { router.isRunning ? router.deviceSampleRate : (router.sampleRateSetting ?? router.deviceSampleRate) }

    private var audioSection: some View {
        Section {
            LabeledContent("Sample rate") {
                choiceRow {
                    choice("Device" + (router.deviceSampleRate > 0 ? " · \(khz(router.deviceSampleRate))" : ""),
                           router.sampleRateSetting == nil) { router.sampleRateSetting = nil }
                    ForEach(router.availableSampleRates, id: \.self) { r in
                        choice(khz(r), router.sampleRateSetting == r) { router.sampleRateSetting = r }
                    }
                }
            }
            LabeledContent("I/O buffer") {
                choiceRow {
                    choice("Device" + (router.deviceBufferFrames > 0 ? " · \(router.deviceBufferFrames)" : ""),
                           router.bufferSetting == nil) { router.bufferSetting = nil }
                    ForEach(AudioRouter.bufferChoices.filter { router.bufferRange.contains($0) }, id: \.self) { n in
                        choice("\(n)", router.bufferSetting == n) { router.bufferSetting = n }
                            .help(ms(n))
                    }
                }
            }
            LabeledContent("Safety buffer") {
                choiceRow {
                    choice("Auto", router.safetySetting == nil) { router.safetySetting = nil }
                        .help("2 × I/O buffer, at least 256 frames")
                    ForEach(AudioRouter.safetyChoices, id: \.self) { n in
                        choice("\(n)", router.safetySetting == n) { router.safetySetting = n }
                            .help(ms(n))
                    }
                }
            }
            note("Smaller buffers = lower latency but more risk of dropouts (clicks). The I/O buffer applies only to Audio Router; the sample rate is set on the output device itself and affects every app using it. Changes restart processing.")
        } header: {
            header("Audio", "waveform")
        }
    }

    private var latencySection: some View {
        Section {
            if router.isRunning {
                let b = router.latencyBreakdown
                LabeledContent("Estimated latency") {
                    Text(String(format: "≈ %.1f ms", router.estimatedLatencyMs))
                        .font(Theme.mono(14, .bold)).glowText(true)
                }
                LabeledContent("Breakdown") {
                    Text(String(format: "in %.1f + safety %.1f + out %.1f + plug-ins %.1f ms",
                                b.input, b.safety, b.output, router.latencyMs))
                        .foregroundStyle(Theme.textDim)
                }
                LabeledContent("In use") {
                    Text("\(khz(router.deviceSampleRate)) · buffer \(router.activeBufferFrames) · safety \(router.activeSafetyFrames)")
                        .foregroundStyle(Theme.textDim)
                }
                LabeledContent("Dropouts") {
                    HStack(spacing: 8) {
                        Text("\(router.dropouts)")
                            .font(Theme.mono(12, .bold))
                            .foregroundStyle(router.dropouts > 0 ? Theme.block : Theme.pass)
                        MiniButton("Reset") { router.resetDropouts() }
                    }
                }
                note("Dropouts count buffer underruns and catch-up skips since processing started. If they keep rising, raise the safety buffer (or the I/O buffer).")
            } else {
                note("Start processing to measure latency and dropouts.")
            }
        } header: {
            header("Latency", "stopwatch")
        }
    }

    // MARK: Appearance (same controls as MIDI Filter)

    private var appearanceSection: some View {
        Section {
            LabeledContent("Background opacity") { percentSlider($look.glassOpacity, 0.3...1) }
            LabeledContent("Glow colour") { swatchRow(ThemeStore.swatches, $look.glowRGB) }
            LabeledContent("Glow intensity") { percentSlider($look.glowIntensity, 0...2) }
            Toggle("Backlight bulb under lit controls", isOn: $look.backlightEnabled)
            Group {
                LabeledContent("Backlight colour") { swatchRow(ThemeStore.backlightSwatches, $look.backlightRGB) }
                LabeledContent("Bulb shape") {
                    choiceRow {
                        ForEach(BulbShape.allCases) { shape in
                            choice(shape.title, look.bulbShape == shape) { look.bulbShape = shape }
                                .help(shape.help)
                        }
                    }
                }
                LabeledContent("Bulb blur") { percentSlider($look.bulbBlur, 0...1) }
                LabeledContent("Bulb intensity") { percentSlider($look.bulbIntensity, 0...2) }
            }
            .disabled(!look.backlightEnabled)
            .opacity(look.backlightEnabled ? 1 : 0.4)
            HStack(spacing: 14) {
                // live preview of the current look
                Toggle("Preview", isOn: .constant(true))
                Button("Lit key") {}.buttonStyle(.rubber(true))
                LEDMeter(level: 0.5, segments: 16).frame(width: 110)
                Spacer()
                MiniButton("Reset appearance") { look.reset() }
            }
        } header: {
            header("Appearance", "paintpalette")
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.glowSoft.opacity(0.85))
            Text(title.uppercased()).font(Theme.mono(10.5, .semibold)).tracking(1.4).foregroundStyle(Theme.textDim)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func choiceRow<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5) { content() }
    }

    private func choice(_ title: String, _ isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(Theme.mono(10.5, .medium)) }
            .buttonStyle(RubberButtonStyle(isOn: isOn, radius: 5, padding: EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)))
    }

    private func khz(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
    }

    private func ms(_ frames: Int) -> String {
        rate > 0 ? String(format: "%.1f ms at %@", Double(frames) / rate * 1000, khz(rate)) : "\(frames) frames"
    }

    private func percentSlider(_ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            RubberSlider(value: Binding(get: { Float(value.wrappedValue) }, set: { value.wrappedValue = Double($0) }),
                         range: Float(range.lowerBound)...Float(range.upperBound))
                .frame(width: 180)
            Text("\(Int(value.wrappedValue * 100))%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func swatchRow(_ swatches: [(String, [Double])], _ selection: Binding<[Double]>) -> some View {
        HStack(spacing: 7) {
            ForEach(swatches, id: \.0) { name, rgb in
                let selected = zip(rgb, selection.wrappedValue).allSatisfy { abs($0 - $1) < 0.01 }
                Button { selection.wrappedValue = rgb } label: {
                    Circle()
                        .fill(Theme.rgb(rgb))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.95 : 0.15),
                                                       lineWidth: selected ? 2 : 1))
                        .shadow(color: selected ? Theme.rgb(rgb) : .clear, radius: 5)
                }
                .buttonStyle(.plain)
                .help(name)
            }
            ColorPicker("", selection: Binding(
                get: { Theme.rgb(selection.wrappedValue) },
                set: { color in
                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                    selection.wrappedValue = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
                }), supportsOpacity: false)
                .labelsHidden()
                .help("Custom colour")
        }
    }
}
