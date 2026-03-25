import SwiftUI
import Combine
import SwiftData

/// ViewModel managing RX state, bridging AudioManager to SwiftUI views.
@MainActor
class TransceiverViewModel: ObservableObject {
    
    private let audioManager = AudioManager()
    private let deviceManager = AudioDeviceManager()
    let liveActivity = LiveActivityManager()
    
    /// FreeDV Reporter integration — set from the view layer.
    var reporter: FreeDVReporter? {
        didSet { audioManager.reporter = reporter }
    }
    
    /// Power management — controls UI update rate and FFT/waterfall.
    var powerManager: PowerManager? {
        didSet {
            guard let pm = powerManager else { return }
            if !isInBackground {
                audioManager.fftEnabled = pm.fftEnabled
            }
            restartStatusTimer(interval: isInBackground ? backgroundTimerInterval : pm.uiUpdateInterval)
        }
    }
    
    /// Whether the app is currently in the background
    private var isInBackground = false
    /// Slow timer interval for background (only needed for Live Activity updates)
    private let backgroundTimerInterval: TimeInterval = 2.0
    
    // MARK: - Published State
    
    @Published var isRunning = false
    @Published var syncState: RADESyncState = .searching
    @Published var snr: Float = 0
    @Published var freqOffset: Float = 0
    @Published var inputLevel: Float = -60
    @Published var outputLevel: Float = -60
    
    // FFT data for spectrum display
    @Published var fftData: [Float] = Array(repeating: -100, count: 512)
    @Published var waterfallHistory: [[Float]] = []
    
    // Device info
    @Published var currentInputDevice: String = "Unknown"
    @Published var currentOutputDevice: String = "Unknown"
    
    // Callsign
    @Published var decodedCallsign: String = ""
    
    // Output volume (0.0 ~ 1.0)
    @Published var outputVolume: Float = 1.0 {
        didSet {
            audioManager.outputVolume = outputVolume
        }
    }
    
    // Recording state
    @Published var isRecording = false

    // Background decode health indicator
    @Published var backgroundHealthText: String = ""
    @Published var backgroundHealthIsHealthy: Bool = false
    
    private var statusTimer: Timer?
    private let maxWaterfallRows = 100
    private var currentTimerInterval: TimeInterval = 0.15
    /// Prevent Task accumulation — skip tick if previous Task is still running
    private var isProcessingTick = false

    private var backgroundObservers: [Any] = []
    private var backgroundEnterTime: Date?
    
    init() {
        setupBindings()
        observeAppLifecycle()
    }
    
    /// Configure the reception logger with a ModelContainer.
    /// Call this once from the view when the environment provides the container.
    func configureLogger(modelContainer: ModelContainer) {
        audioManager.configureLogger(modelContainer: modelContainer)
    }

    // MARK: - Bindings

