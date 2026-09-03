import Foundation

/// Automatic level control for the transmit speech path (16 kHz mono Int16,
/// applied just before LPCNet feature extraction).
///
/// RADE carries the absolute speech level end to end: whatever level reaches
/// the encoder is what the far-end FARGAN vocoder reproduces, and desktop
/// FreeDV applies no makeup gain on receive. The iOS mic runs raw in
/// `.measurement` mode (no system AGC; the hardware gain is often not even
/// settable), and a field log showed speech peaks of −26…−53 dBFS, 15–40 dB
/// below what speech codecs expect — the far end heard a near-silent voice.
///
/// Design: a per-buffer RMS envelope steers a smoothed gain toward a target
/// loudness (fast attack, slow release); a noise gate holds the gain during
/// silence so pauses are not pumped up to speech level (it never attenuates);
/// a soft limiter bounds the output so a loud talker cannot hard-clip; and a
/// manual trim lets the user offset the result. State is confined to the
/// caller's queue (txQueue).
final class TxSpeechAGC {
    /// Manual trim applied after the automatic gain (user setting, dB).
    var manualGainDb: Float = 0

    /// Loudness the automatic gain steers buffer RMS toward (−18 dBFS).
    private let targetRMS: Float = 0.126
    private let maxGain: Float = 31.6      // +30 dB
    private let minGain: Float = 0.25      // −12 dB
    /// Buffers quieter than this (−55 dBFS RMS) count as silence: gain is held.
    private let gateRMS: Float = 0.00178
    /// Soft-limiter knee (−3 dBFS); output magnitude approaches 1.0 asymptotically.
    private let kneeLevel: Float = 0.7
    private let initialGain: Float = 4.0   // +12 dB, a typical phone-mic deficit

    private let attackCoef: Float          // per sample, ≈5 ms
    private let releaseCoef: Float         // per sample, ≈400 ms
    private var gain: Float

    // Stats for the last processed buffer (linear full scale = 1.0).
    private(set) var lastInputPeak: Float = 0
    private(set) var lastInputRMS: Float = 0
    private(set) var lastOutputPeak: Float = 0
    private(set) var lastOutputRMS: Float = 0

    init(sampleRate: Float = 16000) {
        attackCoef = expf(-1 / (0.005 * sampleRate))
        releaseCoef = expf(-1 / (0.4 * sampleRate))
        gain = initialGain
    }

    /// Current automatic gain in dB (excludes the manual trim).
    var gainDb: Float { 20 * log10f(max(gain, 1e-6)) }

    /// Soft limiter: linear below the knee (−3 dBFS), then a tanh curve that
    /// approaches ±1.0 asymptotically, so no input can wrap or hard-clip.
    /// Shared with the RX makeup stage.
    static func softLimit(_ y: Float, knee: Float = 0.7) -> Float {
        let a = abs(y)
        guard a > knee else { return y }
        let limited = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
        return y < 0 ? -limited : limited
    }

    /// Start a fresh over: forget the previous talker's level.
    func reset() {
        gain = initialGain
        lastInputPeak = 0
        lastInputRMS = 0
        lastOutputPeak = 0
        lastOutputRMS = 0
    }

    func process(_ input: [Int16]) -> [Int16] {
        let n = input.count
        guard n > 0 else { return input }

        var x = [Float](repeating: 0, count: n)
        var sumSq: Float = 0
        var peak: Float = 0
        for i in 0..<n {
            let v = Float(input[i]) / 32768
            x[i] = v
            sumSq += v * v
            let a = abs(v)
            if a > peak { peak = a }
        }
        let rms = sqrtf(sumSq / Float(n))
        lastInputPeak = peak
        lastInputRMS = rms

        // Gain this buffer asks for; silence holds the current gain.
        var desired = gain
        if rms > gateRMS {
            desired = min(maxGain, max(minGain, targetRMS / rms))
        }
        let manual = powf(10, manualGainDb / 20)

        var out = [Int16](repeating: 0, count: n)
        var outSumSq: Float = 0
        var outPeak: Float = 0
        var g = gain
        for i in 0..<n {
            // Smooth toward the desired gain: fast when reducing, slow when raising.
            let coef = desired < g ? attackCoef : releaseCoef
            g = coef * g + (1 - coef) * desired
            let y = TxSpeechAGC.softLimit(x[i] * g * manual, knee: kneeLevel)
            outSumSq += y * y
            let ay = abs(y)
            if ay > outPeak { outPeak = ay }
            out[i] = Int16(max(-32768, min(32767, y * 32767)))
        }
        gain = g
        lastOutputRMS = sqrtf(outSumSq / Float(n))
        lastOutputPeak = outPeak
        return out
    }
}
