import Foundation

/// App-wide RADE codec version selection. V2 is experimental: a different
/// waveform, incompatible with V1 stations, applied the next time RX starts.
enum RADEMode {
    static let v2Key = "radeV2Enabled"
    static var v2Enabled: Bool {
        UserDefaults.standard.bool(forKey: v2Key)   // default: V1
    }
    /// Mode string for FreeDV Reporter rx/tx reports.
    static var reporterModeString: String { v2Enabled ? "RADEV2" : "RADEV1" }
}

// MARK: - RADE Sync State

/// Sync state for the RADE receiver
enum RADESyncState: Int {
    case searching = 0
    case candidate = 1
    case synced = 2
}

// MARK: - RX Status

/// RX status report
class RADERxStatus {
    var syncState: RADESyncState = .searching
    var snr: Float = 0
    var freqOffset: Float = 0
}

// MARK: - RADEWrapper

#if targetEnvironment(simulator)

/// Simulator stub: no C library, just provides the same interface for UI preview.
class RADEWrapper {

    var onDecodedAudio: ((_ samples: UnsafePointer<Int16>?, _ count: Int32) -> Void)?
    var onStatusUpdate: ((_ status: RADERxStatus?) -> Void)?
    var onCallsignDecoded: ((_ callsign: String?) -> Void)?
    var onEooDetected: ((_ callsign: String?) -> Void)?
    var speechSynthesisEnabled = true
    var deferredFeatureStorageEnabled = false
    var rxDiagnosticLoggingEnabled = true
    var onModemFrameProcessed: ((_ snr: Float, _ freqOffset: Float, _ syncState: Int, _ nin: Int) -> Void)?

    init() {
        appLog("RADEWrapper: simulator stub initialized (no RADE C library)")
    }

    func rxProcessInputSamples(_ samples: UnsafePointer<Int16>, count: Int32) {
        // No-op on simulator
    }

    var isV2: Bool { RADEMode.v2Enabled }

    func reconfigureForSelectedVersionIfNeeded() {
        // No-op on simulator
    }

    func resetFargan() {
        // No-op on simulator
    }

    func txReset() {
        // No-op on simulator
    }

    func txProcessSpeechSamples(_ pcm16k: UnsafePointer<Int16>, count: Int32) -> [Int16]? {
        return nil
    }

    func txEndOfOver(callsign: String?) -> [Int16] {
        return []
    }

    func resetDeferredFeatures() {
        // No-op on simulator
    }

    func synthesizeDeferredFeatures(batchFrames: Int = 24) {
        // No-op on simulator
    }

    func clearInputBuffer() {
        // No-op on simulator
    }

    func getRxStatus() -> RADERxStatus {
        return RADERxStatus()
    }

    func isSynced() -> Bool {
        return false
    }
}

#else

/// Swift wrapper for the RADE C library with FARGAN vocoder (RX) and LPCNet encoder (TX).
/// Calls rade_api.h, fargan.h, and lpcnet.h C functions directly via the bridging header.
class RADEWrapper {

    /// Opaque pointer to C `struct rade`
    // Upstream rade_api.h now defines `struct rade` publicly, so the API
    // imports as a typed pointer rather than OpaquePointer.
    private var radePtr: UnsafeMutablePointer<rade>?

    /// Cached buffer sizes from C API
    private var ninMax: Int = 0
    private var nFeaturesInOut: Int = 0
    private var nEooBits: Int = 0

    /// Internal RADE buffers
    private var featuresOut: [Float] = []
    private var eooOut: [Float] = []

    /// RX input accumulation buffer
    private var rxInputBuffer: [RADE_COMP] = []

    // MARK: - FARGAN Vocoder State (RX)

    /// FARGAN vocoder state for synthesizing speech from decoded features
    private var farganState: UnsafeMutablePointer<FARGANState>?
    /// Whether FARGAN has been warmed up and is ready for synthesis
    private var farganReady = false
    /// Number of warmup frames accumulated so far
    private var warmupCount = 0
    /// Buffer for accumulating warmup feature frames (5 × NB_TOTAL_FEATURES)
    private let farganWarmupFrames = 5
    private var warmupBuffer: [Float] = []

