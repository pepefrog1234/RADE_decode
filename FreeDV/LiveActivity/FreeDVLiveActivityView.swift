import WidgetKit
import SwiftUI

/// Widget bundle providing Live Activity UI for Lock Screen and Dynamic Island.
/// NOTE: This file should be added to the Widget Extension target once created.
struct FreeDVLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FreeDVAttributes.self) { context in
            // Lock Screen / StandBy banner
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded Dynamic Island
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        syncIndicator(state: context.state.syncState)
                        Text(syncText(context.state.syncState))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 2) {
                        Text("SNR")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%+.0f", context.state.snr))
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(snrColor(context.state.snr))
                        Text("dB")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if !context.state.lastCallsign.isEmpty {
                            Label(context.state.lastCallsign, systemImage: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                        }
                        Spacer()
                        Text(context.attributes.frequencyMHz + " MHz")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // Compact Dynamic Island — left
                HStack(spacing: 3) {
                    syncIndicator(state: context.state.syncState)
                    if !context.state.lastCallsign.isEmpty {
                        Text(context.state.lastCallsign)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            } compactTrailing: {
                // Compact Dynamic Island — right
                Text(String(format: "%+.0f", context.state.snr))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(snrColor(context.state.snr))
            } minimal: {
                // Minimal Dynamic Island (when another activity is competing)
                syncIndicator(state: context.state.syncState)
            }
        }
    }
    
    // MARK: - Lock Screen View
    
    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<FreeDVAttributes>) -> some View {
        HStack(spacing: 12) {
            // Sync status
            VStack(spacing: 4) {
                syncIndicator(state: context.state.syncState, size: 18)
                Text(syncText(context.state.syncState))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(syncColor(context.state.syncState))
            }
            .frame(width: 60)
            
            // Main info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("RADE Decode")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text(context.attributes.frequencyMHz + " MHz")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    // SNR
                    HStack(spacing: 2) {
                        Text("SNR")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%+.0f dB", context.state.snr))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(snrColor(context.state.snr))
                    }
                    
                    Spacer()
                    
                    // Callsign
                    if !context.state.lastCallsign.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Text(context.state.lastCallsign)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                    
                    Spacer()
                    
                    // Decoded count
                    Text("\(context.state.decodedCount) decoded")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .activityBackgroundTint(.black.opacity(0.8))
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func syncIndicator(state: Int, size: CGFloat = 10) -> some View {
        Circle()
            .fill(syncColor(state))
            .frame(width: size, height: size)
    }
    
    private func syncColor(_ state: Int) -> Color {
        switch state {
        case 2: return .green
        case 1: return .yellow
        default: return .red
        }
    }
    
    private func syncText(_ state: Int) -> String {
        switch state {
        case 2: return "SYNC"
        case 1: return "CAND"
        default: return "SRCH"
        }
    }
    
    private func snrColor(_ snr: Float) -> Color {
        if snr > 6 { return .green }
        if snr > 2 { return .yellow }
        return .red
    }
}
