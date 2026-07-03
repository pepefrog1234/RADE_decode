import Foundation
import Network
#if os(iOS)
import UIKit
#endif

// MARK: - ReporterStation Model

struct ReporterStation: Identifiable {
    let sid: String
    var callsign: String
    var gridSquare: String
    var version: String
    var rxOnly: Bool
    var frequencyHz: UInt64?
    var mode: String?
    var transmitting: Bool = false
    var lastRxCallsign: String?         // decoded TX callsign (sticky, cleared by timeout)
    var lastRxSNR: Double?
    var lastRxDate: Date?               // when any rx_report was last received (= receivingAt)
    var receivedCallsignAt: Date?       // when lastRxCallsign was last set non-empty
    var lastUpdate: Date
    var message: String?
    
    var id: String { sid }
}

// MARK: - FreeDVReporter

/// Socket.IO v4 client for FreeDV Reporter (qso.freedv.org).
/// Uses URLSessionWebSocketTask with manual Engine.IO/Socket.IO framing — no external dependencies.
@Observable
class FreeDVReporter {
    
    // MARK: - User Settings (stored properties synced to UserDefaults)
    
    var callsign: String = "" {
        didSet {
            guard didFinishInit else { return }
            UserDefaults.standard.set(callsign, forKey: "reporter_callsign")
        }
    }
    var gridSquare: String = "" {
        didSet {
            guard didFinishInit else { return }
            UserDefaults.standard.set(gridSquare, forKey: "reporter_grid_square")
        }
    }
    var frequencyHz: UInt64 = 14_236_000 {
        didSet {
            guard didFinishInit else { return }
            UserDefaults.standard.set(Int(frequencyHz), forKey: "reporter_frequency_hz")
            if isReady { sendFreqChange() }
        }
    }
    var statusMessage: String = "" {
        didSet {
            guard didFinishInit else { return }
            UserDefaults.standard.set(statusMessage, forKey: "reporter_message")
        }
    }
    var isEnabled: Bool = false {
        didSet {
            guard didFinishInit else { return }
            UserDefaults.standard.set(isEnabled, forKey: "reporter_enabled")
            updateConnection()
        }
    }
    
    // MARK: - Connection State
    
    var isConnected = false
    /// True after server sends `connection_successful` — only then can we send rx_report
    var isReady = false
    
    // MARK: - Online Stations
    
    var stations: [String: ReporterStation] = [:]
    
    // MARK: - Private
    
    @ObservationIgnored private var webSocket: URLSessionWebSocketTask?
    @ObservationIgnored private var urlSession: URLSession?
    @ObservationIgnored private var reconnectDelay: TimeInterval = 5
    @ObservationIgnored private var shouldReconnect = false
    @ObservationIgnored private var didFinishInit = false
    
    @ObservationIgnored private let serverURL = "wss://qso.freedv.org/socket.io/?EIO=4&transport=websocket"
    @ObservationIgnored private let protocolVersion = 2
    @ObservationIgnored private var wasSuspendedForBackground = false
    
    // Network monitoring for WiFi ↔ cellular transitions
    @ObservationIgnored private let networkMonitor = NWPathMonitor()
    @ObservationIgnored private var hasNetwork = true
    
