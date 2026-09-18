import XCTest
@testable import VoiceGlowKit

/// Asserts this port reproduces upstream voice-glow's math exactly.
///
/// The vectors in `voice-golden.json` are not hand-written: they are produced
/// by lifting the pure functions out of upstream's `voiceDriver.ts` and
/// evaluating them (see spec/extract-golden.mjs in voice-glow-ports). A
/// mistyped constant here fails a test instead of shipping as a subtly wrong
/// animation.
final class VoiceGoldenTests: XCTestCase {

    private struct Golden: Decodable {
        struct Source: Decodable { let name: String; let version: String }
        struct Constants: Decodable {
            let BASE_GAIN: Double
            let BAND_GAIN: Double
            let BANDS: [[Double]]
            let fftSize: Int
            let smoothingTimeConstant: Double
            let sampleRate: Double
        }
        struct AnalyserCase: Decodable { let sensitivity: Double; let level: Double; let bands: [Double] }
        struct Analyser: Decodable { let cases: [AnalyserCase] }
        let sourceLibrary: Source
        let tolerance: Double
        let constants: Constants
        let vectors: [String: [[Double]]]
        let analyser: Analyser
    }

    private static let golden: Golden = {
        guard let url = Bundle.module.url(forResource: "voice-golden", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Golden.self, from: data)
        else { fatalError("voice-golden.json missing from the test bundle") }
        return decoded
    }()

    private var tol: Double { Self.golden.tolerance }

    private func vectors(_ name: String) throws -> [[Double]] {
        let v = try XCTUnwrap(Self.golden.vectors[name], "no golden vectors for \(name)")
        XCTAssertFalse(v.isEmpty, "\(name) vector set is empty")
        return v
    }

    func testGoldenMatchesUpstreamVersion() {
        XCTAssertEqual(Self.golden.sourceLibrary.name, "voice-glow")
        XCTAssertFalse(Self.golden.sourceLibrary.version.isEmpty)
    }

    func testShape() throws {
        for v in try vectors("shape") {
            XCTAssertEqual(VoiceMath.shape(v[1], threshold: v[0]), v[2], accuracy: tol,
                           "shape(raw: \(v[1]), threshold: \(v[0]))")
        }
    }

    func testFollow() throws {
        for v in try vectors("follow") {
            let out = VoiceMath.follow(v[3], target: v[4], dt: v[2], attack: v[0], release: v[1])
            XCTAssertEqual(out, v[5], accuracy: tol,
                           "follow(prev: \(v[3]), target: \(v[4]), dt: \(v[2]))")
        }
    }

    func testBell() throws {
        for v in try vectors("bell") {
            XCTAssertEqual(VoiceMath.bell(v[3], p: v[0], sigma: v[1], skew: v[2]), v[4], accuracy: tol,
                           "bell(t: \(v[3]), p: \(v[0]), sigma: \(v[1]), skew: \(v[2]))")
        }
    }

    func testTailLift() throws {
        for v in try vectors("tailLift") {
            let out = VoiceMath.tailLift(v[4], edge: v[3], lift: v[0], position: v[1], curve: v[2])
            XCTAssertEqual(out, v[5], accuracy: tol, "tailLift(dist: \(v[4]), edge: \(v[3]))")
        }
    }

    func testEdgeEnvelope() throws {
        for v in try vectors("edgeEnvelope") {
            XCTAssertEqual(VoiceMath.edgeEnvelope(v[1], span: v[0]), v[2], accuracy: tol,
                           "edgeEnvelope(x: \(v[1]), span: \(v[0]))")
        }
    }

    func testWrapX() throws {
        for v in try vectors("wrapX") {
            XCTAssertEqual(VoiceMath.wrapX(v[1], span: v[0]), v[2], accuracy: tol,
                           "wrapX(x: \(v[1]), span: \(v[0]))")
        }
    }

    func testPingPong() throws {
        for v in try vectors("pingPong") {
            XCTAssertEqual(VoiceMath.pingPong(v[0]), v[1], accuracy: tol, "pingPong(\(v[0]))")
        }
    }

    /// The analyser constants must match upstream, or every level this port
    /// produces is scaled differently from the web component.
    func testAnalyserConstants() {
        let c = Self.golden.constants
        XCTAssertEqual(VoiceAnalyser.baseGain, c.BASE_GAIN, accuracy: tol)
        XCTAssertEqual(VoiceAnalyser.bandGain, c.BAND_GAIN, accuracy: tol)
        XCTAssertEqual(VoiceAnalyser.fftSize, c.fftSize)
        XCTAssertEqual(VoiceAnalyser.smoothingTimeConstant, c.smoothingTimeConstant, accuracy: tol)
        XCTAssertEqual(VoiceAnalyser.bands.count, c.BANDS.count)
        for (i, band) in VoiceAnalyser.bands.enumerated() {
            XCTAssertEqual(band.low, c.BANDS[i][0], accuracy: tol)
            XCTAssertEqual(band.high, c.BANDS[i][1], accuracy: tol)
        }
    }

    /// Feed the same synthetic buffers the extractor used and expect upstream's
    /// level and band numbers back.
    func testAnalyserLevelAndBands() throws {
        let c = Self.golden.constants
        var time = [Float](repeating: 0, count: c.fftSize)
        for i in 0..<time.count {
            let t = Double(i)
            time[i] = Float(0.35 * sin(2 * .pi * 220 * t / c.sampleRate)
                          + 0.18 * sin(2 * .pi * 1800 * t / c.sampleRate)
                          + 0.05 * sin(t * 12.9898))
        }
        var freq = [UInt8](repeating: 0, count: c.fftSize / 2)
        for i in 0..<freq.count { freq[i] = UInt8((i * 37 + 11) % 256) }

        for expected in Self.golden.analyser.cases {
            let level = VoiceAnalyser.level(timeDomain: time, sensitivity: expected.sensitivity)
            XCTAssertEqual(level, expected.level, accuracy: 1e-6,
                           "level at sensitivity \(expected.sensitivity)")

            let bands = VoiceAnalyser.bandLevels(frequencyBins: freq,
                                                 sampleRate: c.sampleRate,
                                                 fftSize: c.fftSize,
                                                 sensitivity: expected.sensitivity)
            for (i, value) in bands.enumerated() {
                XCTAssertEqual(value, expected.bands[i], accuracy: 1e-6,
                               "band \(i) at sensitivity \(expected.sensitivity)")
            }
        }
    }
}
