import AVFoundation

/// Effect category used for filtering in the Add Effect picker. Derived from the plug-in's declared
/// tags where it has them, otherwise from its name (many vendors, e.g. Arturia, declare no tags but
/// name effects by type: "Comp FET-76", "Rev PLATE-140", "Delay TAPE-201").
enum EffectCategory: String, CaseIterable, Identifiable {
    case dynamics = "Dynamics"
    case eq = "EQ"
    case filter = "Filter"
    case delay = "Delay"
    case reverb = "Reverb"
    case distortion = "Distortion"
    case modulation = "Modulation"
    case pitch = "Pitch"
    case preamp = "Preamp"
    case creative = "Creative"
    case utility = "Utility"
    case other = "Other"

    var id: String { rawValue }

    /// Standard Audio Unit tags (`AVAudioUnitComponentManager.standardLocalizedTagNames`) → category.
    private static let tagMap: [String: EffectCategory] = [
        "equalizer": .eq, "filter": .filter, "dynamics processor": .dynamics, "reverb": .reverb,
        "distortion": .distortion, "delay": .delay, "pitch": .pitch, "time effect": .pitch,
        "panner": .utility, "imaging": .utility, "mixer": .utility, "format converter": .utility,
        "output": .utility,
    ]

    /// Unambiguous keywords matched anywhere in the lowercased name.
    private static let substrings: [(String, EffectCategory)] = [
        ("compressor", .dynamics), ("limiter", .dynamics), ("expander", .dynamics), ("dynamics", .dynamics),
        ("equaliz", .eq), ("graphiceq", .eq), ("nbandeq", .eq), ("parametriceq", .eq), ("shelf", .eq),
        ("filter", .filter), ("lowpass", .filter), ("highpass", .filter), ("hipass", .filter), ("bandpass", .filter),
        ("delay", .delay), ("echo", .delay),
        ("reverb", .reverb),
        ("distortion", .distortion), ("overdrive", .distortion), ("bitcrush", .distortion), ("saturat", .distortion),
        ("exciter", .distortion),
        ("chorus", .modulation), ("flanger", .modulation), ("phaser", .modulation), ("tremolo", .modulation),
        ("vibrato", .modulation), ("rotary", .modulation), ("ensemble", .modulation),
        ("pitch", .pitch), ("varispeed", .pitch), ("harmoniz", .pitch),
        ("preamp", .preamp), ("channel strip", .preamp),
        ("matrixmixer", .utility), ("mixer", .utility), ("netsend", .utility), ("roundtrip", .utility),
        ("isolation", .utility), ("panner", .utility), ("converter", .utility), ("splitter", .utility),
    ]

    /// Short keywords that must start a word ("rev" must not match inside "reverse"-like words in the
    /// middle, "pre" must not match inside "compressor").
    private static let wordPrefixes: [(String, EffectCategory)] = [
        ("comp", .dynamics), ("gate", .dynamics), ("multiband", .dynamics),
        ("eq", .eq),
        ("rev", .reverb), ("plate", .reverb), ("spring", .reverb), ("hall", .reverb), ("room", .reverb),
        ("dist", .distortion), ("fuzz", .distortion), ("crush", .distortion), ("lofi", .distortion),
        ("pre", .preamp),
        ("efx", .creative), ("granular", .creative), ("glitch", .creative), ("fragments", .creative),
        ("gain", .utility), ("mix", .utility), ("pan", .utility),
    ]

    /// Weak hints, used only when nothing else matched ("Tape MELLO-FI" is lo-fi, but "Delay TAPE-201"
    /// is a delay and "Comp TUBE-STA" a compressor; "Bus FORCE" is a bus compressor).
    private static let fallbackPrefixes: [(String, EffectCategory)] = [
        ("tape", .distortion), ("tube", .distortion), ("bus", .dynamics),
    ]

    static func categories(for c: AVAudioUnitComponent) -> Set<EffectCategory> {
        categories(name: c.name, tags: c.allTagNames)
    }

    static func categories(name original: String, tags: [String]) -> Set<EffectCategory> {
        var result = Set<EffectCategory>()
        for tag in tags {
            if let cat = tagMap[tag.lowercased()] { result.insert(cat) }
        }
        let name = original.lowercased()
        for (key, cat) in substrings where name.contains(key) { result.insert(cat) }
        let words = Self.words(in: original)
        for (key, cat) in wordPrefixes where words.contains(where: { $0.hasPrefix(key) }) { result.insert(cat) }
        if result.isEmpty {
            for (key, cat) in fallbackPrefixes where words.contains(where: { $0.hasPrefix(key) }) { result.insert(cat) }
        }
        return result.isEmpty ? [.other] : result
    }

    /// Splits "AUNBandEQ" → ["n", "band", "eq"], "Comp FET-76" → ["comp", "fet", "76"], "Lo-Fi" → ["lofi"].
    static func words(in name: String) -> [String] {
        var s = name.replacingOccurrences(of: "Lo-Fi", with: "LoFi", options: .caseInsensitive)
        if s.hasPrefix("AU"), s.count > 2, s[s.index(s.startIndex, offsetBy: 2)].isUppercase {
            s.removeFirst(2)   // Apple's "AU" prefix
        }
        var words: [String] = []
        var current = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if !current.isEmpty, ch.isUppercase {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                // camelCase boundary, or the last capital of an acronym before a word ("NBand" → "N", "Band")
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
}

enum EffectTags {
    /// Tags too generic to filter by (nearly every effect has them).
    private static let ignored: Set<String> = ["effects", "effect"]

    /// Tags the plug-in declares itself, plus any tags the user has added in macOS.
    static func tags(for c: AVAudioUnitComponent) -> [String] {
        c.allTagNames.filter { !ignored.contains($0.lowercased()) }
    }
}
