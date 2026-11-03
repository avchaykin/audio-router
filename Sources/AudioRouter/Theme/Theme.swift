import AppKit
import CoreText
import SwiftUI

// MARK: - Palette & fonts

/// User-adjustable appearance values (set from AppState; views are rebuilt
/// via `.id(themeVersion)` whenever they change).
enum ThemeStore {
    static let defaultGlow: [Double] = [0.64, 0.40, 1.0]   // violet
    static let defaultOpacity: Double = 1.0

    static let defaultIntensity: Double = 0.59
    static let defaultBacklight: [Double] = [1.0, 0.78, 0.38]   // warm incandescent bulb

    nonisolated(unsafe) static var glowRGB: [Double] = defaultGlow
    nonisolated(unsafe) static var glassOpacity: Double = defaultOpacity
    /// 0 = no glow, 1 = default, 2 = very bright.
    nonisolated(unsafe) static var glowIntensity: Double = defaultIntensity
    nonisolated(unsafe) static var backlightEnabled = true
    nonisolated(unsafe) static var backlightRGB: [Double] = defaultBacklight
    static let defaultBulbShape = BulbShape.oval
    static let defaultBulbBlur: Double = 0.25
    static let defaultBulbIntensity: Double = 1.36
    nonisolated(unsafe) static var bulbShape: BulbShape = defaultBulbShape
    /// 0 = hard, small light source; 1 = very diffuse.
    nonisolated(unsafe) static var bulbBlur: Double = defaultBulbBlur
    /// 0 = off, 1 = default, 2 = very bright.
    nonisolated(unsafe) static var bulbIntensity: Double = defaultBulbIntensity

    static let backlightSwatches: [(String, [Double])] = [
        ("Warm Bulb", [1.0, 0.78, 0.38]),
        ("Hot Filament", [1.0, 0.55, 0.18]),
        ("Neon Red", [1.0, 0.22, 0.18]),
        ("Phosphor Green", [0.45, 1.0, 0.45]),
        ("Cold White", [0.88, 0.94, 1.0]),
        ("Cyan", [0.15, 0.85, 1.0]),
        ("Violet", [0.64, 0.40, 1.0]),
        ("Magenta", [1.0, 0.26, 0.66]),
    ]

    static let swatches: [(String, [Double])] = [
        ("Orange-Red", [1.0, 0.32, 0.10]),
        ("Amber", [1.0, 0.66, 0.12]),
        ("Lime", [0.55, 0.95, 0.25]),
        ("Cyan", [0.15, 0.85, 1.0]),
        ("Blue", [0.32, 0.52, 1.0]),
        ("Violet", [0.64, 0.40, 1.0]),
        ("Magenta", [1.0, 0.26, 0.66]),
        ("Ice", [0.85, 0.92, 1.0]),
    ]
}

enum Theme {
    /// Selection glow colour (user-configurable, default orange-red).
    static var glow: Color { rgb(ThemeStore.glowRGB) }
    /// Slightly lighter glow for text.
    static var glowSoft: Color { rgb(ThemeStore.glowRGB.map { $0 + (1 - $0) * 0.28 }) }

    /// Backlight "bulb" colour beneath lit controls.
    static var backlight: Color { rgb(ThemeStore.backlightRGB) }
    static var hasBacklight: Bool { ThemeStore.backlightEnabled && ThemeStore.bulbIntensity > 0.01 }
    /// Glow intensity factor.
    static var k: Double { ThemeStore.glowIntensity }
    /// Opacity scaled by intensity, clamped to 1.
    static func glowOpacity(_ base: Double) -> Double { min(1, base * k) }
    /// Radius scaled by intensity (grows slower than opacity).
    static func glowRadius(_ base: CGFloat) -> CGFloat { base * CGFloat(0.4 + 0.6 * k) }

