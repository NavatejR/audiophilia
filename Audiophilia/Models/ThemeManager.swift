import SwiftUI
import Combine

// MARK: - Glass Intensity

/// How much frosted-glass translucency is applied to surfaces.
enum GlassIntensity: String, CaseIterable, Identifiable {
    case ultraThin = "Ultra Thin"
    case thin = "Thin"
    case regular = "Regular"

    var id: String { rawValue }

    /// The matching SwiftUI material for a surface.
    var material: AnyShapeStyle {
        switch self {
        case .ultraThin: return AnyShapeStyle(.ultraThinMaterial)
        case .thin: return AnyShapeStyle(.thinMaterial)
        case .regular: return AnyShapeStyle(.regularMaterial)
        }
    }

    /// Primary material used for the sidebar / canvas background layers.
    var backgroundMaterial: AnyShapeStyle {
        switch self {
        case .ultraThin: return AnyShapeStyle(.ultraThinMaterial)
        case .thin: return AnyShapeStyle(.thinMaterial)
        case .regular: return AnyShapeStyle(.regularMaterial)
        }
    }

    /// Secondary material used for floating surfaces (playbar, cards, badges).
    var surfaceMaterial: AnyShapeStyle {
        switch self {
        case .ultraThin: return AnyShapeStyle(.ultraThinMaterial)
        case .thin: return AnyShapeStyle(.thinMaterial)
        case .regular: return AnyShapeStyle(.regularMaterial)
        }
    }
}

// MARK: - Appearance Style

/// The app's color scheme. `.system` follows the macOS appearance setting;
/// Light and Dark force a scheme regardless of the OS setting.
enum AppearanceStyle: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    /// Resolves to a SwiftUI `ColorScheme`, or `nil` when following the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Theme Preset