    /// Separate queue for FARGAN synthesis to avoid blocking rade_rx
    private let farganQueue = DispatchQueue(label: "com.freedv.fargan", qos: .userInitiated)
    /// Pending feature frames waiting for FARGAN processing
    private var farganPendingFeatures: [[Float]] = []
    /// Guard against overlapping FARGAN processing
    private var farganBusy = false
    /// File-backed store for deferred feature synthesis.
    private let deferredFeatureStore = DeferredFeatureStore()
    /// Dedicated worker for EOO LDPC decode to avoid blocking the main RX loop.
    private let eooDecodeQueue = DispatchQueue(label: "com.freedv.eooDecode", qos: .utility)
    private let eooDecodeLock = NSLock()
    private var eooDecodeInFlight = false
    private struct EooDecodeResult {
        let callsign: String?
        let symbolCount: Int
    }
    private var pendingEooResults: [EooDecodeResult] = []

    // MARK: - TX (Transmit) State

    /// LPCNet encoder state for extracting speech features (TX).
    private var lpcnetEncState: OpaquePointer?
    /// CPU arch selector for LPCNet feature extraction.
    private var opusArch: Int32 = 0
    /// Accumulates 16 kHz Int16 mic samples until a 160-sample frame is ready.
    private var txPcmAccum: [Int16] = []
    /// Accumulates LPCNet feature frames until a full rade_tx() input is ready.
    private var txFeatureAccum: [Float] = []
    /// Number of feature frames consumed by one rade_tx() call.
    private var txFramesPerModemFrame = 0
    /// Scratch buffer for rade_tx() modem output.
    private var txOutBuf: [RADE_COMP] = []
    /// Scratch buffer for rade_tx_eoo() modem output.
    private var txEooBuf: [RADE_COMP] = []
    /// EOO soft-decision bits (+/-1 floats).
    private var eooBits: [Float] = []

    // Callbacks

    /// Called when decoded speech audio is available (16kHz int16 PCM)
    var onDecodedAudio: ((_ samples: UnsafePointer<Int16>?, _ count: Int32) -> Void)?
    var onStatusUpdate: ((_ status: RADERxStatus?) -> Void)?
    var onCallsignDecoded: ((_ callsign: String?) -> Void)?
    var onEooDetected: ((_ callsign: String?) -> Void)?

    /// Disable FARGAN synthesis in background to reduce CPU load.
    var speechSynthesisEnabled = true
    /// Store decoded feature frames to disk while in background.
    var deferredFeatureStorageEnabled = false
    /// Enable/disable per-frame RX diagnostic logs.
    var rxDiagnosticLoggingEnabled = true
    
    /// Called after each rade_rx() call with data for reception logging.
    /// Parameters: (snr, freqOffset, syncState, nin, hasEoo, callsign)
    var onModemFrameProcessed: ((_ snr: Float, _ freqOffset: Float, _ syncState: Int, _ nin: Int) -> Void)?

    /// True when the current context runs RADE V2 (experimental).
    private(set) var isV2 = false

    init() {
        // Initialize the RADE library
        rade_initialize()
        openContext()

        // Initialize FARGAN vocoder for RX (version-independent).
        farganState = UnsafeMutablePointer<FARGANState>.allocate(capacity: 1)
        fargan_init(farganState)
        warmupBuffer = [Float](repeating: 0,
                               count: farganWarmupFrames * Int(NB_TOTAL_FEATURES))

        // Initialize LPCNet encoder (transmit path, version-independent).
        opusArch = freedv_opus_select_arch()
        lpcnetEncState = lpcnet_encoder_create()
        if let enc = lpcnetEncState {
            lpcnet_encoder_init(enc)
        } else {
            appLog("RADEWrapper: lpcnet_encoder_create() failed — TX disabled")
        }
    }

