import SwiftUI

/// A sound-reactive glow along a view's bottom edge: a centred, colourful beam
/// that rises and blooms with voice, and gathers into a travelling sweep while
/// you are thinking.
///
/// ```swift
/// @StateObject private var mic = VoiceMicrophone()
///
/// VoiceBeam(level: mic.level, bands: mic.bands, processing: thinking) {
///     ChatInput()
/// }
/// .onAppear { mic.start() }
/// ```
///
/// The glow is drawn behind and below `content`; the view keeps `content`'s
/// own size and lets the bloom spill outside it, so it needs no layout space
/// of its own.
public struct VoiceBeam<Content: View>: View {

    private let content: Content
    private var config: VoiceConfig
    private let level: Double
    private let bands: [Double]

    @State private var driver = VoiceDriver()
    @State private var frame = VoiceFrame()
    @State private var lastTick: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - level: Latest microphone level, typically `VoiceMicrophone.level`.
    ///   - bands: Latest three-band split, typically `VoiceMicrophone.bands`.
    ///   - processing: While true the glow gathers into a travelling beam.
    ///   - config: Everything else — start from `VoiceConfig(type:)`.
    public init(level: Double,
                bands: [Double] = [0, 0, 0],
                processing: Bool = false,
                config: VoiceConfig = VoiceConfig(),
                @ViewBuilder content: () -> Content) {
        self.level = level
        self.bands = bands
        self.content = content()
        var resolved = config
        resolved.processing = processing
        self.config = resolved
    }

    public var body: some View {
        content
            .background(alignment: .bottom) { glow }
            .allowsHitTesting(true)
            .accessibilityHidden(false)
    }

