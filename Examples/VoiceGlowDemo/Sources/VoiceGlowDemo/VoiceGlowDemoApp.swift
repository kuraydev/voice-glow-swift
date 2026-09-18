import SwiftUI
import VoiceGlowKit

@main
struct VoiceGlowDemoApp: App {
    var body: some Scene {
        WindowGroup("VoiceGlowKit") {
            DemoView()
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

/// A playground for the beam: drive it from the microphone or a simulated
/// level, flip presets and themes, and watch the knobs move the picture.
struct DemoView: View {
    @StateObject private var mic = VoiceMicrophone()
    @StateObject private var typing = TypingPulse()

    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var useMic = false
    @State private var simulated: Double = 0.45
    @State private var processing = false
    @State private var preset: VoiceBeamType = .standard
    @State private var theme: VoiceBeamTheme = .dark
    @State private var sensitivity: Double = 3.1
    @State private var reach: Double = 1.2
    @State private var spread: Double = 1.05
    @State private var flow: Double = 48
    @State private var bandStrength: Double = 1.55
    @State private var typingStrength: Double = 0.55
    @State private var typingDecay: Double = 0.5

    private var config: VoiceConfig {
        var c = VoiceConfig(type: preset, theme: theme)
        c.sensitivity = sensitivity
        c.reach = reach
        c.spread = spread
        c.flow = flow
        c.bandStrength = bandStrength
        return c
    }

    /// Voice, typing and the manual slider all drive the same beam — whichever
    /// is loudest wins, so you can talk and type without them fighting.
    private var level: Double {
        max(useMic ? mic.level : 0, max(typing.level, useMic ? 0 : simulated))
    }

    private var bands: [Double] {
        let voice = useMic ? mic.bands : [simulated, simulated * 0.8, simulated * 0.5]
        let keys = typing.bands
        return (0..<3).map { max($0 < voice.count ? voice[$0] : 0, $0 < keys.count ? keys[$0] : 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            Divider()
            controls
        }
        .background(theme == .dark ? Color.black : Color(white: 0.96))
        .preferredColorScheme(theme == .dark ? .dark : .light)
        .onChange(of: useMic) { _, on in
            on ? mic.start() : mic.stop()
        }
        .onChange(of: sensitivity) { _, value in
            mic.sensitivity = value
        }
        .onChange(of: typingStrength) { _, value in typing.strength = value }
        .onChange(of: typingDecay) { _, value in typing.decay = value }
        .onAppear { focused = true }
    }

    private var stage: some View {
        ZStack {
            (theme == .dark ? Color.black : Color(white: 0.96)).ignoresSafeArea()

            VoiceBeam(level: level, bands: bands, processing: processing, config: config) {
                composer
            }
            .padding(.horizontal, 60)
        }
        .frame(maxHeight: .infinity)
    }

    /// A working chat input: the beam lights from typing as well as voice.
    private var composer: some View {
        HStack(spacing: 12) {
            Button {
                useMic.toggle()
            } label: {
                Image(systemName: useMic ? "waveform.circle.fill" : "waveform")
                    .font(.title3)
                    .foregroundStyle(useMic ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)

            TextField(useMic ? statusText : "Ask anything…", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: text) { old, new in typing.type(old: old, new: new) }
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: processing ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(theme == .dark ? Color.white.opacity(0.06) : Color.white)
                .stroke(theme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
        )
        .frame(maxWidth: 560)
    }

    /// Send: flash the beam, then sit in the processing sweep for a beat.
    private func send() {
        typing.submit()
        text = ""
        processing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { processing = false }
    }

    private var statusText: String {
        switch mic.state {
        case .idle: return "Microphone idle"
        case .live: return String(format: "Listening — level %.2f", mic.level)
        case .denied: return "Microphone permission denied"
        case .failed(let message): return "Microphone failed: \(message)"
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 20) {
                    Toggle("Use microphone", isOn: $useMic)
                    Toggle("Processing", isOn: $processing)
                    Picker("Preset", selection: $preset) {
                        Text("Standard").tag(VoiceBeamType.standard)
                        Text("Pill").tag(VoiceBeamType.pill)
                        Text("Mobile").tag(VoiceBeamType.mobile)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    Picker("Theme", selection: $theme) {
                        Text("Dark").tag(VoiceBeamTheme.dark)
                        Text("Light").tag(VoiceBeamTheme.light)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                HStack(spacing: 20) {
                    Text("Typing").frame(width: 130, alignment: .leading)
                    Text("strength").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $typingStrength, in: 0...1)
                    Text("decay").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $typingDecay, in: 0.1...2)
                }
                .font(.callout)

                if !useMic {
                    slider("Simulated level", $simulated, 0...1)
                }
                slider("Sensitivity", $sensitivity, 0.5...8)
                slider("Reach", $reach, 0.2...4)
                slider("Spread", $spread, 0.2...2)
                slider("Flow", $flow, -120...120)
                slider("Band strength", $bandStrength, 0...3)
            }
            .padding(18)
        }
        .frame(height: 230)
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .font(.callout)
    }
}
