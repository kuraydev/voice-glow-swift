# VoiceGlowKit 🎙️✨

> Sound-reactive glow for SwiftUI — a centered, colorful beam along the bottom edge that rises and blooms with voice.

A SwiftUI port of [voice-glow](https://libraries.dev/voice) by
[Jakub Antalik](https://github.com/Jakubantalik). Same math, native renderer:
`Canvas`, `AVAudioEngine`, and an Accelerate FFT. Built for AI chat composers,
voice assistants, and anything that should feel like it's listening.

## ✨ Features

- 🎚️ **Real voice response** — RMS level + a three-band split (chest, vowels, sibilance), gated and envelope-followed so a shout rounds off instead of clipping
- 🌈 **Drifting palette** — lobes flow along the edge with a slow hue cycle
- 🤔 **Processing state** — the glow gathers into a beam that sweeps the edge while your model thinks
- 📐 **Three presets** — `.standard`, `.pill`, `.mobile`, each a full set of tuned geometry
- ♿️ **Reduce Motion aware** — no flow, no breathing, no sweep when the system asks
- 🔬 **Golden-tested** — the driver math is verified against vectors lifted from the upstream library

## 📦 Install

```swift
.package(url: "https://github.com/kuraydev/voice-glow-swift.git", from: "0.1.0")
```

iOS 17+ / macOS 14+.

## 🚀 Usage

```swift
import VoiceGlowKit

struct Composer: View {
    @StateObject private var mic = VoiceMicrophone()
    let thinking: Bool

    var body: some View {
        VoiceBeam(level: mic.level, bands: mic.bands, processing: thinking) {
            ChatInput()
        }
        .onAppear { mic.start() }
        .onDisappear { mic.stop() }
    }
}
```

Driving it from your own audio pipeline (a voice SDK, a remote stream)? Skip
`VoiceMicrophone` and pass a level yourself — anything roughly 0–1 works:

```swift
VoiceBeam(level: myLevel, config: VoiceConfig(type: .mobile, theme: .light))
```

## 🎛️ Configuration

Everything is a field on `VoiceConfig`. `VoiceConfig(type:theme:)` fills in a
tuned preset; change anything on top of it.

```swift
var config = VoiceConfig(type: .pill)
config.sensitivity = 4.2     // input gain
config.threshold = 0.02      // noise gate
config.attack = 0.325        // seconds up
config.release = 0.86        // seconds down
config.idle = 0.23           // how lit it sits in silence
config.flow = 60             // lobe drift, px/s
config.hueRange = 26         // degrees of hue cycle
```

## 🔒 Permissions

`VoiceMicrophone` needs the app to hold mic permission first:

- **iOS** — `NSMicrophoneUsageDescription` in `Info.plist`
- **macOS** — the same key plus the `com.apple.security.device.audio-input` entitlement

## 🧪 Verifying the port

The driver math isn't a hand transcription you have to trust — the pure
functions are lifted out of upstream's source, evaluated, and stored as golden
vectors in `Tests/VoiceGlowKitTests/Resources/voice-golden.json`:

```bash
swift test    # 21 tests: 911 golden vectors + driver behaviour
```

Change a constant and a test fails, rather than the animation quietly drifting
from the web component.

## 🤖 React Native

Same effect for Expo / React Native apps: [react-native-voice-glow](https://github.com/kuraydev/react-native-voice-glow).

## 📄 License

MIT © [kuraydev](https://github.com/kuraydev) — ported from
[voice-glow](https://github.com/Jakubantalik/Libraries.dev) (MIT © Jakub Antalik).