    init() {
        // Load persisted settings (didSet guards prevent side effects)
        callsign = UserDefaults.standard.string(forKey: "reporter_callsign") ?? ""
        gridSquare = UserDefaults.standard.string(forKey: "reporter_grid_square") ?? ""
        let v = UserDefaults.standard.integer(forKey: "reporter_frequency_hz")
        frequencyHz = v > 0 ? UInt64(v) : 14_236_000
        statusMessage = UserDefaults.standard.string(forKey: "reporter_message") ?? ""
        isEnabled = UserDefaults.standard.bool(forKey: "reporter_enabled")
        
        didFinishInit = true
        startNetworkMonitoring()
        
        // Auto-connect on launch if enabled
        if isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.connect()
            }
        }
    }
    
    deinit {
        disconnect()
        networkMonitor.cancel()
    }
    
    // MARK: - Connect / Disconnect
    
    func updateConnection() {
        if isEnabled {
            if !isConnected {
                connect()
            }
        } else {
            disconnect()
        }
    }
    
    func connect() {
        guard !isConnected else { return }
        shouldReconnect = true
        reconnectDelay = 5
        
        guard let url = URL(string: serverURL) else {
            appLog("Reporter: invalid URL")
            return
        }
        
        urlSession = URLSession(configuration: .default)
        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()
        
        appLog("Reporter: connecting to qso.freedv.org...")
        receiveMessage()
    }
    
    func disconnect() {
        shouldReconnect = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.isReady = false
            self.stations.removeAll()
        }
        appLog("Reporter: disconnected")
    }

    // MARK: - App Lifecycle

    /// Called when app enters background to avoid long-lived stale sockets.
    func suspendForBackground() {
        guard isEnabled else { return }
        wasSuspendedForBackground = true
        disconnect()
    }

    /// Called when app returns to foreground to restore reporter connection.
    func resumeFromBackground() {
        guard wasSuspendedForBackground else { return }
        wasSuspendedForBackground = false
        guard isEnabled else { return }
        connect()
    }
    
    // MARK: - WebSocket Message Loop
    
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue listening
                self.receiveMessage()
                
            case .failure(let error):
                appLog("Reporter: WebSocket error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isReady = false
                }
                self.scheduleReconnect()
            }
        }
    }
    
    // MARK: - Engine.IO / Socket.IO Message Parsing
    
    private func handleMessage(_ raw: String) {
        guard !raw.isEmpty else { return }
        
        // Engine.IO packet type is the first character
        guard let typeChar = raw.first, let type = typeChar.wholeNumberValue else { return }
        let payload = String(raw.dropFirst())
        
        switch type {
        case 0:
            // Engine.IO OPEN — contains {sid, pingInterval, pingTimeout}
            handleEngineOpen(payload)
            
        case 2:
            // Engine.IO PING from server — respond with PONG
            sendRaw("3")
            
        case 4:
            // Socket.IO packet — second digit is Socket.IO type
            handleSocketIOPacket(payload)
            
        default:
            break
        }
    }
    
    private func handleEngineOpen(_ payload: String) {
        appLog("Reporter: Engine.IO open")
        // Send Socket.IO CONNECT with auth payload
        sendSocketIOConnect()
    }
    
    private func handleSocketIOPacket(_ payload: String) {
        guard !payload.isEmpty, let sioType = payload.first?.wholeNumberValue else { return }
        let sioPayload = String(payload.dropFirst())
        
        switch sioType {
        case 0:
            // Socket.IO CONNECT ACK — {"sid":"..."}
            DispatchQueue.main.async {
                self.isConnected = true
            }
            appLog("Reporter: Socket.IO connected")
            
        case 2:
            // Socket.IO EVENT — ["event_name", {data}]
            handleSocketIOEvent(sioPayload)
            
        case 4:
            // Socket.IO ERROR
            appLog("Reporter: Socket.IO error: \(sioPayload)")
            
        default:
            break
        }
    }
    
    private func handleSocketIOEvent(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let eventName = array.first as? String else { return }
        
        let eventData = array.count > 1 ? array[1] : nil
        
        switch eventName {
        case "connection_successful":
            DispatchQueue.main.async {
                self.isReady = true
            }
            appLog("Reporter: connection_successful — ready to send reports")
            // Send initial state
            sendFreqChange()
            if !statusMessage.isEmpty {
                sendMessageUpdate()
            }
            
        case "new_connection":
            if let dict = eventData as? [String: Any] {
                handleNewConnection(dict)
            }
            
        case "remove_connection":
            if let dict = eventData as? [String: Any], let sid = dict["sid"] as? String {
                DispatchQueue.main.async {
                    self.stations.removeValue(forKey: sid)
                    // RX links on other stations are NOT cleared — timeout handles it
                }
            }
            
        case "bulk_update":
            if let updates = eventData as? [[Any]] {
                handleBulkUpdate(updates)
            }
            
        case "rx_report":
            if let dict = eventData as? [String: Any] {
                handleRxReport(dict)
            }
            
        case "freq_change":
            if let dict = eventData as? [String: Any] {
                handleFreqChange(dict)
            }
            
        case "tx_report":
            if let dict = eventData as? [String: Any] {
                handleTxReport(dict)
            }
            
        case "message_update":
            if let dict = eventData as? [String: Any],
               let sid = dict["sid"] as? String {
                DispatchQueue.main.async {
                    self.stations[sid]?.message = dict["message"] as? String
                    self.stations[sid]?.lastUpdate = Date()
                }
            }
            
        default:
            break
        }
    }
    
    // MARK: - Send Messages (Client → Server)
    
    private func sendSocketIOConnect() {
        var auth: [String: Any]
        
        if callsign.isEmpty || gridSquare.isEmpty {
            // View-only mode
            auth = [
                "role": "view",
                "protocol_version": protocolVersion
            ]
            appLog("Reporter: connecting as viewer (no callsign)")
        } else {
            var osVersion = "iOS"
            #if os(iOS)
            osVersion = "iOS \(UIDevice.current.systemVersion)"
            #endif

            // RX-only SWL unless the IC-705 WiFi transmit path is available.
            // (Evaluated at connect time; changing the audio source while
            // connected takes effect on the next reconnect.)
            let rxOnly = !(RadioSettings.audioInputSource == .icomRadio && RadioSettings.enableTx)
            auth = [
                "role": "report",
                "callsign": callsign.uppercased(),
                "grid_square": gridSquare,
                "version": "RADE Decode iOS \(Bundle.main.shortVersion)",
                "rx_only": rxOnly,
                "os": osVersion,
                "protocol_version": protocolVersion
            ]
            appLog("Reporter: connecting as \(callsign.uppercased()) (\(gridSquare)) rxOnly=\(rxOnly)")
        }
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: auth),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            sendRaw("40\(jsonStr)")
        }
    }
    
    /// Send freq_change event
    func sendFreqChange() {
        sendEvent("freq_change", ["freq": frequencyHz])
    }
    
    /// Send rx_report when EOO callsign is decoded
    func reportRx(callsign: String, snr: Int) {
        guard isReady else { return }
        sendEvent("rx_report", [
            "callsign": callsign,
            "mode": "RADEV1",
            "snr": snr
        ])
        appLog("Reporter: rx_report sent — \(callsign) SNR=\(snr)")
    }

    /// Report our transmit state (PTT down/up) — the site highlights the
    /// station while it is transmitting.
    func reportTx(transmitting: Bool) {
        guard isReady else { return }
        sendEvent("tx_report", [
            "mode": "RADEV1",
            "transmitting": transmitting
        ])
        appLog("Reporter: tx_report sent — transmitting=\(transmitting)")
    }
    
    /// Send status message update
    func sendMessageUpdate() {
        sendEvent("message_update", ["message": statusMessage])
    }
    
    private func sendEvent(_ event: String, _ data: [String: Any]) {
        let array: [Any] = [event, data]
        if let jsonData = try? JSONSerialization.data(withJSONObject: array),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            sendRaw("42\(jsonStr)")
        }
    }
    
    private func sendRaw(_ text: String) {
        webSocket?.send(.string(text)) { error in
            if let error {
                appLog("Reporter: send error: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Reconnect
    
    private func scheduleReconnect() {
        guard shouldReconnect, hasNetwork else { return }
        appLog("Reporter: reconnecting in \(Int(reconnectDelay))s...")
        DispatchQueue.global().asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.connect()
        }
        // Exponential backoff, max 30s
        reconnectDelay = min(reconnectDelay * 1.5, 30)
    }
    
    // MARK: - Network Monitoring
    
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasConnected = self.hasNetwork
            self.hasNetwork = path.status == .satisfied
            
            if self.hasNetwork && !wasConnected && self.shouldReconnect && !self.isConnected {
                appLog("Reporter: network restored, reconnecting...")
                self.reconnectDelay = 5
                self.connect()
            }
        }
        networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }
    
    // MARK: - Server Event Handlers
    
    private func handleNewConnection(_ dict: [String: Any]) {
        guard let sid = dict["sid"] as? String,
              let cs = dict["callsign"] as? String else { return }
        
        let station = ReporterStation(
            sid: sid,
            callsign: cs.uppercased(),
            gridSquare: (dict["grid_square"] as? String) ?? "",
            version: (dict["version"] as? String) ?? "",
            rxOnly: (dict["rx_only"] as? Bool) ?? false,
            frequencyHz: (dict["freq"] as? NSNumber)?.uint64Value,
            transmitting: (dict["transmitting"] as? Bool) ?? false,
            lastUpdate: Date(),
            message: dict["message"] as? String
        )
        DispatchQueue.main.async {
            // Preserve RX data if station was already created from an earlier rx_report
            let existing = self.stations[sid]
            self.stations[sid] = station
            if existing?.lastRxDate != nil {
                self.stations[sid]?.lastRxCallsign = existing?.lastRxCallsign
                self.stations[sid]?.lastRxSNR = existing?.lastRxSNR
                self.stations[sid]?.lastRxDate = existing?.lastRxDate
                self.stations[sid]?.receivedCallsignAt = existing?.receivedCallsignAt
            }
        }
    }
    
    private func handleBulkUpdate(_ updates: [[Any]]) {
        for update in updates {
            guard update.count >= 2,
                  let eventName = update[0] as? String,
                  let eventData = update[1] as? [String: Any] else { continue }
            
            switch eventName {
            case "new_connection":
                handleNewConnection(eventData)
            case "freq_change":
                handleFreqChange(eventData)
            case "tx_report":
                handleTxReport(eventData)
            case "rx_report":
                handleRxReport(eventData)
            default:
                break
            }
        }
    }
    
    private func handleRxReport(_ dict: [String: Any]) {
        guard let sid = dict["sid"] as? String else { return }
        let raw = (dict["callsign"] as? String)?.uppercased()
        let hasCallsign = raw != nil && !raw!.isEmpty

        // Use server's last_update timestamp if available (bulk_update),
        // otherwise current time (real-time event).
        let eventTime: Date
        if let ts = dict["last_update"] as? Double {
            eventTime = Date(timeIntervalSince1970: ts)
        } else if let ts = dict["last_update"] as? Int {
            eventTime = Date(timeIntervalSince1970: Double(ts))
        } else {
            eventTime = Date()
        }

        DispatchQueue.main.async {
            if self.stations[sid] != nil {
                // Always mark as receiving and update SNR
                self.stations[sid]?.lastRxDate = eventTime
                self.stations[sid]?.lastUpdate = eventTime
                if let snr = (dict["snr"] as? NSNumber)?.doubleValue {
                    self.stations[sid]?.lastRxSNR = snr
                }
                // Only update callsign if non-empty (sticky)
                if hasCallsign {
                    self.stations[sid]?.lastRxCallsign = raw
                    self.stations[sid]?.receivedCallsignAt = eventTime
                }
            } else if let receiverCallsign = dict["receiver_callsign"] as? String {
                // Station not yet created (rx_report arrived before new_connection in bulk_update)
                self.stations[sid] = ReporterStation(
                    sid: sid,
                    callsign: receiverCallsign.uppercased(),
                    gridSquare: (dict["receiver_grid_square"] as? String) ?? "",
                    version: "",
                    rxOnly: false,
                    lastRxCallsign: hasCallsign ? raw : nil,
                    lastRxSNR: (dict["snr"] as? NSNumber)?.doubleValue,
                    lastRxDate: eventTime,
                    receivedCallsignAt: hasCallsign ? eventTime : nil,
                    lastUpdate: eventTime
                )
            }
        }
    }
    
    private func handleFreqChange(_ dict: [String: Any]) {
        guard let sid = dict["sid"] as? String else { return }
        DispatchQueue.main.async {
            self.stations[sid]?.frequencyHz = (dict["freq"] as? NSNumber)?.uint64Value
            self.stations[sid]?.lastUpdate = Date()
        }
    }
    
    private func handleTxReport(_ dict: [String: Any]) {
        guard let sid = dict["sid"] as? String else { return }
        let isTransmitting = (dict["transmitting"] as? Bool) ?? false
        DispatchQueue.main.async {
            self.stations[sid]?.transmitting = isTransmitting
            self.stations[sid]?.mode = dict["mode"] as? String
            self.stations[sid]?.lastUpdate = Date()
            // RX state on other stations is NOT cleared here — timeout handles it
        }
    }
}

// MARK: - Bundle Extension

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