    static func rgb(_ c: [Double]) -> Color {
        Color(red: c.count > 0 ? c[0] : 1, green: c.count > 1 ? c[1] : 0.32, blue: c.count > 2 ? c[2] : 0.1)
    }
    static let text = Color.white.opacity(0.88)
    static let textDim = Color.white.opacity(0.50)
    static let textFaint = Color.white.opacity(0.30)
    static let pass = Color(red: 0.35, green: 0.90, blue: 0.55)
    static let block = Color(red: 1.0, green: 0.30, blue: 0.30)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "JetBrainsMono-Bold"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .medium: name = "JetBrainsMono-Medium"
        default: name = "JetBrainsMono-Regular"
        }
        return .custom(name, size: size)
    }

    /// Registers the bundled JetBrains Mono fonts for this process.
    static func registerFonts() {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Fonts")) }
        // `swift run` from the repo root
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Fonts"))
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            let fonts = files.filter { $0.pathExtension.lowercased() == "ttf" }
            guard !fonts.isEmpty else { continue }
            for url in fonts { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
            return
        }
    }
}

// MARK: - Frosted glass window background

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Makes the hosting window transparent, dark and draggable by its background.
struct WindowConfigurator: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private let titleBarReach: CGFloat = 40

extension View {
    /// Dark grey frosted glass + window setup.
    func frostedWindow() -> some View {
        background {
            ZStack {
                GlassBackground()
                LinearGradient(colors: [Color(white: 0.15).opacity(ThemeStore.glassOpacity),
                                        Color(white: 0.07).opacity(min(1, ThemeStore.glassOpacity + 0.06))],
                               startPoint: .top, endPoint: .bottom)
                WindowConfigurator().frame(width: 0, height: 0)
            }
            // Reach under the transparent title bar even when the root view is fixed-size
            // and laid out below it (simple mode), where ignoresSafeArea can't stretch it.
            .padding(.top, -titleBarReach)
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Backlight bulb

enum BulbShape: Int, CaseIterable, Identifiable {
    case round, oval, tube, edge
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .round: "Round"
        case .oval: "Oval"
        case .tube: "Tube"
        case .edge: "Edge"
        }
    }
    var help: String {
        switch self {
        case .round: "Small round bulb under the centre"
        case .oval: "Diffuse oval following the button"
        case .tube: "Horizontal tube / filament line"
        case .edge: "Light leaking up from the bottom edge"
        }
    }
}

/// Light from a bulb behind translucent rubber. Drawn with gradients only (no
/// blur filters), so it is cheap and renders identically everywhere.
/// `halo` = the softer light spilling around the control's edges.
struct BulbLight: View {
    var strength: Double = 1
    var halo = false
    /// Not clipped by a control shape: the light must fade out inside its own frame.
    var contained = false
    private var fitsFrame: Bool { halo || contained }

    var body: some View {
        if Theme.hasBacklight {
            GeometryReader { geo in
                light(geo.size)
            }
            .padding(.horizontal, halo ? -spread : 0)
            .padding(.vertical, halo ? -spread * 0.8 : 0)
            .allowsHitTesting(false)
        }
    }

    private var blur: Double { ThemeStore.bulbBlur }
    private var spread: CGFloat { CGFloat(3 + 13 * blur) * CGFloat(0.5 + 0.5 * min(ThemeStore.bulbIntensity, 1.5)) }

    /// Peak opacity scaled by bulb intensity.
    private var peak: Double {
        min(1, (halo ? 0.40 : 0.78) * strength * ThemeStore.bulbIntensity)
    }

    /// Hard core that widens into a soft falloff as blur increases.
    private var gradient: Gradient {
        let c = Theme.backlight
        let core = (1 - blur) * 0.55
        let mid = core + (1 - core) * (0.25 + 0.25 * blur)
        return Gradient(stops: [
            .init(color: c.opacity(peak), location: 0),
            .init(color: c.opacity(peak), location: core),
            .init(color: c.opacity(peak * 0.35), location: mid),
            .init(color: c.opacity(0), location: 1),
        ])
    }

