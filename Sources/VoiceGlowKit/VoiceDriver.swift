import Foundation

/// One frame of resolved animation state: everything the renderer needs and
/// nothing about how it is drawn.
public struct VoiceFrame: Sendable, Equatable {
    /// Shaped, followed level, 0–1. The glow's height rides this.
    public var level: Double = 0
    /// The three voice bands, shaped and followed.
    public var bands: [Double] = [0, 0, 0]
    /// Lobe drift in px, wrapped into the lobe ring.
    public var flowOffset: Double = 0
    /// Hue drift in degrees.
    public var hue: Double = 0
    /// How far into the processing morph, 0 (voice glow) → 1 (travelling beam).
    public var morph: Double = 0
    /// The beam's position along the edge while processing, -1…1.
    public var sweep: Double = 0
}

/// The per-frame math: gate, follow, breathe, flow, sweep. Platform-free and
/// deterministic — advance it with a time step and it produces the frame the
/// renderer draws. The pure functions it leans on are golden-tested against
/// upstream (see `VoiceMath`).
public struct VoiceDriver: Sendable {

    public private(set) var frame = VoiceFrame()
    private var elapsed: Double = 0
    private var sweepPhase: Double = 0

    public init() {}

    /// Advance by `dt` seconds against the latest analyser read.
    /// Pass `level`/`bands` straight from `VoiceMicrophone`.
    public mutating func advance(dt: Double, level rawLevel: Double, bands rawBands: [Double],
                                 config: VoiceConfig) {
        guard !config.paused else { return }
        let dt = min(max(dt, 0), 0.05)   // upstream clamps the step at 50 ms
        elapsed += dt

        // Idle breathing keeps the glow alive between words; Reduce Motion
        // holds it at its resting level instead.
        let breathe: Double
        if config.reducedMotion {
            breathe = config.idle
        } else {
            let phase = (2 * Double.pi * elapsed) / max(0.2, config.breatheDuration)
            breathe = config.idle * (0.5 + 0.5 * sin(phase))
        }

        // Processing holds the glow at a fixed level rather than reading voice.
        let targetLevel: Double
        if config.processing {
            targetLevel = max(config.processingLevel, breathe)
        } else {
            targetLevel = max(VoiceMath.shape(rawLevel, threshold: config.threshold), breathe)
        }
        frame.level = VoiceMath.follow(frame.level, target: targetLevel, dt: dt,
                                       attack: config.attack, release: config.release)

        for i in 0..<3 {
            let raw = i < rawBands.count ? rawBands[i] : 0
            let target = config.processing ? config.processingLevel * 0.6
                                           : VoiceMath.shape(raw, threshold: config.threshold)
            frame.bands[i] = VoiceMath.follow(frame.bands[i], target: target, dt: dt,
                                              attack: config.attack, release: config.release)
        }

        // Lobes drift at a speed set by how loud it is, wrapped into the ring
        // so a lobe never pops from one side to the other.
        if !config.reducedMotion && config.flow != 0 {
            let span = VoiceGeometry.lobeSpan(config: config)
            frame.flowOffset = VoiceMath.wrapX(frame.flowOffset + config.flow * frame.level * dt,
                                               span: span)
        }

        if config.staticColors || config.reducedMotion {
            frame.hue = 0
        } else {
            let phase = elapsed / max(0.5, config.hueDuration)
            frame.hue = max(0, config.hueRange) * sin(2 * .pi * phase)
        }

        // The morph runs on its own clock so the swap between glow and beam
        // reads as the shimmer coming to rest rather than a cut.
        let morphTarget: Double = config.processing ? 1 : 0
        let ease = max(0.001, config.processingEase)
        frame.morph = VoiceMath.follow(frame.morph, target: morphTarget, dt: dt,
                                       attack: ease, release: ease)

        if config.processing && !config.reducedMotion {
            sweepPhase += dt / max(0.05, config.processingDuration)
            if sweepPhase >= 2 { sweepPhase -= 2 }
            // Ping-pong with an eased turn: the beam dwells at each end rather
            // than snapping back.
            let forward = sweepPhase < 1
            let u = forward ? sweepPhase : sweepPhase - 1
            let k = max(1, config.processingCurve)
            let eased = u < 0.5 ? 0.5 * pow(2 * u, k) : 1 - 0.5 * pow(2 - 2 * u, k)
            frame.sweep = forward ? 2 * eased - 1 : 1 - 2 * eased
        } else {
            frame.sweep = VoiceMath.follow(frame.sweep, target: 0, dt: dt, attack: ease, release: ease)
        }
    }

    /// Drop back to rest — call when the microphone stops.
    public mutating func reset() {
        frame = VoiceFrame()
        elapsed = 0
        sweepPhase = 0
    }
}

/// Geometry shared by the driver and the renderer, from upstream's `styles.ts`.
public enum VoiceGeometry {
    /// One lobe of the beam: a resting offset from centre, its size, and which
    /// voice band drives it.
    public struct Lobe: Sendable, Equatable {
        public let x: Double
        public let w: Double
        public let h: Double
        public let band: Int
    }

    /// Seven lobes: the centre rides the low band, its neighbours the mids, the
    /// outer pair the highs and the far pair the mids again, so a voice makes
    /// the colours ripple outward instead of one blob pumping.
    public static let lobes: [Lobe] = [
        Lobe(x: 0, w: 74, h: 46, band: 0),
        Lobe(x: -36, w: 54, h: 40, band: 1),
        Lobe(x: 36, w: 54, h: 40, band: 1),
        Lobe(x: -72, w: 48, h: 32, band: 2),
        Lobe(x: 72, w: 48, h: 32, band: 2),
        Lobe(x: -108, w: 42, h: 26, band: 1),
        Lobe(x: 108, w: 42, h: 26, band: 1),
    ]

    /// Resting distance between neighbouring lobes, px.
    public static let lobeSpacing: Double = 36
    /// Width of the ring the lobes travel around — one full turn of the flow.
    public static let lobeSpan: Double = lobeSpacing * Double(lobes.count)

    /// The ceiling every layer is masked to (px at scale 1): an ellipse on the
    /// bottom edge that the glow lives inside.
    public static let ceilingHalfWidth: Double = 170
    public static let ceilingHeight: Double = 64
    /// Samples along the band line.
    public static let bandSamples: Int = 56

    /// The lobe ring's span for a config — the distance a lobe travels before
    /// it wraps.
    public static func lobeSpan(config: VoiceConfig) -> Double {
        max(1, lobeSpan * config.spread * config.scale)
    }
}
