import SwiftUI
import SwiftData
import CoreLocation

/// Main transceiver UI — professional ham radio interface with dark theme.
struct TransceiverView: View {
    var reporter: FreeDVReporter
    @StateObject private var viewModel = TransceiverViewModel()
    @Environment(\.modelContext) private var modelContext
    @State private var isOutdoorMode = false
    
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
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                        // Spectrum + Waterfall stacked display
                        Group {
                            if viewModel.effectiveFFTEnabled {
                                VStack(spacing: 1) {
                                    SpectrumView(fftData: viewModel.fftData)
                                        .frame(height: geo.size.height * 0.18)

                                    WaterfallView(history: viewModel.waterfallHistory)
                                        .frame(height: geo.size.height * 0.22)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "gauge.with.dots.needle.33percent")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.orange.opacity(0.9))
                                    if viewModel.autoLowLoadModeActive {
                                        Text("Auto low-load mode enabled")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.orange.opacity(0.95))
                                    }
                                    Text("On older devices, turning off FFT / Waterfall can improve sync and decode speed.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: geo.size.height * 0.40)
                                .background(Color.white.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange.opacity(0.25), lineWidth: 0.8)
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
                        
                        // Bottom control area: Start/Stop
                        BottomControls(viewModel: viewModel)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
            }
            .navigationTitle("RADE Decode")
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
                viewModel.configureLogger(modelContainer: modelContext.container)
                viewModel.reporter = reporter
            }
        }
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
    TransceiverView(reporter: FreeDVReporter())
}
