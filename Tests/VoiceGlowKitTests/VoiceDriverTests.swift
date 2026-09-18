import XCTest
@testable import VoiceGlowKit

/// Behaviour the golden vectors can't cover: how the driver composes the math
/// over time.
final class VoiceDriverTests: XCTestCase {

    private func config(_ mutate: (inout VoiceConfig) -> Void = { _ in }) -> VoiceConfig {
        var c = VoiceConfig()
        c.idle = 0          // silence means silence, so gate behaviour is readable
        c.staticColors = true
        mutate(&c)
        return c
    }

    func testSilenceStaysDark() {
        var driver = VoiceDriver()
        let c = config()
        for _ in 0..<120 { driver.advance(dt: 1.0 / 60, level: 0, bands: [0, 0, 0], config: c) }
        XCTAssertEqual(driver.frame.level, 0, accuracy: 1e-9)
    }

    func testBelowThresholdIsGated() {
        var driver = VoiceDriver()
        let c = config { $0.threshold = 0.2 }
        for _ in 0..<120 { driver.advance(dt: 1.0 / 60, level: 0.19, bands: [0, 0, 0], config: c) }
        XCTAssertEqual(driver.frame.level, 0, accuracy: 1e-9)
    }

    func testLoudInputRisesAndDecays() {
        var driver = VoiceDriver()
        let c = config()
        for _ in 0..<120 { driver.advance(dt: 1.0 / 60, level: 1, bands: [1, 1, 1], config: c) }
        let peak = driver.frame.level
        XCTAssertGreaterThan(peak, 0.8, "two seconds of full level should be near the top")

        for _ in 0..<300 { driver.advance(dt: 1.0 / 60, level: 0, bands: [0, 0, 0], config: c) }
        XCTAssertLessThan(driver.frame.level, peak * 0.05, "release should bring it back down")
    }

    func testAttackIsFasterThanRelease() {
        let c = config()
        var rising = VoiceDriver(), falling = VoiceDriver()
        for _ in 0..<30 { rising.advance(dt: 1.0 / 60, level: 1, bands: [1, 1, 1], config: c) }
        for _ in 0..<200 { falling.advance(dt: 1.0 / 60, level: 1, bands: [1, 1, 1], config: c) }
        let settled = falling.frame.level
        for _ in 0..<30 { falling.advance(dt: 1.0 / 60, level: 0, bands: [0, 0, 0], config: c) }
        XCTAssertGreaterThan(rising.frame.level / settled, 1 - falling.frame.level / settled,
                             "the glow should come up faster than it goes down")
    }

    func testLevelStaysInRange() {
        var driver = VoiceDriver()
        let c = config { $0.idle = 0.23 }
        for i in 0..<600 {
            driver.advance(dt: 1.0 / 60, level: Double(i % 7) * 0.9, bands: [2, 0.4, 3], config: c)
            XCTAssertGreaterThanOrEqual(driver.frame.level, 0)
            XCTAssertLessThanOrEqual(driver.frame.level, 1.0001)
        }
    }

    func testIdleBreathesWithoutInput() {
        var driver = VoiceDriver()
        let c = config { $0.idle = 0.3; $0.breatheDuration = 2 }
        var seen: [Double] = []
        for _ in 0..<240 {
            driver.advance(dt: 1.0 / 60, level: 0, bands: [0, 0, 0], config: c)
            seen.append(driver.frame.level)
        }
        let spread = (seen.max() ?? 0) - (seen.min() ?? 0)
        XCTAssertGreaterThan(spread, 0.01, "the idle glow should breathe")
        XCTAssertLessThanOrEqual(seen.max() ?? 0, 0.31)
    }

    func testReducedMotionStopsFlowAndBreathing() {
        var driver = VoiceDriver()
        let c = config { $0.idle = 0.3; $0.reducedMotion = true; $0.flow = 100 }
        var seen: [Double] = []
        for _ in 0..<240 {
            driver.advance(dt: 1.0 / 60, level: 0, bands: [0, 0, 0], config: c)
            seen.append(driver.frame.level)
        }
        XCTAssertEqual(driver.frame.flowOffset, 0, accuracy: 1e-9, "no drift under Reduce Motion")
        XCTAssertEqual(seen.suffix(30).max()! - seen.suffix(30).min()!, 0, accuracy: 1e-3,
                       "no breathing under Reduce Motion")
    }

    func testPausedHoldsTheFrame() {
        var driver = VoiceDriver()
        var c = config()
        for _ in 0..<60 { driver.advance(dt: 1.0 / 60, level: 1, bands: [1, 1, 1], config: c) }
        let held = driver.frame
        c.paused = true
        for _ in 0..<60 { driver.advance(dt: 1.0 / 60, level: 0, bands: [0, 0, 0], config: c) }
        XCTAssertEqual(driver.frame, held, "a paused driver should not move")
    }

    func testProcessingSweepStaysOnTheEdge() {
        var driver = VoiceDriver()
        let c = config { $0.processing = true }
        for _ in 0..<600 {
            driver.advance(dt: 1.0 / 60, level: 0, bands: [0, 0, 0], config: c)
            XCTAssertGreaterThanOrEqual(driver.frame.sweep, -1.0001)
            XCTAssertLessThanOrEqual(driver.frame.sweep, 1.0001)
        }
        XCTAssertGreaterThan(driver.frame.morph, 0.9, "processing should have fully morphed in")
    }

    func testResetReturnsToRest() {
        var driver = VoiceDriver()
        let c = config()
        for _ in 0..<60 { driver.advance(dt: 1.0 / 60, level: 1, bands: [1, 1, 1], config: c) }
        driver.reset()
        XCTAssertEqual(driver.frame, VoiceFrame())
    }

    func testLargeTimeStepsAreClamped() {
        var a = VoiceDriver(), b = VoiceDriver()
        let c = config()
        a.advance(dt: 5, level: 1, bands: [1, 1, 1], config: c)      // a tab that was backgrounded
        b.advance(dt: 0.05, level: 1, bands: [1, 1, 1], config: c)
        XCTAssertEqual(a.frame.level, b.frame.level, accuracy: 1e-9,
                       "a long gap must not jump the animation")
    }
}
