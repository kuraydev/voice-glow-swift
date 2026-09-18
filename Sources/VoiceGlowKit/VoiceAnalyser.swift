import Accelerate
import AVFoundation

/// The audio read, matched to upstream voice-glow's Web Audio setup: an
/// analyser at `fftSize` 1024 with light smoothing, RMS for the level, and a
/// three-band split of the byte spectrum. The numbers this produces are
/// asserted against golden vectors lifted from upstream — see VoiceGoldenTests.
public enum VoiceAnalyser {

    public struct Band: Sendable, Equatable {
        public let low: Double
        public let high: Double
    }

    // Voice bands in Hz: fundamentals and chest, vowels and presence, sibilance.
    public static let bands: [Band] = [
        Band(low: 80, high: 300),
        Band(low: 300, high: 2000),
        Band(low: 2000, high: 6000),
    ]

    public static let baseGain: Double = 5
    public static let bandGain: Double = 1.7
    /// 1024 bins at 48 kHz is ~47 Hz per bin: fine enough to split the voice
    /// bands, cheap enough to read every frame.
    public static let fftSize: Int = 1024
    /// The driver does its own attack/release, so the spectrum smoothing stays
    /// light — just enough to take the flicker off.
    public static let smoothingTimeConstant: Double = 0.5

    /// RMS of the time-domain window, gained the way upstream gains it.
    public static func level(timeDomain: [Float], sensitivity: Double) -> Double {
        guard !timeDomain.isEmpty else { return 0 }
        var mean: Float = 0
        vDSP_measqv(timeDomain, 1, &mean, vDSP_Length(timeDomain.count))
        return Double(sqrt(mean)) * baseGain * sensitivity
    }

    /// Average each voice band out of a 0–255 spectrum, exactly as upstream
    /// reads `getByteFrequencyData`.
    public static func bandLevels(frequencyBins: [UInt8], sampleRate: Double,
                                  fftSize: Int, sensitivity: Double) -> [Double] {
        let binHz = sampleRate / Double(fftSize)
        return bands.map { band in
            let from = max(0, Int((band.low / binHz).rounded(.down)))
            let to = min(frequencyBins.count - 1, Int((band.high / binHz).rounded(.up)))
            guard to >= from else { return 0 }
            var acc = 0.0
            for i in from...to { acc += Double(frequencyBins[i]) }
            let avg = acc / Double(to - from + 1) / 255
            return avg * bandGain * sensitivity
        }
    }
}

/// A live microphone read: AVAudioEngine tap → windowed FFT → the same level
/// and band numbers the web component works from.
///
/// The caller owns permission. On iOS add `NSMicrophoneUsageDescription`; on
/// macOS add it plus the `com.apple.security.device.audio-input` entitlement.
@MainActor
public final class VoiceMicrophone: ObservableObject {

    public enum State: Equatable, Sendable { case idle, live, denied, failed(String) }

    @Published public private(set) var state: State = .idle
    /// Latest RMS level, gained by `sensitivity`. Read by the driver each frame.
    @Published public private(set) var level: Double = 0
    /// Latest three-band split, gained by `sensitivity`.
    @Published public private(set) var bands: [Double] = [0, 0, 0]

    public var sensitivity: Double = 1

    private let engine = AVAudioEngine()
    private var fft: FFTProcessor?
    private var smoothed: [Double] = []
    private var running = false

    public init() {}

    public func start() {
        guard !running else { return }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            #endif

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                state = .failed("no input device")
                return
            }
            fft = FFTProcessor(size: VoiceAnalyser.fftSize)
            smoothed = Array(repeating: 0, count: VoiceAnalyser.fftSize / 2)

            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(VoiceAnalyser.fftSize), format: format) { [weak self] buffer, _ in
                guard let self, let channel = buffer.floatChannelData?[0] else { return }
                let frames = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
                let rate = format.sampleRate
                Task { @MainActor in self.consume(samples: samples, sampleRate: rate) }
            }

            engine.prepare()
            try engine.start()
            running = true
            state = .live
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
        bands = [0, 0, 0]
        state = .idle
    }

    private func consume(samples: [Float], sampleRate: Double) {
        guard let fft else { return }
        var window = samples
        if window.count < VoiceAnalyser.fftSize {
            window.append(contentsOf: repeatElement(0, count: VoiceAnalyser.fftSize - window.count))
        } else if window.count > VoiceAnalyser.fftSize {
            window = Array(window.suffix(VoiceAnalyser.fftSize))
        }

        level = VoiceAnalyser.level(timeDomain: window, sensitivity: sensitivity)

        // Match Web Audio: magnitudes in dB, clipped to [minDecibels, maxDecibels],
        // smoothed over time, then quantised to the 0–255 byte range the band
        // split expects.
        let magnitudes = fft.magnitudes(of: window)
        let minDb = -100.0, maxDb = -30.0
        var bytes = [UInt8](repeating: 0, count: magnitudes.count)
        for i in magnitudes.indices {
            let db = 20 * log10(max(magnitudes[i], 1e-9))
            smoothed[i] = VoiceAnalyser.smoothingTimeConstant * smoothed[i]
                + (1 - VoiceAnalyser.smoothingTimeConstant) * db
            let norm = (smoothed[i] - minDb) / (maxDb - minDb)
            bytes[i] = UInt8(max(0, min(255, norm * 255)))
        }
        bands = VoiceAnalyser.bandLevels(frequencyBins: bytes, sampleRate: sampleRate,
                                         fftSize: VoiceAnalyser.fftSize, sensitivity: sensitivity)
    }
}

/// Hann-windowed real FFT over Accelerate.
private final class FFTProcessor {
    private let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    init(size: Int) {
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: size)
        vDSP_hann_window(&w, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.window = w
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Normalised magnitude per bin, `size / 2` bins.
    func magnitudes(of samples: [Float]) -> [Double] {
        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        let half = size / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        var scale = Float(1) / Float(size)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))
        return magnitudes.map(Double.init)
    }
}