    private var glow: some View {
        TimelineView(.animation(paused: config.paused)) { timeline in
            Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: true) { ctx, size in
                draw(in: &ctx, size: size, frame: tick(at: timeline.date))
            }
            .frame(height: bloomHeight)
            .offset(y: bloomHeight / 2)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var bloomHeight: CGFloat {
        CGFloat(VoiceGeometry.ceilingHeight * config.reach * config.scale * 2.2)
    }

    /// Advance the driver to `date` and hand back the frame to draw.
    private func tick(at date: Date) -> VoiceFrame {
        var resolved = config
        resolved.reducedMotion = config.reducedMotion || reduceMotion

        var local = driver
        let dt = lastTick.map { date.timeIntervalSince($0) } ?? 1.0 / 60.0
        local.advance(dt: dt, level: level, bands: bands, config: resolved)

        // TimelineView re-evaluates this body; carry the state forward without
        // triggering another pass.
        DispatchQueue.main.async {
            driver = local
            frame = local.frame
            lastTick = date
        }
        return local.frame
    }

    // ── painting ───────────────────────────────────────────────────────────

    private func draw(in ctx: inout GraphicsContext, size: CGSize, frame f: VoiceFrame) {
        guard size.width > 0, size.height > 0 else { return }

        let scale = config.scale
        let level = VoiceMath.clamp01(f.level)
        let centre = size.width / 2 + CGFloat(f.sweep) * sweepReach(width: size.width)
        let baseline = size.height / 2

        // Each lobe is one colour of the palette, offset around the ring and
        // faded out at the wrap edge so it never pops across.
        let span = VoiceGeometry.lobeSpan(config: config)
        let lobes = config.colors.count
        let reach = VoiceGeometry.ceilingHeight * config.reach * scale
        let bend = config.bend * scale * level

        for (index, color) in config.colors.enumerated() {
            let slot = Double(index) - Double(lobes - 1) / 2
            let offset = VoiceMath.wrapX(slot * span / Double(max(1, lobes)) + f.flowOffset, span: span)
            let envelope = VoiceMath.edgeEnvelope(offset, span: span)
            guard envelope > 0.001 else { continue }

            // The band each lobe rides on lifts it a little further.
            let band = f.bands.indices.contains(index % 3) ? f.bands[index % 3] : level
            let height = (reach * (0.35 + 0.65 * level) + bend * 0.5) * (0.7 + 0.3 * band)
            let width = VoiceGeometry.ceilingHalfWidth * config.spread * scale * (0.6 + 0.4 * level)

            let rect = CGRect(x: centre + CGFloat(offset) - CGFloat(width) / 2,
                              y: baseline - CGFloat(height),
                              width: CGFloat(width),
                              height: CGFloat(height) * 2)

            let tinted = hueShifted(color, by: f.hue)
            let gradient = Gradient(stops: [
                .init(color: tinted.opacity(0.85 * envelope * (0.25 + 0.75 * level)), location: 0),
                .init(color: tinted.opacity(0.35 * envelope * level), location: 0.45),
                .init(color: .clear, location: 1),
            ])

            ctx.fill(
                Ellipse().path(in: rect),
                with: .radialGradient(gradient,
                                      center: CGPoint(x: rect.midX, y: rect.midY),
                                      startRadius: 0,
                                      endRadius: max(rect.width, rect.height) / 2)
            )
        }

        drawBand(in: &ctx, size: size, frame: f, baseline: baseline, centre: centre, level: level)
    }

    /// The bright line that rides the edge: a normalised bell, lifted at the
    /// corners by the tail, sampled across the width.
    private func drawBand(in ctx: inout GraphicsContext, size: CGSize, frame f: VoiceFrame,
                          baseline: CGFloat, centre: CGFloat, level: Double) {
        guard config.bandStrength > 0 else { return }

        let scale = config.scale
        let halfWidth = Double(size.width) / 2 + config.bandTailOverflow
        let peak = VoiceGeometry.ceilingHeight * config.bandWidth * config.bandPosition * scale
            * (0.3 + 0.7 * level)
        let offset = config.bandOffset * scale

        var path = Path()
        for i in 0...VoiceGeometry.bandSamples {
            let t = Double(i) / Double(VoiceGeometry.bandSamples)          // 0…1
            let x = -halfWidth + t * halfWidth * 2
            let normalised = x / max(1, halfWidth)                          // -1…1
            let bell = VoiceMath.bell(normalised, p: config.bandCurve,
                                      sigma: config.bandSpread, skew: config.bandSkew)
            let tail = VoiceMath.tailLift(abs(x), edge: halfWidth, lift: config.bandTail,
                                          position: config.bandTailPosition,
                                          curve: config.bandTailCurve)
            let y = baseline + CGFloat(offset) - CGFloat(peak * (bell + tail))
            let point = CGPoint(x: centre + CGFloat(x), y: y)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        let strength = config.bandStrength * (0.2 + 0.8 * level)
        let core = hueShifted(config.bandColors.core, by: f.hue)

        // Chromatic split: the fringes ride just above and below the core.
        if config.bandAberration > 0 {
            let split = CGFloat(config.bandAberration * scale)
            for (color, dy) in [(config.bandColors.above, -split),
                                (config.bandColors.mid, 0),
                                (config.bandColors.below, split)] {
                ctx.stroke(path.offsetBy(dx: 0, dy: dy),
                           with: .color(hueShifted(color, by: f.hue).opacity(0.5 * strength)),
                           style: StrokeStyle(lineWidth: 2.2 * CGFloat(scale), lineCap: .round))
            }
        }

        ctx.stroke(path,
                   with: .color(core.opacity(min(1, strength))),
                   style: StrokeStyle(lineWidth: 1.4 * CGFloat(scale), lineCap: .round))
    }

    /// How far the travelling beam runs to each side.
    private func sweepReach(width: CGFloat) -> CGFloat {
        CGFloat(VoiceGeometry.lobeSpan(config: config) * config.processingTravel / 2)
    }

    private func hueShifted(_ color: Color, by degrees: Double) -> Color {
        guard degrees != 0 else { return color }
        #if canImport(UIKit)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        return Color(hue: Double((h + CGFloat(degrees / 360)).truncatingRemainder(dividingBy: 1) + 1)
                        .truncatingRemainder(dividingBy: 1),
                     saturation: Double(s), brightness: Double(b), opacity: Double(a))
        #else
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let shifted = (ns.hueComponent + CGFloat(degrees / 360)).truncatingRemainder(dividingBy: 1)
        return Color(hue: Double(shifted < 0 ? shifted + 1 : shifted),
                     saturation: Double(ns.saturationComponent),
                     brightness: Double(ns.brightnessComponent),
                     opacity: Double(ns.alphaComponent))
        #endif
    }
}
