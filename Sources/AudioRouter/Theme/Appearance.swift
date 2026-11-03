import Combine
import Foundation

/// User-adjustable look (same options as MIDI Filter). Writes through to `ThemeStore`, persists to
/// UserDefaults, and bumps `themeVersion` so root views (which use it as `.id`) redraw.
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()
    private let defaults = UserDefaults.standard

    @Published var skin: Skin { didSet { ThemeStore.skin = skin; save("skin", skin.rawValue) } }
    @Published var glassOpacity: Double { didSet { ThemeStore.glassOpacity = glassOpacity; save("glassOpacity", glassOpacity) } }
    @Published var glowRGB: [Double] { didSet { ThemeStore.glowRGB = glowRGB; save("glowRGB", glowRGB) } }
    @Published var glowIntensity: Double { didSet { ThemeStore.glowIntensity = glowIntensity; save("glowIntensity", glowIntensity) } }
    @Published var backlightEnabled: Bool { didSet { ThemeStore.backlightEnabled = backlightEnabled; save("backlightEnabled", backlightEnabled) } }
    @Published var backlightRGB: [Double] { didSet { ThemeStore.backlightRGB = backlightRGB; save("backlightRGB", backlightRGB) } }
    @Published var bulbShape: BulbShape { didSet { ThemeStore.bulbShape = bulbShape; save("bulbShape", bulbShape.rawValue) } }
    @Published var bulbBlur: Double { didSet { ThemeStore.bulbBlur = bulbBlur; save("bulbBlur", bulbBlur) } }
    @Published var bulbIntensity: Double { didSet { ThemeStore.bulbIntensity = bulbIntensity; save("bulbIntensity", bulbIntensity) } }

    /// Bumped on any change; root views use it as `.id` to redraw with the new theme values.
    @Published private(set) var themeVersion = 0

    private init() {
        let defaults = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) != nil ? defaults.double(forKey: key) : fallback
        }
        func rgb(_ key: String, _ fallback: [Double]) -> [Double] {
            (defaults.array(forKey: key) as? [Double]).flatMap { $0.count == 3 ? $0 : nil } ?? fallback
        }
        skin = defaults.object(forKey: "skin") != nil ? (Skin(rawValue: defaults.integer(forKey: "skin")) ?? ThemeStore.defaultSkin)
                                                      : ThemeStore.defaultSkin
        glassOpacity = double("glassOpacity", ThemeStore.defaultOpacity)
        glowRGB = rgb("glowRGB", ThemeStore.defaultGlow)
        glowIntensity = double("glowIntensity", ThemeStore.defaultIntensity)
        backlightEnabled = defaults.object(forKey: "backlightEnabled") != nil ? defaults.bool(forKey: "backlightEnabled") : true
        backlightRGB = rgb("backlightRGB", ThemeStore.defaultBacklight)
        bulbShape = BulbShape(rawValue: defaults.integer(forKey: "bulbShape")).flatMap {
            defaults.object(forKey: "bulbShape") != nil ? $0 : nil } ?? ThemeStore.defaultBulbShape
        bulbBlur = double("bulbBlur", ThemeStore.defaultBulbBlur)
        bulbIntensity = double("bulbIntensity", ThemeStore.defaultBulbIntensity)
        apply()
    }

    private func apply() {
        ThemeStore.skin = skin
        ThemeStore.glassOpacity = glassOpacity
        ThemeStore.glowRGB = glowRGB
        ThemeStore.glowIntensity = glowIntensity
        ThemeStore.backlightEnabled = backlightEnabled
        ThemeStore.backlightRGB = backlightRGB
        ThemeStore.bulbShape = bulbShape
        ThemeStore.bulbBlur = bulbBlur
        ThemeStore.bulbIntensity = bulbIntensity
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        themeVersion &+= 1
    }

    /// Resets colours and lighting; the skin choice is kept.
    func reset() {
        glassOpacity = ThemeStore.defaultOpacity
        glowRGB = ThemeStore.defaultGlow
        glowIntensity = ThemeStore.defaultIntensity
        backlightEnabled = true
        backlightRGB = ThemeStore.defaultBacklight
        bulbShape = ThemeStore.defaultBulbShape
        bulbBlur = ThemeStore.defaultBulbBlur
        bulbIntensity = ThemeStore.defaultBulbIntensity
    }
}
