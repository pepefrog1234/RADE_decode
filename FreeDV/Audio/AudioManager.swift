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
    
    // Published state
    @Published var isRunning = false
    @Published var syncState: RADESyncState = .searching
    @Published var snr: Float = 0
    @Published var freqOffset: Float = 0
    @Published var inputLevel: Float = -60
    @Published var outputLevel: Float = -60
    
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
    
    // Reception logging
    var receptionLogger: ReceptionLogger?
    var wavRecorder: WAVRecorder?
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
    
    // Dedicated processing queue to avoid blocking the real-time audio thread.
    // .userInitiated keeps processing near real-time for responsive sync display.
    private let processingQueue = DispatchQueue(label: "com.freedv.rade.processing",
                                                 qos: .userInitiated)
    /// Separate queue for FFT so it's not blocked by RADE neural network processing.
    private let fftQueue = DispatchQueue(label: "com.freedv.fft", qos: .default)
    /// Backpressure gate for RX processing queue to prevent unbounded task buildup.
    private let processingBackpressureLock = NSLock()
    private var pendingProcessingChunks = 0
    private let maxPendingProcessingChunks = 6
    private let maxPendingProcessingChunksInBackground = 2
    private var droppedProcessingChunks = 0
    /// Last observed modem sync status, used by background throttle policy.
    private var isModemSyncedForBackground = false
    /// Background decode base stride. Adaptive logic raises this under load.
    private let backgroundDecodeBaseStride = 1
    private var backgroundChunkCounter = 0
    
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
    
    init() {
        // Set up vDSP FFT
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        fftWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        setupAudioSession()
        setupRADECallbacks()
    }
    
    /// Configure reception logger with a SwiftData ModelContainer.
    /// Logger/context are created on processingQueue so all SwiftData access
    /// stays on the same execution context used by RX processing.
    func configureLogger(modelContainer: ModelContainer) {
        processingQueue.sync {
            guard receptionLogger == nil else { return }
            receptionLogger = ReceptionLogger(modelContainer: modelContainer)
        }
        appLog("ReceptionLogger: configured")
    }
    
    // MARK: - Background Task

    func setBackgroundDecodeOnly(_ enabled: Bool) {
        radeWrapper.speechSynthesisEnabled = !enabled
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

    func resetBackgroundHeartbeat() {
        processingQueue.sync {
            backgroundUpdateCounter = 0
            backgroundHeartbeatCount = 0
            backgroundHeartbeatLastDate = nil
            backgroundRxChunkCount = 0
            backgroundRxChunkLastDate = nil
            isModemSyncedForBackground = false
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
        let currentMode = session.mode
        
        guard newMode != currentMode else {
            bgLog("Audio mode already \(newMode.rawValue), skipping")
            return
        }
        
        bgLog("Switching audio mode from \(currentMode.rawValue) to \(newMode.rawValue)")
        
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
                .playAndRecord,
                mode: newMode,
                options: [.allowBluetooth, .defaultToSpeaker]
            )
            // Re-apply preferred audio parameters after category/mode switch.
            // iOS may inflate IO buffer duration in background, which can make
            // callback cadence too sparse for modem decoding.
            try session.setPreferredIOBufferDuration(0.04)
            try session.setPreferredSampleRate(48000)
            bgLog("Category set with mode \(newMode.rawValue), ioBuffer=\(session.ioBufferDuration), preferredSR=\(session.preferredSampleRate)")
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
        configureInputConverter(for: inputFormat)
        installInputTapIfNeeded(with: inputFormat)
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
            if self.backgroundMode {
                self.processingBackpressureLock.lock()
                let pending = self.pendingProcessingChunks
                let dropped = self.droppedProcessingChunks
                let isSynced = self.isModemSyncedForBackground
                self.processingBackpressureLock.unlock()
                let loadLevel: Int
                if pending >= 5 {
                    loadLevel = 3
                } else if pending >= 3 {
                    loadLevel = 2
                } else {
                    loadLevel = 1
                }
                bgLog("Health tick: engine=\(engineRunning) pending=\(pending) dropped=\(dropped) load=\(loadLevel) synced=\(isSynced)")
            }
            if !engineRunning {
                bgLog("Health check: engine NOT running — restarting")
                self.checkEngineHealth()
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
    
    private func setupAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [
                    .allowBluetooth,
                    .defaultToSpeaker
                ]
            )
            
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
            
            appLog("Audio session: mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate) inputGainSettable=\(session.isInputGainSettable) inputGain=\(session.inputGain)")
        } catch {
            print("Audio session setup failed: \(error)")
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
            if !self.backgroundMode {
                self.playDecodedAudio(samples: samples, count: Int(count))
            }
        }
        
        // Status updates — skip main thread dispatch in background to avoid
        // triggering SwiftUI view body re-evaluation for invisible views.
        radeWrapper.onStatusUpdate = { [weak self] status in
            guard let self = self, let status = status else { return }
            if self.backgroundMode { return }
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
            guard let callsign = callsign else { return }
            let currentSNR = self?.snr ?? 0
            let frameCount = self?.receptionLogger?.currentSession?.totalModemFrames ?? 0
            // Skip main thread dispatch in background (no one sees the UI)
            if !(self?.backgroundMode ?? false) {
                DispatchQueue.main.async {
                    self?.decodedCallsign = callsign
                }
            }
            // Record callsign event with GPS location
            let lat = self?.locationTracker.latitude
            let lon = self?.locationTracker.longitude
            self?.receptionLogger?.recordCallsign(callsign, snr: currentSNR, modemFrame: frameCount,
                                                   latitude: lat, longitude: lon)
            // Report to FreeDV Reporter (qso.freedv.org)
            self?.reporter?.reportRx(callsign: callsign, snr: Int(currentSNR))
        }
        
        // Modem frame processed — detect sync transitions and record snapshots
        radeWrapper.onModemFrameProcessed = { [weak self] snr, freqOffset, syncState, nin in
            guard let self = self else { return }
            
            let isSynced = syncState == 2
            self.processingBackpressureLock.lock()
            self.isModemSyncedForBackground = isSynced
            self.processingBackpressureLock.unlock()
            
            // Session lifecycle with grace period for brief sync drops
            if self.shouldProcess {
                if isSynced {
                    // Cancel any pending session-end timer
                    self.unsyncGraceTimer?.cancel()
                    self.unsyncGraceTimer = nil
                    
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
               isSynced,
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
        receptionLogger?.endSession()
        sessionStartTime = nil
        sessionActive = false
        unsyncGraceTimer?.cancel()
        unsyncGraceTimer = nil
        appLog("AudioManager: session finalized (sync lost for >\(unsyncGracePeriod)s)")
    }
    
    /// Begin a new reception sub-session with WAV recording.
    /// Called on processingQueue when sync is gained and no session is active.
    private func beginNewSubSession() {
        sessionActive = true
        sessionStartTime = Date()
        
        let deviceName: String
        #if os(iOS)
        deviceName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Unknown"
        #else
        deviceName = "Unknown"
        #endif
        
        receptionLogger?.beginSession(audioDevice: deviceName, sampleRate: currentSampleRate)
        
        // Record GPS location if available
        if let loc = locationTracker.currentLocation {
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
        }
    }

    private func installInputTapIfNeeded(with inputFormat: AVAudioFormat) {
        guard !isInputTapInstalled else { return }
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
        
        // Use .default mode for better background compatibility on iOS.
        // Voice processing is disabled on the input node below.
        resetDeferredFeatures()
        
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                  options: [.allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
        applyFixedInputGain()
        #endif
        
        // Disable voice processing on input to get raw wideband audio
        do {
            try inputNode.setVoiceProcessingEnabled(false)
        } catch {
            print("Failed to disable voice processing: \(error)")
        }
        
        // Create source node for decoded speech output.
        // AVAudioSourceNode uses a render callback that the OS invokes every
        // audio cycle.  This keeps the audio render graph active even when no
        // decoded speech is available (the callback simply outputs zeros),
        // which is the proper way to maintain background audio execution.
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
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: speechFormat)
        
        // Capture modem signal from mic / audio input
        // inputNode native format is typically 48 kHz with measurement mode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        appLog("Audio input format: \(inputFormat)")
        appLog("Input channels: \(inputFormat.channelCount), sampleRate: \(inputFormat.sampleRate)")
        
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
        backgroundChunkCounter = 0
        isModemSyncedForBackground = false
        processingBackpressureLock.unlock()
        installInputTapIfNeeded(with: inputFormat)
        
        do {
            try audioEngine.start()
            
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
        // Signal processingQueue to skip pending work items immediately
        shouldProcess = false
        setDeferredFeatureStorageEnabled(false)
        processingBackpressureLock.lock()
        pendingProcessingChunks = 0
        droppedProcessingChunks = 0
        backgroundChunkCounter = 0
        isModemSyncedForBackground = false
        processingBackpressureLock.unlock()
        
        // Stop health monitoring
        stopHealthCheckTimer()

        removeInputTapIfInstalled()

        audioEngine.stop()
        
        // Detach source node
        if let node = sourceNode {
            audioEngine.detach(node)
            sourceNode = nil
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
                logger?.endSession()
            }
            
            if let self = self {
                self.sessionStartTime = nil
                self.previousRxSyncInt = 0
                self.sessionActive = false
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
        guard let converter = rxConverter,
              let monoFmt = monoFloatFormat else { return }
        
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
        
        // RADE processing (may take 10-50ms per chunk due to neural network).
        // Apply queue backpressure so background does not accumulate unlimited chunks.
        var shouldEnqueue = false
        processingBackpressureLock.lock()
        var effectiveMaxPending = maxPendingProcessingChunks
        if backgroundMode {
            effectiveMaxPending = maxPendingProcessingChunksInBackground
            let isSynced = isModemSyncedForBackground
            let adaptiveStride: Int
            if isSynced {
                // Synced: prioritize continuity while still applying backpressure.
                if pendingProcessingChunks >= 2 {
                    adaptiveStride = 3
                } else if pendingProcessingChunks >= 1 {
                    adaptiveStride = 2
                } else {
                    adaptiveStride = 1
                }
            } else if pendingProcessingChunks >= 0 {
                // Unsynced/searching: aggressive throttling to protect background survival.
                if pendingProcessingChunks >= 2 {
                    adaptiveStride = 8
                } else if pendingProcessingChunks >= 1 {
                    adaptiveStride = 4
                } else {
                    adaptiveStride = 2
                }
            } else {
                adaptiveStride = backgroundDecodeBaseStride
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
            if droppedProcessingChunks % 100 == 0 {
                appLog("AudioManager: dropped \(droppedProcessingChunks) RX chunks (backpressure)")
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
                    try AVAudioSession.sharedInstance().setActive(true)
                    try audioEngine.start()
                    applyFixedInputGain()
                    appLog("Audio engine resumed successfully")
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
