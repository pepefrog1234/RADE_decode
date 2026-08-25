import SwiftUI
import SwiftData
import CoreLocation

/// Main transceiver UI — professional ham radio interface with dark theme.
struct TransceiverView: View {
    var reporter: FreeDVReporter
    var radioController: IcomRadioController
    @StateObject private var viewModel = TransceiverViewModel()
    @Environment(\.modelContext) private var modelContext
    @State private var isOutdoorMode = false
    /// Waterfall is replaced by the reception-reports panel during TX, and
    /// held a few seconds afterwards — callsign confirmations (EOO decodes
    /// from other stations) mostly arrive right as the over ends.
    @State private var showTxReports = false
    @State private var txReportsHoldTask: Task<Void, Never>?
    @AppStorage(RADEMode.v2Key) private var radeV2Enabled = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Dark background
                Color(white: 0.08)
                    .ignoresSafeArea()
                
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        // Top info bar: Sync + SNR + Freq offset
                        HStack {
                            StatusBar(
                                syncState: viewModel.syncState,
                                syncStateText: viewModel.syncStateText,
                                syncStateColor: viewModel.syncStateColor,
                                snr: viewModel.snr,
                                freqOffset: viewModel.freqOffset,
                                isRunning: viewModel.isRunning,
                                reporterEnabled: reporter.isEnabled,
                                reporterConnected: reporter.isConnected
                            )
                            
                            // Recording indicator
                            if viewModel.isRecording {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                    .padding(.leading, 4)
                            }

                            // Experimental codec reminder
                            if RADEMode.v2FeatureAvailable && radeV2Enabled {
                                Text("V2 EXPERIMENTAL")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.25))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                                    .padding(.leading, 4)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                        // Spectrum + Waterfall stacked display; while
                        // transmitting it becomes the reception-reports panel.
                        Group {
                            if showTxReports {
                                TxReportsView(reporter: reporter,
                                              isTransmitting: viewModel.radioIsTransmitting)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: geo.size.height * 0.40)
                                    .background(Color.white.opacity(0.03))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(viewModel.radioIsTransmitting
                                                    ? Color.red.opacity(0.4)
                                                    : Color.white.opacity(0.1),
                                                    lineWidth: 0.8)
                                    )
                            } else {
                                // Spectrum (when FFT is on) + band activity from
                                // FreeDV Reporter — the waterfall is gone: it cost
                                // CPU and finding active frequencies is what the
                                // activity list does better.
                                VStack(spacing: 1) {
                                    if viewModel.effectiveFFTEnabled {
                                        SpectrumView(fftData: viewModel.fftData)
                                            .frame(height: geo.size.height * 0.16)
                                    }
                                    BandActivityView(reporter: reporter, viewModel: viewModel)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: geo.size.height * (viewModel.effectiveFFTEnabled ? 0.24 : 0.40))
                                        .background(Color.white.opacity(0.03))
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        
                        // Level meters
                        VStack(spacing: 6) {
                            MeterView(label: "IN", level: viewModel.inputLevel)
                            MeterView(label: "OUT", level: viewModel.outputLevel)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        
                        // Decoded callsign banner (auto-dismisses after 10s)
                        if !viewModel.decodedCallsign.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.green)
                                Text(viewModel.decodedCallsign)
                                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 20)
                            .background(Color.green.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.top, 10)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                        
                        Spacer()

                        // IC-705 radio control (frequency / mode / PTT)
                        if viewModel.usingRadioSource {
                            RadioControlPanel(viewModel: viewModel)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }

                        // Bottom control area: Start/Stop
                        BottomControls(viewModel: viewModel)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
            }
            .navigationTitle("RADE Decode")
            // Inline title: the band-activity / TX-reports scroll views would
            // otherwise drive the collapsible large title, making "RADE
            // Decode" slide down when the list is pulled.
            .navigationBarTitleDisplayMode(.inline)
            #if os(iOS)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color(white: 0.08), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isOutdoorMode = true
                    } label: {
                        Image(systemName: "sun.max.fill")
                            .foregroundStyle(.yellow.opacity(0.7))
                    }
                }
                ToolbarItem(placement: .automatic) {
                    NavigationLink(destination: BackgroundAnalysisView(viewModel: viewModel)) {
                        Image(systemName: "waveform.and.magnifyingglass")
                            .foregroundStyle(.gray)
                    }
                }
            }
            .fullScreenCover(isPresented: $isOutdoorMode) {
                OutdoorView(viewModel: viewModel)
                    .onTapGesture(count: 2) {
                        isOutdoorMode = false
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            isOutdoorMode = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(16)
                    }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                viewModel.attachRadioController(radioController)
                viewModel.configureLogger(modelContainer: modelContext.container)
                viewModel.reporter = reporter
            }
            .onChange(of: viewModel.radioIsTransmitting) { _, transmitting in
                txReportsHoldTask?.cancel()
                if transmitting {
                    withAnimation { showTxReports = true }
                } else {
                    // Hold the panel while post-over EOO reports come in.
                    txReportsHoldTask = Task {
                        try? await Task.sleep(for: .seconds(8))
                        guard !Task.isCancelled else { return }
                        withAnimation { showTxReports = false }
                    }
                }
            }
        }
    }
}

