import SwiftUI

/// Shown in place of the spectrum/waterfall while transmitting (half-duplex —
/// there is nothing to see there anyway): a live list of FreeDV Reporter
/// stations on our frequency and what they are hearing. Rows whose heard
/// callsign is ours are highlighted — those stations are receiving this
/// transmission. Kept on screen briefly after the over ends because the
/// callsign confirmations (EOO decodes) mostly arrive right at that moment.
struct TxReportsView: View {
    var reporter: FreeDVReporter
    /// True while PTT is down; false during the post-over hold.
    var isTransmitting: Bool

    /// Stations count as "on frequency" within this dial tolerance.
    private let freqToleranceHz: Int64 = 1_000
    /// Only reports newer than this are listed.
    private let maxReportAge: TimeInterval = 120

    private struct ReportRow: Identifiable {
        let id: String
        let station: String
        let heard: String?
        let snr: Double?
        let date: Date
        let hearsUs: Bool
    }

    private func rows(now: Date) -> [ReportRow] {
        let ourFreq = Int64(reporter.frequencyHz)
        let us = reporter.callsign.uppercased()
        return reporter.stations.values
            .filter { st in
                guard st.callsign != us else { return false }
                guard let f = st.frequencyHz,
                      abs(Int64(f) - ourFreq) <= freqToleranceHz else { return false }
                guard let d = st.lastRxDate,
                      now.timeIntervalSince(d) <= maxReportAge else { return false }
                return true
            }
            .map { st in
                ReportRow(id: st.sid,
                          station: st.callsign,
                          heard: st.lastRxCallsign,
                          snr: st.lastRxSNR,
                          date: st.lastRxDate ?? st.lastUpdate,
                          hearsUs: !us.isEmpty && st.lastRxCallsign == us)
            }
            .sorted { a, b in
                if a.hearsUs != b.hearsUs { return a.hearsUs }
                return a.date > b.date
            }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let list = rows(now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isTransmitting
                          ? "dot.radiowaves.up.forward" : "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(isTransmitting ? .red : .secondary)
                    Text(isTransmitting
                         ? "ON AIR — who hears this frequency"
                         : "Last over — reception reports")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isTransmitting ? .red.opacity(0.95) : .secondary)
                    Spacer()
                    Text(String(format: "%.3f MHz", Double(reporter.frequencyHz) / 1_000_000))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !reporter.isReady {
                    emptyLabel("FreeDV Reporter not connected")
                } else if list.isEmpty {
                    emptyLabel("No reception reports on this frequency yet")
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(list) { row in
                                reportRow(row, now: context.date)
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

    private func reportRow(_ row: ReportRow, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(row.station)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(row.hearsUs ? .green : .primary)
                .lineLimit(1)

            Image(systemName: "ear")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(row.heard ?? "—")
                .font(.system(size: 13, weight: row.hearsUs ? .bold : .regular, design: .monospaced))
                .foregroundStyle(row.hearsUs ? .green : .secondary)
                .lineLimit(1)

            Spacer()

            if let snr = row.snr {
                Text(String(format: "%.0f dB", snr))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(row.hearsUs ? .green : .primary)
            }

            Text(ageText(now.timeIntervalSince(row.date)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(row.hearsUs ? Color.green.opacity(0.12) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func ageText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60)s"
    }
}