    /// Track previous sync state for haptic edge detection
    private var previousSyncState: RADESyncState = .searching
    /// Track previous callsign for haptic on new decode
    private var previousCallsign: String = ""
    /// Throttle strong signal haptics (at most once per 10 seconds)
    private var lastStrongSignalHaptic: Date = .distantPast

    
    private func setupBindings() {
        // Pre-warm haptic engines
        HapticManager.shared.prepare()
        
        // Observe AudioManager state changes
        statusTimer = Timer.scheduledTimer(withTimeInterval: currentTimerInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.isProcessingTick else { return }
            self.isProcessingTick = true
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                defer { self.isProcessingTick = false }
                
                // Update isRunning FIRST so haptic/live activity checks see current state
                let amIsRunning = self.audioManager.isRunning
                self.isRunning = amIsRunning
                
                let newSyncState = self.audioManager.syncState
                let newSNR = self.audioManager.snr
                
                // Haptic feedback + Live Activity on sync state transitions
                if amIsRunning && newSyncState != self.previousSyncState {
                    if newSyncState == .synced && self.previousSyncState != .synced {
                        HapticManager.shared.onSync()
                    } else if newSyncState == .searching && self.previousSyncState == .synced {
                        HapticManager.shared.onUnsync()
                    }
                    self.previousSyncState = newSyncState
                    // Update Live Activity on sync transitions
                    self.liveActivity.updateActivity(
                        syncState: newSyncState.rawValue,
                        snr: newSNR,
                        freqOffsetHz: self.audioManager.freqOffset,
                        lastCallsign: ""
                    )
                }
                
                // Skip haptics and heavy UI updates when in background
                if !self.isInBackground {
                    // Haptic feedback on strong signal (SNR > 20 dB, throttled)
                    if amIsRunning && newSyncState == .synced && newSNR > 20 {
                        let now = Date()
                        if now.timeIntervalSince(self.lastStrongSignalHaptic) > 10 {
                            HapticManager.shared.onStrongSignal()
                            self.lastStrongSignalHaptic = now
                        }
                    }
                }
                
                self.syncState = newSyncState
                self.snr = newSNR
                self.freqOffset = self.audioManager.freqOffset
                self.inputLevel = self.audioManager.inputLevel
                self.outputLevel = self.audioManager.outputLevel

                // Skip FFT/waterfall updates in background (saves CPU + memory)
                if !self.isInBackground {
                    let newFFT = self.audioManager.fftData
                    if newFFT != self.fftData {
                        self.fftData = newFFT
                        self.waterfallHistory.append(newFFT)
                        if self.waterfallHistory.count > self.maxWaterfallRows {
                            self.waterfallHistory.removeFirst(
                                self.waterfallHistory.count - self.maxWaterfallRows)
                        }
                    }
                    
                    self.currentInputDevice = self.deviceManager.currentInputName
                    self.currentOutputDevice = self.deviceManager.currentOutputName
                }
                self.isRecording = self.audioManager.wavRecorder != nil
                
                // Update decoded callsign from EOO + haptic on new callsign
                let newCallsign = self.audioManager.decodedCallsign
                if !newCallsign.isEmpty && newCallsign != self.decodedCallsign {
                    self.decodedCallsign = newCallsign
                    if newCallsign != self.previousCallsign {
                        HapticManager.shared.onCallsign()
                        self.previousCallsign = newCallsign
                        // Update Live Activity with new callsign
                        self.liveActivity.updateActivity(
                            syncState: newSyncState.rawValue,
                            snr: newSNR,
                            freqOffsetHz: self.audioManager.freqOffset,
                            lastCallsign: newCallsign
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    
    func toggleRunning() {
        if isRunning {
            stopTransceiver()
        } else {
            startTransceiver()
        }
    }
    
    func startTransceiver() {
        backgroundHealthText = ""
        backgroundHealthIsHealthy = false
        backgroundEnterTime = nil
        audioManager.resetBackgroundHeartbeat()
        audioManager.resetDeferredFeatures()

        audioManager.startRX()
        // Start Live Activity with current reporter frequency
        let freqMHz = String(format: "%.3f", Double(reporter?.frequencyHz ?? 14_236_000) / 1_000_000)
        liveActivity.startActivity(frequencyMHz: freqMHz)
    }
    
    func stopTransceiver() {
        audioManager.stop()
        liveActivity.endActivity()

        backgroundHealthText = ""
        backgroundHealthIsHealthy = false
        backgroundEnterTime = nil
        audioManager.resetBackgroundHeartbeat()
    }
    
    /// Restart the status polling timer with a new interval (for power profile changes).
    func restartStatusTimer(interval: TimeInterval) {
        statusTimer?.invalidate()
        statusTimer = nil
        currentTimerInterval = interval
        setupBindings()
    }
    
    // MARK: - Background / Foreground
    
    private func observeAppLifecycle() {
        let bg = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.enterBackground()
            }
        }
        let fg = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.exitBackground()
            }
        }
        backgroundObservers = [bg, fg]
    }
    
    private func enterBackground() {
        isInBackground = true

        if isRunning {
            backgroundEnterTime = Date()
            audioManager.resetBackgroundHeartbeat()
            backgroundHealthText = "Background monitoring..."
            backgroundHealthIsHealthy = false
        }

        // Disable FFT and waterfall — no one can see them in background
        audioManager.fftEnabled = false
        // Tell AudioManager and LogManager to skip non-essential main thread dispatches
        // Background strategy: decode + store feature frames only (no synthesis).
        audioManager.backgroundMode = true
        audioManager.setBackgroundDecodeOnly(true)
        audioManager.setDeferredFeatureStorageEnabled(true)
        LogManager.shared.backgroundMode = true
        // Stop the UI timer entirely — no SwiftUI updates needed in background.
        // Live Activity updates come from AudioManager's background callback instead.
        statusTimer?.invalidate()
        statusTimer = nil
        
        // Disable non-essential background callbacks.
        // Keep background execution focused on decoding + logging only.
        audioManager.onBackgroundStatusUpdate = nil

        #if os(iOS)
        // Request short transition time, but keep the current audio mode.
        // On some devices/routes, switching mode in background fails with 560557684
        // and leaves the engine dead until foreground.
        audioManager.beginBackgroundTask()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.audioManager.reassertAudioSession()
            self?.audioManager.checkEngineHealth()
        }
        // End background task promptly; persistent background runtime should come
        // from audio background mode, not a long-lived UIApplication task.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.audioManager.endBackgroundTask()
        }
        #endif
        
