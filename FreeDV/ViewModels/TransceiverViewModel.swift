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
    
    private var statusTimer: Timer?
    private let maxWaterfallRows = 100
    private var currentTimerInterval: TimeInterval = 0.15
    /// Prevent Task accumulation — skip tick if previous Task is still running
    private var isProcessingTick = false

    private var backgroundObservers: [Any] = []
    
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
        audioManager.startRX()
        // Start Live Activity with current reporter frequency
        let freqMHz = String(format: "%.3f", Double(reporter?.frequencyHz ?? 14_236_000) / 1_000_000)
        liveActivity.startActivity(frequencyMHz: freqMHz)
    }
    
    func stopTransceiver() {
        audioManager.stop()
        liveActivity.endActivity()
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
        // Disable FFT and waterfall — no one can see them in background
        audioManager.fftEnabled = false
        // Tell AudioManager and LogManager to skip non-essential main thread dispatches
        audioManager.backgroundMode = true
        LogManager.shared.backgroundMode = true
        // Stop the UI timer entirely — no SwiftUI updates needed in background.
        // Live Activity updates come from AudioManager's background callback instead.
        statusTimer?.invalidate()
        statusTimer = nil
        
        // Set up lightweight background callback for Live Activity
        audioManager.onBackgroundStatusUpdate = { [weak self] syncState, snr, freqOffset in
            guard let self = self else { return }
            // Dispatch to main actor for Live Activity (very lightweight, ~every 5s)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.liveActivity.updateActivity(
                    syncState: syncState,
                    snr: snr,
                    freqOffsetHz: freqOffset,
                    lastCallsign: self.decodedCallsign
                )
            }
        }
        
        #if os(iOS)
        // Request extra time during background transition
        audioManager.beginBackgroundTask()
        // Switch to .default mode via full deactivate/reactivate cycle.
        // This is required for iOS to recognize the audio as background-worthy.
        // The tap is removed and reinstalled with the new format.
        audioManager.setBackgroundAudioMode(true)
        #endif
        
        bgLog("ViewModel: entered background mode (FFT off, timer stopped)")
    }
    
    private func exitBackground() {
        isInBackground = false
        // Remove background callback
        audioManager.onBackgroundStatusUpdate = nil
        audioManager.backgroundMode = false
        LogManager.shared.backgroundMode = false
        
        #if os(iOS)
        // End background task if still active
        audioManager.endBackgroundTask()
        // Restore .measurement mode for optimal modem quality
        audioManager.setBackgroundAudioMode(false)
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
