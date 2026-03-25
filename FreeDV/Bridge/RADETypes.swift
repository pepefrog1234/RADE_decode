import Foundation

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
    var speechSynthesisEnabled = true
    var deferredFeatureStorageEnabled = false
    var onModemFrameProcessed: ((_ snr: Float, _ freqOffset: Float, _ syncState: Int, _ nin: Int) -> Void)?

    init() {
        appLog("RADEWrapper: simulator stub initialized (no RADE C library)")
    }

    func rxProcessInputSamples(_ samples: UnsafePointer<Int16>, count: Int32) {
        // No-op on simulator
    }

    func resetFargan() {
        // No-op on simulator
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
    private var radePtr: OpaquePointer?

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

    // Callbacks

    /// Called when decoded speech audio is available (16kHz int16 PCM)
    var onDecodedAudio: ((_ samples: UnsafePointer<Int16>?, _ count: Int32) -> Void)?
    var onStatusUpdate: ((_ status: RADERxStatus?) -> Void)?
    var onCallsignDecoded: ((_ callsign: String?) -> Void)?

    /// Disable FARGAN synthesis in background to reduce CPU load.
    var speechSynthesisEnabled = true
    /// Store decoded feature frames to disk while in background.
    var deferredFeatureStorageEnabled = false
    
    /// Called after each rade_rx() call with data for reception logging.
    /// Parameters: (snr, freqOffset, syncState, nin, hasEoo, callsign)
    var onModemFrameProcessed: ((_ snr: Float, _ freqOffset: Float, _ syncState: Int, _ nin: Int) -> Void)?

    init() {
        // Initialize the RADE library
        rade_initialize()

        // Open RADE context with C encoder and decoder, quiet mode
        let flags: Int32 = RADE_USE_C_ENCODER | RADE_USE_C_DECODER | RADE_VERBOSE_0
        var modelPath = Array("built-in".utf8CString)
        radePtr = modelPath.withUnsafeMutableBufferPointer { buf -> OpaquePointer? in
            return rade_open(buf.baseAddress, flags)
        }

        guard let r = radePtr else {
            print("RADEWrapper: rade_open() failed")
            return
        }

        // Cache RADE buffer sizes
        ninMax = Int(rade_nin_max(r))
        nFeaturesInOut = Int(rade_n_features_in_out(r))
        nEooBits = Int(rade_n_eoo_bits(r))

        // Allocate RADE output buffers
        featuresOut = [Float](repeating: 0, count: nFeaturesInOut)
        eooOut = [Float](repeating: 0, count: max(nEooBits, 1))

        // Initialize FARGAN vocoder for RX
        farganState = UnsafeMutablePointer<FARGANState>.allocate(capacity: 1)
        fargan_init(farganState)
        warmupBuffer = [Float](repeating: 0,
                               count: farganWarmupFrames * Int(NB_TOTAL_FEATURES))

        appLog("RADEWrapper: initialized, ninMax=\(ninMax) nFeatures=\(nFeaturesInOut)")
    }

    deinit {
        if let r = radePtr {
            rade_close(r)
        }
        rade_finalize()

        farganState?.deallocate()
        farganState = nil
    }

    // MARK: - RX (Receive)

    /// Diagnostic: count rade_rx calls for periodic logging
    private var rxCallCount = 0

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

            // Remove consumed samples
            rxInputBuffer.removeFirst(nin)

            // Update status
            let status = RADERxStatus()
            let syncVal = rade_sync(r)
            if syncVal != 0 {
                status.syncState = .synced
            } else {
                status.syncState = .searching
            }
            status.snr = Float(rade_snrdB_3k_est(r))
            status.freqOffset = rade_freq_offset(r)
            onStatusUpdate?(status)

            // Fire frame-processed callback for reception logging
            onModemFrameProcessed?(status.snr, status.freqOffset, status.syncState.rawValue, nin)
            
            // Periodic diagnostic log (every ~1 second, ~8 calls at 120ms modem frames)
            rxCallCount += 1
            if rxCallCount % 8 == 0 {
                let peakDB = 20 * log10(max(peakSample, 1e-10))
                appLog("RADE RX: sync=\(syncVal) snr=\(status.snr)dB fOff=\(String(format: "%.1f", status.freqOffset))Hz peak=\(String(format: "%.1f", peakDB))dBFS nin=\(nin) feat=\(nFeatOut) buf=\(rxInputBuffer.count)")
            }

            // Check for EOO callsign
            if hasEoo != 0 && nEooBits > 0 {
                var callsignBuf = [CChar](repeating: 0, count: 16)
                let symCount = nEooBits / 2
                let decoded = eooOut.withUnsafeBufferPointer { eooBuf -> Bool in
                    callsignBuf.withUnsafeMutableBufferPointer { csBuf in
                        eoo_callsign_decode(eooBuf.baseAddress, Int32(symCount),
                                           csBuf.baseAddress, Int32(csBuf.count)) != 0
                    }
                }
                if decoded {
                    let callsign = String(cString: callsignBuf)
                    onCallsignDecoded?(callsign)
                }
            }

            // Handle decoded feature frames.
            if nFeatOut > 0 {
                let totalFeatures = Int(nFeatOut)
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
    }

    /// Dispatch feature frames to FARGAN queue with overload protection.
    /// If FARGAN is still busy processing, drop new frames to prevent freeze.
    private func dispatchFargan(frames: [[Float]]) {
        enqueueFargan(frames: frames, dropIfBusy: true)
    }

    private func enqueueDeferredFargan(frames: [[Float]]) {
        enqueueFargan(frames: frames, dropIfBusy: false)
    }

    private func enqueueFargan(frames: [[Float]], dropIfBusy: Bool) {
        guard !frames.isEmpty else { return }
        if dropIfBusy && farganBusy {
            appLog("FARGAN: dropping \(frames.count) frames (overloaded)")
            return
        }
        farganPendingFeatures.append(contentsOf: frames)
        runFarganQueueIfNeeded()
    }

    private func runFarganQueueIfNeeded() {
        guard !farganBusy, !farganPendingFeatures.isEmpty else { return }

        farganBusy = true
        let framesToProcess = farganPendingFeatures
        farganPendingFeatures.removeAll(keepingCapacity: true)

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
            self.farganBusy = false
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

