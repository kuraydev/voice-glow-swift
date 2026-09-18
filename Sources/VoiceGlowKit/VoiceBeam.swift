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

    /// When set, the view paints exactly this frame and runs no clock — for
    /// previews, snapshot tests, and comparing against a reference.
    private let fixedFrame: VoiceFrame?

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
        self.fixedFrame = nil
        var resolved = config
        resolved.processing = processing
        self.config = resolved
    }

    /// Paint one exact frame, with no animation clock — settle a `VoiceDriver`
    /// yourself and hand the result over.
    public init(frame: VoiceFrame,
                config: VoiceConfig = VoiceConfig(),
                @ViewBuilder content: () -> Content) {
        self.level = frame.level
        self.bands = frame.bands
        self.content = content()
        self.fixedFrame = frame
        self.config = config
    }

    public var body: some View {
        content
            .overlay { glow }
    }

    /// The glow lives inside the host's own bounds and radiates from its bottom
    /// edge — the bloom spills outside without the view taking any extra space.
    private var glow: some View {
        GeometryReader { proxy in
            if let fixedFrame {
                Canvas(opaque: false, colorMode: .extendedLinear) { ctx, size in
                    draw(in: &ctx, size: size, frame: fixedFrame)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                TimelineView(.animation(paused: config.paused)) { timeline in
                    Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: true) { ctx, size in
                        draw(in: &ctx, size: size, frame: tick(at: timeline.date))
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
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

        let scale = config.scale
        let eff = VoiceMath.clamp01(f.level)

        // Upstream's three multipliers. The lobe sizes in `VoiceGeometry` are
        // radii to be scaled by these — not pixel sizes — which is what makes
        // the glow span the whole host instead of sitting in a puddle.
        let glow = 0.15 + 0.85 * eff
        let hMul = 0.5 + config.reach * eff
        let wMul = 0.85 + config.spread * eff

        let baseline = size.height
        let centre = size.width / 2 + CGFloat(f.sweep) * CGFloat(sweepReach())

        // Everything lives inside the host's rounded rect — the glow is light
        // behind the surface, not a halo hanging off it.
        let hostShape = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: CGFloat(config.radius > 0 ? config.radius : Double(size.height) / 2),
                             style: .continuous)
        ctx.clip(to: hostShape)

        // Bloom (widest, softest) → inner light → stroke, exactly upstream's
        // stack. `y` lifts the stroke pass slightly off the edge.
        let layers: [(sw: Double, sh: Double, y: Double, alpha: Double, blur: Double)] = [
            (1.15, 1.50, 0, config.theme == .dark ? 0.72 : 0.46, 32),
            (0.90, 0.90, 0, 0.40, 18),
            (1.00, 1.00, 2, 0.46, 11),
        ]

        ctx.drawLayer { layer in
            layer.opacity = glow
            for spec in layers {
                layer.drawLayer { pass in
                    pass.addFilter(.blur(radius: spec.blur * config.glowSize * scale))
                    paintLobes(in: &pass, frame: f, eff: eff, centre: centre, baseline: baseline,
                               wMul: wMul, hMul: hMul, sw: spec.sw, sh: spec.sh,
                               yOffset: spec.y, alpha: spec.alpha)
                }
            }
            paintCore(in: &layer, eff: eff, wMul: wMul, hMul: hMul, centre: centre, baseline: baseline)
        }

        drawBand(in: &ctx, size: size, frame: f, baseline: baseline, centre: centre, lit: eff,
                 hMul: hMul, wMul: wMul)
    }

    /// One pass of the seven lobes. Each is a radial gradient anchored on the
    /// bottom edge, its height lifted by the band it follows and faded out at
    /// the wrap edge so colours cycle through the centre.
    private func paintLobes(in ctx: inout GraphicsContext, frame f: VoiceFrame, eff: Double,
                            centre: CGFloat, baseline: CGFloat,
                            wMul: Double, hMul: Double, sw: Double, sh: Double,
                            yOffset: Double, alpha: Double) {
        let scale = config.scale
        let span = VoiceGeometry.lobeSpan * config.lobeSpacing
        // Where the gradient reaches full transparency, as a share of its
        // radius — upstream's `softness`.
        let fade = min(0.95, max(0.4, 0.70 * config.softness))

        for (index, lobe) in VoiceGeometry.lobes.enumerated() {
            let x = VoiceMath.wrapX(lobe.x * config.lobeSpacing + f.flowOffset, span: span)
            let band = f.bands.indices.contains(lobe.band) ? f.bands[lobe.band] : eff
            // The band a lobe follows lifts it between 0.6x and 1.3x of the
            // shared height; the envelope fades it toward the wrap.
            let lift = (config.bands ? 0.6 + 0.7 * band : 1) * VoiceMath.edgeEnvelope(x, span: span)
            guard lift > 0.001 else { continue }

            let rx = lobe.w * sw * wMul * scale
            let ry = lobe.h * sh * hMul * lift * scale
            let cx = centre + CGFloat(x * wMul * scale)
            let cy = baseline + CGFloat(yOffset * scale)

            let rect = CGRect(x: cx - CGFloat(rx), y: cy - CGFloat(ry),
                              width: CGFloat(rx) * 2, height: CGFloat(ry) * 2)
            let color = hueShifted(config.colors[index % config.colors.count], by: f.hue)

            ctx.fill(
                Ellipse().path(in: rect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(alpha), location: 0),
                        .init(color: .clear, location: fade),
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
    private func paintCore(in ctx: inout GraphicsContext, eff: Double, wMul: Double, hMul: Double,
                           centre: CGFloat, baseline: CGFloat) {
        let scale = config.scale
        let rx = 30 * config.coreSize * wMul * scale
        let ry = 30 * config.coreSize * hMul * scale
        let rect = CGRect(x: centre - CGFloat(rx), y: baseline - CGFloat(ry),
                          width: CGFloat(rx) * 2, height: CGFloat(ry) * 2)
        let base: Color = config.theme == .dark ? .white : .black
        let peak = config.theme == .dark ? 0.16 : 0.24

        ctx.fill(
            Ellipse().path(in: rect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: base.opacity(peak * eff), location: 0),
                    .init(color: base.opacity((config.theme == .dark ? 0.05 : 0.09) * eff), location: 0.3),
                    .init(color: .clear, location: 0.65),
                ]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: 0,
                endRadius: max(rect.width, rect.height) / 2
            )
        )
    }

    /// The rim that traces the ceiling's hump. It fades in with the bend, so
    /// at rest there is no line at all.
    private func drawBand(in ctx: inout GraphicsContext, size: CGSize, frame f: VoiceFrame,
                          baseline: CGFloat, centre: CGFloat, lit: Double,
                          hMul: Double, wMul: Double) {
        // Upstream gates the rim on the bend: flat at silence, so nothing is
        // drawn until the voice actually lifts the ceiling.
        let bendA = config.bend > 0 ? min(1, (config.bend * lit) / config.bend) : 0
        let strength = config.bandStrength * bendA * lit
        guard strength > 0.01 else { return }

        let scale = config.scale
        let halfWidth = Double(size.width) / 2 + config.bandTailOverflow
        let ceiling = VoiceGeometry.ceilingHeight * config.rangeHeight * hMul * scale * 0.5
            + config.bend * scale * lit
        let peak = min(ceiling * config.bandPosition, Double(size.height) * 0.42)
        let bellHalfWidth = max(1, VoiceGeometry.ceilingHalfWidth * config.rangeWidth
                                * config.bandWidth * 0.5 * wMul * scale)

        var path = Path()
        for i in 0...VoiceGeometry.bandSamples {
            let x = -halfWidth + (Double(i) / Double(VoiceGeometry.bandSamples)) * halfWidth * 2
            let bell = VoiceMath.bell(x / bellHalfWidth, p: config.bandCurve,
                                      sigma: config.bandSpread, skew: config.bandSkew)
            let tail = VoiceMath.tailLift(abs(x), edge: halfWidth, lift: config.bandTail * 0.35,
                                          position: config.bandTailPosition,
                                          curve: config.bandTailCurve)
            let point = CGPoint(x: centre + CGFloat(x),
                                y: baseline - CGFloat(peak * (bell + tail)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        let core = hueShifted(config.bandColors.core, by: f.hue)
        if config.bandAberration > 0 {
            let split = CGFloat(config.bandAberration * scale)
            for (color, dy) in [(config.bandColors.above, -split),
                                (config.bandColors.mid, 0),
                                (config.bandColors.below, split)] {
                ctx.stroke(path.offsetBy(dx: 0, dy: dy),
                           with: .color(hueShifted(color, by: f.hue).opacity(0.05 * strength)),
                           style: StrokeStyle(lineWidth: 1.4 * CGFloat(scale), lineCap: .round))
            }
        }
        ctx.stroke(path,
                   with: .color(core.opacity(0.10 * strength)),
                   style: StrokeStyle(lineWidth: 0.9 * CGFloat(scale), lineCap: .round))
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
