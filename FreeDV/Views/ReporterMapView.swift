import SwiftUI
import MapKit

/// Map view showing online FreeDV Reporter stations and TX→RX link lines.
struct ReporterMapView: View {
    var reporter: FreeDVReporter
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshId = UUID()
    @State private var showLegend = false

    var body: some View {
        // TimelineView forces periodic re-evaluation so Map content stays in sync
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let _ = refreshId   // force re-eval on foreground return
            let groups = rxLinkGroups
            let annotations = stationAnnotations
            Map {
                // TX→RX link lines
                ForEach(groups, id: \.txCallsign) { group in
                    ForEach(group.links) { link in
                        MapPolyline(
                            coordinates: [link.txCoord, link.rxCoord],
                            contourStyle: .geodesic
                        )
                        .stroke(link.color, lineWidth: link.lineWidth)

                        // Arrowhead at RX end, pointing TX→RX
                        MapPolygon(coordinates: arrowHead(from: link.txCoord, to: link.rxCoord))
                            .foregroundStyle(link.color)

                        // SNR badge at midpoint
                        Annotation("", coordinate: link.midpoint) {
                            Text(String(format: "%+.0f dB", link.snr))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(link.color.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }

                // Station annotations
                ForEach(annotations) { station in
                    Annotation("", coordinate: station.coordinate) {
                        StationPin(
                            callsign: station.callsign,
                            color: station.color,
                            transmitting: station.transmitting,
                            frequencyHz: station.frequencyHz,
                            lastRxCallsign: station.lastRxCallsign,
                            lastRxSNR: station.lastRxSNR
                        )
                    }
                }

                // TX hub labels (for TX stations not online, shown as ghost marker)
                ForEach(groups, id: \.txCallsign) { group in
                    if !group.txIsOnline {
                        Annotation("", coordinate: group.hubCoord) {
                            VStack(spacing: 2) {
                                ZStack {
                                    Circle()
                                        .fill(.red.opacity(0.5))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                Text(group.txCallsign)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            if stationAnnotations.isEmpty {
                emptyState
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showLegend = true
            } label: {
                Image(systemName: "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(12)
            }
        }
        .sheet(isPresented: $showLegend) {
            MapLegendView()
                .presentationDetents([.medium])
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                refreshId = UUID()
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if !reporter.isConnected {
            ContentUnavailableView(
                "Not Connected",
                systemImage: "wifi.slash",
                description: Text("Enable Reporter in Settings to see stations on the map.")
            )
        } else {
            ContentUnavailableView(
                "No Station Locations",
                systemImage: "map",
                description: Text("Waiting for stations with grid squares…")
            )
        }
    }

    // MARK: - Timeout

    /// Freshness window for "receiving" state. Clients report at different
    /// cadences while synced (freedv-gui ~0.5 s, wfweb ~4 s, RADE Decode iOS
    /// builds ≤1.2 every 10 s), so anything under ~10 s makes slower
    /// reporters' dots flap green↔gray between reports. qso.freedv.org keeps
    /// its highlight for 20 s after the last report; 15 s is close to that
    /// while still decaying reasonably fast after an over ends.
    private let rxTimeout: TimeInterval = 15

    /// True if station has had an rx_report within the timeout window.
    private func isReceiving(_ station: ReporterStation) -> Bool {
        guard let date = station.lastRxDate else { return false }
        return date.timeIntervalSinceNow > -rxTimeout
    }

    /// True if station has a decoded callsign within the timeout window.
    private func hasActiveCallsign(_ station: ReporterStation) -> Bool {
        guard station.lastRxCallsign != nil,
              let date = station.receivedCallsignAt else { return false }
        return date.timeIntervalSinceNow > -rxTimeout
    }

    // MARK: - Inferred TX

    /// Callsigns that are actively being received by at least one station (inferred TX).
    private var inferredTxCallsigns: Set<String> {
        var result = Set<String>()
        for station in reporter.stations.values {
            if hasActiveCallsign(station),
               let tx = station.lastRxCallsign?.uppercased(), !tx.isEmpty {
                result.insert(tx)
            }
        }
        return result
    }

    // MARK: - Station Annotations

    private var stationAnnotations: [StationAnnotation] {
        let inferred = inferredTxCallsigns
        return reporter.stations.values.compactMap { station in
            guard !station.gridSquare.isEmpty,
                  let coord = MaidenheadConverter.coordinates(from: station.gridSquare)
            else { return nil }

            let receiving = isReceiving(station)
            let activeCallsign = hasActiveCallsign(station)
            let isTx = station.transmitting || inferred.contains(station.callsign.uppercased())

            let color: Color
            if isTx {
                color = .red
            } else if receiving || activeCallsign {
                color = .green
            } else {
                color = .gray
            }

            return StationAnnotation(
                id: "\(station.sid)_\(station.lastRxCallsign ?? "")_\(station.lastRxSNR ?? -999)_\(isTx)_\(receiving)_\(station.frequencyHz ?? 0)",
                callsign: station.callsign,
                coordinate: coord,
                color: color,
                transmitting: isTx,
                frequencyHz: station.frequencyHz,
                lastRxCallsign: activeCallsign ? station.lastRxCallsign : nil,
                lastRxSNR: activeCallsign ? station.lastRxSNR : nil
            )
        }
    }

    // MARK: - RX Link Groups

    /// Groups stations by the TX callsign they received, computes a hub
    /// position (TX station's grid if online, otherwise centroid of receivers),
    /// and builds link lines from hub to each receiver.
    private var rxLinkGroups: [RXLinkGroup] {
        let allStations = Array(reporter.stations.values)

        // callsign → coordinate for online stations
        var callsignCoords: [String: CLLocationCoordinate2D] = [:]
        for station in allStations {
            guard !station.gridSquare.isEmpty,
                  let coord = MaidenheadConverter.coordinates(from: station.gridSquare)
            else { continue }
            callsignCoords[station.callsign.uppercased()] = coord
        }

        // Group RX stations by the TX callsign they heard (only if callsign still active)
        var groups: [String: [(coord: CLLocationCoordinate2D, snr: Double, rxCallsign: String)]] = [:]
        for station in allStations {
            guard hasActiveCallsign(station),
                  let txCallsign = station.lastRxCallsign?.uppercased(),
                  !txCallsign.isEmpty,
                  station.callsign.uppercased() != txCallsign,
                  let rxCoord = callsignCoords[station.callsign.uppercased()]
            else { continue }
            let snr = station.lastRxSNR ?? 0
            groups[txCallsign, default: []].append((rxCoord, snr, station.callsign))
        }

        var result: [RXLinkGroup] = []
        for (txCallsign, receivers) in groups {
            // Hub = TX station's position if online, otherwise centroid of receivers
            let hubCoord: CLLocationCoordinate2D
            if let txCoord = callsignCoords[txCallsign] {
                hubCoord = txCoord
            } else {
                let avgLat = receivers.map(\.coord.latitude).reduce(0, +) / Double(receivers.count)
                let avgLon = receivers.map(\.coord.longitude).reduce(0, +) / Double(receivers.count)
                hubCoord = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            }
            let txIsOnline = callsignCoords[txCallsign] != nil

            var links: [RXLink] = []
            for rx in receivers {
                // Skip zero-length links (same grid square)
                let dLat = abs(hubCoord.latitude - rx.coord.latitude)
                let dLon = abs(hubCoord.longitude - rx.coord.longitude)
                guard dLat > 0.001 || dLon > 0.001 else { continue }

                links.append(RXLink(
                    id: "\(txCallsign)->\(rx.rxCallsign)_\(rx.snr)",
                    txCoord: hubCoord,
                    rxCoord: rx.coord,
                    snr: rx.snr,
                    color: snrColor(rx.snr),
                    inferred: false,
                    lineWidth: 2.5
                ))
            }

            result.append(RXLinkGroup(
                txCallsign: txCallsign,
                hubCoord: hubCoord,
                txIsOnline: txIsOnline,
                links: links
            ))
        }
        // --- Inferred links: TX transmitting + RX receiving, same frequency ±5kHz ---
        let confirmedRxCallsigns = Set(result.flatMap { $0.links.map { $0.id } })

        // Collect TX stations (explicitly transmitting)
        let txStations = allStations.filter { $0.transmitting && !$0.gridSquare.isEmpty }
        // Collect RX stations (receiving but no active decoded callsign)
        let rxStations = allStations.filter {
            isReceiving($0) && !hasActiveCallsign($0) && !$0.gridSquare.isEmpty
        }

        for tx in txStations {
            guard let txFreq = tx.frequencyHz, txFreq > 0,
                  let txCoord = callsignCoords[tx.callsign.uppercased()] else { continue }
            var inferredLinks: [RXLink] = []
            for rx in rxStations {
                guard let rxFreq = rx.frequencyHz, rxFreq > 0,
                      rx.callsign.uppercased() != tx.callsign.uppercased(),
                      abs(Int64(txFreq) - Int64(rxFreq)) <= 5000,
                      let rxCoord = callsignCoords[rx.callsign.uppercased()]
                else { continue }

                let snr = rx.lastRxSNR ?? 0
                let linkId = "\(tx.callsign)~>\(rx.callsign)"
                guard !confirmedRxCallsigns.contains(linkId) else { continue }

                let dLat = abs(txCoord.latitude - rxCoord.latitude)
                let dLon = abs(txCoord.longitude - rxCoord.longitude)
                guard dLat > 0.001 || dLon > 0.001 else { continue }

                inferredLinks.append(RXLink(
                    id: "\(linkId)_\(snr)",
                    txCoord: txCoord,
                    rxCoord: rxCoord,
                    snr: rx.lastRxSNR ?? 0,
                    color: Color.blue.opacity(0.6),
                    inferred: true,
                    lineWidth: 1.5
                ))
            }
            if !inferredLinks.isEmpty {
                result.append(RXLinkGroup(
                    txCallsign: tx.callsign,
                    hubCoord: txCoord,
                    txIsOnline: true,
                    links: inferredLinks
                ))
            }
        }

        return result
    }

    private func snrColor(_ snr: Double) -> Color {
        if snr > 10 { return .green.opacity(0.8) }
        if snr > 4 { return .yellow.opacity(0.8) }
        return .orange.opacity(0.8)
    }



    /// Builds a triangle (3 coordinates) forming an arrowhead at the RX end of a link.
    /// Uses cos(latitude)-scaled space so the triangle is symmetric at any latitude.
    private func arrowHead(from tx: CLLocationCoordinate2D, to rx: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let midLat = (tx.latitude + rx.latitude) / 2.0
        let cosLat = cos(midLat * .pi / 180.0)
        guard cosLat > 0.001 else { return [rx, rx, rx] }

        // Work in scaled space: x = lon * cosLat, y = lat
        let dx = (rx.longitude - tx.longitude) * cosLat
        let dy = rx.latitude - tx.latitude
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0.001 else { return [rx, rx, rx] }

        let ndx = dx / len
        let ndy = dy / len

        let arrowLen = max(0.06, min(0.6, len * 0.15))
        let arrowWidth = arrowLen * 0.45

        // Base point in scaled space (back from RX toward TX)
        let rxX = rx.longitude * cosLat
        let rxY = rx.latitude
        let baseX = rxX - arrowLen * ndx
        let baseY = rxY - arrowLen * ndy

        // Perpendicular in scaled space: rotate (ndx, ndy) 90° → (-ndy, ndx)
        let left  = CLLocationCoordinate2D(latitude: baseY + arrowWidth * ndx,
                                           longitude: (baseX - arrowWidth * ndy) / cosLat)
        let right = CLLocationCoordinate2D(latitude: baseY - arrowWidth * ndx,
                                           longitude: (baseX + arrowWidth * ndy) / cosLat)
        return [left, rx, right]
    }
}

// MARK: - Data Models

private struct StationAnnotation: Identifiable {
    let id: String
    let callsign: String
    let coordinate: CLLocationCoordinate2D
    let color: Color
    let transmitting: Bool
    let frequencyHz: UInt64?
    let lastRxCallsign: String?
    let lastRxSNR: Double?
}

private struct RXLinkGroup {
    let txCallsign: String
    let hubCoord: CLLocationCoordinate2D
    let txIsOnline: Bool
    let links: [RXLink]
}

private struct RXLink: Identifiable {
    let id: String
    let txCoord: CLLocationCoordinate2D
    let rxCoord: CLLocationCoordinate2D
    let snr: Double
    let color: Color
    let inferred: Bool       // true = frequency-matched guess, false = confirmed callsign
    let lineWidth: CGFloat

    var midpoint: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (txCoord.latitude + rxCoord.latitude) / 2,
            longitude: (txCoord.longitude + rxCoord.longitude) / 2
        )
    }
}

// MARK: - Station Pin

private struct StationPin: View {
    let callsign: String
    let color: Color
    let transmitting: Bool
    var frequencyHz: UInt64? = nil
    var lastRxCallsign: String? = nil
    var lastRxSNR: Double? = nil

    private var freqMHz: String? {
        guard let hz = frequencyHz, hz > 0 else { return nil }
        return String(format: "%.3f", Double(hz) / 1_000_000)
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 28, height: 28)
                Image(systemName: transmitting
                    ? "antenna.radiowaves.left.and.right"
                    : "radio")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(callsign)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            // Frequency + SNR line
            if freqMHz != nil || lastRxSNR != nil {
                HStack(spacing: 3) {
                    if let freq = freqMHz {
                        Text(freq)
                    }
                    if let snr = lastRxSNR {
                        Text(String(format: "%+.0fdB", snr))
                    }
                }
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(color.opacity(0.7))
            }
            // RX callsign badge
            if let rx = lastRxCallsign, !rx.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 6))
                    Text(rx)
                }
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}

// MARK: - Map Legend

private struct MapLegendView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("map_legend_station_colors")) {
                    LegendRow(color: .red, symbol: "antenna.radiowaves.left.and.right",
                              text: Text("map_legend_tx"))
                    LegendRow(color: .green, symbol: "radio",
                              text: Text("map_legend_rx"))
                    LegendRow(color: .gray, symbol: "radio",
                              text: Text("map_legend_idle"))
                }

                Section(header: Text("map_legend_links")) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.green)
                            .frame(width: 30, height: 3)
                        Text("map_legend_confirmed_link")
                            .font(.subheadline)
                    }
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.blue.opacity(0.6))
                            .frame(width: 30, height: 2)
                        Text("map_legend_inferred_link")
                            .font(.subheadline)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text("map_legend_arrow")
                            .font(.subheadline)
                    }
                    HStack(spacing: 10) {
                        Text("+5 dB")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text("map_legend_snr_badge")
                            .font(.subheadline)
                    }
                }

                Section(header: Text("map_legend_snr_colors")) {
                    LegendColorRow(color: .green.opacity(0.8), text: Text("map_legend_snr_good"))
                    LegendColorRow(color: .yellow.opacity(0.8), text: Text("map_legend_snr_fair"))
                    LegendColorRow(color: .orange.opacity(0.8), text: Text("map_legend_snr_weak"))
                }

                Section {
                    Text("map_legend_note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Text("map_legend_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Text("Close")
                    }
                }
            }
        }
    }
}

private struct LegendRow: View {
    let color: Color
    let symbol: String
    let text: Text

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 24, height: 24)
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            text.font(.subheadline)
        }
    }
}

private struct LegendColorRow: View {
    let color: Color
    let text: Text

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 24, height: 14)
            text.font(.subheadline)
        }
    }
}
