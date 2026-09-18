import SwiftUI

/// Preset shapes, matching upstream voice-glow's `type` prop.
public enum VoiceBeamType: String, Sendable, CaseIterable {
    /// The full-width glow for a chat composer.
    case standard
    /// Small and tight, for a pill-shaped control.
    case pill
    /// Taller and narrower, tuned for a phone's bottom edge.
    case mobile
}

public enum VoiceBeamTheme: String, Sendable, CaseIterable {
    case dark, light
}

/// Every knob upstream exposes as a prop. Defaults track voice-glow 0.2.0;
/// `VoiceBeamType` presets override a subset, and anything you set explicitly
/// wins over both.
public struct VoiceConfig: Sendable, Equatable {

    // ── response ───────────────────────────────────────────────────────────
    /// Input gain applied to the microphone level.
    public var sensitivity: Double = 3.1
    /// Noise gate: levels at or below this read as silence.
    public var threshold: Double = 0.015
    /// Seconds for the glow to rise to a new louder level.
    public var attack: Double = 0.325
    /// Seconds for it to fall back.
    public var release: Double = 0.86
    /// How lit the glow sits when nobody is speaking, 0–1.
    public var idle: Double = 0.23
    /// Seconds for one breath of the idle glow.
    public var breatheDuration: Double = 5.2

    // ── geometry ───────────────────────────────────────────────────────────
    /// Overall size of the effect.
    public var scale: Double = 1
    /// How far the glow reaches up from the edge.
    public var reach: Double = 1.2
    /// How wide the lobes sit apart.
    public var spread: Double = 1.05
    /// Lobe drift in px/s at full level; negative flows right-to-left.
    public var flow: Double = 48
    /// Extra px of height the glow's top gains at the centre at full level.
    public var bend: Double = 60
    /// Bloom blur multiplier.
    public var glowSize: Double = 1
    /// Resting distance between lobes.
    public var lobeSpacing: Double = 0.85
    /// The ceiling's tuned width multiplier — how wide the glow's mask sits.
    /// How far a lobe's colour reaches before it fades out.
    public var softness: Double = 1.07
    /// Size of the hot core at the centre of the edge.
    public var coreSize: Double = 1
    /// Lobes follow the voice bands individually.
    public var bands: Bool = true
    public var rangeWidth: Double = 0.75
    /// The ceiling's tuned height multiplier.
    public var rangeHeight: Double = 1

    // ── the band (the bright line riding the edge) ──────────────────────────
    public var bandStrength: Double = 1.55
    public var bandWidth: Double = 2.15
    public var bandPosition: Double = 0.35
    /// Bell exponent: below 2 a cusp-like rise, 2 a gaussian, above a flatter top.
    public var bandCurve: Double = 1.75
    /// Bell width: small is a narrow spike with long tails, large a broad dome.
    public var bandSpread: Double = 0.87
    /// Positive widens the right side and steepens the left.
    public var bandSkew: Double = 0.12
    /// Vertical shift of the whole line, px (negative lowers it).
    public var bandOffset: Double = -27
    /// Rise of the ends toward the corners, as a fraction of the peak.
    public var bandTail: Double = 0.59
    /// Where that rise starts, as a share of the centre-to-edge distance.
    public var bandTailPosition: Double = 0.67
    /// Exponent of the rise: 1 a ramp, higher a hook that whips up at the end.
    public var bandTailCurve: Double = 2.4
    /// Px the band runs past each side before the host crops it.
    public var bandTailOverflow: Double = 15
    /// Chromatic split across the band's fringes.
    public var bandAberration: Double = 0.89

    // ── processing (the travelling beam) ───────────────────────────────────
    /// While true the glow gathers into a beam that sweeps the edge.
    public var processing: Bool = false
    /// Seconds for one pass, left to right or back.
    public var processingDuration: Double = 1.1
    /// How lit the glow is held while processing, 0–1.
    public var processingLevel: Double = 0.55
    /// How far the beam travels each way, × half the lobe ring.
    public var processingTravel: Double = 1.55
    /// Easing into each turn: 1 constant speed, 2 smooth, higher dwells at the ends.
    public var processingCurve: Double = 2.1
    /// Seconds the morph between glow and beam takes.
    public var processingEase: Double = 0.42
    /// How much the coloured glow rides the corner arcs, 0–1.
    public var cornerFollow: Double = 0.45

