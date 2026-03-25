import SwiftUI
import SwiftData
import CoreLocation

/// Main transceiver UI — professional ham radio interface with dark theme.
struct TransceiverView: View {
    var reporter: FreeDVReporter
    var powerManager: PowerManager
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
                        
                        // Spectrum + Waterfall stacked display (hidden in ultraLow)
                        if powerManager.fftEnabled {
                            VStack(spacing: 1) {
                                SpectrumView(fftData: viewModel.fftData)
                                    .frame(height: geo.size.height * (powerManager.waterfallEnabled ? 0.18 : 0.30))
                                
                                if powerManager.waterfallEnabled {
                                    WaterfallView(history: viewModel.waterfallHistory)
                                        .frame(height: geo.size.height * 0.22)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                        
                        // Level meters
                        VStack(spacing: 6) {
                            MeterView(label: "IN", level: viewModel.inputLevel)
                            MeterView(label: "OUT", level: viewModel.outputLevel)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        
                        // Decoded callsign banner
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
                    NavigationLink(destination: LogView()) {
                        Image(systemName: "doc.text.magnifyingglass")
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
                viewModel.powerManager = powerManager
                // Clean up any Live Activities left over from a previous crash/kill
                viewModel.liveActivity.cleanupStaleActivities()
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
                    Text("IN: \(viewModel.currentInputDevice)")
                    Text("·")
                    Text("OUT: \(viewModel.currentOutputDevice)")
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
        VStack(spacing: 2) {
            if authStatus == .authorizedAlways {
                Text("Continues in background")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.gray.opacity(0.35))
            } else {
                Text("Enable \"Always\" location in Settings for background RX")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.orange.opacity(0.6))
            }

            if !viewModel.backgroundHealthText.isEmpty {
                Text(viewModel.backgroundHealthText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(viewModel.backgroundHealthIsHealthy ? .green : .orange)
                    .lineLimit(1)
            }
        }
    }
}

#Preview {
    TransceiverView(reporter: FreeDVReporter(), powerManager: PowerManager())
}
