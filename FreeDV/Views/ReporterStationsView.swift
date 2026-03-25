import SwiftUI

/// Displays online FreeDV Reporter stations grouped by band.
struct ReporterStationsView: View {
    var reporter: FreeDVReporter
    @AppStorage("hiddenCallsigns") private var hiddenCallsignsData: Data = Data()
    @State private var showReportAlert = false
    @State private var reportCallsign = ""
    
    private var hiddenCallsigns: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: hiddenCallsignsData)) ?? []
    }
    
    private func hideStation(_ callsign: String) {
        var hidden = hiddenCallsigns
        hidden.insert(callsign.uppercased())
        if let data = try? JSONEncoder().encode(hidden) {
            hiddenCallsignsData = data
        }
    }
    
    private func unhideAll() {
        hiddenCallsignsData = Data()
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedByBand, id: \.band) { group in
                    Section {
                        ForEach(group.stations) { station in
                            StationRow(station: station)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        hideStation(station.callsign)
                                    } label: {
                                        Label("Hide Station", systemImage: "eye.slash")
                                    }
                                    Button {
                                        reportCallsign = station.callsign
                                        showReportAlert = true
                                    } label: {
                                        Label("Report Content", systemImage: "exclamationmark.bubble")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text(group.band)
                                .font(.system(.subheadline, design: .monospaced, weight: .bold))
                            Spacer()
                            Text("\(group.stations.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Online Stations")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if reporter.isConnected {
                        Text("\(reporter.stations.count) online")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !hiddenCallsigns.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button("Unhide All") { unhideAll() }
                            .font(.caption)
                    }
                }
            }
            .alert("Report Station", isPresented: $showReportAlert) {
                Button("Send Report") {
                    if let url = URL(string: "https://github.com/drowe67/freedv-gui/issues") {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Report \(reportCallsign) for objectionable content? This will open the FreeDV project issue tracker where the server administrators can take action.")
            }
            .overlay {
                if reporter.stations.isEmpty {
                    if reporter.isConnected {
                        ContentUnavailableView(
                            "No Stations",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("Waiting for station data...")
                        )
                    } else {
                        ContentUnavailableView(
                            "Not Connected",
                            systemImage: "wifi.slash",
                            description: Text("Enable Reporter in Settings to see online stations.")
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Band Grouping
    
    struct BandGroup {
        let band: String
        let sortOrder: Int
        let stations: [ReporterStation]
    }
    
    var groupedByBand: [BandGroup] {
        let hidden = hiddenCallsigns
        let allStations = Array(reporter.stations.values)
            .filter { !hidden.contains($0.callsign.uppercased()) }
        var groups: [String: (order: Int, stations: [ReporterStation])] = [:]
        
        for station in allStations {
            let (band, order) = bandInfo(for: station.frequencyHz)
            groups[band, default: (order, [])].stations.append(station)
        }
        
        return groups.map { key, value in
            BandGroup(
                band: key,
                sortOrder: value.order,
                stations: value.stations.sorted { $0.lastUpdate > $1.lastUpdate }
            )
        }
        .sorted { $0.sortOrder < $1.sortOrder }
    }
    
    /// Map frequency to ham band name and sort order.
    private func bandInfo(for frequencyHz: UInt64?) -> (String, Int) {
        guard let freq = frequencyHz else { return ("Unknown", 999) }
        let mhz = Double(freq) / 1_000_000
        
        switch mhz {
        case 1.8..<2.0:    return ("160m – 1.8 MHz", 0)
        case 3.5..<4.0:    return ("80m – 3.5 MHz", 1)
        case 5.0..<5.5:    return ("60m – 5 MHz", 2)
        case 7.0..<7.3:    return ("40m – 7 MHz", 3)
        case 10.1..<10.15: return ("30m – 10 MHz", 4)
        case 14.0..<14.35: return ("20m – 14 MHz", 5)
        case 18.0..<18.17: return ("17m – 18 MHz", 6)
        case 21.0..<21.45: return ("15m – 21 MHz", 7)
        case 24.89..<24.99:return ("12m – 24 MHz", 8)
        case 28.0..<29.7:  return ("10m – 28 MHz", 9)
        case 50.0..<54.0:  return ("6m – 50 MHz", 10)
        case 144.0..<148.0:return ("2m – 144 MHz", 11)
        case 420.0..<450.0:return ("70cm – 430 MHz", 12)
        default:
            return (String(format: "%.3f MHz", mhz), 50)
        }
    }
}

// MARK: - Station Row

struct StationRow: View {
    let station: ReporterStation
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(station.callsign)
                        .font(.system(.body, design: .monospaced, weight: .bold))
                    if station.rxOnly {
                        Text("RX")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if station.transmitting {
                        Text("TX")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                
                HStack(spacing: 8) {
                    if !station.gridSquare.isEmpty {
                        Text(station.gridSquare)
                    }
                    if let mode = station.mode {
                        Text(mode)
                    }
                    if let lastRx = station.lastRxCallsign, !lastRx.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 8))
                            Text(lastRx)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                
                if let message = station.message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                if let freq = station.frequencyHz {
                    Text(String(format: "%.3f", Double(freq) / 1_000_000))
                        .font(.system(.caption, design: .monospaced))
                }
                if let snr = station.lastRxSNR {
                    Text(String(format: "SNR %+.0f", snr))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            
            Circle()
                .fill(stationColor)
                .frame(width: 8, height: 8)
        }
    }
    
    var stationColor: Color {
        if station.transmitting { return .red }
        if station.lastRxCallsign != nil { return .green }
        return .blue
    }
}

#Preview {
    ReporterStationsView(reporter: FreeDVReporter())
}