// MARK: - Radio Control Panel (IC-705)

/// Frequency / mode display + push-to-talk for the connected IC-705.
struct RadioControlPanel: View {
    @ObservedObject var viewModel: TransceiverViewModel
    @State private var pttActive = false
    /// Debounced release: a micro touch-loss while pressing hard (finger
    /// roll, contact-shape change) must not end the over — the touch coming
    /// back within the window cancels the pending release.
    @State private var pttReleaseTask: Task<Void, Never>?

    private var freqText: String {
        guard viewModel.radioFrequencyHz > 0 else { return "—" }
        let mhz = Double(viewModel.radioFrequencyHz) / 1_000_000.0
        return String(format: "%.4f MHz", mhz)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                // Connection state
                Circle()
                    .fill(viewModel.radioConnected ? .green : (viewModel.radioConnecting ? .yellow : .gray))
                    .frame(width: 8, height: 8)
                Text(viewModel.radioConnected ? (viewModel.radioName.isEmpty ? "IC-705" : viewModel.radioName)
                                              : (viewModel.radioConnecting ? "Connecting…" : "Not connected"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(freqText)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("\(viewModel.radioMode.description)\(viewModel.radioDataMode ? "-D" : "")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cyan.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Push-to-talk
            Text(viewModel.radioIsTransmitting ? "TRANSMITTING" : "HOLD TO TALK")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(viewModel.radioIsTransmitting ? Color.red : Color(white: 0.2))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(viewModel.radioIsTransmitting ? Color.red : Color.white.opacity(0.15), lineWidth: 1)
                )
                .opacity(viewModel.radioConnected && viewModel.isRunning ? 1 : 0.4)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if let pending = pttReleaseTask {
                                // Touch back within the debounce window — keep transmitting.
                                pending.cancel()
                                pttReleaseTask = nil
                            }
                            guard !pttActive, viewModel.radioConnected, viewModel.isRunning else { return }
                            pttActive = true
                            viewModel.pttDown()
                        }
                        .onEnded { _ in
                            guard pttActive, pttReleaseTask == nil else { return }
                            pttReleaseTask = Task {
                                try? await Task.sleep(for: .milliseconds(200))
                                guard !Task.isCancelled else { return }
                                pttActive = false
                                pttReleaseTask = nil
                                viewModel.pttUp()
                            }
                        }
                )
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    let syncState: RADESyncState
    let syncStateText: String
    let syncStateColor: Color
    let snr: Float
    let freqOffset: Float
    let isRunning: Bool
    var reporterEnabled: Bool = false
    var reporterConnected: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            // Mode badge
            Text("RX")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            
            Spacer()
            
            // Sync indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(isRunning ? syncStateColor : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(isRunning ? syncStateText : "Idle")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRunning ? .primary : .secondary)
            }
            
