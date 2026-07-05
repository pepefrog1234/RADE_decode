import SwiftUI

/// Replaces the waterfall: a live list of FreeDV Reporter stations operating
/// near the current dial frequency, grouped by kHz — finding an active
/// frequency no longer needs a spectrum display (or its CPU cost). Tapping a
/// row tunes the IC-705 there when connected.
struct BandActivityView: View {
    var reporter: FreeDVReporter
    @ObservedObject var viewModel: TransceiverViewModel

    /// Stations within this window of the dial count as "nearby".
    private let windowHz: Int64 = 250_000
    /// Stations idle longer than this are considered stale and hidden.
    private let maxAge: TimeInterval = 600

    private struct FrequencyGroup: Identifiable {
        let id: Int64                  // kHz
        let hz: UInt64
        let callsigns: [String]
        let transmitting: Bool
        let lastActivity: Date
        let deltaHz: Int64
    }

    private var dialHz: UInt64 {
        viewModel.radioFrequencyHz > 0 ? viewModel.radioFrequencyHz : reporter.frequencyHz
    }

    private func groups(now: Date) -> [FrequencyGroup] {
        let dial = Int64(dialHz)
        var byKHz: [Int64: [ReporterStation]] = [:]
        for st in reporter.stations.values {
            guard let f = st.frequencyHz, f > 0,
                  abs(Int64(f) - dial) <= windowHz,
                  now.timeIntervalSince(st.lastUpdate) <= maxAge else { continue }
            byKHz[Int64(f) / 1000, default: []].append(st)
        }
        return byKHz.map { kHz, stations in
            let sorted = stations.sorted { $0.lastUpdate > $1.lastUpdate }
            return FrequencyGroup(
                id: kHz,
                hz: UInt64(kHz) * 1000,
                callsigns: sorted.map(\.callsign),
                transmitting: stations.contains { $0.transmitting },
                lastActivity: sorted.first?.lastUpdate ?? now,
                deltaHz: kHz * 1000 - dial
            )
        }
        .sorted { abs($0.deltaHz) < abs($1.deltaHz) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let list = groups(now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Band activity ±\(Int(windowHz / 1000)) kHz")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.3f MHz", Double(dialHz) / 1_000_000))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !reporter.isReady {
                    emptyLabel("FreeDV Reporter not connected")
                } else if list.isEmpty {
                    emptyLabel("No FreeDV activity nearby — try another band")
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(list) { group in
                                activityRow(group, now: context.date)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer()
        }
    }

    private func activityRow(_ group: FrequencyGroup, now: Date) -> some View {
        let onDial = abs(group.deltaHz) < 1000
        let shown = group.callsigns.prefix(3).joined(separator: " ")
        let more = group.callsigns.count > 3 ? " +\(group.callsigns.count - 3)" : ""

        return Button {
            if viewModel.radioConnected && !onDial {
                viewModel.tuneRadio(toHz: group.hz)
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(group.transmitting ? .red : .green.opacity(0.6))
                    .frame(width: 7, height: 7)

                Text(String(format: "%.3f", Double(group.hz) / 1_000_000))
                    .font(.system(size: 13, weight: onDial ? .bold : .semibold, design: .monospaced))
                    .foregroundStyle(onDial ? .green : .primary)

                Text(shown + more)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(group.transmitting ? .red : .secondary)
                    .lineLimit(1)

                Spacer()

                Text(ageText(now.timeIntervalSince(group.lastActivity)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(onDial ? Color.green.opacity(0.10) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func ageText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m"
    }
}