        bgLog("ViewModel: entered background mode (FFT off, timer stopped)")
    }
    
    private func exitBackground() {
        isInBackground = false

        if let enterTime = backgroundEnterTime {
            let elapsed = Int(Date().timeIntervalSince(enterTime))
            let heartbeat = audioManager.backgroundHeartbeatSnapshot()
            if heartbeat.count > 0, let last = heartbeat.lastDate {
                let lag = Int(Date().timeIntervalSince(last))
                backgroundHealthText = "BG decode OK · \(heartbeat.count) updates in \(elapsed)s (last \(lag)s ago)"
                backgroundHealthIsHealthy = true
            } else if heartbeat.rxChunkCount > 0 {
                let lag = heartbeat.rxChunkLastDate.map { Int(Date().timeIntervalSince($0)) } ?? -1
                if lag >= 0 {
                    backgroundHealthText = "BG audio active, but no decode heartbeat · chunks \(heartbeat.rxChunkCount), last \(lag)s ago"
                } else {
                    backgroundHealthText = "BG audio active, but no decode heartbeat · chunks \(heartbeat.rxChunkCount)"
                }
                backgroundHealthIsHealthy = false
            } else {
                backgroundHealthText = "BG decode not observed · 0 updates in \(elapsed)s"
                backgroundHealthIsHealthy = false
            }
        }

        // Remove background callback
        audioManager.onBackgroundStatusUpdate = nil
        audioManager.backgroundMode = false
        audioManager.setDeferredFeatureStorageEnabled(false)
        audioManager.setBackgroundDecodeOnly(false)
        LogManager.shared.backgroundMode = false

        // Foreground: synthesize deferred background features into session audio log.
        audioManager.synthesizeDeferredFeatures()
        
        #if os(iOS)
        // Ensure no transition task is left running.
        audioManager.endBackgroundTask()
        #endif
        
        
        // Check if audio engine is still running after returning from background
        audioManager.checkEngineHealth()
        // Restore FFT based on power profile
        audioManager.fftEnabled = powerManager?.fftEnabled ?? true
        // Restart the UI timer
        restartStatusTimer(interval: powerManager?.uiUpdateInterval ?? 0.15)
        bgLog("ViewModel: exited background mode (settings restored)")
    }
    
    // MARK: - Sync State Display
    
    var syncStateText: String {
        switch syncState {
        case .searching:
            return "Searching"
        case .candidate:
            return "Candidate"
        case .synced:
            return "Synced"
        @unknown default:
            return "Unknown"
        }
    }
    
    var syncStateColor: Color {
        switch syncState {
        case .searching:
            return .red
        case .candidate:
            return .yellow
        case .synced:
            return .green
        @unknown default:
            return .gray
        }
    }
}