            Spacer()
            
            // SNR
            HStack(spacing: 2) {
                Text("SNR")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(syncState == .synced ? String(format: "%+.1f", snr) : "--")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(syncState == .synced ? snrColor : .secondary)
            }
            
            Spacer()
            
            // Frequency offset
            HStack(spacing: 2) {
                Text("dF")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(syncState == .synced ? String(format: "%+.0f", freqOffset) : "--")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(syncState == .synced ? .primary : .secondary)
            }
            
            // Reporter indicator
            if reporterEnabled {
                Spacer()
                Image(systemName: reporterConnected
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(reporterConnected ? .green : .red)
                    .font(.system(size: 10))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private var snrColor: Color {
        if snr > 6 { return .green }
        if snr > 2 { return .yellow }
        return .red
    }
}

// MARK: - Bottom Controls

struct BottomControls: View {
    @ObservedObject var viewModel: TransceiverViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            // Start / Stop button
            Button(action: { viewModel.toggleRunning() }) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 16))
                    Text(viewModel.isRunning ? "STOP" : "START")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    viewModel.isRunning
                        ? Color.red.opacity(0.8)
                        : Color.green.opacity(0.7)
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            
            // Device info + background hint
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("RX: \(viewModel.currentInputDevice)")
                    Text("·")
                    Text("TX: \(viewModel.currentOutputDevice)")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.gray.opacity(0.5))
                .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text("Mic: \(viewModel.userMicDevice)")
                    Text("·")
                    Text("Spk: \(viewModel.userSpeakerDevice)")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.gray.opacity(0.5))
                .lineLimit(1)
                if viewModel.isRunning {
                    BackgroundHintLabel(viewModel: viewModel)
                }
            }
        }
    }
}

// MARK: - Background Hint

/// Shows a small hint below the start button about background reception status.
struct BackgroundHintLabel: View {
    @ObservedObject var viewModel: TransceiverViewModel
    private let authStatus = CLLocationManager().authorizationStatus
    
    var body: some View {
        if authStatus == .authorizedAlways {
            Text("Continues in background")
                .font(.system(size: 9))
                .foregroundStyle(Color.gray.opacity(0.35))
        } else {
            Text("Enable \"Always\" location in Settings for background RX")
                .font(.system(size: 9))
                .foregroundStyle(Color.orange.opacity(0.6))
        }
    }
}

// MARK: - Background Analysis

struct BackgroundAnalysisView: View {
    @ObservedObject var viewModel: TransceiverViewModel

    private var activeTasks: [TransceiverViewModel.BackgroundAnalysisTask] {
        viewModel.backgroundAnalysisTasks.filter { $0.status == .running || $0.status == .paused }
    }

    private var pendingTasks: [TransceiverViewModel.BackgroundAnalysisTask] {
        viewModel.backgroundAnalysisTasks.filter { $0.status == .pending }
    }

    private var finishedTasks: [TransceiverViewModel.BackgroundAnalysisTask] {
        viewModel.backgroundAnalysisTasks.filter { $0.status == .completed || $0.status == .cancelled }
    }