/// A complete Liquid Glass color theme. Exposes accent + gradient colors
/// that drive the entire UI. All presets are stored in UserDefaults.
struct ThemePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let accent: Color
    let topGradient: Color
    let midGradient: Color
    let bottomGradient: Color

    /// Full gradient used for category tiles / empty artwork.
    var artworkGradient: LinearGradient {
        LinearGradient(
            colors: [topGradient, midGradient, bottomGradient],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Gentle, low-opacity gradient wash for window backgrounds.
    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [topGradient.opacity(0.22), bottomGradient.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Strong gradient for the playbar and prominent buttons.
    var vibrantGradient: LinearGradient {
        LinearGradient(
            colors: [topGradient, bottomGradient],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Equalizer Sound Styles

/// A named equalizer "sound style". Each style applies 10 band gains (in dB)
/// over the ISO-standard bands [31, 62, 125, 250, 500, 1000, 2000, 4000,
/// 8000, 16000] used by `AVAudioUnitEQ` in `AudioEngine`. The "Flat" style is
/// all-zero gains and is represented as the EQ being physically off.
struct EQPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let gains: [Float]

    /// The "Flat (Off)" style — no EQ applied anywhere.
    var isOff: Bool { id == "flat" }

    static let presets: [EQPreset] = [
        EQPreset(id: "flat",       name: "Flat (Off)",   icon: "waveform",             gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(id: "bassBoost",  name: "Bass Boost",   icon: "speaker.wave.2.fill",  gains: [6, 4, 2, 1, 0, 0, 0, 0, 0, 0]),
        EQPreset(id: "bassPro",    name: "Bass Boost +", icon: "speaker.wave.3.fill",  gains: [9, 7, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(id: "acoustic",   name: "Acoustic",     icon: "guitars.fill",         gains: [0, 1, 3, 4, 4, 3, 2, 2, 2, 1]),
        EQPreset(id: "classical",  name: "Classical",    icon: "music.quarternote.3",  gains: [0, 0, 0, 1, 2, 3, 2, 2, 3, 3]),
        EQPreset(id: "electronic", name: "Electronic",   icon: "bolt.fill",            gains: [4, 3, 2, 0, -1, 1, 3, 4, 5, 5]),
        EQPreset(id: "hiphop",     name: "Hip Hop",      icon: "music.mic",            gains: [7, 5, 3, 1, 1, 0, 0, 0, 1, 1]),
        EQPreset(id: "jazz",       name: "Jazz",         icon: "music.note.list",      gains: [0, 1, 2, 1, 3, 0, -1, -1, 2, 4]),
        EQPreset(id: "rock",       name: "Rock",         icon: "guitars",              gains: [6, 4, 2, -1, -2, 2, 3, 4, 5, 4]),
        EQPreset(id: "vocal",      name: "Vocal",        icon: "mic.fill",             gains: [0, 0, 1, 2, 3, 4, 3, 2, 1, 0]),
        EQPreset(id: "pop",        name: "Pop",          icon: "star.fill",            gains: [-2, 1, 0, 2, 3, 4, 1, 1, 2, 2]),
        EQPreset(id: "reggae",     name: "Reggae",       icon: "leaf.fill",            gains: [2, 1, 0, -1, 0, 2, 3, 3, 2, 2]),
        EQPreset(id: "treble",     name: "Treble Boost", icon: "speaker.zzz.fill",     gains: [0, 0, 0, 0, 0, 0, 1, 2, 5, 8])
    ]
}

// MARK: - Theme Manager

/// Shared observable theme + settings store.
/// Persists choices in UserDefaults via @AppStorage.
/// Note: no explicit @MainActor — the project already defaults to MainActor
/// isolation (SWIFT_DEFAULT_ACTOR_ISOLATION), and an explicit annotation
/// breaks ObservableObject conformance synthesis.
final class ThemeManager: ObservableObject {

    static let shared = ThemeManager()

    // MARK: Theme presets

    static let presets: [ThemePreset] = [
        ThemePreset(
            id: "liquidBlue",
            name: "Liquid Blue",
            icon: "circle.fill",
            accent: Color(red: 0.04, green: 0.52, blue: 1.0),
            topGradient: Color(red: 0.04, green: 0.52, blue: 1.0),
            midGradient: Color(red: 0.29, green: 0.34, blue: 0.89),
            bottomGradient: Color(red: 0.36, green: 0.36, blue: 0.90)
        ),
        ThemePreset(
            id: "auroraPurple",
            name: "Aurora Purple",
            icon: "circle.fill",
            accent: Color(red: 0.75, green: 0.35, blue: 0.95),
            topGradient: Color(red: 0.75, green: 0.35, blue: 0.95),
            midGradient: Color(red: 0.49, green: 0.30, blue: 0.89),
            bottomGradient: Color(red: 0.36, green: 0.36, blue: 0.90)
        ),
        ThemePreset(
            id: "sunsetEmber",
            name: "Sunset Ember",
            icon: "circle.fill",
            accent: Color(red: 1.0, green: 0.62, blue: 0.04),
            topGradient: Color(red: 1.0, green: 0.62, blue: 0.04),
            midGradient: Color(red: 1.0, green: 0.42, blue: 0.22),
            bottomGradient: Color(red: 1.0, green: 0.22, blue: 0.37)
        ),
        ThemePreset(
            id: "emeraldGlass",
            name: "Emerald Glass",
            icon: "circle.fill",
            accent: Color(red: 0.19, green: 0.82, blue: 0.35),
            topGradient: Color(red: 0.19, green: 0.82, blue: 0.35),
            midGradient: Color(red: 0.0, green: 0.64, blue: 0.65),
            bottomGradient: Color(red: 0.04, green: 0.52, blue: 1.0)
        ),
        ThemePreset(
            id: "roseQuartz",
            name: "Rose Quartz",
            icon: "circle.fill",
            accent: Color(red: 1.0, green: 0.39, blue: 0.51),
            topGradient: Color(red: 1.0, green: 0.39, blue: 0.51),
            midGradient: Color(red: 0.96, green: 0.28, blue: 0.58),
            bottomGradient: Color(red: 0.75, green: 0.35, blue: 0.95)
        ),
        ThemePreset(
            id: "midnightAbyss",
            name: "Midnight Abyss",
            icon: "circle.fill",
            accent: Color(red: 0.35, green: 0.44, blue: 0.85),
            topGradient: Color(red: 0.10, green: 0.12, blue: 0.28),
            midGradient: Color(red: 0.18, green: 0.22, blue: 0.48),
            bottomGradient: Color(red: 0.35, green: 0.44, blue: 0.85)
        ),
        ThemePreset(
            id: "forestCanopy",
            name: "Forest Canopy",
            icon: "circle.fill",
            accent: Color(red: 0.25, green: 0.72, blue: 0.45),
            topGradient: Color(red: 0.10, green: 0.45, blue: 0.28),
            midGradient: Color(red: 0.18, green: 0.60, blue: 0.38),
            bottomGradient: Color(red: 0.55, green: 0.78, blue: 0.40)
        ),
        ThemePreset(
            id: "oceanDeep",
            name: "Ocean Deep",
            icon: "circle.fill",
            accent: Color(red: 0.10, green: 0.55, blue: 0.80),
            topGradient: Color(red: 0.04, green: 0.25, blue: 0.55),
            midGradient: Color(red: 0.08, green: 0.45, blue: 0.75),
            bottomGradient: Color(red: 0.30, green: 0.70, blue: 0.85)
        ),
        ThemePreset(
            id: "candyPop",
            name: "Candy Pop",
            icon: "circle.fill",
            accent: Color(red: 1.0, green: 0.55, blue: 0.75),
            topGradient: Color(red: 0.95, green: 0.30, blue: 0.60),
            midGradient: Color(red: 0.82, green: 0.35, blue: 0.90),
            bottomGradient: Color(red: 1.0, green: 0.62, blue: 0.35)
        ),
        ThemePreset(
            id: "lavaFlow",
            name: "Lava Flow",
            icon: "circle.fill",
            accent: Color(red: 1.0, green: 0.42, blue: 0.10),
            topGradient: Color(red: 0.75, green: 0.12, blue: 0.05),
            midGradient: Color(red: 1.0, green: 0.30, blue: 0.10),
            bottomGradient: Color(red: 1.0, green: 0.62, blue: 0.15)
        ),
        ThemePreset(
            id: "amoledBlack",
            name: "AMOLED Black",
            icon: "circle.fill",
            accent: Color(red: 0.48, green: 0.64, blue: 0.97),
            topGradient: Color(red: 0.0, green: 0.0, blue: 0.0),
            midGradient: Color(red: 0.02, green: 0.02, blue: 0.04),
            bottomGradient: Color(red: 0.04, green: 0.04, blue: 0.08)
        ),
        ThemePreset(
            id: "darkPurple",
            name: "Dark Purple",
            icon: "circle.fill",
            accent: Color(red: 0.71, green: 0.56, blue: 0.97),
            topGradient: Color(red: 0.18, green: 0.11, blue: 0.31),
            midGradient: Color(red: 0.10, green: 0.06, blue: 0.19),
            bottomGradient: Color(red: 0.05, green: 0.03, blue: 0.10)
        ),
        ThemePreset(
            id: "tokyoNight",
            name: "Tokyo Night",
            icon: "circle.fill",
            accent: Color(red: 0.48, green: 0.64, blue: 0.97),
            topGradient: Color(red: 0.10, green: 0.11, blue: 0.15),
            midGradient: Color(red: 0.14, green: 0.16, blue: 0.23),
            bottomGradient: Color(red: 0.25, green: 0.28, blue: 0.41)
        ),
        ThemePreset(
            id: "bloodMoon",
            name: "Blood Moon",
            icon: "circle.fill",
            accent: Color(red: 1.0, green: 0.30, blue: 0.30),
            topGradient: Color(red: 0.23, green: 0.06, blue: 0.06),
            midGradient: Color(red: 0.11, green: 0.03, blue: 0.03),
            bottomGradient: Color(red: 0.04, green: 0.01, blue: 0.01)
        ),
        ThemePreset(
            id: "voidNebula",
            name: "Void Nebula",
            icon: "circle.fill",
            accent: Color(red: 0.78, green: 0.57, blue: 0.92),
            topGradient: Color(red: 0.07, green: 0.07, blue: 0.13),
            midGradient: Color(red: 0.11, green: 0.08, blue: 0.19),
            bottomGradient: Color(red: 0.14, green: 0.07, blue: 0.27)
        )
    ]

    // MARK: Published settings

    @AppStorage("themeAccentID") var themeID: String = "liquidBlue" {
        didSet { objectWillChange.send() }
    }

    @AppStorage("glassIntensityRaw") var glassIntensityRaw: String = GlassIntensity.thin.rawValue {
        didSet { objectWillChange.send() }
    }

    @AppStorage("appearanceRaw") var appearanceRaw: String = AppearanceStyle.system.rawValue {
        didSet { objectWillChange.send() }
    }

    @AppStorage("defaultSectionRaw") var defaultSectionRaw: String = LibrarySection.albums.rawValue {
        didSet { objectWillChange.send() }
    }

    @AppStorage("showLosslessBadges") var showLosslessBadges: Bool = true {
        didSet { objectWillChange.send() }
    }

    @AppStorage("autoScanOnLaunch") var autoScanOnLaunch: Bool = true {
        didSet { objectWillChange.send() }
    }

    @AppStorage("autoAdvance") var autoAdvance: Bool = true {
        didSet { objectWillChange.send() }
    }

    @AppStorage("defaultVolume") var defaultVolume: Double = 0.8 {
        didSet { objectWillChange.send() }
    }

    @AppStorage("eqPresetID") var eqPresetID: String = "flat" {
        didSet { objectWillChange.send() }
    }

    // MARK: Computed theme

    /// The currently selected equalizer sound style.
    var eqPreset: EQPreset {
        EQPreset.presets.first(where: { $0.id == eqPresetID }) ?? EQPreset.presets[0]
    }

    /// The currently selected accent theme.
    var theme: ThemePreset {
        ThemeManager.presets.first(where: { $0.id == themeID }) ?? ThemeManager.presets[0]
    }

    /// The currently selected glass intensity.
    var glass: GlassIntensity {
        GlassIntensity(rawValue: glassIntensityRaw) ?? .thin
    }

    /// The currently selected color scheme (System / Light / Dark).
    var appearance: AppearanceStyle {
        AppearanceStyle(rawValue: appearanceRaw) ?? .system
    }

    /// The default section shown on launch.
    var defaultSection: LibrarySection {
        LibrarySection(rawValue: defaultSectionRaw) ?? .albums
    }

    private init() {}
}