import Foundation

/// The driver math, transcribed from voice-glow's `voiceDriver.ts` (MIT,
/// Jakub Antalik). Every function here is covered by golden vectors lifted
/// from that source — see `VoiceGoldenTests`. Keep the two in step: change a
/// constant here and a test fails rather than the animation quietly drifting.
public enum VoiceMath {

    public static func clamp01(_ v: Double) -> Double {
        v < 0 ? 0 : (v > 1 ? 1 : v)
    }

    /// Wrap a lobe offset into [-span/2, span/2).
    public static func wrapX(_ x: Double, span: Double) -> Double {
        let half = span / 2
        return ((x + half).truncatingRemainder(dividingBy: span) + span)
            .truncatingRemainder(dividingBy: span) - half
    }

    /// How much of a lobe shows at offset x: full at centre, gone at the wrap
    /// edge so a lobe never pops from one side to the other.
    public static func edgeEnvelope(_ x: Double, span: Double) -> Double {
        let t = x / (span / 2 + 4)
        return max(0, 1 - t * t)
    }

    /// Noise gate then soft saturation, so a shout rounds off instead of clipping.
    public static func shape(_ raw: Double, threshold: Double) -> Double {
        if raw <= threshold { return 0 }
        let t = (raw - threshold) / max(0.001, 1 - threshold)
        return clamp01((1 - exp(-3 * t)) / (1 - exp(-3)))
    }

    /// One-pole follower: fast up (attack), slow down (release).
    public static func follow(_ prev: Double, target: Double, dt: Double,
                              attack: Double, release: Double) -> Double {
        let tau = target > prev ? attack : release
        let a = 1 - exp(-dt / max(0.001, tau))
        return prev + (target - prev) * a
    }

    /// The band's bell, normalised to 1 at the centre and exactly 0 at the
    /// ends. `p` below 2 gives a cusp-like rise, above 2 a flatter top;
    /// `skew` widens one side and narrows the other.
    public static func bell(_ t: Double, p: Double, sigma: Double, skew: Double) -> Double {
        let side = t < 0 ? 1 - skew : 1 + skew
        let s = max(0.05, sigma * side)
        let v = exp(-pow(abs(t) / s, p))
        let tail = exp(-pow(1 / s, p))
        return max(0, (v - tail) / (1 - tail))
    }

    /// The band's tail lift: from `position` of the way out to the edge, the
    /// line rises again to the full `lift` exactly at the corner.
    public static func tailLift(_ dist: Double, edge: Double, lift: Double,
                                position: Double, curve: Double) -> Double {
        if lift <= 0 || edge <= 0 { return 0 }
        let start = edge * max(0, min(0.98, position))
        if dist <= start { return 0 }
        let u = min(1, (dist - start) / max(1, edge - start))
        return lift * pow(u, max(0.5, curve))
    }

    /// 0 → 1 → 0 over one unit of phase.
    public static func pingPong(_ phase: Double) -> Double {
        (1 - cos(2 * .pi * phase)) / 2
    }
}
