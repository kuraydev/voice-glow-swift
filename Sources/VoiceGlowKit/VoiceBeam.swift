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
            .overlay { glow }
    }

    /// The glow lives inside the host's own bounds and radiates from its bottom
    /// edge — the bloom spills outside without the view taking any extra space.
    private var glow: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: config.paused)) { timeline in
                Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: true) { ctx, size in
                    draw(in: &ctx, size: size, frame: tick(at: timeline.date))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .blendMode(config.theme == .dark ? .screen : .multiply)
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
    //
    // Upstream stacks three gradient layers (a sharp stroke, a dimmer inner
    // light, a wide bloom), all anchored on the host's bottom edge and masked
    // to one ellipse — the "ceiling" — that grows with the voice. The band is
    // a separate line traced along that ceiling's hump.

    private func draw(in ctx: inout GraphicsContext, size: CGSize, frame f: VoiceFrame) {
        guard size.width > 0, size.height > 0 else { return }

        let lit = VoiceMath.clamp01(f.level)
        let scale = config.scale
        // Everything radiates from the middle of the bottom edge; while
        // processing the beam slides along it.
        let baseline = size.height
        let centre = size.width / 2 + CGFloat(f.sweep) * CGFloat(sweepReach())

        // The ceiling: the ellipse every layer is masked to. It widens and
        // rises with the level, and `bend` humps its top at the centre.
        let ceilingW = VoiceGeometry.ceilingHalfWidth * config.rangeWidth * scale * (0.7 + 0.3 * lit)
        let ceilingH = (VoiceGeometry.ceilingHeight * 0.62 * config.rangeHeight * config.reach * scale
                        * (0.45 + 0.55 * lit)) + config.bend * 0.45 * scale * lit

        // Bloom first (widest, softest), then the inner light, then the stroke.
        // Each layer carries its own blur: the bloom is a haze, the stroke is
        // the only near-sharp pass, and together they stay well under white.
        let layers: [(spread: Double, height: Double, alpha: Double, blur: Double)] = [
            (1.15, 1.50, config.theme == .dark ? 0.55 : 0.34, 16),
            (0.90, 0.90, 0.38, 7),
            (1.00, 1.00, 0.48, 2.0),
        ]

        ctx.drawLayer { layer in
            for spec in layers {
                layer.drawLayer { pass in
                    pass.addFilter(.blur(radius: spec.blur * config.glowSize * scale))
                    paintLobes(in: &pass, frame: f, lit: lit, centre: centre, baseline: baseline,
                               widthScale: spec.spread, heightScale: spec.height, alpha: spec.alpha)
                }
            }
            paintCore(in: &layer, lit: lit, centre: centre, baseline: baseline)

            // The soft ceiling mask: white at the edge, gone at the ellipse's
            // rim, so nothing paints outside the hump.
            let mask = CGRect(x: centre - CGFloat(ceilingW), y: baseline - CGFloat(ceilingH),
                              width: CGFloat(ceilingW) * 2, height: CGFloat(ceilingH) * 2)
            layer.fill(
                Ellipse().path(in: mask),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.55), location: 0.35),
                        .init(color: .white.opacity(0.12), location: 0.7),
                        .init(color: .clear, location: 1),
                    ]),
                    center: CGPoint(x: mask.midX, y: mask.midY),
                    startRadius: 0,
                    endRadius: max(mask.width, mask.height) / 2
                ),
                style: FillStyle()
            )
        }

        drawBand(in: &ctx, size: size, frame: f, baseline: baseline, centre: centre, lit: lit)
    }

    /// One pass of the seven lobes. Each slides along the ring by the flow
    /// phase and fades out at the wrap edge, so colours cycle through the
    /// centre instead of popping across.
    private func paintLobes(in ctx: inout GraphicsContext, frame f: VoiceFrame, lit: Double,
                            centre: CGFloat, baseline: CGFloat,
                            widthScale: Double, heightScale: Double, alpha: Double) {
        let scale = config.scale
        let span = VoiceGeometry.lobeSpan(config: config)

        for (index, lobe) in VoiceGeometry.lobes.enumerated() {
            let resting = lobe.x * config.spread * scale
            let offset = VoiceMath.wrapX(resting + f.flowOffset, span: span)
            let envelope = VoiceMath.edgeEnvelope(offset, span: span)
            guard envelope > 0.001 else { continue }

            // Each lobe rides its own voice band, so a voice ripples outward.
            let band = f.bands.indices.contains(lobe.band) ? f.bands[lobe.band] : lit
            let drive = 0.45 + 0.55 * VoiceMath.clamp01(0.5 * lit + 0.5 * band)

            let w = lobe.w * widthScale * config.spread * scale * drive
            let h = lobe.h * heightScale * config.reach * scale * drive
                + config.bend * scale * lit * (index == 0 ? 0.5 : 0.2)

            let rect = CGRect(x: centre + CGFloat(offset) - CGFloat(w),
                              y: baseline - CGFloat(h),
                              width: CGFloat(w) * 2,
                              height: CGFloat(h) * 2)

            let color = hueShifted(config.colors[index % config.colors.count], by: f.hue)
            let strength = alpha * envelope * (0.2 + 0.8 * lit)

            ctx.fill(
                Ellipse().path(in: rect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(strength), location: 0),
                        .init(color: color.opacity(strength * 0.45), location: 0.4),
                        .init(color: .clear, location: 1),
                    ]),
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: max(rect.width, rect.height) / 2
                )
            )
        }
    }

    /// The hot core at the centre of the edge — the light source the colours
    /// fan out from. Black on a light theme, so the edge still reads.
    private func paintCore(in ctx: inout GraphicsContext, lit: Double,
                           centre: CGFloat, baseline: CGFloat) {
        let scale = config.scale
        let w = 30 * scale * (0.6 + 0.4 * lit)
        let h = 30 * scale * config.reach * (0.5 + 0.5 * lit)
        let rect = CGRect(x: centre - CGFloat(w), y: baseline - CGFloat(h),
                          width: CGFloat(w) * 2, height: CGFloat(h) * 2)
        let base: Color = config.theme == .dark ? .white : .black
        let peak = config.theme == .dark ? 0.20 : 0.28
        let drive = lit * lit   // quadratic: a glint at full voice, nothing at rest

        ctx.fill(
            Ellipse().path(in: rect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: base.opacity(peak * drive), location: 0),
                    .init(color: base.opacity(0.06 * drive), location: 0.3),
                    .init(color: .clear, location: 0.65),
                ]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: 0,
                endRadius: max(rect.width, rect.height) / 2
            )
        )
    }

    /// The bright line that traces the ceiling's hump: a normalised bell,
    /// lifted at the corners by the tail, sampled across the width.
    private func drawBand(in ctx: inout GraphicsContext, size: CGSize, frame f: VoiceFrame,
                          baseline: CGFloat, centre: CGFloat, lit: Double) {
        guard config.bandStrength > 0 else { return }

        let scale = config.scale
        let halfWidth = Double(size.width) / 2 + config.bandTailOverflow
        // The hump rides the ceiling, capped so the line always stays in the
        // bottom third of the host — it traces the glow, it doesn't cross the
        // content.
        let ceiling = VoiceGeometry.ceilingHeight * 0.62 * config.rangeHeight * config.reach * scale
            * (0.45 + 0.55 * lit) + config.bend * 0.45 * scale * lit
        let peak = min(ceiling * config.bandPosition, Double(size.height) * 0.34)
        let offset = config.bandOffset * scale * 0.12
        // The bell is measured against the ceiling's own width, not the host's,
        // so a wide composer gets a centred hump instead of one long swell.
        let bellHalfWidth = max(1, VoiceGeometry.ceilingHalfWidth * config.rangeWidth
                                * config.bandWidth * 0.5 * config.spread * scale)

        var path = Path()
        for i in 0...VoiceGeometry.bandSamples {
            let x = -halfWidth + (Double(i) / Double(VoiceGeometry.bandSamples)) * halfWidth * 2
            let bell = VoiceMath.bell(x / bellHalfWidth, p: config.bandCurve,
                                      sigma: config.bandSpread, skew: config.bandSkew)
            let tail = VoiceMath.tailLift(abs(x), edge: halfWidth, lift: config.bandTail * 0.35,
                                          position: config.bandTailPosition,
                                          curve: config.bandTailCurve)
            let point = CGPoint(x: centre + CGFloat(x),
                                y: baseline + CGFloat(offset) - CGFloat(peak * (bell + tail)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        let strength = VoiceMath.clamp01(config.bandStrength * (0.15 + 0.85 * lit))
        let core = hueShifted(config.bandColors.core, by: f.hue)

        // Chromatic split: the fringes ride just above and below the core.
        if config.bandAberration > 0 {
            let split = CGFloat(config.bandAberration * scale)
            for (color, dy) in [(config.bandColors.above, -split),
                                (config.bandColors.mid, 0),
                                (config.bandColors.below, split)] {
                ctx.stroke(path.offsetBy(dx: 0, dy: dy),
                           with: .color(hueShifted(color, by: f.hue).opacity(0.30 * strength)),
                           style: StrokeStyle(lineWidth: 1.6 * CGFloat(scale), lineCap: .round))
            }
        }

        ctx.stroke(path,
                   with: .color(core.opacity(0.85 * strength)),
                   style: StrokeStyle(lineWidth: 1.0 * CGFloat(scale), lineCap: .round))
    }

    /// How far the travelling beam runs to each side.
    private func sweepReach() -> Double {
        VoiceGeometry.lobeSpan(config: config) * config.processingTravel / 2
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