    // ── colour ─────────────────────────────────────────────────────────────
    public var theme: VoiceBeamTheme = .dark
    /// Degrees of hue drift across one cycle.
    public var hueRange: Double = 26
    /// Seconds for one hue cycle.
    public var hueDuration: Double = 12
    /// Freeze the hue drift.
    public var staticColors: Bool = false
    /// Beam colours, bottom to top of the bloom.
    public var colors: [Color] = VoiceConfig.darkPalette
    /// The band's core and fringe colours.
    public var bandColors: VoiceBandColors = .dark

    // ── state ──────────────────────────────────────────────────────────────
    /// Corner radius of the host, px — the beam follows its arc while processing.
    public var radius: Double = 0
    /// Hold the frame: the clock stops and the source is not read.
    public var paused: Bool = false
    /// Honour Reduce Motion: no flow, no breathing, no sweep.
    public var reducedMotion: Bool = false

    public init() {}

    /// The defaults for a preset shape.
    public init(type: VoiceBeamType, theme: VoiceBeamTheme = .dark) {
        self.init()
        self.theme = theme
        if theme == .light {
            reach = 1.8
            spread = 0.8
            colors = VoiceConfig.lightPalette
            bandColors = .light
        }
        switch type {
        case .standard:
            break
        case .pill:
            scale = 0.45; glowSize = 0.95
            reach = 1.35; spread = 1.1
            flow = 0; bend = 23
            bandWidth = 1.85; bandCurve = 1.95; bandSpread = 0.38
            bandOffset = -16; bandTail = 0
            processingTravel = 2; cornerFollow = 0
            lobeSpacing = 0.45
            rangeWidth = 0.8; rangeHeight = 0.7
        case .mobile:
            scale = 1.25
            spread = 0.45; reach = 3
            flow = 60; bend = 70
            bandWidth = 2.4; bandCurve = 1.55; bandSpread = 0.9
            bandOffset = -50
            bandTail = 0.62; bandTailPosition = 0.42
            bandTailCurve = 2.7; bandTailOverflow = 22
            processingDuration = 1.05; processingLevel = 0.35
            processingTravel = 1; cornerFollow = 0.4
        }
    }

    /// Seven colours, one per lobe (centre first, then pairs outward).
    public static let darkPalette: [Color] = [
        Color(red: 1.00, green: 0.27, blue: 0.47),   // pink
        Color(red: 0.24, green: 0.75, blue: 1.00),   // sky
        Color(red: 0.69, green: 0.27, blue: 1.00),   // purple
        Color(red: 0.24, green: 0.86, blue: 0.51),   // green
        Color(red: 1.00, green: 0.59, blue: 0.16),   // orange
        Color(red: 0.35, green: 0.39, blue: 1.00),   // indigo
        Color(red: 0.16, green: 0.78, blue: 0.75),   // teal
    ]

    /// Deeper values, because on a white surface they sit at far lower opacity.
    public static let lightPalette: [Color] = [
        Color(red: 1.00, green: 0.79, blue: 0.08),   // gold
        Color(red: 0.49, green: 0.77, blue: 1.00),   // sky
        Color(red: 0.71, green: 0.16, blue: 0.90),   // violet
        Color(red: 0.92, green: 0.39, blue: 0.63),   // rose
        Color(red: 1.00, green: 0.69, blue: 0.48),   // peach
        Color(red: 0.60, green: 0.63, blue: 1.00),   // periwinkle
        Color(red: 0.50, green: 0.85, blue: 0.93),   // aqua
    ]
}

/// The band's core and its fringes, bottom to top.
public struct VoiceBandColors: Sendable, Equatable {
    public var core: Color
    public var above: Color
    public var mid: Color
    public var below: Color

    public init(core: Color, above: Color, mid: Color, below: Color) {
        self.core = core
        self.above = above
        self.mid = mid
        self.below = below
    }

    public static let dark = VoiceBandColors(
        core: .white,
        above: Color(red: 0.62, green: 0.80, blue: 1.00),
        mid: Color(red: 1.00, green: 0.78, blue: 0.94),
        below: Color(red: 1.00, green: 0.72, blue: 0.48)
    )

    public static let light = VoiceBandColors(
        core: .white,
        above: Color(red: 0.55, green: 0.74, blue: 1.00),
        mid: Color(red: 1.00, green: 0.70, blue: 0.90),
        below: Color(red: 1.00, green: 0.64, blue: 0.40)
    )
}
