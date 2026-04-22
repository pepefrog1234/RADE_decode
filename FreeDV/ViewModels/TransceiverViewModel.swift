import SwiftUI
import Combine
import SwiftData

/// ViewModel managing RX state, bridging AudioManager to SwiftUI views.
@MainActor
class TransceiverViewModel: ObservableObject {
    enum BackgroundAnalysisTaskStatus: String {
        case pending = "Pending"
        case running = "Running"
        case paused = "Paused"
        case completed = "Done"
        case cancelled = "Cancelled"
    }

    struct BackgroundAnalysisTask: Identifiable {
        let id: UUID
        let createdAt: Date
        var title: String
        var status: BackgroundAnalysisTaskStatus
        var progress: Double
        var scannedSeconds: Double
        var etaSeconds: Double
        var signalCount: Int = 0
        /// Index of the deferred sample batch file this task decodes.
        var batchIndex: Int?
    }
    
    private let audioManager = AudioManager()
    private let deviceManager = AudioDeviceManager()
    
    /// FreeDV Reporter integration — set from the view layer.
    var reporter: FreeDVReporter? {
        didSet { audioManager.reporter = reporter }
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
    @Published var effectiveFFTEnabled = true
    @Published var autoLowLoadModeActive = false
    
    // FFT data for spectrum display
    @Published var fftData: [Float] = Array(repeating: -100, count: 512)
    @Published var waterfallHistory: [[Float]] = []
    
    // Device info
    @Published var currentInputDevice: String = NSLocalizedString("Unknown", comment: "Unknown audio input device")
    @Published var currentOutputDevice: String = NSLocalizedString("Unknown", comment: "Unknown audio output device")
    @Published var userMicDevice: String = NSLocalizedString("Unknown", comment: "Unknown user microphone device")
    @Published var userSpeakerDevice: String = NSLocalizedString("Unknown", comment: "Unknown user speaker device")
    
    // Callsign (auto-clears after 10 seconds)
    @Published var decodedCallsign: String = ""
    private var callsignDismissTask: Task<Void, Never>?
    
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
    @Published var deferredDecodeInProgress = false
    @Published var deferredDecodeProgress: Double = 0
    @Published var deferredDecodeStatusText = ""
    @Published var deferredDecodePaused = false
    @Published var deferredDecodeScannedSeconds: Double = 0
    @Published var deferredDecodeETASeconds: Double = 0
    @Published var backgroundAnalysisTasks: [BackgroundAnalysisTask] = []
    
    private var statusTimer: Timer?
    private let maxWaterfallRows = 100
    private var currentTimerInterval: TimeInterval = 0.15
    /// Prevent Task accumulation — skip tick if previous Task is still running
    private var isProcessingTick = false

    private var backgroundObservers: [Any] = []
    private var backgroundEnterTime: Date?
    private var deferredDecodeWasActiveBeforeBackground = false
    private var lastDeferredDecodeInProgress = false
    private var lastDeferredDecodeProgress: Double = 0
    
    init() {
        setupBindings()
        observeAppLifecycle()
    }

    @MainActor deinit {
        // Ensure timer/observers/tasks are torn down deterministically.
        statusTimer?.invalidate()
        statusTimer = nil
        callsignDismissTask?.cancel()
        callsignDismissTask = nil
        for observer in backgroundObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        backgroundObservers.removeAll()

        // Stop runtime side effects owned by this VM.
        audioManager.onBackgroundStatusUpdate = nil
        audioManager.stop()
    }
    
    /// Configure the reception logger with a ModelContainer.
    /// Call this once from the view when the environment provides the container.
    func configureLogger(modelContainer: ModelContainer) {
        audioManager.configureLogger(modelContainer: modelContainer)
    }

    // MARK: - Bindings

    private func setupBindings() {
        // Observe AudioManager state changes
        statusTimer = Timer.scheduledTimer(withTimeInterval: currentTimerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isProcessingTick else { return }
                self.isProcessingTick = true
                defer { self.isProcessingTick = false }
                
                // Update isRunning first for dependent UI state.
                let amIsRunning = self.audioManager.isRunning
                self.isRunning = amIsRunning
                
                let newSyncState = self.audioManager.syncState
                let newSNR = self.audioManager.snr
                
                self.syncState = newSyncState
                self.snr = newSNR
                self.freqOffset = self.audioManager.freqOffset
                self.inputLevel = self.audioManager.inputLevel
                self.outputLevel = self.audioManager.outputLevel

                // Skip FFT/waterfall updates in background (saves CPU + memory)
                if !self.isInBackground {
                    self.autoLowLoadModeActive = self.audioManager.autoLowLoadModeActive
                    let shouldEnableFFT = AudioManager.fftEnabledPreference
                        && !self.audioManager.isFFTForcedOffForPerformance
                        && !self.audioManager.isAcquisitionBoostActive
                    self.effectiveFFTEnabled = shouldEnableFFT
                    self.audioManager.fftEnabled = shouldEnableFFT
                    if shouldEnableFFT {
                        let newFFT = self.audioManager.fftData
                        if newFFT != self.fftData {
                            self.fftData = newFFT
                            self.waterfallHistory.append(newFFT)
                            let excess = self.waterfallHistory.count - self.maxWaterfallRows
                            if excess > 0 {
                                self.waterfallHistory.removeFirst(excess)
                            }
                        }
                    }
                    
                    self.currentInputDevice = self.deviceManager.currentInputName
                    self.currentOutputDevice = self.deviceManager.currentOutputName
                    self.userMicDevice = self.deviceManager.userInputName
                    self.userSpeakerDevice = self.deviceManager.userOutputName
                }
                self.isRecording = self.audioManager.wavRecorder != nil
                self.deferredDecodeInProgress = self.audioManager.deferredDecodeInProgress
                self.deferredDecodeProgress = self.audioManager.deferredDecodeProgress
                self.deferredDecodeStatusText = self.audioManager.deferredDecodeStatusText
                self.deferredDecodePaused = self.audioManager.deferredDecodePaused
                self.deferredDecodeScannedSeconds = self.audioManager.deferredDecodeScannedSeconds
                self.deferredDecodeETASeconds = self.audioManager.deferredDecodeETASeconds
                self.syncBackgroundAnalysisTasks()
                
                // Update decoded callsign from EOO (auto-dismiss after 10s).
                let newCallsign = self.audioManager.decodedCallsign
                if !newCallsign.isEmpty && newCallsign != self.decodedCallsign {
                    self.decodedCallsign = newCallsign
                    self.callsignDismissTask?.cancel()
                    self.callsignDismissTask = Task {
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled else { return }
                        withAnimation { self.decodedCallsign = "" }
                        self.audioManager.decodedCallsign = ""
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

    func toggleDeferredDecodePause() {
        audioManager.setDeferredDecodePaused(!deferredDecodePaused)
    }

    func startDeferredDecodeAnalysis() {
        if deferredDecodeInProgress {
            if deferredDecodePaused {
                audioManager.setDeferredDecodePaused(false)
            }
            return
        }
        ensurePendingTaskExists()
        audioManager.decodeDeferredSamples()
    }

    func cancelDeferredDecodeAnalysis() {
        audioManager.cancelDeferredDecode()
    }

    func removeBackgroundAnalysisTask(id: UUID) {
        backgroundAnalysisTasks.removeAll { $0.id == id }
    }
    
    func startTransceiver() {
        backgroundHealthText = ""
        backgroundHealthIsHealthy = false
        backgroundEnterTime = nil
        audioManager.resetBackgroundHeartbeat()
        audioManager.resetDeferredFeatures()
        audioManager.resetDeferredSamples()

        audioManager.startRX()
    }
    
    func stopTransceiver() {
        audioManager.stop()

        backgroundHealthText = ""
        backgroundHealthIsHealthy = false
        backgroundEnterTime = nil
        audioManager.resetBackgroundHeartbeat()
    }
    
    /// Restart the status polling timer.
    func restartStatusTimer(interval: TimeInterval) {
        statusTimer?.invalidate()
        statusTimer = nil
        currentTimerInterval = interval
        setupBindings()
    }
    
    // MARK: - Background / Foreground
    
    private func observeAppLifecycle() {
        let resign = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pauseDeferredDecodeForLifecycleIfNeeded()
            }
        }
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
        backgroundObservers = [resign, bg, fg]
    }

    private func pauseDeferredDecodeForLifecycleIfNeeded() {
        let wasActive = audioManager.deferredDecodeInProgress
        if wasActive {
            deferredDecodeWasActiveBeforeBackground = true
            audioManager.setDeferredDecodePaused(true)
        }
    }

    private func enqueueBackgroundAnalysisTask() {
        let index = backgroundAnalysisTasks.count + 1
        let task = BackgroundAnalysisTask(
            id: UUID(),
            createdAt: Date(),
            title: captureTitle(index: index),
            status: .pending,
            progress: 0,
            scannedSeconds: 0,
            etaSeconds: 0,
            batchIndex: audioManager.latestPendingBatchIndex
        )
        backgroundAnalysisTasks.insert(task, at: 0)
    }

    /// Remove a pending task and its corresponding batch file from disk.
    func removePendingBackgroundAnalysisTask(id: UUID) {
        guard let task = backgroundAnalysisTasks.first(where: { $0.id == id }),
              task.status == .pending else { return }
        if let batchIndex = task.batchIndex {
            audioManager.removeDeferredBatch(at: batchIndex)
            appLog("ViewModel: removed pending task batch \(batchIndex)")
        }
        backgroundAnalysisTasks.removeAll { $0.id == id }
    }

    private func ensurePendingTaskExists() {
        let hasPending = backgroundAnalysisTasks.contains { $0.status == .pending }
        let hasRunning = backgroundAnalysisTasks.contains { $0.status == .running || $0.status == .paused }
        if !hasPending && !hasRunning {
            enqueueBackgroundAnalysisTask()
        }
    }

    private func syncBackgroundAnalysisTasks() {
        if deferredDecodeInProgress {
            let sigCount = audioManager.deferredDecodeSignalCount
            if let index = backgroundAnalysisTasks.firstIndex(where: { $0.status == .running || $0.status == .paused }) {
                backgroundAnalysisTasks[index].status = deferredDecodePaused ? .paused : .running
                backgroundAnalysisTasks[index].progress = deferredDecodeProgress
                backgroundAnalysisTasks[index].scannedSeconds = deferredDecodeScannedSeconds
                backgroundAnalysisTasks[index].etaSeconds = deferredDecodeETASeconds
                backgroundAnalysisTasks[index].signalCount = sigCount
            } else if let pendingIndex = backgroundAnalysisTasks.lastIndex(where: { $0.status == .pending }) {
                backgroundAnalysisTasks[pendingIndex].status = deferredDecodePaused ? .paused : .running
                backgroundAnalysisTasks[pendingIndex].progress = deferredDecodeProgress
                backgroundAnalysisTasks[pendingIndex].scannedSeconds = deferredDecodeScannedSeconds
                backgroundAnalysisTasks[pendingIndex].etaSeconds = deferredDecodeETASeconds
                backgroundAnalysisTasks[pendingIndex].signalCount = sigCount
            } else {
                var task = BackgroundAnalysisTask(
                    id: UUID(),
                    createdAt: Date(),
                    title: captureTitle(index: backgroundAnalysisTasks.count + 1),
                    status: deferredDecodePaused ? .paused : .running,
                    progress: deferredDecodeProgress,
                    scannedSeconds: deferredDecodeScannedSeconds,
                    etaSeconds: deferredDecodeETASeconds
                )
                if task.progress >= 1 { task.progress = 0.999 }
                backgroundAnalysisTasks.insert(task, at: 0)
            }
        } else if lastDeferredDecodeInProgress {
            if let index = backgroundAnalysisTasks.firstIndex(where: { $0.status == .running || $0.status == .paused }) {
                // Use current progress (not last tick's) because AudioManager sets
                // progress=1.0 and inProgress=false in the same main queue dispatch.
                let completed = deferredDecodeProgress >= 0.999 || lastDeferredDecodeProgress >= 0.999
                backgroundAnalysisTasks[index].status = completed ? .completed : .cancelled
                backgroundAnalysisTasks[index].progress = completed ? 1.0 : backgroundAnalysisTasks[index].progress
                backgroundAnalysisTasks[index].etaSeconds = 0
                backgroundAnalysisTasks[index].signalCount = audioManager.deferredDecodeSignalCount

                // Auto-chain: if a pending task exists, start the next decode batch
                if completed, backgroundAnalysisTasks.contains(where: { $0.status == .pending }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.startDeferredDecodeAnalysis()
                    }
                }
            }
        }

        lastDeferredDecodeInProgress = deferredDecodeInProgress
        lastDeferredDecodeProgress = deferredDecodeProgress
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
        // Tell AudioManager and LogManager to skip non-essential main thread dispatches.
        // Background strategy: capture raw modem samples; decode on foreground.
        audioManager.backgroundMode = true
        audioManager.setBackgroundDecodeOnly(true)
        audioManager.setDeferredFeatureStorageEnabled(false)
        pauseDeferredDecodeForLifecycleIfNeeded()
        // Advance to a new batch file so new background captures
        // don't corrupt the paused decode's data.
        if deferredDecodeWasActiveBeforeBackground {
            audioManager.advanceDeferredSampleBatch()
        }
        audioManager.hadRawSampleCapture = false
        audioManager.setBackgroundRawSampleCaptureEnabled(true)
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
        
        bgLog("ViewModel: entered background mode (FFT off, timer stopped, deferredWasActive=\(deferredDecodeWasActiveBeforeBackground))")
    }
    
    private func exitBackground() {
        isInBackground = false

        // Detect background capture: check heartbeat, raw-capture flag, AND
        // whether new batch files appeared on disk (most reliable).
        let heartbeat = audioManager.backgroundHeartbeatSnapshot()
        let hadRawCapture = audioManager.hadRawSampleCapture
        let pendingBatches = audioManager.pendingDeferredBatchCount
        let existingRunningOrPending = backgroundAnalysisTasks.filter { $0.status == .running || $0.status == .paused || $0.status == .pending }.count
        let hadBackgroundCapture = heartbeat.rxChunkCount > 0
            || hadRawCapture
            || pendingBatches > existingRunningOrPending

        if let enterTime = backgroundEnterTime {
            let elapsed = Int(Date().timeIntervalSince(enterTime))
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

        appLog("ViewModel: exitBackground hadCapture=\(hadBackgroundCapture) rawFlag=\(hadRawCapture) rxChunks=\(heartbeat.rxChunkCount) batches=\(pendingBatches) existingTasks=\(existingRunningOrPending) deferredWasActive=\(deferredDecodeWasActiveBeforeBackground)")

        // Remove background callback
        audioManager.onBackgroundStatusUpdate = nil
        audioManager.backgroundMode = false
        audioManager.setBackgroundRawSampleCaptureEnabled(false)
        audioManager.setDeferredFeatureStorageEnabled(false)
        audioManager.setBackgroundDecodeOnly(false)
        LogManager.shared.backgroundMode = false
        // Skip recordings shorter than 5 seconds — not enough data to decode meaningfully.
        let minSamplesForDecode = 8000 * 5  // 8kHz × 5s
        let latestBatchSamples = audioManager.latestDeferredBatchSampleCount
        if hadBackgroundCapture && latestBatchSamples >= minSamplesForDecode {
            enqueueBackgroundAnalysisTask()
            appLog("ViewModel: enqueued analysis task (total: \(backgroundAnalysisTasks.count))")
        } else if hadBackgroundCapture {
            appLog("ViewModel: skipped short capture (\(String(format: "%.1f", Double(latestBatchSamples) / 8000.0))s < 5s), removing batch")
            audioManager.removeLatestDeferredBatch()
        }

        if deferredDecodeWasActiveBeforeBackground {
            // If user left app mid-analysis, keep it paused after returning.
            audioManager.setDeferredDecodePaused(true)
            deferredDecodeWasActiveBeforeBackground = false
            // Ensure a pending task exists for the new capture regardless of detection.
            // But only if the captured audio is long enough to decode.
            if !backgroundAnalysisTasks.contains(where: { $0.status == .pending }),
               latestBatchSamples >= minSamplesForDecode {
                enqueueBackgroundAnalysisTask()
                appLog("ViewModel: force-enqueued task for paused-decode return (total: \(backgroundAnalysisTasks.count))")
            } else if latestBatchSamples < minSamplesForDecode {
                appLog("ViewModel: skipped force-enqueue, capture too short (\(String(format: "%.1f", Double(latestBatchSamples) / 8000.0))s)")
                audioManager.removeLatestDeferredBatch()
            }
            // The paused decode will resume when the user taps Resume.
            // After it completes, syncBackgroundAnalysisTasks auto-chains
            // the next pending task.
        } else {
            audioManager.setDeferredDecodePaused(false)
            // Foreground: decode deferred background raw samples into session audio log.
            audioManager.decodeDeferredSamples()
        }
        
        #if os(iOS)
        // Ensure no transition task is left running.
        audioManager.endBackgroundTask()
        #endif
        
        
        // Check if audio engine is still running after returning from background
        audioManager.checkEngineHealth()
        // Restore FFT preference and UI timer in foreground.
        audioManager.fftEnabled = AudioManager.fftEnabledPreference
            && !audioManager.isFFTForcedOffForPerformance
            && !audioManager.isAcquisitionBoostActive
        // Restart the UI timer
        restartStatusTimer(interval: 0.15)
        bgLog("ViewModel: exited background mode (settings restored)")
    }
    
    // MARK: - Sync State Display
    
    var syncStateText: String {
        switch syncState {
        case .searching:
            return NSLocalizedString("Searching", comment: "Sync state: searching")
        case .candidate:
            return NSLocalizedString("Candidate", comment: "Sync state: candidate")
        case .synced:
            return NSLocalizedString("Synced", comment: "Sync state: synced")
        @unknown default:
            return NSLocalizedString("Unknown", comment: "Sync state: unknown")
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

private func captureTitle(index: Int) -> String {
    String.localizedStringWithFormat(
        NSLocalizedString("Capture #%d", comment: "Background analysis capture title"),
        index
    )
}