    /// Open (or re-open) the RADE context in the version selected in settings
    /// and size every buffer from the API — V1 and V2 differ in frame sizes
    /// (V1: 432 features / 960 samples; V2: 144 / 320) and V2 has no EOO
    /// data bits.
    private func openContext() {
        // RADE_VERBOSE_0 suppresses per-frame fprintf to stderr which causes
        // significant I/O overhead on iOS and degrades real-time decoding.
        var flags: Int32 = RADE_USE_C_ENCODER | RADE_USE_C_DECODER | RADE_VERBOSE_0
        let wantV2 = RADEMode.v2Enabled
        if wantV2 { flags |= RADE_MODE_V2 }
        var modelPath = Array("built-in".utf8CString)
        radePtr = modelPath.withUnsafeMutableBufferPointer { buf -> UnsafeMutablePointer<rade>? in
            return rade_open(buf.baseAddress, flags)
        }

        guard let r = radePtr else {
            print("RADEWrapper: rade_open() failed")
            return
        }
        isV2 = wantV2

        // Cache RADE buffer sizes
        ninMax = Int(rade_nin_max(r))
        nFeaturesInOut = Int(rade_n_features_in_out(r))
        nEooBits = Int(rade_n_eoo_bits(r))

        // Allocate RADE output buffers
        featuresOut = [Float](repeating: 0, count: nFeaturesInOut)
        eooOut = [Float](repeating: 0, count: max(nEooBits, 1))

        txFramesPerModemFrame = max(1, nFeaturesInOut / Int(NB_TOTAL_FEATURES))
        txOutBuf = [RADE_COMP](repeating: RADE_COMP(real: 0, imag: 0),
                               count: max(Int(rade_n_tx_out(r)), 1))
        txEooBuf = [RADE_COMP](repeating: RADE_COMP(real: 0, imag: 0),
                               count: max(Int(rade_n_tx_eoo_out(r)), 1))
        eooBits = [Float](repeating: 0, count: max(nEooBits, 1))

        appLog("RADEWrapper: initialized RADE \(isV2 ? "V2 (EXPERIMENTAL)" : "V1"), ninMax=\(ninMax) nFeatures=\(nFeaturesInOut) txOut=\(txOutBuf.count) txEoo=\(txEooBuf.count) framesPerTx=\(txFramesPerModemFrame)")
    }

    /// Re-open the context if the settings version differs from the running
    /// one. Only call while decoding is fully stopped (no in-flight
    /// rxProcessInputSamples / tx work) — the START path does this.
    func reconfigureForSelectedVersionIfNeeded() {
        guard RADEMode.v2Enabled != isV2 else { return }
        appLog("RADEWrapper: switching to RADE \(RADEMode.v2Enabled ? "V2 (EXPERIMENTAL)" : "V1")")
        if let r = radePtr {
            rade_close(r)
            radePtr = nil
        }
        rxInputBuffer.removeAll(keepingCapacity: false)
        txPcmAccum.removeAll(keepingCapacity: false)
        txFeatureAccum.removeAll(keepingCapacity: false)
        openContext()
        resetFargan()
    }

    deinit {
        if let r = radePtr {
            rade_close(r)
        }
        rade_finalize()

        farganState?.deallocate()
        farganState = nil

        if let enc = lpcnetEncState {
            lpcnet_encoder_destroy(enc)
            lpcnetEncState = nil
        }
    }

    // MARK: - RX (Receive)

    /// Diagnostic: count rade_rx calls for periodic logging
    private var rxCallCount = 0
    /// Require stable sync before allowing expensive EOO decode work.
    private var consecutiveSyncedFrames = 0
    /// Cooldown between EOO decode attempts (in modem frames).
    private var lastEooAttemptFrame = -9999
    private let minSyncedFramesForEoo = 12         // ~1.4 seconds at ~8.3 fps
    private let minFramesBetweenEooAttempts = 16   // ~1.9 seconds

