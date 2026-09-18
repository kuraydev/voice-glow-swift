import Foundation

/// Drives the beam from typing instead of (or alongside) a microphone.
///
/// Every keystroke lands as a pulse that decays on its own; typing fast keeps
/// the glow lit, pausing lets it fall away. Feed `level`/`bands` to `VoiceBeam`
/// exactly as you would the microphone's.
///
/// ```swift
/// @StateObject private var typing = TypingPulse()
///
/// TextField("Ask anything…", text: $text)
///     .onChange(of: text) { old, new in typing.type(old: old, new: new) }
///
/// VoiceBeam(level: typing.level, bands: typing.bands) { composer }
/// ```
@MainActor
public final class TypingPulse: ObservableObject {

    /// Current level, 0–1 — hand straight to `VoiceBeam(level:)`.
    @Published public private(set) var level: Double = 0
    /// A three-band split derived from the pulse, so the lobes still ripple.
    @Published public private(set) var bands: [Double] = [0, 0, 0]

    /// How much one keystroke adds. @default 0.55
    public var strength: Double = 0.55
    /// Seconds for a burst of typing to fall back to dark. @default 0.5
    public var decay: Double = 0.5
    /// A deletion is a smaller pulse than a keystroke. @default 0.6
    public var deleteRatio: Double = 0.6
    /// Submitting the field flashes the beam to full. @default 1
    public var submitStrength: Double = 1

    private var charge: Double = 0
    private var lastEvent = Date()
    private var timer: Timer?

    public init() {}

    deinit { timer?.invalidate() }

    /// Register a keystroke from a text change. Comparing old and new tells a
    /// deletion from an insertion, and a paste from a single character.
    public func type(old: String, new: String) {
        let delta = new.count - old.count
        if delta == 0 { return }
        // A paste is one event, not one pulse per character — scale sublinearly.
        let magnitude = min(1, pow(Double(abs(delta)), 0.45) / 2.2)
        pulse(strength * magnitude * (delta < 0 ? deleteRatio : 1))
    }

    /// Register a keystroke directly, when you aren't diffing text.
    public func keystroke() { pulse(strength) }

    /// Flash the beam — for send, or any moment worth a beat.
    public func submit() { pulse(submitStrength) }

    private func pulse(_ amount: Double) {
        // Rapid typing accumulates, but the glow saturates rather than clipping.
        charge = min(1, charge + amount * (1 - charge * 0.55))
        lastEvent = Date()
        start()
    }

    /// The decay clock only runs while there is something to decay.
    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    private func step() {
        charge *= exp(-(1.0 / 60) / max(0.05, decay))
        if charge < 0.001 {
            charge = 0
            timer?.invalidate()
            timer = nil
        }
        level = charge
        // Keystrokes read as mid-band: the centre lobe leads, the sides follow.
        bands = [charge * 0.85, charge, charge * 0.6]
    }

    /// Drop back to dark immediately.
    public func reset() {
        charge = 0
        level = 0
        bands = [0, 0, 0]
        timer?.invalidate()
        timer = nil
    }
}
