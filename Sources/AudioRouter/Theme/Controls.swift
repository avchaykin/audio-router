import SwiftUI

// Audio-specific controls built from the MIDI Filter theme pieces (rubber keys, glow, bulb light).

/// Horizontal slider: dark groove, glowing fill, rubber knob. Double-click resets to `defaultValue`.
struct RubberSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var defaultValue: Float? = nil
    /// Where the fill starts (e.g. the 0 dB point of a gain control). nil = from the left edge.
    var origin: Float? = nil

    private let knobWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knobWidth, 1)
            let x = CGFloat(fraction(value)) * usable
            let ox = CGFloat(fraction(origin ?? range.lowerBound)) * usable
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.well(0.40))
                    .overlay(Capsule().strokeBorder(Theme.line(0.07)))
                    .frame(height: 6)
                    .padding(.horizontal, knobWidth / 2)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.glowSoft, Theme.glow], startPoint: .top, endPoint: .bottom))
                    .frame(width: abs(x - ox), height: 6)
                    .offset(x: min(x, ox) + knobWidth / 2)
                    .shadow(color: Theme.glow.opacity(Theme.glowOpacity(0.9)), radius: Theme.glowRadius(4))
                Color.clear
                    .frame(width: knobWidth, height: 18)
                    .rubber(false, radius: 5)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = Float(min(max((g.location.x - knobWidth / 2) / usable, 0), 1))
                value = range.lowerBound + f * (range.upperBound - range.lowerBound)
            })
            .onTapGesture(count: 2) { if let defaultValue { value = defaultValue } }
        }
        .frame(height: 22)
    }

    private func fraction(_ v: Float) -> Float {
        (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}

/// Segmented peak meter (−60…0 dBFS) with glowing LEDs; the top segments light red.
struct LEDMeter: View {
    let level: Float   // linear peak
    var segments = 30

    private var db: Float { 20 * log10(max(level, 0.000_01)) }

    var body: some View {
        let lit = Int((max(0, min(1, (db + 60) / 60)) * Float(segments)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let on = i < lit
                let hot = i >= segments - 2
                let color = hot ? Theme.block : Theme.glowSoft
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(on ? color : Theme.line(0.07))
                    .shadow(color: on ? color.opacity(Theme.glowOpacity(0.9)) : .clear, radius: Theme.glowRadius(3))
            }
        }
        .frame(height: 9)
        .animation(nil, value: lit)
    }
}

/// One choice in a single-selection list: glowing checkbox + label (+ optional tag), whole row clickable.
struct RadioRow: View {
    let title: String
    var tag: String? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                GlowCheckbox(isOn: isOn)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .glowText(isOn)
                if let tag {
                    Text(tag).font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small rubber icon key (refresh, move, delete…).
struct IconKey: View {
    let symbol: String
    var tint: Color = Theme.glow
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 12, height: 12)
        }
        .buttonStyle(RubberButtonStyle(radius: 5, tint: tint, padding: EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)))
        .help(help)
    }
}