    var body: some View {
        Group {
            if viewModel.backgroundAnalysisTasks.isEmpty {
                ContentUnavailableView(
                    "No Analysis Tasks",
                    systemImage: "waveform.and.magnifyingglass",
                    description: Text("Background analysis replays captured audio to decode signals received while the app was in the background. Tasks appear here automatically.")
                )
            } else {
                List {
                    ForEach(activeTasks) { task in
                        ActiveTaskCard(task: task, viewModel: viewModel)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }

                    if !pendingTasks.isEmpty {
                        Section {
                            ForEach(pendingTasks) { task in
                                CompactTaskCard(task: task)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            viewModel.removePendingBackgroundAnalysisTask(id: task.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            Text("QUEUED")
                                .font(.caption.weight(.semibold))
                        }
                    }

                    if !finishedTasks.isEmpty {
                        Section {
                            ForEach(finishedTasks) { task in
                                CompactTaskCard(task: task)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            viewModel.removeBackgroundAnalysisTask(id: task.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            Text("COMPLETED")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .bottom) {
                    if !viewModel.deferredDecodeInProgress && !pendingTasks.isEmpty {
                        startAnalysisButton
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .padding(.top, 12)
                            .background(.ultraThinMaterial)
                    }
                }
            }
        }
        .navigationTitle("Background Analysis")
    }

    @ViewBuilder
    private var startAnalysisButton: some View {
        Button {
            viewModel.startDeferredDecodeAnalysis()
        } label: {
            Label("Start Analysis", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active Task Card

private struct ActiveTaskCard: View {
    let task: TransceiverViewModel.BackgroundAnalysisTask
    @ObservedObject var viewModel: TransceiverViewModel

    private var color: Color {
        task.status == .paused ? .orange : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                statusIcon
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.headline)
                    Text(relativeTimestamp(task.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(task.status == .running ? "Analyzing" : "Paused")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.15))
                    .foregroundStyle(color)
                    .clipShape(Capsule())
            }

            // Progress
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: task.progress)
                    .tint(color)

                HStack {
                    Text(String(format: "%.0f%%", task.progress * 100))
                        .font(.system(.subheadline, design: .monospaced).bold())

                    Spacer()

                    Label(formatDuration(task.scannedSeconds), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label(formatETA(task.etaSeconds), systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if task.signalCount > 0 {
                    Label(signalsFoundText(task.signalCount), systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            // Inline controls
            HStack(spacing: 12) {
                Button {
                    viewModel.toggleDeferredDecodePause()
                } label: {
                    Label(
                        task.status == .paused ? "Resume" : "Pause",
                        systemImage: task.status == .paused ? "play.fill" : "pause.fill"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.cancelDeferredDecodeAnalysis()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(color.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        if task.status == .running {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(.blue)
                .symbolEffect(.variableColor.iterative)
        } else {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Compact Task Card

private struct CompactTaskCard: View {
    let task: TransceiverViewModel.BackgroundAnalysisTask

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                Text(relativeTimestamp(task.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailingContent
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch task.status {
        case .pending:
            Text("Queued")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .completed:
            VStack(alignment: .trailing, spacing: 2) {
                Text("Done")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                Text(task.signalCount > 0
                     ? "\(task.signalCount) signal\(task.signalCount == 1 ? "" : "s")"
                     : "No signals")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        case .cancelled:
            VStack(alignment: .trailing, spacing: 2) {
                Text("Cancelled")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                Text(String(format: "%.0f%% completed", task.progress * 100))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Helpers

private func signalsFoundText(_ count: Int) -> String {
    String.localizedStringWithFormat(
        NSLocalizedString("%d signals found", comment: "Background analysis signal count"),
        count
    )
}

private func relativeTimestamp(_ date: Date) -> String {
    let calendar = Calendar.current
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm"
    let timeString = timeFormatter.string(from: date)

    if calendar.isDateInToday(date) {
        return String.localizedStringWithFormat(
            NSLocalizedString("Today %@", comment: "Timestamp prefix for today"),
            timeString
        )
    } else if calendar.isDateInYesterday(date) {
        return String.localizedStringWithFormat(
            NSLocalizedString("Yesterday %@", comment: "Timestamp prefix for yesterday"),
            timeString
        )
    } else {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        return "\(dayFormatter.string(from: date)), \(timeString)"
    }
}

private func formatDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s == 0 { return "--:--" }
    let m = s / 60
    let r = s % 60
    return String(format: "%d:%02d", m, r)
}

private func formatETA(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s == 0 { return NSLocalizedString("almost done", comment: "ETA indicates completion is imminent") }
    let m = s / 60
    let r = s % 60
    return String.localizedStringWithFormat(
        NSLocalizedString("~%d:%02d left", comment: "ETA with minutes and seconds remaining"),
        m,
        r
    )
}

#Preview {
    TransceiverView(reporter: FreeDVReporter(), radioController: IcomRadioController())
}