    @ViewBuilder
    private func light(_ size: CGSize) -> some View {
        let center = UnitPoint(x: 0.5, y: halo ? 0.56 : 0.62)
        switch ThemeStore.bulbShape {
        case .round:
            let r = fitsFrame ? min(size.width, size.height) * 0.5
                              : min(size.width, size.height) * (0.42 + 0.35 * blur)
            RadialGradient(gradient: gradient, center: center, startRadius: 0, endRadius: max(r, 1))
                .blendMode(.screen)
        case .oval:
            EllipticalGradient(gradient: gradient, center: fitsFrame ? .center : center,
                               startRadiusFraction: 0, endRadiusFraction: fitsFrame ? 0.5 : 0.45 + 0.2 * blur)
                .blendMode(.screen)
        case .edge where fitsFrame:
            // light pooled below the control, fading out in every direction
            EllipticalGradient(gradient: gradient, center: UnitPoint(x: 0.5, y: 0.62),
                               startRadiusFraction: 0, endRadiusFraction: 0.38)
                .blendMode(.screen)
        case .tube:
            let t = 0.10 + 0.32 * blur
            LinearGradient(stops: [
                .init(color: .clear, location: max(0, 0.6 - t)),
                .init(color: Theme.backlight.opacity(peak), location: 0.6),
                .init(color: .clear, location: min(1, 0.6 + t)),
            ], startPoint: .top, endPoint: .bottom)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.12 + 0.1 * blur),
                .init(color: .white, location: 0.88 - 0.1 * blur),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))
            .blendMode(.screen)
        case .edge:
            LinearGradient(stops: [
                .init(color: Theme.backlight.opacity(peak), location: 0),
                .init(color: Theme.backlight.opacity(peak * 0.3), location: 0.18 + 0.3 * blur),
                .init(color: .clear, location: 0.35 + 0.55 * blur),
            ], startPoint: .bottom, endPoint: .top)
            .blendMode(.screen)
        }
    }
}

struct BacklightInside: View {
    var strength: Double = 1
    var body: some View { BulbLight(strength: strength) }
}

struct BacklightHalo: View {
    var strength: Double = 1
    var blur: CGFloat = 9
    var body: some View { BulbLight(strength: strength, halo: true) }
}

// MARK: - Rubber surface