    /// Process incoming 8kHz mono int16 PCM samples for RX.
    /// Converts real samples to IQ (real part only, imag = 0), feeds to rade_rx(),
    /// then synthesizes speech via FARGAN vocoder.
    func rxProcessInputSamples(_ samples: UnsafePointer<Int16>, count: Int32) {
        guard let r = radePtr else { return }

        // Convert int16 to RADE_COMP (real = sample/32768, imag = 0)
        let sampleCount = Int(count)
        var peakSample: Float = 0
        for i in 0..<sampleCount {
            let sample = Float(samples[i]) / 32768.0
            rxInputBuffer.append(RADE_COMP(real: sample, imag: 0))
            peakSample = max(peakSample, abs(sample))
        }

        // Process as many full frames as we have
        while true {
            flushPendingEooResults()
            let nin = Int(rade_nin(r))
            guard rxInputBuffer.count >= nin else { break }

            // Call rade_rx
            var hasEoo: Int32 = 0
            let nFeatOut = rxInputBuffer.withUnsafeMutableBufferPointer { rxBuf -> Int32 in
                featuresOut.withUnsafeMutableBufferPointer { featBuf in
                    eooOut.withUnsafeMutableBufferPointer { eooBuf in
                        rade_rx(r, featBuf.baseAddress, &hasEoo,
                                eooBuf.baseAddress, rxBuf.baseAddress)
                    }
                }
            }

            // Remove consumed samples (re-check count to guard against concurrent clearInputBuffer)
            guard rxInputBuffer.count >= nin else { break }
            rxInputBuffer.removeFirst(nin)

            // Update status
            let status = RADERxStatus()
            let syncVal = rade_sync(r)
            if syncVal != 0 {
                status.syncState = .synced
                consecutiveSyncedFrames += 1
            } else {
                status.syncState = .searching
                consecutiveSyncedFrames = 0
            }
            status.snr = Float(rade_snrdB_3k_est(r))
            status.freqOffset = rade_freq_offset(r)
            onStatusUpdate?(status)

            // Fire frame-processed callback for reception logging
            onModemFrameProcessed?(status.snr, status.freqOffset, status.syncState.rawValue, nin)
            
            // Periodic diagnostic log (every ~1 second, ~8 calls at 120ms modem frames)
            rxCallCount += 1
            if rxDiagnosticLoggingEnabled && rxCallCount % 8 == 0 {
                let peakDB = 20 * log10(max(peakSample, 1e-10))
                appLog("RADE RX: sync=\(syncVal) snr=\(status.snr)dB fOff=\(String(format: "%.1f", status.freqOffset))Hz peak=\(String(format: "%.1f", peakDB))dBFS nin=\(nin) feat=\(nFeatOut) buf=\(rxInputBuffer.count)")
            }

            // Check for EOO callsign (decode asynchronously, callbacks flushed on RX queue)
            if hasEoo != 0 && nEooBits > 0 {
                let minEooSnrForDecode: Float = 6.0
                let minEooRmsForDecode: Float = 0.03
                let canAttemptDecode = status.syncState == .synced
                    && status.snr >= minEooSnrForDecode
                    && consecutiveSyncedFrames >= minSyncedFramesForEoo
                    && (rxCallCount - lastEooAttemptFrame) >= minFramesBetweenEooAttempts
                if !canAttemptDecode {
                    continue
                }
                lastEooAttemptFrame = rxCallCount

                let totalSymCount = nEooBits / 2
                let eooRms = eooOut.withUnsafeBufferPointer { eooBuf -> Float in
                    guard let base = eooBuf.baseAddress else { return 0 }
                    var sum: Float = 0
                    for i in 0..<nEooBits {
                        let v = base[i]
                        sum += v * v
                    }
                    return sqrt(sum / Float(max(nEooBits, 1)))
                }
                if eooRms < minEooRmsForDecode {
                    continue
                }

                var scheduled = false
                eooDecodeLock.lock()
                if !eooDecodeInFlight {
                    eooDecodeInFlight = true
                    scheduled = true
                }
                eooDecodeLock.unlock()
                guard scheduled else { continue }

                let symbolCopy = Array(eooOut.prefix(nEooBits))
                eooDecodeQueue.async { [weak self] in
                    guard let self = self else { return }
                    let decoded = self.decodeEooCallsign(symbols: symbolCopy, totalSymCount: totalSymCount)
                    self.eooDecodeLock.lock()
                    self.pendingEooResults.append(EooDecodeResult(callsign: decoded, symbolCount: totalSymCount))
                    self.eooDecodeInFlight = false
                    self.eooDecodeLock.unlock()
                }
            }

            // Handle decoded feature frames.
            if nFeatOut > 0 {
                let totalFeatures = Int(nFeatOut)
                // Diagnostic: catch garbage features from the decoder (NaN /
                // stuck-at-zero) — a silent-corruption canary for the V2 path.
                if rxDiagnosticLoggingEnabled && rxCallCount % 16 == 0 {
                    var nanCount = 0
                    var maxAbs: Float = 0
                    var sum: Float = 0
                    for i in 0..<totalFeatures {
                        let v = featuresOut[i]
                        if v.isNaN || v.isInfinite { nanCount += 1 }
                        else { maxAbs = max(maxAbs, abs(v)); sum += v }
                    }
                    appLog(String(format: "RADE feat stats: nan=%d maxAbs=%.3f mean=%.3f c0=%.3f pitch=%.3f",
                                  nanCount, maxAbs, sum / Float(totalFeatures),
                                  featuresOut[0], featuresOut[18]))
                }
                if deferredFeatureStorageEnabled && !speechSynthesisEnabled {
                    // Background decode-only mode: write contiguous features directly.
                    featuresOut.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return }
                        deferredFeatureStore.appendRawFloats(base, count: totalFeatures)
                    }
                } else {
                    let nFrames = totalFeatures / Int(NB_TOTAL_FEATURES)
                    var frames: [[Float]] = []
                    frames.reserveCapacity(nFrames)
                    for fi in 0..<nFrames {
                        let offset = fi * Int(NB_TOTAL_FEATURES)
                        frames.append(Array(featuresOut[offset..<offset + Int(NB_TOTAL_FEATURES)]))
                    }

                    if deferredFeatureStorageEnabled {
                        deferredFeatureStore.append(frames: frames)
                    }

                    if speechSynthesisEnabled {
                        dispatchFargan(frames: frames)
                    }
                }
            }
        }
        flushPendingEooResults()
    }

    private func decodeEooCallsign(symbols: [Float], totalSymCount: Int) -> String? {
        symbols.withUnsafeBufferPointer { eooBuf in
            guard let base = eooBuf.baseAddress else { return nil }

            let attempts: [(offset: Int, count: Int)] = [
                (0, totalSymCount),
                (0, min(totalSymCount, 56))
            ]

            for attempt in attempts {
                let floatOffset = attempt.offset * 2
                let floatCount = attempt.count * 2
                guard floatOffset + floatCount <= eooBuf.count else { continue }

                var callsignBuf = [CChar](repeating: 0, count: 16)
                let ok = callsignBuf.withUnsafeMutableBufferPointer { csBuf in
                    eoo_callsign_decode(base.advanced(by: floatOffset),
                                       Int32(attempt.count),
                                       csBuf.baseAddress,
                                       Int32(csBuf.count)) != 0
                }
                if ok {
                    return String(cString: callsignBuf)
                }
            }
            return nil
        }
    }

    private func flushPendingEooResults() {
        eooDecodeLock.lock()
        let results = pendingEooResults
        pendingEooResults.removeAll(keepingCapacity: true)
        eooDecodeLock.unlock()
        guard !results.isEmpty else { return }

        for result in results {
            if let callsign = result.callsign {
                onCallsignDecoded?(callsign)
                onEooDetected?(callsign)
            } else {
                appLog("EOO detected but callsign decode failed (symbols=\(result.symbolCount))")
                onEooDetected?(nil)
            }
        }
    }

    /// Dispatch feature frames to FARGAN queue with overload protection.
    /// Frames queue while FARGAN is busy and are only dropped past a real
    /// backlog depth. (The old "drop whenever busy" rule was invisible with
    /// V1's 12-frame/120 ms cadence but shredded V2's 4-frame/40 ms stream —
    /// any synthesis pass still running when the next block arrived threw
    /// that block away, punching 40 ms holes and tearing vocoder state.)
    private func dispatchFargan(frames: [[Float]]) {
        enqueueFargan(frames: frames, dropIfBusy: true)
    }

    private func enqueueDeferredFargan(frames: [[Float]]) {
        enqueueFargan(frames: frames, dropIfBusy: false)
    }

    /// Real-time path may buffer up to ~480 ms of synthesis backlog before
    /// dropping — enough to ride out warmup and scheduling hiccups; FARGAN
    /// runs several times faster than real time, so the backlog drains.
    private let maxPendingFarganFrames = 48
    /// Guards farganPendingFeatures + farganBusy (touched from the RX
    /// processing queue and the FARGAN queue).
    private let farganPendingLock = NSLock()

    private func enqueueFargan(frames: [[Float]], dropIfBusy: Bool) {
        guard !frames.isEmpty else { return }
        farganPendingLock.lock()
        if dropIfBusy && farganPendingFeatures.count + frames.count > maxPendingFarganFrames {
            let backlog = farganPendingFeatures.count
            farganPendingLock.unlock()
            appLog("FARGAN: dropping \(frames.count) frames (backlog \(backlog))")
            return
        }
        farganPendingFeatures.append(contentsOf: frames)
        farganPendingLock.unlock()
        runFarganQueueIfNeeded()
    }

    private func runFarganQueueIfNeeded() {
        farganPendingLock.lock()
        guard !farganBusy, !farganPendingFeatures.isEmpty else {
            farganPendingLock.unlock()
            return
        }
        farganBusy = true
        let framesToProcess = farganPendingFeatures
        farganPendingFeatures.removeAll(keepingCapacity: true)
        farganPendingLock.unlock()

        farganQueue.async { [weak self] in
            guard let self = self else { return }
            let startTime = CFAbsoluteTimeGetCurrent()

            for feat in framesToProcess {
                self.farganProcessFeatureFrame(feat)
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed > 0.1 {
                appLog("FARGAN: \(framesToProcess.count) frames took \(String(format: "%.0f", elapsed * 1000))ms")
            }
            self.farganPendingLock.lock()
            self.farganBusy = false
            self.farganPendingLock.unlock()
            self.runFarganQueueIfNeeded()
        }
    }

    /// Feed one decoded feature frame (36 floats) to FARGAN.
    /// Handles warmup buffering, then per-frame synthesis.
    private func farganProcessFeatureFrame(_ features: [Float]) {
        guard let fg = farganState else { return }

        if !farganReady {
            // Buffer warmup frames
            let offset = warmupCount * Int(NB_TOTAL_FEATURES)
            for i in 0..<Int(NB_TOTAL_FEATURES) {
                warmupBuffer[offset + i] = features[i]
            }
            warmupCount += 1

            if warmupCount >= farganWarmupFrames {
                // Pack warmup frames with NB_FEATURES stride for fargan_cont
                var packed = [Float](repeating: 0,
                                     count: farganWarmupFrames * Int(NB_FEATURES))
                for i in 0..<farganWarmupFrames {
                    let srcOffset = i * Int(NB_TOTAL_FEATURES)
                    let dstOffset = i * Int(NB_FEATURES)
                    for j in 0..<Int(NB_FEATURES) {
                        packed[dstOffset + j] = warmupBuffer[srcOffset + j]
                    }
                }

                // Prime FARGAN with zero PCM continuity and packed features
                var zeros = [Float](repeating: 0, count: Int(FARGAN_CONT_SAMPLES))
                zeros.withUnsafeMutableBufferPointer { zBuf in
                    packed.withUnsafeMutableBufferPointer { pBuf in
                        fargan_cont(fg, zBuf.baseAddress, pBuf.baseAddress)
                    }
                }
                farganReady = true
                appLog("RADEWrapper: FARGAN warmed up after \(farganWarmupFrames) frames")
            }
            return
        }

        // Normal synthesis: one frame → 160 samples at 16kHz
        var pcmOut = [Int16](repeating: 0, count: Int(FARGAN_FRAME_SIZE))
        var feat = features
        feat.withUnsafeMutableBufferPointer { featBuf in
            pcmOut.withUnsafeMutableBufferPointer { pcmBuf in
                fargan_synthesize_int(fg, pcmBuf.baseAddress, featBuf.baseAddress)
            }
        }

        // Deliver synthesized speech
        pcmOut.withUnsafeBufferPointer { buf in
            onDecodedAudio?(buf.baseAddress, Int32(FARGAN_FRAME_SIZE))
        }
    }

    /// Reset FARGAN state (e.g., on sync loss)
    func resetFargan() {
        if let fg = farganState {
            fargan_init(fg)
        }
        farganReady = false
        warmupCount = 0
    }

    /// Clear deferred feature file.
    func resetDeferredFeatures() {
        deferredFeatureStore.reset()
    }

    /// Drain deferred features from disk and enqueue for synthesis.
    func synthesizeDeferredFeatures(batchFrames: Int = 24) {
        deferredFeatureStore.drain(frameWidth: Int(NB_TOTAL_FEATURES),
                                   batchFrames: batchFrames) { [weak self] frames in
            self?.enqueueDeferredFargan(frames: frames)
        }
    }

    /// Clear accumulated RX input samples so stale data doesn't carry over between sessions.
    func clearInputBuffer() {
        rxInputBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - TX (Transmit)

    /// Reset the transmit encoder + accumulators. Call before each over.
    func txReset() {
        if let enc = lpcnetEncState { lpcnet_encoder_init(enc) }
        txPcmAccum.removeAll(keepingCapacity: true)
        txFeatureAccum.removeAll(keepingCapacity: true)
    }

    /// Feed 16 kHz mono Int16 speech samples. Returns any RADE modem samples
    /// (8 kHz Int16, real waveform) produced this call, or nil if none yet.
    func txProcessSpeechSamples(_ pcm16k: UnsafePointer<Int16>, count: Int32) -> [Int16]? {
        guard let r = radePtr, let enc = lpcnetEncState else { return nil }
        let frameSize = Int(LPCNET_FRAME_SIZE)  // 160 samples @ 16 kHz (10 ms)
        let featWidth = Int(NB_TOTAL_FEATURES)

        for i in 0..<Int(count) { txPcmAccum.append(pcm16k[i]) }

        var modemOut: [Int16] = []

        // Extract features one 160-sample frame at a time.
        while txPcmAccum.count >= frameSize {
            var features = [Float](repeating: 0, count: featWidth)
            txPcmAccum.withUnsafeBufferPointer { pcmBuf in
                _ = features.withUnsafeMutableBufferPointer { featBuf in
                    lpcnet_compute_single_frame_features(enc, pcmBuf.baseAddress, featBuf.baseAddress, opusArch)
                }
            }
            txPcmAccum.removeFirst(frameSize)
            txFeatureAccum.append(contentsOf: features)

            // Once we have enough feature frames, run one modem frame.
            let neededFloats = txFramesPerModemFrame * featWidth
            while txFeatureAccum.count >= neededFloats {
                var featIn = Array(txFeatureAccum.prefix(neededFloats))
                txFeatureAccum.removeFirst(neededFloats)
                let n = featIn.withUnsafeMutableBufferPointer { fb in
                    txOutBuf.withUnsafeMutableBufferPointer { tb in
                        rade_tx(r, tb.baseAddress, fb.baseAddress)
                    }
                }
                appendModemSamples(from: txOutBuf, count: Int(n), into: &modemOut)
            }
        }
        return modemOut.isEmpty ? nil : modemOut
    }

    /// Produce the End-Of-Over modem samples, optionally carrying a callsign.
    func txEndOfOver(callsign: String?) -> [Int16] {
        guard let r = radePtr else { return [] }
        if let callsign, !callsign.isEmpty, nEooBits > 0 {
            callsign.withCString { cs in
                eooBits.withUnsafeMutableBufferPointer { bits in
                    eoo_callsign_encode(cs, bits.baseAddress, Int32(nEooBits))
                }
            }
            eooBits.withUnsafeMutableBufferPointer { bits in
                rade_tx_set_eoo_bits(r, bits.baseAddress)
            }
        }
        let n = txEooBuf.withUnsafeMutableBufferPointer { tb in
            rade_tx_eoo(r, tb.baseAddress)
        }
        var out: [Int16] = []
        appendModemSamples(from: txEooBuf, count: Int(n), into: &out)
        return out
    }

    /// Convert RADE_COMP modem samples (real waveform) to clamped Int16.
    /// No filtering — RADE V1 must be transmitted unfiltered (per the
    /// author); the waveform goes out exactly as rade_tx produced it.
    /// Conversion mirrors the Android implementation byte-for-byte
    /// (audio_engine.cpp: clamp ±0.999, scale 32767) so the radio needs the
    /// same WLAN MOD Level setting on both platforms.
    private func appendModemSamples(from buf: [RADE_COMP], count: Int, into out: inout [Int16]) {
        guard count > 0 else { return }
        out.reserveCapacity(out.count + count)
        for i in 0..<min(count, buf.count) {
            let v = max(-0.999, min(0.999, buf[i].real)) * 32767.0
            out.append(Int16(v))
        }
    }

    // MARK: - Status

    /// Get current RX status
    func getRxStatus() -> RADERxStatus {
        let status = RADERxStatus()
        guard let r = radePtr else { return status }

        let syncVal = rade_sync(r)
        if syncVal != 0 {
            status.syncState = .synced
        } else {
            status.syncState = .searching
        }
        status.snr = Float(rade_snrdB_3k_est(r))
        status.freqOffset = rade_freq_offset(r)
        return status
    }

    /// Check if receiver is synced
    func isSynced() -> Bool {
        return getRxStatus().syncState == .synced
    }
}
#endif
