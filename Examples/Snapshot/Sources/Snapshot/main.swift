import AppKit
import SwiftUI
import VoiceGlowKit

/// Renders the beam offscreen at fixed levels, so the port can be compared to
/// the web reference frame by frame instead of by eye through a screenshot.
///
/// Usage: swift run Snapshot <out-dir>

@MainActor
func snapshot(level: Double, theme: VoiceBeamTheme, type: VoiceBeamType, to url: URL) {
    var config = VoiceConfig(type: type, theme: theme)
    config.staticColors = true

    // Settle a driver at the target level, then paint that exact frame — a
    // paused view would freeze at rest and every snapshot would look alike.
    var driver = VoiceDriver()
    var settling = config
    settling.idle = 0
    for _ in 0..<600 {
        driver.advance(dt: 1.0 / 60, level: level, bands: [level, level * 0.8, level * 0.55],
                       config: settling)
    }
    let settled = driver.frame

    let view = ZStack {
        (theme == .dark ? Color.black : Color(white: 0.96))
        VoiceBeam(frame: settled, config: config) {
            HStack {
                Text("Ask anything…")
                    .foregroundStyle(theme == .dark ? .white.opacity(0.7) : .black.opacity(0.6))
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(theme == .dark ? Color.white.opacity(0.06) : Color.white)
            )
        }
        .padding(.horizontal, 40)
    }
    .frame(width: 720, height: 260)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        print("✗ could not render \(url.lastPathComponent)")
        return
    }
    try? png.write(to: url)
    print("✓ \(url.lastPathComponent)")
}

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "snapshots")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    for level in [0.0, 0.35, 0.7, 1.0] {
        let name = "swift-dark-\(Int(level * 100)).png"
        snapshot(level: level, theme: .dark, type: .standard, to: outDir.appendingPathComponent(name))
    }
    snapshot(level: 0.7, theme: .light, type: .standard, to: outDir.appendingPathComponent("swift-light-70.png"))
}