/// Semi-transparent, slightly convex "rubber" key. When `isOn`, it lights up
/// with an orange-red glow.
struct RubberSurface: ViewModifier {
    var isOn: Bool
    var pressed = false
    var radius: CGFloat = 7
    var tint: Color = Theme.glow

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .foregroundStyle(isOn ? Color.white : Theme.text.opacity(0.8))
            .background {
                ZStack {
                    if isOn { BacklightHalo(strength: 0.8) }
                    shape.fill(LinearGradient(
                        colors: isOn
                            ? [tint.opacity(0.42), tint.opacity(0.20)]
                            : [Color.white.opacity(pressed ? 0.05 : 0.10), Color.white.opacity(pressed ? 0.07 : 0.035)],
                        startPoint: .top, endPoint: .bottom))
                    if isOn { BacklightInside().clipShape(shape) }
                    // soft top sheen = rubbery convex look
                    shape.fill(LinearGradient(colors: [Color.white.opacity(isOn ? 0.18 : 0.08), .clear],
                                              startPoint: .top, endPoint: .center))
                        .padding(1)
                    shape.strokeBorder(LinearGradient(
                        colors: isOn
                            ? [tint.opacity(1.0), tint.opacity(0.6)]
                            : [Color.white.opacity(0.20), Color.white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .shadow(color: isOn ? tint.opacity(Theme.glowOpacity(0.85)) : .black.opacity(0.35),
                        radius: isOn ? Theme.glowRadius(5) : 1.5, y: isOn ? 0 : 1)
                .shadow(color: isOn ? tint.opacity(Theme.glowOpacity(0.40)) : .clear, radius: Theme.glowRadius(11))
            }
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

extension View {
    func rubber(_ isOn: Bool, pressed: Bool = false, radius: CGFloat = 7, tint: Color = Theme.glow) -> some View {
        modifier(RubberSurface(isOn: isOn, pressed: pressed, radius: radius, tint: tint))
    }
}

/// Button that looks like a rubber key; pass `isOn` for toggle-like buttons.
struct RubberButtonStyle: ButtonStyle {
    var isOn = false
    var radius: CGFloat = 7
    var tint: Color = Theme.glow
    var padding = EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(padding)
            .contentShape(Rectangle())
            .rubber(isOn || configuration.isPressed, pressed: configuration.isPressed,
                    radius: radius, tint: tint)
    }
}

extension ButtonStyle where Self == RubberButtonStyle {
    static func rubber(_ isOn: Bool = false, radius: CGFloat = 7) -> RubberButtonStyle {
        RubberButtonStyle(isOn: isOn, radius: radius)
    }

    static func rubberCell(_ isOn: Bool) -> RubberButtonStyle {
        RubberButtonStyle(isOn: isOn, radius: 4, padding: EdgeInsets())
    }
}

/// Small square rubber checkbox that lights up when on.
struct GlowCheckbox: View {
    var isOn: Bool
    var size: CGFloat = 15

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            if isOn { BacklightHalo(strength: 0.9, blur: 6) }
            shape.fill(LinearGradient(
                colors: isOn ? [Theme.glowSoft, Theme.glow] : [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                startPoint: .top, endPoint: .bottom))
            if isOn { BacklightInside(strength: 1.1).clipShape(shape) }
            shape.fill(LinearGradient(colors: [Color.white.opacity(isOn ? 0.35 : 0.10), .clear],
                                      startPoint: .top, endPoint: .center))
                .padding(1)
            shape.strokeBorder(isOn ? Theme.glowSoft : Color.white.opacity(0.18), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: isOn ? Theme.glow.opacity(Theme.glowOpacity(0.9)) : .black.opacity(0.4),
                radius: isOn ? Theme.glowRadius(4) : 1, y: isOn ? 0 : 1)
        .shadow(color: isOn ? Theme.glow.opacity(Theme.glowOpacity(0.45)) : .clear, radius: Theme.glowRadius(9))
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// Text that glows in the accent colour when on.
struct GlowText: ViewModifier {
    var isOn: Bool
    func body(content: Content) -> some View {
        content
            .foregroundStyle(isOn ? Theme.glowSoft : Theme.text.opacity(0.62))
            .shadow(color: isOn ? Theme.glow.opacity(Theme.glowOpacity(0.85)) : .clear, radius: Theme.glowRadius(3.5))
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

extension View {
    func glowText(_ isOn: Bool) -> some View { modifier(GlowText(isOn: isOn)) }
}

/// Checkbox replacement: glowing rubber checkbox + title beside it (the title
/// glows too when on). The whole row is clickable.
struct RubberToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                GlowCheckbox(isOn: configuration.isOn)
                configuration.label
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .glowText(configuration.isOn)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A bare number (or short text) that glows when active — used for channel
/// rows and the CC matrix.
struct GlowNumberStyle: ButtonStyle {
    var isOn: Bool
    var size: CGFloat = 11

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(size, isOn ? .bold : .regular))
            .foregroundStyle(isOn ? Theme.glowSoft : Color.white.opacity(configuration.isPressed ? 0.6 : 0.30))
            .shadow(color: isOn ? Theme.glow.opacity(Theme.glowOpacity(1)) : .clear, radius: Theme.glowRadius(3))
            .shadow(color: isOn ? Theme.glow.opacity(Theme.glowOpacity(0.6)) : .clear, radius: Theme.glowRadius(8))
            .background {
                // little bulb behind each lit number
                if isOn && Theme.hasBacklight {
                    BulbLight(strength: 0.55, contained: true)
                        .frame(width: size * 2.4, height: size * 2.0)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: isOn)
    }
}

extension ButtonStyle where Self == GlowNumberStyle {
    static func glowNumber(_ isOn: Bool, size: CGFloat = 11) -> GlowNumberStyle { GlowNumberStyle(isOn: isOn, size: size) }
}

extension ToggleStyle where Self == RubberToggleStyle {
    static var rubber: RubberToggleStyle { RubberToggleStyle() }
}

// MARK: - Panel

struct Panel<Content: View, Accessory: View>: View {
    let title: String
    var icon: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.glowSoft.opacity(0.85))
                Text(title.uppercased())
                    .font(Theme.mono(10.5, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.textDim)
                Spacer(minLength: 4)
                accessory
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        }
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Small text buttons used in panel headers ("All", "None"…).
struct MiniButton: View {
    let title: String
    var isOn = false
    let action: () -> Void
    init(_ title: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.mono(10, .medium))
        }
        .buttonStyle(RubberButtonStyle(isOn: isOn, radius: 5, padding: EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)))
    }
}

// MARK: - Stepper

/// [−] value [+] made of rubber keys.
struct RubberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var width: CGFloat = 56
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        HStack(spacing: 3) {
            key("minus") { value = max(range.lowerBound, value - step) }
            Text(format(value))
                .font(Theme.mono(11.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(width: width)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.28)))
            key("plus") { value = min(range.upperBound, value + step) }
        }
    }

    private func key(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14)
        }
        .buttonStyle(RubberButtonStyle(radius: 5, padding: EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)))
    }
}
