import SwiftUI
import AVFoundation
import Combine
import Accelerate
import SwiftData
import CoreLocation
#if os(iOS)
import UIKit
#endif

/// Manages AVAudioEngine for RADE RX/TX audio processing.
/// Replaces ALSA/PulseAudio/PortAudio from the desktop version.
class AudioManager: ObservableObject {
    
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode { audioEngine.inputNode }
    private var outputNode: AVAudioOutputNode { audioEngine.outputNode }
    
    private let radeWrapper = RADEWrapper()
    
    // Audio formats
    private let modemFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 8000,
        channels: 1,
        interleaved: true
    )!
    
    private let speechFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!
    
    // Mono float format at hardware sample rate (for stereo→mono downmix)
    private var monoFloatFormat: AVAudioFormat?
    
    // Converter for sample rate conversion (mono float → 8kHz int16)
    private var rxConverter: AVAudioConverter?
    
    // RX EQ compensation (iOS microphone mid-band dip compensation)
    private var rxEqSampleRate: Float = 0
    private var rxEqGainDbApplied: Float = 0
    private var rxEqB0: Float = 1
    private var rxEqB1: Float = 0
    private var rxEqB2: Float = 0
    private var rxEqA1: Float = 0
    private var rxEqA2: Float = 0
    private var rxEqZ1: Float = 0
    private var rxEqZ2: Float = 0
    
    // Published state
    @Published var isRunning = false
    @Published var syncState: RADESyncState = .searching
    @Published var snr: Float = 0
    @Published var freqOffset: Float = 0
    @Published var inputLevel: Float = -60
    @Published var outputLevel: Float = -60
    @Published var deferredDecodeInProgress = false
    @Published var deferredDecodeProgress: Double = 0
    @Published var deferredDecodeStatusText = ""
    @Published var deferredDecodePaused = false
    @Published var deferredDecodeScannedSeconds: Double = 0
    @Published var deferredDecodeETASeconds: Double = 0
    @Published var deferredDecodeSignalCount: Int = 0
    @Published var autoLowLoadModeActive = false
    
    // FFT spectrum data (dB magnitude, 512 bins covering 0-4kHz at 8kHz sample rate)
    @Published var fftData: [Float] = Array(repeating: -100, count: 512)
    
    /// When false, FFT computation is skipped to save CPU (power management)
    var fftEnabled: Bool = true
    
    /// When true, skip non-essential main thread dispatches (meter levels, etc.)
    /// Set by TransceiverViewModel when the app enters/exits background.
    var backgroundMode: Bool = false
    
    /// Called periodically from processingQueue when in background mode.
    /// Provides (syncState, snr, freqOffset) for Live Activity updates
    /// without touching the main thread.
    var onBackgroundStatusUpdate: ((_ syncState: Int, _ snr: Float, _ freqOffset: Float) -> Void)?
    
    /// Counter to throttle background status updates (~every 5 seconds)
    private var backgroundUpdateCounter = 0
    /// Background heartbeat count used for diagnostics in the UI.
    private var backgroundHeartbeatCount = 0
    /// Last background heartbeat timestamp.
    private var backgroundHeartbeatLastDate: Date?
    /// Count of RX chunks processed in background (pre-heartbeat diagnostic).
    private var backgroundRxChunkCount = 0
    /// Last RX chunk timestamp in background.
    private var backgroundRxChunkLastDate: Date?
    /// Set to true when raw samples are captured in background (deferred decode path).
    /// Reset before each background session; checked on return to foreground.
    var hadRawSampleCapture = false
    
    // Decoded callsign from EOO
    @Published var decodedCallsign: String = ""
    
    // Output volume (0.0 ~ 1.0), applied in the source node render callback
    var outputVolume: Float = 1.0
    
    // FreeDV Reporter integration
    var reporter: FreeDVReporter?
    
    // GPS tracking for reception log
    let locationTracker = LocationTracker()
    
    /// Static accessor for GPS tracking toggle (used by SettingsView)
    static var gpsTrackingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "gpsTrackingEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "gpsTrackingEnabled") }
    }
    
    /// RX EQ compensation toggle.
    static var rxEqCompensationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "rxEqCompensationEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "rxEqCompensationEnabled") }
    }
    
    /// RX EQ compensation peaking gain in dB.
    static var rxEqCompensationGainDb: Float {
        get {
            let value = UserDefaults.standard.object(forKey: "rxEqCompensationGainDb") as? Double ?? 4.5
            return Float(value)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "rxEqCompensationGainDb") }
    }
    
    /// Foreground FFT processing toggle.
    static var fftEnabledPreference: Bool {
        get { UserDefaults.standard.object(forKey: "fftEnabledPreference") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fftEnabledPreference") }
    }
    
    /// Digital preamp gain for RX input (applied before EQ/RADE).
    static var rxInputGainDb: Float {
        get {
            let value = UserDefaults.standard.object(forKey: "rxInputGainDb") as? Double ?? 0.0
            return Float(value)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "rxInputGainDb") }
    }
    
    /// Saved ID for the user's preferred speaker output device.
    static var userSpeakerOutputId: String {
        get { UserDefaults.standard.string(forKey: "userAudioOutputId") ?? "speaker" }
        set { UserDefaults.standard.set(newValue, forKey: "userAudioOutputId") }
    }
    
    /// Saved UID for the user's preferred microphone input device.
    static var userMicrophoneInputUID: String? {
        get { UserDefaults.standard.string(forKey: "userAudioInputUID") }
        set { UserDefaults.standard.set(newValue, forKey: "userAudioInputUID") }
    }
    
    // Reception logging
    var receptionLogger: ReceptionLogger?
    var wavRecorder: WAVRecorder?
    private let deferredSampleStore = DeferredSampleStore()
    private var backgroundRawSampleCaptureEnabled = false
    var isRecordingEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoRecordEnabled") as? Bool ?? true
    }
    private var sessionStartTime: Date?
    


    // MARK: - FFT State

    private let fftSize = 1024  // FFT length (produces 512 magnitude bins)
    private let fftLog2n: vDSP_Length = 10  // log2(1024)
    private var fftSetup: FFTSetup?
    private var fftAccumBuffer: [Float] = []  // accumulates float samples for FFT
    private var fftWindow: [Float] = []       // Hann window

    // Ring buffer for decoded speech output via AVAudioSourceNode.
    // Uses a fixed-size circular buffer with os_unfair_lock — safe for the
    // real-time audio render thread (no heap allocation, priority-inheriting lock).
    private let speechRing = AudioRingBuffer(capacity: 32768)  // ~2s at 16 kHz
    private var sourceNode: AVAudioSourceNode?
    
    /// Mixer node for decoded speech output to the user's selected speaker device.
    private var speakerOutputNode: AVAudioMixerNode?
    
    /// Mixer node for user microphone input (prepared for future TX support).
    private var microphoneInputNode: AVAudioMixerNode?
    
    // Dedicated processing queue to avoid blocking the real-time audio thread.
    // .userInitiated keeps processing near real-time for responsive sync display.
    private let processingQueue = DispatchQueue(label: "com.freedv.rade.processing",
                                                 qos: .userInitiated)
    // Deferred replay queue runs at lower priority to keep foreground UI responsive.
    private let deferredDecodeQueue = DispatchQueue(label: "com.freedv.rade.deferredDecode",
                                                    qos: .userInitiated)
    /// Separate queue for FFT so it's not blocked by RADE neural network processing.
    private let fftQueue = DispatchQueue(label: "com.freedv.fft", qos: .default)
    private let deferredDecodeControlLock = NSLock()
    private var deferredDecodePauseRequested = false
    private var deferredDecodeCancelRequested = false
    private var deferredDecodeActive = false
    private var deferredReplayFastMode = false
    private var deferredSessionCounter = 0  // Sessions found during deferred decode
    private let realtimeDecodeControlLock = NSLock()
    private var realtimeDecodePaused = false
    /// Backpressure gate for RX processing queue to prevent unbounded task buildup.
    private let processingBackpressureLock = NSLock()
    private var pendingProcessingChunks = 0
    private let maxPendingProcessingChunks = 6
    private let maxPendingProcessingChunksInBackground = 2
    private var droppedProcessingChunks = 0
    /// Auto low-load mode trigger for older/slower devices.
    /// When too many RX chunks are dropped, disable FFT/waterfall processing.
    private let autoLowLoadDropThreshold = 30
    private var forceFFTOffForPerformance = false
    /// Last observed modem sync status, used by background throttle policy.
    private var isModemSyncedForBackground = false
    /// Event-driven background boost window for sync acquisition.
    private var backgroundDecodeBoostUntil: Date?
    private let backgroundDecodeBoostDuration: TimeInterval = 12
    private var backgroundChunkCounter = 0
    /// Foreground acquisition boost window right after RX start.
    /// During this window we disable FFT and add temporary preamp when unsynced.
    private var acquisitionBoostUntil: Date?
    private let acquisitionBoostDuration: TimeInterval = 20
    private let acquisitionBoostGainDb: Float = 0.0
    private var lastKnownSyncState: Int = 0
    
    /// Flag to signal processingQueue to skip work during shutdown
    private var shouldProcess = false
    
    /// Track sync state for auto-splitting reception sessions
    private var previousRxSyncInt: Int = 0
    
    /// Hardware sample rate, stored for sub-session creation
    private var currentSampleRate: Int = 48000

    /// Track whether input tap is currently installed.
    private var isInputTapInstalled = false
    
    /// Grace period timer for sync loss — brief sync drops don't end the session.
    /// Real radio signals often have momentary sync drops due to fading.
    private var unsyncGraceTimer: DispatchWorkItem?
    /// How long to wait after sync loss before ending the session (seconds).
    /// Matches RADE_TUNSYNC (3s) so the modem and session lifecycle align.
    private let unsyncGracePeriod: TimeInterval = 3.0
    /// Whether a session is currently active (may persist through brief sync drops)
    private var sessionActive = false
    /// Real end time captured at first sync-loss frame (before grace delay).
    private var pendingSessionEndTime: Date?
    
    #if os(iOS)
    /// Background task identifier — buys extra time during app→background transition
    /// while the audio session is being established for background execution.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    /// Diagnostic: count processRXInput calls for one-time data logging
    private var rxInputCallCount = 0
    
    /// Throttle input level meter updates (~10 Hz instead of every audio callback)
    private var inputLevelCounter = 0
    
    /// Background health check timer — runs on a background queue,
    /// periodically checks if the audio engine is still alive and restarts if needed.
    private var healthCheckTimer: DispatchSourceTimer?
    /// RX watchdog timestamps for stale-pipeline recovery.
    private var lastRxInputCallbackDate: Date?
    private var lastModemFrameProcessedDate: Date?
    private var lastRxRecoveryDate: Date?
    private let rxInputStallThreshold: TimeInterval = 12
    private let rxFrameStallThreshold: TimeInterval = 15
    private let rxRecoveryCooldown: TimeInterval = 20
    
    init() {
        // Set up vDSP FFT
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        fftWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        setupAudioSession()
        setupRADECallbacks()
    }
    
    /// Configure reception logger with a SwiftData ModelContainer.
    /// Logger is created on main queue because SwiftData ModelContext is main-bound.
    func configureLogger(modelContainer: ModelContainer) {
        guard receptionLogger == nil else { return }
        receptionLogger = ReceptionLogger(modelContainer: modelContainer)
        appLog("ReceptionLogger: configured")
    }
    
    // MARK: - Background Task

    func setBackgroundDecodeOnly(_ enabled: Bool) {
        // In background mode, skip FARGAN synthesis to save CPU.
        // In foreground, enable synthesis so decoded audio plays through the user speaker.
        #if os(iOS)
        let shouldSynthesize = !enabled && !isForegroundRxIsolationEnabled()
        #else
        let shouldSynthesize = !enabled
        #endif
        radeWrapper.speechSynthesisEnabled = shouldSynthesize
    }

    func setBackgroundRawSampleCaptureEnabled(_ enabled: Bool) {
        backgroundRawSampleCaptureEnabled = enabled
    }

    var isFFTForcedOffForPerformance: Bool {
        processingBackpressureLock.lock()
        let forced = forceFFTOffForPerformance
        processingBackpressureLock.unlock()
        return forced
    }

    var isAcquisitionBoostActive: Bool {
        processingBackpressureLock.lock()
        let active = acquisitionBoostUntil.map { Date() < $0 } ?? false
        processingBackpressureLock.unlock()
        return active
    }

    func setDeferredFeatureStorageEnabled(_ enabled: Bool) {
        radeWrapper.deferredFeatureStorageEnabled = enabled
    }

    func resetDeferredFeatures() {
        radeWrapper.resetDeferredFeatures()
    }

    func synthesizeDeferredFeatures() {
        processingQueue.async { [weak self] in
            self?.radeWrapper.synthesizeDeferredFeatures()
        }
    }

    func resetDeferredSamples() {
        processingQueue.async { [weak self] in
            self?.deferredSampleStore.reset()
        }
    }

    /// Advance to a new batch file so new background captures don't corrupt
    /// a paused deferred decode's data.
    func advanceDeferredSampleBatch() {
        deferredSampleStore.advanceBatch()
    }

    /// Number of deferred sample batch files on disk (includes those being drained).
    var pendingDeferredBatchCount: Int {
        deferredSampleStore.pendingBatchIndices().count
    }

    /// Sample count of the most recently captured deferred batch.
    var latestDeferredBatchSampleCount: Int {
        deferredSampleStore.latestBatchSampleCount()
    }

    /// Remove the latest deferred batch file (e.g. too short to be worth decoding).
    func removeLatestDeferredBatch() {
        deferredSampleStore.removeLatestBatch()
    }

    /// Remove a specific deferred batch file by index.
    func removeDeferredBatch(at index: Int) {
        deferredSampleStore.removeBatch(at: index)
    }

    /// The batch index of the most recently written deferred sample file.
    var latestPendingBatchIndex: Int? {
        deferredSampleStore.pendingBatchIndices().last
    }

    func setDeferredDecodePaused(_ paused: Bool) {
        deferredDecodeControlLock.lock()
        guard deferredDecodeActive else {
            deferredDecodeControlLock.unlock()
            return
        }
        deferredDecodePauseRequested = paused
        deferredDecodeControlLock.unlock()
        DispatchQueue.main.async {
            self.deferredDecodePaused = paused
            if paused {
                self.deferredDecodeStatusText = "Paused"
            } else if self.deferredDecodeInProgress {
                self.deferredDecodeStatusText = "Decoding background capture..."
            }
        }
    }

    func cancelDeferredDecode() {
        deferredDecodeControlLock.lock()
        let wasActive = deferredDecodeActive
        deferredDecodeCancelRequested = true
        deferredDecodePauseRequested = false
        deferredDecodeControlLock.unlock()
        guard wasActive else { return }
        DispatchQueue.main.async {
            self.deferredDecodeInProgress = false
            self.deferredDecodePaused = false
            self.deferredDecodeStatusText = ""
            self.deferredDecodeETASeconds = 0
        }
    }

    func setRealtimeDecodePaused(_ paused: Bool) {
        realtimeDecodeControlLock.lock()
        realtimeDecodePaused = paused
        realtimeDecodeControlLock.unlock()
    }

    private func isRealtimeDecodePaused() -> Bool {
        realtimeDecodeControlLock.lock()
        let paused = realtimeDecodePaused
        realtimeDecodeControlLock.unlock()
        return paused
    }

    private func isDeferredDecodeActiveNow() -> Bool {
        deferredDecodeControlLock.lock()
        let active = deferredDecodeActive
        deferredDecodeControlLock.unlock()
        return active
    }

    func decodeDeferredSamples(chunkSamples: Int = 32000) {
        deferredDecodeQueue.async { [weak self] in
            guard let self = self else { return }
            self.deferredDecodeControlLock.lock()
            if self.deferredDecodeActive {
                // Already decoding: treat as a resume request.
                self.deferredDecodePauseRequested = false
                self.deferredDecodeControlLock.unlock()
                DispatchQueue.main.async {
                    self.deferredDecodePaused = false
                    if self.deferredDecodeInProgress {
                        self.deferredDecodeStatusText = "Decoding background capture..."
                    }
                }
                return
            }
            self.deferredDecodeActive = true
            self.deferredDecodePauseRequested = false
            self.deferredDecodeCancelRequested = false
            self.deferredDecodeControlLock.unlock()
            self.deferredSessionCounter = 0
            defer {
                self.deferredDecodeControlLock.lock()
                self.deferredDecodeActive = false
                self.deferredDecodePauseRequested = false
                self.deferredDecodeCancelRequested = false
                self.deferredDecodeControlLock.unlock()
            }

            let totalSamples = self.deferredSampleStore.totalSampleCount()
            guard totalSamples > 0 else {
                DispatchQueue.main.async {
                    self.deferredDecodeInProgress = false
                    self.deferredDecodeProgress = 0
                    self.deferredDecodeStatusText = ""
                    self.deferredDecodePaused = false
                    self.deferredDecodeScannedSeconds = 0
                    self.deferredDecodeETASeconds = 0
                }
                return
            }

            let decodeStartDate = Date()
            let previousFastMode = self.deferredReplayFastMode
            let previousRxDiag = self.radeWrapper.rxDiagnosticLoggingEnabled
            let wasRealtimePaused = self.isRealtimeDecodePaused()
            self.deferredReplayFastMode = true
            self.radeWrapper.rxDiagnosticLoggingEnabled = false
            self.setRealtimeDecodePaused(true)
            self.receptionLogger?.deferPersistence = true
            defer {
                self.deferredReplayFastMode = previousFastMode
                self.radeWrapper.rxDiagnosticLoggingEnabled = previousRxDiag
                self.setRealtimeDecodePaused(wasRealtimePaused)
            }

            @inline(__always) func waitIfPausedOrCancelled() -> Bool {
                while true {
                    self.deferredDecodeControlLock.lock()
                    let paused = self.deferredDecodePauseRequested
                    let cancelled = self.deferredDecodeCancelRequested
                    self.deferredDecodeControlLock.unlock()
                    if cancelled { return false }
                    if !paused { return true }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }

            DispatchQueue.main.async {
                self.deferredDecodeInProgress = true
                self.deferredDecodeProgress = 0
                self.deferredDecodeStatusText = "Decoding background capture..."
                self.deferredDecodePaused = false
                self.deferredDecodeScannedSeconds = 0
                self.deferredDecodeETASeconds = 0
                self.deferredDecodeSignalCount = 0
            }

            self.radeWrapper.clearInputBuffer()
            self.radeWrapper.resetFargan()

            let totalDecodeSamples = totalSamples
            var processedDecodeSamples = 0
            var lastUIUpdate = Date.distantPast
            var cancelled = false

            self.deferredSampleStore.drain(
                chunkSamples: max(chunkSamples, 16000),
                process: { samples in
                guard waitIfPausedOrCancelled() else {
                    cancelled = true
                    return
                }
                samples.withUnsafeBufferPointer { buf in
                    guard let ptr = buf.baseAddress else { return }
                    self.radeWrapper.rxProcessInputSamples(ptr, count: Int32(buf.count))
                }
                processedDecodeSamples += samples.count

                let now = Date()
                if now.timeIntervalSince(lastUIUpdate) >= 0.5 || processedDecodeSamples >= totalDecodeSamples {
                    let progress = min(1.0, Double(processedDecodeSamples) / Double(max(totalDecodeSamples, 1)))
                    let elapsed = max(now.timeIntervalSince(decodeStartDate), 0.001)
                    let rate = Double(processedDecodeSamples) / elapsed
                    let remaining = max(0, totalDecodeSamples - processedDecodeSamples)
                    let eta = rate > 0 ? Double(remaining) / rate : 0
                    let scannedSeconds = Double(processedDecodeSamples) / 8000.0
                    let liveSessionCount = self.deferredSessionCounter
                    DispatchQueue.main.async {
                        self.deferredDecodeProgress = progress
                        self.deferredDecodeScannedSeconds = scannedSeconds
                        self.deferredDecodeETASeconds = eta
                        self.deferredDecodeSignalCount = liveSessionCount
                    }
                    lastUIUpdate = now
                }
                },
                shouldContinue: {
                    self.deferredDecodeControlLock.lock()
                    let keepGoing = !self.deferredDecodeCancelRequested
                    self.deferredDecodeControlLock.unlock()
                    return keepGoing
                }
            )

            let finalSessionCount = self.deferredSessionCounter

            // Finalize any in-progress session before handling completion
            if self.sessionActive {
                self.finalizeCurrentSession()
            }

            if cancelled {
                // Discard any sessions decoded before cancellation
                self.receptionLogger?.discardDeferredSessions()
                self.receptionLogger?.deferPersistence = false
                DispatchQueue.main.async {
                    self.deferredDecodeSignalCount = finalSessionCount
                    self.deferredDecodeInProgress = false
                    self.deferredDecodePaused = false
                    self.deferredDecodeStatusText = ""
                    self.deferredDecodeETASeconds = 0
                }
                return
            }

            // Flush all deferred sessions to SwiftData now that decode is complete
            self.receptionLogger?.flushDeferredSessions()
            self.receptionLogger?.deferPersistence = false

            DispatchQueue.main.async {
                self.deferredDecodeSignalCount = finalSessionCount
                self.deferredDecodeProgress = 1.0
                self.deferredDecodeInProgress = false
                self.deferredDecodeStatusText = ""
                self.deferredDecodePaused = false
                self.deferredDecodeETASeconds = 0
            }
        }
    }

    func resetBackgroundHeartbeat() {
        processingQueue.sync {
            backgroundUpdateCounter = 0
            backgroundHeartbeatCount = 0
            backgroundHeartbeatLastDate = nil
            backgroundRxChunkCount = 0
            backgroundRxChunkLastDate = nil
            isModemSyncedForBackground = false
            backgroundDecodeBoostUntil = nil
        }
    }

    func backgroundHeartbeatSnapshot() -> (count: Int, lastDate: Date?, rxChunkCount: Int, rxChunkLastDate: Date?) {
        var count = 0
        var lastDate: Date?
        var rxChunkCount = 0
        var rxChunkLastDate: Date?
        processingQueue.sync {
            count = backgroundHeartbeatCount
            lastDate = backgroundHeartbeatLastDate
            rxChunkCount = backgroundRxChunkCount
            rxChunkLastDate = backgroundRxChunkLastDate
        }
        return (count, lastDate, rxChunkCount, rxChunkLastDate)
    }
    
    #if os(iOS)
    /// Request extra time from iOS during the background transition.
    /// This gives ~30s for the audio engine to prove it's still active,
    /// after which iOS will keep the app alive via the audio background mode.
    func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "RADEDecode-Audio") { [weak self] in
            self?.endBackgroundTask()
        }
        bgLog("Background task started (id=\(backgroundTaskID.rawValue))")
    }
    
    func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        bgLog("Background task ended (id=\(backgroundTaskID.rawValue))")
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
    
    /// Re-assert the audio session when entering background.
    /// This signals to iOS that the audio session is still actively needed.
    func reassertAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let engineRunning = audioEngine.isRunning
        bgLog("Reassert audio session: engine=\(engineRunning) category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate)")
        
        do {
            // Re-activate the session to make sure iOS knows we're still using it
            try session.setActive(true, options: [])
            bgLog("Audio session re-activated for background")
        } catch {
            appLog("Failed to re-activate audio session: \(error)")
        }
        
        // If engine stopped, restart it
        if !engineRunning && isRunning {
            do {
                try audioEngine.start()
                applyFixedInputGain()
                appLog("Audio engine restarted during background transition")
            } catch {
                appLog("Failed to restart engine: \(error)")
            }
        }
    }
    #endif
    
    /// Switch audio session mode for background/foreground transitions.
    /// `.measurement` gives raw unprocessed audio (ideal for modem decoding in foreground).
    /// `.default` is the standard mode that iOS reliably supports for background audio.
    ///
    /// The full sequence required by iOS:
    ///   stop engine → deactivate session → set new category/mode → reactivate → restart engine
    /// Just stopping the engine is NOT enough — setCategory returns '!int' if session is still active.
    func setBackgroundAudioMode(_ background: Bool) {
        let session = AVAudioSession.sharedInstance()
        let newMode: AVAudioSession.Mode = background ? .default : .measurement
        let newCategory: AVAudioSession.Category = background ? .playAndRecord : preferredSessionCategoryForCurrentState()
        let newOptions: AVAudioSession.CategoryOptions = background
            ? [.allowBluetooth, .defaultToSpeaker]
            : preferredSessionOptionsForCurrentState()
        let currentMode = session.mode
        let currentCategory = session.category
        
        guard newMode != currentMode || newCategory != currentCategory else {
            bgLog("Audio session already category=\(newCategory.rawValue) mode=\(newMode.rawValue), skipping")
            return
        }
        
        bgLog("Switching audio session from category=\(currentCategory.rawValue) mode=\(currentMode.rawValue) to category=\(newCategory.rawValue) mode=\(newMode.rawValue)")
        
        // Step 1: Stop the engine and remove input tap
        let wasRunning = audioEngine.isRunning
        if wasRunning {
            removeInputTapIfInstalled()
            audioEngine.stop()
        }
        
        // Step 2: Deactivate session — REQUIRED for iOS to accept mode change
        do {
            try session.setActive(false)
            bgLog("Session deactivated for mode switch")
        } catch {
            bgLog("Session deactivate failed: \(error) — continuing anyway")
        }
        
        // Step 3: Set new category/mode
        do {
            try session.setCategory(
                newCategory,
                mode: newMode,
                options: newOptions
            )
            // Re-apply preferred audio parameters after category/mode switch.
            // iOS may inflate IO buffer duration in background, which can make
            // callback cadence too sparse for modem decoding.
            try session.setPreferredIOBufferDuration(0.04)
            try session.setPreferredSampleRate(48000)
            bgLog("Category set \(newCategory.rawValue) mode \(newMode.rawValue), ioBuffer=\(session.ioBufferDuration), preferredSR=\(session.preferredSampleRate)")
        } catch {
            bgLog("Failed to set category: \(error)")
        }
        
        // Step 4: Reactivate session
        do {
            try session.setActive(true)
            bgLog("Session reactivated (mode=\(session.mode.rawValue))")
        } catch {
            bgLog("Session reactivate failed: \(error)")
        }
        
        // Step 5: Restart engine with reinstalled tap
        if wasRunning {
            do {
                try audioEngine.start()

                // Disable voice processing — .default mode enables echo cancellation
                // which destroys the modem signal. If this fails, continue anyway.
                do {
                    try inputNode.setVoiceProcessingEnabled(false)
                } catch {
                    bgLog("Failed to disable voice processing after mode switch: \(error)")
                }

                // Reinstall input tap with current format
                let inputFormat = inputNode.outputFormat(forBus: 0)
                bgLog("Input format after switch: \(inputFormat.sampleRate)Hz ch=\(inputFormat.channelCount)")

                guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                    bgLog("ERROR: invalid input format after mode switch — tap not reinstalled")
                    return
                }

                // Rebuild converter and input tap for potentially changed format
                configureInputConverter(for: inputFormat)
                installInputTapIfNeeded(with: inputFormat)

                if !background {
                    applyFixedInputGain()
                }
                bgLog("Engine restarted with fresh tap (mode=\(session.mode.rawValue))")
            } catch {
                bgLog("Failed to restart engine: \(error)")
            }
        }
        
    }
    
    /// Check if the audio engine is still running and restart if needed.
    /// Call this periodically or after interruptions.
    func checkEngineHealth() {
        guard isRunning else { return }

        if !audioEngine.isRunning {
            bgLog("Audio engine stalled — attempting restart")
            do {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                try audioEngine.start()
                #if os(iOS)
                applyFixedInputGain()
                #endif
                bgLog("Audio engine restarted successfully")
            } catch {
                appLog("Audio engine restart failed: \(error)")
                return
            }
        }

        // Ensure the input converter/tap are present after lifecycle transitions.
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            bgLog("WARN: invalid input format in health check (ch=\(inputFormat.channelCount) sr=\(inputFormat.sampleRate)) — skipping tap")
            return
        }
        configureInputConverter(for: inputFormat)
        installInputTapIfNeeded(with: inputFormat)
    }

    /// Recover RX pipeline when watchdog detects stale input/frame activity.
    /// This handles cases where old devices keep engine alive but input tap stops delivering.
    private func recoverRXPipelineIfNeeded(reason: String) {
        let now = Date()
        processingBackpressureLock.lock()
        if let last = lastRxRecoveryDate, now.timeIntervalSince(last) < rxRecoveryCooldown {
            processingBackpressureLock.unlock()
            return
        }
        lastRxRecoveryDate = now
        pendingProcessingChunks = 0
        processingBackpressureLock.unlock()

        appLog("RX watchdog: \(reason) — rebuilding RX pipeline")
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            appLog("RX watchdog: setActive failed: \(error)")
        }
        #endif

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                appLog("RX watchdog: engine start failed: \(error)")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            appLog("RX watchdog: invalid input format (ch=\(inputFormat.channelCount) sr=\(inputFormat.sampleRate))")
            return
        }

        removeInputTapIfInstalled()
        configureInputConverter(for: inputFormat)
        installInputTapIfNeeded(with: inputFormat)
        #if os(iOS)
        applyFixedInputGain()
        #endif
    }
    
    /// Start a periodic health check timer that runs on a background queue.
    /// Detects and recovers from audio engine stalls in the background.
    func startHealthCheckTimer() {
        stopHealthCheckTimer()
        
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + 10, repeating: 10)  // every 10 seconds
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRunning else { return }
            let engineRunning = self.audioEngine.isRunning
            let now = Date()
            self.processingBackpressureLock.lock()
            let lastInput = self.lastRxInputCallbackDate
            let lastFrame = self.lastModemFrameProcessedDate
            self.processingBackpressureLock.unlock()
            if self.backgroundMode {
                self.processingBackpressureLock.lock()
                let pending = self.pendingProcessingChunks
                let dropped = self.droppedProcessingChunks
                let isSynced = self.isModemSyncedForBackground
                let boost = self.backgroundDecodeBoostUntil.map { Date() < $0 } ?? false
                self.processingBackpressureLock.unlock()
                let loadLevel: Int
                if pending >= 5 {
                    loadLevel = 3
                } else if pending >= 3 {
                    loadLevel = 2
                } else {
                    loadLevel = 1
                }
                bgLog("Health tick: engine=\(engineRunning) pending=\(pending) dropped=\(dropped) load=\(loadLevel) synced=\(isSynced) boost=\(boost)")
            }
            if !engineRunning {
                bgLog("Health check: engine NOT running — restarting")
                self.checkEngineHealth()
            }

            if let lastInput, now.timeIntervalSince(lastInput) > self.rxInputStallThreshold {
                self.recoverRXPipelineIfNeeded(reason: "no input callback for \(Int(now.timeIntervalSince(lastInput)))s")
                return
            }

            let shouldCheckFrameStall = !self.isRealtimeDecodePaused()
                && !(self.backgroundMode && self.backgroundRawSampleCaptureEnabled)
            if shouldCheckFrameStall,
               let lastFrame,
               now.timeIntervalSince(lastFrame) > self.rxFrameStallThreshold {
                self.recoverRXPipelineIfNeeded(reason: "no modem frames for \(Int(now.timeIntervalSince(lastFrame)))s")
            }
        }
        timer.resume()
        healthCheckTimer = timer
        appLog("Health check timer started (10s interval)")
    }
    
    /// Stop the health check timer.
    func stopHealthCheckTimer() {
        healthCheckTimer?.cancel()
        healthCheckTimer = nil
    }
    
    // MARK: - Audio Session Setup
    
    #if os(iOS)
    /// Foreground modem decode prefers raw capture (`.measurement`).
    /// Background execution uses `.default` for better iOS reliability.
    private func preferredSessionModeForCurrentState() -> AVAudioSession.Mode {
        return backgroundMode ? .default : .measurement
    }
    
    private func preferredSessionCategoryForCurrentState() -> AVAudioSession.Category {
        return .playAndRecord
    }
    
    private func preferredSessionOptionsForCurrentState() -> AVAudioSession.CategoryOptions {
        return [.allowBluetooth, .defaultToSpeaker]
    }
    
    /// Foreground RX isolation mode — disabled so decoded audio plays through
    /// the user's selected speaker output device.
    private func isForegroundRxIsolationEnabled() -> Bool {
        return false
    }
    #endif
    
    private func setupAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            let mode = preferredSessionModeForCurrentState()
            let category = preferredSessionCategoryForCurrentState()
            let options = preferredSessionOptionsForCurrentState()
            try session.setCategory(category, mode: mode, options: options)
            
            // Larger buffer reduces callback frequency and CPU context switches
            // SWL receiver doesn't need ultra-low latency
            try session.setPreferredIOBufferDuration(0.04) // 40ms
            
            // Request wideband sample rate (48kHz) to preserve modem spectrum
            try session.setPreferredSampleRate(48000)
            
            try session.setActive(true)
            
            // Fix input gain to prevent AGC from distorting modem signal
            applyFixedInputGain()
            
            // Listen for audio route changes (USB audio devices, etc.)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )
            
            // Listen for audio interruptions (phone calls, alarms, etc.)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleInterruption),
                name: AVAudioSession.interruptionNotification,
                object: nil
            )
            
            // Listen for media services reset (rare but fatal if unhandled)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMediaServicesReset),
                name: AVAudioSession.mediaServicesWereResetNotification,
                object: nil
            )
            
            // Listen for audio engine configuration changes (route changes in background, etc.)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleEngineConfigChange),
                name: NSNotification.Name.AVAudioEngineConfigurationChange,
                object: audioEngine
            )
            
            appLog("Audio session: category=\(session.category.rawValue) mode=\(session.mode.rawValue) preferredCategory=\(category.rawValue) preferredMode=\(mode.rawValue) sampleRate=\(session.sampleRate) inputGainSettable=\(session.isInputGainSettable) inputGain=\(session.inputGain)")
            
            if session.category != category {
                appLog("WARN: category is \(session.category.rawValue), expected \(category.rawValue)")
            }
        } catch {
            appLog("Audio session setup failed: \(error)")
        }
        #endif
    }
    
    #if os(iOS)
    /// Set a fixed input gain to prevent iOS AGC from modulating the modem signal.
    private func applyFixedInputGain() {
        let session = AVAudioSession.sharedInstance()
        if session.isInputGainSettable {
            do {
                // Set moderate fixed gain (0.0 = min, 1.0 = max)
                try session.setInputGain(0.5)
                appLog("Input gain fixed at 0.5 (AGC bypassed)")
            } catch {
                print("Failed to set input gain: \(error)")
            }
        } else {
            appLog("Input gain not settable on this device/route")
        }
    }
    #endif
    
    // MARK: - RADE Callbacks
    
    private func setupRADECallbacks() {
        // Decode success path: always write synthesized speech to WAV log.
        // In background we skip speaker playback but keep session audio evidence.
        radeWrapper.onDecodedAudio = { [weak self] samples, count in
            guard let self = self, let samples = samples else { return }
            self.wavRecorder?.writeSamples(samples, count: Int(count))
            if !self.backgroundMode && !self.deferredReplayFastMode && !self.isForegroundRxIsolationEnabled() {
                self.playDecodedAudio(samples: samples, count: Int(count))
            }
        }
        
        // Status updates — skip main thread dispatch in background to avoid
        // triggering SwiftUI view body re-evaluation for invisible views.
        radeWrapper.onStatusUpdate = { [weak self] status in
            guard let self = self, let status = status else { return }
            if self.backgroundMode || self.deferredReplayFastMode { return }
            DispatchQueue.main.async { [weak self] in
                self?.syncState = status.syncState
                self?.snr = status.snr
                self?.freqOffset = status.freqOffset
                // Reset output meter when not synced (no decoded audio playing)
                if status.syncState != .synced {
                    self?.outputLevel = -60
                }
            }
        }
        
        // Callsign decoded from EOO frame
        radeWrapper.onCallsignDecoded = { [weak self] callsign in
            guard let self = self, let callsign = callsign else { return }
            let normalizedCallsign = callsign
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .controlCharacters)
                .joined()
                .uppercased()
            guard !normalizedCallsign.isEmpty else {
                appLog("EOO callsign decode returned empty/whitespace")
                return
            }
            if self.receptionLogger?.currentSession == nil {
                // EOO may arrive near a session boundary. Ensure we always have
                // a session container so the callsign event is persisted.
                let deviceName: String
                #if os(iOS)
                deviceName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Unknown"
                #else
                deviceName = "Unknown"
                #endif
                self.receptionLogger?.beginSession(audioDevice: deviceName, sampleRate: self.currentSampleRate)
                self.sessionActive = true
                self.sessionStartTime = Date()
                self.pendingSessionEndTime = nil
                appLog("AudioManager: created callsign-only session")
            }

            let currentSNR = self.snr
            let frameCount = self.receptionLogger?.currentSession?.totalModemFrames ?? 0
            let isDeferredReplay = self.deferredReplayFastMode
            let logMessage = String(format: "EOO callsign decoded: %@ (SNR=%.1f dB)", normalizedCallsign, currentSNR)

            if self.backgroundMode || isDeferredReplay {
                bgLog(logMessage)
            } else {
                appLog(logMessage)
            }

            // Skip main thread dispatch in background / deferred replay fast mode.
            if !self.backgroundMode && !isDeferredReplay {
                DispatchQueue.main.async {
                    self.decodedCallsign = normalizedCallsign
                }
            }
            // For deferred background replay, coordinates are unknown at capture time.
            // Persist nil so Reception Log / Map do not show misleading positions.
            let lat = isDeferredReplay ? nil : self.locationTracker.latitude
            let lon = isDeferredReplay ? nil : self.locationTracker.longitude
            self.receptionLogger?.recordCallsign(normalizedCallsign, snr: currentSNR, modemFrame: frameCount,
                                                 latitude: lat, longitude: lon)
            // Report to FreeDV Reporter (qso.freedv.org)
            if !isDeferredReplay {
                self.reporter?.reportRx(callsign: normalizedCallsign, snr: Int(currentSNR))
            }
        }

        // EOO detected regardless of callsign decode success.
        radeWrapper.onEooDetected = { [weak self] callsign in
            guard self != nil else { return }
            guard callsign != nil else {
                // Decode failure is too noisy on weak/old-device paths; do not persist
                // a pseudo callsign event ("EOO-DETECTED") to avoid false positives.
                appLog("EOO detected but unresolved; ignored for reception log")
                return
            }
        }

        // Modem frame processed — detect sync transitions and record snapshots
        radeWrapper.onModemFrameProcessed = { [weak self] snr, freqOffset, syncState, nin in
            guard let self = self else { return }
            self.processingBackpressureLock.lock()
            self.lastModemFrameProcessedDate = Date()
            self.lastKnownSyncState = syncState
            if syncState == 2 {
                self.acquisitionBoostUntil = nil
            }
            self.processingBackpressureLock.unlock()
            
            let isSynced = syncState == 2
            self.processingBackpressureLock.lock()
            self.isModemSyncedForBackground = isSynced
            if isSynced {
                self.backgroundDecodeBoostUntil = Date().addingTimeInterval(self.backgroundDecodeBoostDuration)
            } else if syncState == 1 || snr >= 4 {
                self.backgroundDecodeBoostUntil = Date().addingTimeInterval(self.backgroundDecodeBoostDuration)
            }
            self.processingBackpressureLock.unlock()
            
            // Session lifecycle with grace period for brief sync drops
            if self.shouldProcess {
                if isSynced {
                    // Cancel any pending session-end timer
                    self.unsyncGraceTimer?.cancel()
                    self.unsyncGraceTimer = nil
                    self.pendingSessionEndTime = nil
                    
                    // Start a new session if none is active
                    if !self.sessionActive {
                        if self.backgroundMode {
                            bgLog("Sync gained in background — starting session")
                        }
                        self.beginNewSubSession()
                    }
                } else if self.sessionActive && self.unsyncGraceTimer == nil {
                    // Sync lost — start grace period timer instead of ending immediately.
                    // Brief sync drops (fading, noise bursts) won't split the session.
                    self.pendingSessionEndTime = Date()
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self = self, self.shouldProcess else { return }
                        self.finalizeCurrentSession()
                    }
                    self.unsyncGraceTimer = timer
                    self.processingQueue.asyncAfter(
                        deadline: .now() + self.unsyncGracePeriod,
                        execute: timer
                    )
                }
            }
            
            // Record high-rate snapshots only in foreground.
            // In background this object stream can cause memory pressure/jetsam.
            if !self.backgroundMode,
               let logger = self.receptionLogger,
               let startTime = self.sessionStartTime {
                let now = Date()
                let offsetMs = Int64(now.timeIntervalSince(startTime) * 1000)

                let snapshot = SignalSnapshot(
                    timestamp: now,
                    offsetMs: offsetMs,
                    snr: snr,
                    freqOffset: freqOffset,
                    syncState: syncState,
                    inputLevelDb: self.inputLevel,
                    outputLevelDb: self.outputLevel,
                    nin: nin,
                    clockOffset: 0
                )
                logger.recordSnapshot(snapshot)
            }
            
            self.previousRxSyncInt = syncState
            
            // Periodic Live Activity update in background (~every 5 seconds)
            // Modem frames arrive at ~8.3 Hz, so 42 frames ≈ 5 seconds
            if self.backgroundMode {
                self.backgroundUpdateCounter += 1
                if self.backgroundUpdateCounter >= 42 {
                    self.backgroundUpdateCounter = 0
                    self.backgroundHeartbeatCount += 1
                    self.backgroundHeartbeatLastDate = Date()
                    self.onBackgroundStatusUpdate?(syncState, snr, freqOffset)
                }
            }
        }
    }
    
    // MARK: - Session Auto-Split
    
    /// End the current reception session and persist to SwiftData.
    /// Called on processingQueue after grace period expires.
    private func finalizeCurrentSession() {
        guard sessionActive else { return }
        if let recorder = wavRecorder {
            let fileSize = recorder.stop()
            receptionLogger?.currentSession?.audioFileSize = fileSize
            wavRecorder = nil
        }
        receptionLogger?.endSession(endTime: pendingSessionEndTime)
        sessionStartTime = nil
        sessionActive = false
        pendingSessionEndTime = nil
        unsyncGraceTimer?.cancel()
        unsyncGraceTimer = nil
        appLog("AudioManager: session finalized (sync lost for >\(unsyncGracePeriod)s)")
    }
    
    /// Begin a new reception sub-session with WAV recording.
    /// Called on processingQueue when sync is gained and no session is active.
    private func beginNewSubSession() {
        sessionActive = true
        sessionStartTime = Date()
        pendingSessionEndTime = nil
        if deferredReplayFastMode { deferredSessionCounter += 1 }
        
        let deviceName: String
        #if os(iOS)
        deviceName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Unknown"
        #else
        deviceName = "Unknown"
        #endif
        
        receptionLogger?.beginSession(audioDevice: deviceName, sampleRate: currentSampleRate)
        
        // Record GPS location if available (skip during deferred replay — location is unknown)
        if !deferredReplayFastMode, let loc = locationTracker.currentLocation {
            receptionLogger?.currentSession?.startLatitude = loc.coordinate.latitude
            receptionLogger?.currentSession?.startLongitude = loc.coordinate.longitude
            receptionLogger?.currentSession?.startAltitude = loc.altitude
        }
        
        // Start WAV recording for this session
        if isRecordingEnabled {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let filename = "rade_rx_\(formatter.string(from: Date())).wav"
            wavRecorder = WAVRecorder()
            try? wavRecorder?.start(filename: filename)
            receptionLogger?.currentSession?.audioFilename = filename
        }
        
        appLog("AudioManager: new sub-session started (sync gained)")
    }
    
    // MARK: - RX (Receive Mode)

    private func configureInputConverter(for inputFormat: AVAudioFormat) {
        if let monoFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: true
        ) {
            monoFloatFormat = monoFmt
            rxConverter = AVAudioConverter(from: monoFmt, to: modemFormat)
            updateRxEqCoefficients(sampleRate: Float(inputFormat.sampleRate))
        }
    }
    
    /// Build a peaking EQ biquad targeting the common mid-band dip on phone mics.
    private func updateRxEqCoefficients(sampleRate fs: Float) {
        guard fs > 1000 else { return }
        rxEqSampleRate = fs
        
        let centerHz: Float = 1600
        let q: Float = 1.15
        let gainDb = Self.rxEqCompensationGainDb
        rxEqGainDbApplied = gainDb
        let a = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * centerHz / fs
        let cosW0 = cosf(w0)
        let sinW0 = sinf(w0)
        let alpha = sinW0 / (2 * q)
        
        let b0 = 1 + alpha * a
        let b1 = -2 * cosW0
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosW0
        let a2 = 1 - alpha / a
        
        guard abs(a0) > 1e-9 else { return }
        rxEqB0 = b0 / a0
        rxEqB1 = b1 / a0
        rxEqB2 = b2 / a0
        rxEqA1 = a1 / a0
        rxEqA2 = a2 / a0
        rxEqZ1 = 0
        rxEqZ2 = 0
    }
    
    private func applyRxEqCompensation(to monoData: UnsafeMutablePointer<Float>, count: Int, sampleRate: Float) {
        if rxEqSampleRate != sampleRate || abs(rxEqGainDbApplied - Self.rxEqCompensationGainDb) > 0.001 {
            updateRxEqCoefficients(sampleRate: sampleRate)
        }
        guard Self.rxEqCompensationEnabled else { return }
        
        var z1 = rxEqZ1
        var z2 = rxEqZ2
        let b0 = rxEqB0
        let b1 = rxEqB1
        let b2 = rxEqB2
        let a1 = rxEqA1
        let a2 = rxEqA2
        
        for i in 0..<count {
            let x = monoData[i]
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            monoData[i] = y
        }
        
        rxEqZ1 = z1
        rxEqZ2 = z2
    }
    
    private func applyRxInputGain(to monoData: UnsafeMutablePointer<Float>, count: Int) {
        let baseGainDb = Self.rxInputGainDb
        var boostGainDb: Float = 0
        processingBackpressureLock.lock()
        let boostActive = acquisitionBoostUntil.map { Date() < $0 } ?? false
        if boostActive && lastKnownSyncState != 2 && acquisitionBoostGainDb > 0 {
            boostGainDb = acquisitionBoostGainDb
        }
        processingBackpressureLock.unlock()
        let gainDb = baseGainDb + boostGainDb
        if abs(gainDb) < 0.001 { return }
        let gain = powf(10, gainDb / 20)
        for i in 0..<count {
            let y = monoData[i] * gain
            monoData[i] = max(-1.0, min(1.0, y))
        }
    }

    private func installInputTapIfNeeded(with inputFormat: AVAudioFormat) {
        guard !isInputTapInstalled else { return }

        // Validate format — inputNode.outputFormat can return 0 channels / 0 Hz
        // when the audio session isn't fully ready or the route changed.
        // installTap throws an unrecoverable NSException if the format is invalid.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            appLog("ERROR: invalid input format (ch=\(inputFormat.channelCount) sr=\(inputFormat.sampleRate)) — skipping tap install")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 960,
                            format: inputFormat) { [weak self] buffer, _ in
            self?.processRXInput(buffer: buffer)
        }
        isInputTapInstalled = true
    }

    private func removeInputTapIfInstalled() {
        guard isInputTapInstalled else { return }
        inputNode.removeTap(onBus: 0)
        isInputTapInstalled = false
    }
    
    func startRX() {
        guard !isRunning else { return }
        
        // Foreground: .measurement for raw modem capture.
        // Background: .default for better iOS background stability.
        resetDeferredFeatures()
        
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let mode = preferredSessionModeForCurrentState()
        let category = preferredSessionCategoryForCurrentState()
        let options = preferredSessionOptionsForCurrentState()
        do {
            try session.setCategory(category, mode: mode, options: options)
        } catch {
            appLog("WARN: setCategory failed: \(error) — retrying without bluetooth")
            try? session.setCategory(category, mode: mode, options: [.defaultToSpeaker])
        }
        do {
            try session.setActive(true)
        } catch {
            appLog("WARN: setActive failed: \(error)")
        }
        if session.category != category {
            appLog("WARN: audio session category is \(session.category.rawValue), expected \(category.rawValue) — forcing")
            try? session.setCategory(category, mode: mode, options: [.defaultToSpeaker])
            try? session.setActive(true)
        }
        if session.mode != mode {
            appLog("WARN: audio session mode is \(session.mode.rawValue), expected \(mode.rawValue)")
        }
        applyFixedInputGain()
        #endif
        
        // Disable voice processing on input to get raw wideband audio
        do {
            try inputNode.setVoiceProcessingEnabled(false)
        } catch {
            print("Failed to disable voice processing: \(error)")
        }
        
        // Source node feeds decoded speech through speakerOutputNode to the user's
        // selected speaker. Ring buffer bridges the processing queue → render thread.
        speechRing.reset()
        let ring = speechRing  // capture the reference, not self
        let node = AVAudioSourceNode(format: speechFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            let vol = self?.outputVolume ?? 1.0
            
            for buf in ablPointer {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                // read() zeros any unfilled portion automatically
                let read = ring.read(into: data, count: frames)
                // Apply volume to the samples that were actually read
                if read > 0 && vol != 1.0 {
                    for i in 0..<read {
                        data[i] *= vol
                    }
                }
                // Unfilled portion is already zeroed by ring.read() — silence is fine
                // because background execution is maintained by location + audio modes.
            }
            
            return noErr
        }
        sourceNode = node
        let speakerMixer = AVAudioMixerNode()
        speakerOutputNode = speakerMixer
        let micMixer = AVAudioMixerNode()
        microphoneInputNode = micMixer
        
        audioEngine.attach(node)
        audioEngine.attach(speakerMixer)
        audioEngine.attach(micMixer)
        audioEngine.connect(node, to: speakerMixer, format: speechFormat)
        audioEngine.connect(speakerMixer, to: audioEngine.mainMixerNode, format: speechFormat)
        // microphoneInputNode is attached but not connected (prepared for future TX)
        
        // Capture modem signal from mic / audio input
        // inputNode native format is typically 48 kHz with measurement mode
        var inputFormat = inputNode.outputFormat(forBus: 0)
        appLog("Audio input format: \(inputFormat)")
        appLog("Input channels: \(inputFormat.channelCount), sampleRate: \(inputFormat.sampleRate)")
        
        // Guard against invalid format — can happen when audio route changes or
        // session isn't fully ready. Re-activate and retry once.
        if inputFormat.channelCount == 0 || inputFormat.sampleRate == 0 {
            appLog("WARN: invalid input format — re-activating session and retrying")
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            inputFormat = inputNode.outputFormat(forBus: 0)
            appLog("Retry input format: ch=\(inputFormat.channelCount) sr=\(inputFormat.sampleRate)")
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                appLog("ERROR: input format still invalid after retry — cannot start RX")
                return
            }
        }
        
        // Set up RX sample rate converter from mono float → 8kHz int16
        // This avoids a complex multi-step conversion (stereo→mono + 48kHz→8kHz + float→int16)
        configureInputConverter(for: inputFormat)
        if let monoFmt = monoFloatFormat {
            appLog("RX converter: mono \(monoFmt.sampleRate)Hz Float32 → \(modemFormat.sampleRate)Hz Int16")
        }

        shouldProcess = true
        processingBackpressureLock.lock()
        pendingProcessingChunks = 0
        droppedProcessingChunks = 0
        lastRxInputCallbackDate = Date()
        lastModemFrameProcessedDate = Date()
        lastRxRecoveryDate = nil
        acquisitionBoostUntil = Date().addingTimeInterval(acquisitionBoostDuration)
        lastKnownSyncState = 0
        forceFFTOffForPerformance = false
        backgroundChunkCounter = 0
        isModemSyncedForBackground = false
        backgroundDecodeBoostUntil = nil
        processingBackpressureLock.unlock()
        appLog("RX acquisition boost enabled for \(Int(acquisitionBoostDuration))s (FFT paused)")
        DispatchQueue.main.async {
            self.autoLowLoadModeActive = false
        }
        deferredSampleStore.reset()
        installInputTapIfNeeded(with: inputFormat)
        
        do {
            try audioEngine.start()
            
            // Apply user speaker output preference, then re-apply the transceiver
            // input because overrideOutputAudioPort(.speaker) also changes input
            // to built-in mic.  Re-setting preferredInput restores the transceiver
            // input when the two devices are compatible with the route.
            if AudioManager.userSpeakerOutputId == "speaker" {
                try? session.overrideOutputAudioPort(.speaker)
                if let preferred = session.preferredInput {
                    try? session.setPreferredInput(preferred)
                    appLog("User speaker → Built-in Speaker, re-applied transceiver input: \(preferred.portName)")
                } else {
                    appLog("User speaker → Built-in Speaker")
                }
            }
            
            // Start background health check to detect and recover from engine stalls
            startHealthCheckTimer()
            
            // Store sample rate for sub-session creation and reset sync tracker
            currentSampleRate = Int(inputFormat.sampleRate)
            previousRxSyncInt = 0
            sessionActive = false
            
            // Start GPS tracking for reception log
            locationTracker.startTracking()
            
            // Session and WAV recording are now started automatically
            // when sync is gained (see beginNewSubSession)
            
            DispatchQueue.main.async {
                self.isRunning = true
            }
        } catch {
            print("Failed to start audio engine for RX: \(error)")
        }
    }
    
    func stop() {
        let keepDeferredReplayRunning = isDeferredDecodeActiveNow()
        if !keepDeferredReplayRunning {
            cancelDeferredDecode()
        }
        // Signal processingQueue to skip pending work items immediately
        shouldProcess = keepDeferredReplayRunning
        setDeferredFeatureStorageEnabled(false)
        backgroundRawSampleCaptureEnabled = false
        processingBackpressureLock.lock()
        pendingProcessingChunks = 0
        droppedProcessingChunks = 0
        lastRxInputCallbackDate = nil
        lastModemFrameProcessedDate = nil
        lastRxRecoveryDate = nil
        acquisitionBoostUntil = nil
        lastKnownSyncState = 0
        forceFFTOffForPerformance = false
        backgroundChunkCounter = 0
        isModemSyncedForBackground = false
        backgroundDecodeBoostUntil = nil
        processingBackpressureLock.unlock()
        DispatchQueue.main.async {
            self.autoLowLoadModeActive = false
        }
        if !keepDeferredReplayRunning {
            deferredSampleStore.reset()
            // Ensure deferred replay work has observed cancellation before teardown.
            // Without this, STOP can race with foreground replay and hit RADE state conflicts.
            deferredDecodeQueue.sync {}
        }
        
        // Stop health monitoring
        stopHealthCheckTimer()

        removeInputTapIfInstalled()

        audioEngine.stop()
        
        // Detach source and user audio nodes
        if let node = sourceNode {
            audioEngine.detach(node)
            sourceNode = nil
        }
        if let node = speakerOutputNode {
            audioEngine.detach(node)
            speakerOutputNode = nil
        }
        if let node = microphoneInputNode {
            audioEngine.detach(node)
            microphoneInputNode = nil
        }
        
        // Clear speech ring buffer
        speechRing.reset()
        
        // Drain processing queue and finalize session on background to avoid blocking main thread
        let logger = receptionLogger
        let tracker = locationTracker
        let wrapper = radeWrapper
        
        // Cancel any pending grace timer
        unsyncGraceTimer?.cancel()
        unsyncGraceTimer = nil
        
        processingQueue.async { [weak self] in
            if keepDeferredReplayRunning {
                // Keep deferred replay path alive; only stop real-time RX side.
                tracker.stopTracking()
                return
            }
            // Clear RADE internal buffers so stale data doesn't carry over
            wrapper.clearInputBuffer()
            wrapper.resetFargan()
            
            // Finalize any active session (safety net — may already be ended by sync-loss auto-split)
            if logger?.currentSession != nil {
                if let self = self, let recorder = self.wavRecorder {
                    let fileSize = recorder.stop()
                    logger?.currentSession?.audioFileSize = fileSize
                    self.wavRecorder = nil
                }
                logger?.endSession(endTime: self?.pendingSessionEndTime)
            }
            
            if let self = self {
                self.sessionStartTime = nil
                self.previousRxSyncInt = 0
                self.sessionActive = false
                self.pendingSessionEndTime = nil
            }
            tracker.stopTracking()
        }
        
        // Reset meter levels immediately on main thread
        DispatchQueue.main.async {
            self.isRunning = false
            self.outputLevel = -60
            self.inputLevel = -60
            self.syncState = .searching
            self.snr = 0
            self.freqOffset = 0
        }
    }
    
    // MARK: - RX Processing
    
    private func processRXInput(buffer: AVAudioPCMBuffer) {
        processingBackpressureLock.lock()
        lastRxInputCallbackDate = Date()
        processingBackpressureLock.unlock()

        guard let converter = rxConverter,
              let monoFmt = monoFloatFormat else { return }
        
        // Background raw capture must run even when real-time decode is paused
        // (e.g. during a deferred foreground replay). Without this, going to
        // background while a replay is paused would capture nothing.
        let needsRawCapture = backgroundMode && backgroundRawSampleCaptureEnabled
        
        // During deferred foreground replay, pause real-time decode work entirely.
        // But still allow conversion when background raw capture is needed.
        if isRealtimeDecodePaused() && !needsRawCapture {
            return
        }
        
        // Step 1: Extract mono from input (handles both mono and stereo)
        let inputFrames = Int(buffer.frameLength)
        guard inputFrames > 0 else { return }
        
        guard let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFmt,
            frameCapacity: AVAudioFrameCount(inputFrames)
        ) else { return }
        monoBuffer.frameLength = AVAudioFrameCount(inputFrames)
        
        guard let monoData = monoBuffer.floatChannelData?[0] else { return }
        
        if buffer.format.channelCount >= 2, let floatData = buffer.floatChannelData {
            // Stereo input: use channel 0 only (left/primary)
            // Averaging both channels can degrade signal if ch1 is inverted or unused
            let ch0 = floatData[0]
            memcpy(monoData, ch0, inputFrames * MemoryLayout<Float>.size)
        } else if let floatData = buffer.floatChannelData {
            // Mono float input: copy directly
            memcpy(monoData, floatData[0], inputFrames * MemoryLayout<Float>.size)
        } else {
            return
        }
        
        applyRxInputGain(to: monoData, count: inputFrames)
        applyRxEqCompensation(to: monoData, count: inputFrames, sampleRate: Float(buffer.format.sampleRate))
        
        // Diagnostic: log a few samples from mono buffer on first call
        rxInputCallCount += 1
        if rxInputCallCount == 10 {
            var peakMono: Float = 0
            for i in 0..<min(inputFrames, 4800) {
                peakMono = max(peakMono, abs(monoData[i]))
            }
            let s0 = inputFrames > 0 ? monoData[0] : 0
            let s1 = inputFrames > 1 ? monoData[1] : 0
            let s2 = inputFrames > 2 ? monoData[2] : 0
            appLog("Mono extract: frames=\(inputFrames) peak=\(String(format: "%.4f", peakMono)) samples=[\(String(format: "%.4f", s0)), \(String(format: "%.4f", s1)), \(String(format: "%.4f", s2))]")
        }
        
        // Step 2: Convert mono float at hardware rate → 8kHz int16
        let frameCount = AVAudioFrameCount(
            Double(inputFrames) * 8000.0 / buffer.format.sampleRate
        )
        guard frameCount > 0 else { return }
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: modemFormat,
            frameCapacity: frameCount
        ) else { return }
        
        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return monoBuffer
        }
        
        guard status != .error, error == nil else {
            appLog("RX conversion error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        
        let convertedCount = Int(convertedBuffer.frameLength)
        guard convertedCount > 0, let channelData = convertedBuffer.int16ChannelData else {
            return
        }
        
        // Diagnostic: log converted 8kHz samples on first call
        if rxInputCallCount == 10 {
            let s = channelData[0]
            var peak16: Int16 = 0
            for i in 0..<convertedCount {
                let av = abs(s[i])
                if av > peak16 { peak16 = av }
            }
            let s0 = convertedCount > 0 ? s[0] : 0
            let s1 = convertedCount > 1 ? s[1] : 0
            let s2 = convertedCount > 2 ? s[2] : 0
            appLog("8kHz convert: frames=\(convertedCount) peak=\(peak16) samples=[\(s0), \(s1), \(s2)]")
        }
        
        // Calculate input level for meter (throttled to ~10 Hz)
        // Skip in background — no one can see the meters
        let samples = channelData[0]
        if !backgroundMode {
            inputLevelCounter += 1
            if inputLevelCounter >= 5 {
                inputLevelCounter = 0
                var sum: Float = 0
                for i in 0..<convertedCount {
                    let sample = Float(samples[i]) / 32768.0
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(max(convertedCount, 1)))
                let db = 20 * log10(max(rms, 1e-10))
                DispatchQueue.main.async {
                    self.inputLevel = db
                }
            }
        }

        // Background low-load mode: store raw modem-band samples and defer decode.
        if needsRawCapture {
            hadRawSampleCapture = true
            deferredSampleStore.appendRawInt16(samples, count: convertedCount)
            return
        }
        
        // After raw capture check, enforce the real-time pause.
        if isRealtimeDecodePaused() {
            return
        }
        
        // RADE processing (may take 10-50ms per chunk due to neural network).
        // Apply queue backpressure so background does not accumulate unlimited chunks.
        var shouldEnqueue = false
        processingBackpressureLock.lock()
        var effectiveMaxPending = maxPendingProcessingChunks
        if backgroundMode {
            effectiveMaxPending = maxPendingProcessingChunksInBackground
            let isSynced = isModemSyncedForBackground
            let isBoostActive: Bool
            if let until = backgroundDecodeBoostUntil {
                isBoostActive = Date() < until
            } else {
                isBoostActive = false
            }
            let adaptiveStride: Int
            if !isSynced && isBoostActive {
                // Event-driven acquisition boost (candidate / elevated SNR seen).
                if pendingProcessingChunks >= 2 {
                    adaptiveStride = 2
                } else {
                    adaptiveStride = 1
                }
            } else if isSynced {
                // Synced: prioritize continuity while still applying backpressure.
                if pendingProcessingChunks >= 2 {
                    adaptiveStride = 3
                } else if pendingProcessingChunks >= 1 {
                    adaptiveStride = 2
                } else {
                    adaptiveStride = 1
                }
            } else {
                // Unsynced/searching: aggressive throttling to protect background survival.
                if pendingProcessingChunks >= 2 {
                    adaptiveStride = 8
                } else if pendingProcessingChunks >= 1 {
                    adaptiveStride = 4
                } else {
                    adaptiveStride = 2
                }
            }
            backgroundChunkCounter += 1
            if backgroundChunkCounter % adaptiveStride != 0 {
                processingBackpressureLock.unlock()
                return
            }
        }
        if pendingProcessingChunks < effectiveMaxPending {
            pendingProcessingChunks += 1
            shouldEnqueue = true
        } else {
            droppedProcessingChunks += 1
            let shouldEnableAutoLowLoad = !forceFFTOffForPerformance
                && droppedProcessingChunks >= autoLowLoadDropThreshold
                && !backgroundMode
            if shouldEnableAutoLowLoad {
                forceFFTOffForPerformance = true
                fftEnabled = false
            }
            if droppedProcessingChunks % 100 == 0 {
                appLog("AudioManager: dropped \(droppedProcessingChunks) RX chunks (backpressure)")
            }
            if shouldEnableAutoLowLoad {
                appLog("AudioManager: auto low-load mode enabled (FFT/waterfall disabled due to RX backpressure)")
                DispatchQueue.main.async {
                    self.autoLowLoadModeActive = true
                }
            }
        }
        processingBackpressureLock.unlock()

        guard shouldEnqueue else { return }

        // Copy samples off the audio thread only after queue admission succeeds.
        let samplesCopy = Array(UnsafeBufferPointer(start: samples, count: convertedCount))

        processingQueue.async { [self] in
            defer {
                processingBackpressureLock.lock()
                pendingProcessingChunks = max(0, pendingProcessingChunks - 1)
                processingBackpressureLock.unlock()
            }
            guard shouldProcess else { return }
            guard !isRealtimeDecodePaused() else { return }
            if backgroundMode {
                backgroundRxChunkCount += 1
                backgroundRxChunkLastDate = Date()
            }
            samplesCopy.withUnsafeBufferPointer { buf in
                guard let ptr = buf.baseAddress else { return }
                radeWrapper.rxProcessInputSamples(ptr, count: Int32(convertedCount))
            }
        }
        
        // FFT on a separate queue so it's not blocked by RADE
        if fftEnabled {
            fftQueue.async { [weak self] in
                guard let self = self else { return }
                samplesCopy.withUnsafeBufferPointer { buf in
                    guard let ptr = buf.baseAddress else { return }
                    self.accumulateForFFT(samples: ptr, count: convertedCount)
                }
            }
        }
    }
    
    // MARK: - Audio Output
    
    /// Enqueue decoded speech into the ring buffer for the source node to consume.
    private func playDecodedAudio(samples: UnsafePointer<Int16>, count: Int) {
        // Convert int16 → float and push into ring buffer
        var floats = [Float](repeating: 0, count: count)
        for i in 0..<count {
            floats[i] = Float(samples[i]) / 32768.0
        }
        
        // Calculate output level for meter (skip in background)
        if !backgroundMode {
            var sum: Float = 0
            for i in 0..<count {
                sum += floats[i] * floats[i]
            }
            let rms = sqrt(sum / Float(max(count, 1)))
            let db = 20 * log10(max(rms, 1e-10))
            DispatchQueue.main.async {
                self.outputLevel = db
            }
        }
        
        floats.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            speechRing.write(ptr, count: count)
        }
    }
    
    // MARK: - FFT Spectrum

    /// Accumulate 8kHz int16 samples and compute FFT when we have enough.
    private func accumulateForFFT(samples: UnsafePointer<Int16>, count: Int) {
        // Convert int16 to float and append to accumulation buffer
        for i in 0..<count {
            fftAccumBuffer.append(Float(samples[i]) / 32768.0)
        }

        // Compute FFT when we have at least fftSize samples
        while fftAccumBuffer.count >= fftSize {
            computeFFT(Array(fftAccumBuffer.prefix(fftSize)))
            // No overlap — saves ~50% FFT CPU
            guard fftAccumBuffer.count >= fftSize else { break }
            fftAccumBuffer.removeFirst(fftSize)
        }
    }

    /// Compute power spectrum from fftSize float samples using vDSP.
    private func computeFFT(_ samples: [Float]) {
        guard let setup = fftSetup else { return }

        var windowed = [Float](repeating: 0, count: fftSize)
        // Apply Hann window
        vDSP_vmul(samples, 1, fftWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack into split complex format
        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!)

                // Convert real input to split complex
                windowed.withUnsafeBufferPointer { inputBuf in
                    inputBuf.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: halfN
                    ) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                // Forward FFT
                vDSP_fft_zrip(setup, &splitComplex, 1, fftLog2n, FFTDirection(FFT_FORWARD))

                // Compute magnitude squared
                var magnitudes = [Float](repeating: 0, count: halfN)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))

                // Normalize magnitude squared by N for practical display levels.
                var scale: Float = 1.0 / Float(fftSize)
                vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))

                // Convert to dB (10*log10 for power).
                // Use 1.0 as reference so 0 dB = full-scale sine.
                var ref: Float = 1.0
                vDSP_vdbcon(magnitudes, 1, &ref, &magnitudes, 1, vDSP_Length(halfN), 1)

                // Publish to main thread
                DispatchQueue.main.async { [magnitudes] in
                    self.fftData = magnitudes
                }
            }
        }
    }

    // MARK: - Audio Route
    
    #if os(iOS)
    @objc private func handleRouteChange(notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }
        
        let session = AVAudioSession.sharedInstance()
        let currentInput = session.currentRoute.inputs.first
        let currentOutput = session.currentRoute.outputs.first
        appLog("Route change: reason=\(reason.rawValue) input=\(currentInput?.portName ?? "none")(\(currentInput?.portType.rawValue ?? "")) output=\(currentOutput?.portName ?? "none") sampleRate=\(session.sampleRate)")
        
        switch reason {
        case .newDeviceAvailable:
            // Re-apply fixed gain for new audio device
            applyFixedInputGain()
            // Re-disable voice processing
            if isRunning {
                do {
                    try inputNode.setVoiceProcessingEnabled(false)
                } catch {
                    print("Failed to re-disable voice processing: \(error)")
                }
            }
        case .oldDeviceUnavailable:
            appLog("Audio device disconnected")
        default:
            break
        }
    }
    // MARK: - Audio Interruption (phone calls, alarms, etc.)
    
    @objc private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        
        switch type {
        case .began:
            bgLog("Audio interruption began (phone call, alarm, etc.)")
            // iOS pauses our audio engine automatically; just log it
            
        case .ended:
            bgLog("Audio interruption ended")
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            if options.contains(.shouldResume) && isRunning {
                appLog("Resuming audio engine after interruption")
                do {
                    let session = AVAudioSession.sharedInstance()
                    let mode = preferredSessionModeForCurrentState()
                    let category = preferredSessionCategoryForCurrentState()
                    let options = preferredSessionOptionsForCurrentState()
                    try session.setCategory(category, mode: mode, options: options)
                    try session.setActive(true)
                    try audioEngine.start()
                    applyFixedInputGain()
                    appLog("Audio engine resumed successfully (category=\(session.category.rawValue) mode=\(session.mode.rawValue))")
                } catch {
                    appLog("Failed to resume audio engine: \(error)")
                }
            }
            
        @unknown default:
            break
        }
    }
    // MARK: - Media Services Reset
    
    @objc private func handleMediaServicesReset(notification: Notification) {
        bgLog("Media services were reset — rebuilding audio engine")
        // Media services reset destroys all audio objects.
        // We need to stop and restart RX from scratch.
        if isRunning {
            stop()
            // Brief delay to let the system stabilize, then restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startRX()
            }
        }
    }
    
    @objc private func handleEngineConfigChange(notification: Notification) {
        bgLog("Audio engine configuration changed — restarting engine")
        // The audio graph has been reconfigured (e.g. route change).
        // The engine is stopped by the system; we need to restart it.
        if isRunning && !audioEngine.isRunning {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try audioEngine.start()
                applyFixedInputGain()
                appLog("Audio engine restarted after config change")
            } catch {
                appLog("Failed to restart engine after config change: \(error)")
            }
        }
    }
    #endif
}
