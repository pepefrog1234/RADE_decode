//
//  IcomUDPStream.swift
//  FreeDV
//
//  UDP transport for the Icom LAN protocol. One `IcomUDPStream` per stream
//  (control / serial / audio). Handles the are-you-there handshake, ping/idle
//  keepalive, and retransmit request/response. Concrete subclasses implement
//  the per-stream state machine.
//
//  Ported from NetworkIcom's UDPBase/UDPControl/UDPSerial/UDPAudio (Swift
//  reference implementation) and wfview (GPLv3). All work runs on a dedicated
//  serial queue per stream; callbacks are invoked on that queue — the owner
//  (IcomRadioController) hops to the main actor as needed.
//

import Foundation
import Network

// MARK: - Base stream

class IcomUDPStream {
    let label: String
    let queue: DispatchQueue
    let builder: IcomPacketBuilder
    private(set) var connection: NWConnection?

    /// Diagnostics / lifecycle callbacks (invoked on `queue`).
    var onState: ((String) -> Void)?
    var onConnected: ((Bool) -> Void)?

    private let host: String
    private let port: UInt16

    // Keepalive / retry timers.
    private var pingTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var resendTimer: DispatchSourceTimer?

    var retryPacket = Data()
    var disconnecting = false
    private(set) var current = Data()

    private let pingInterval = 3.0
    private let idleInterval = 1.0
    private let retryInterval = 5.0

    // Retransmit tracking (bounded).
    private static let trackDepth = 20
    private var trackedOrder: [UInt16] = []
    private var trackedData: [UInt16: Data] = [:]
    private var totalRetransmit = 0

    private var lastPingSentAt = Date()
    private var lastPingSeq = UInt16(0)

    init(label: String, host: String, port: UInt16, builder: IcomPacketBuilder) {
        self.label = label
        self.host = host
        self.port = port
        self.builder = builder
        self.queue = DispatchQueue(label: "com.freedv.icom.\(label)")
    }

    // MARK: Lifecycle

    func start() {
        let params = NWParameters.udp
        params.allowFastOpen = true
        params.allowLocalEndpointReuse = true
        // Bind our local UDP port to the same number as the radio's stream port.
        // The radio associates TX audio (and CI-V) with the port we advertise in
        // the conninfo packet; without this our source port is random and the
        // radio won't route our TX audio to the modulator (RX still works because
        // replies follow the source port).
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any),
                                                           port: NWEndpoint.Port(integerLiteral: port))
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(integerLiteral: port),
                                using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handleStateChange(state) }
        }
        onState?("Connecting \(label)…")
        conn.start(queue: queue)
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let local = connection?.currentPath?.localEndpoint.map { "\($0)" } ?? "?"
            appLog("Icom[\(label)]: NWConnection ready (local=\(local))")
            startConnection()
            startReceive()
        case .failed(let error):
            appLog("Icom[\(label)]: connection failed: \(error)")
            onConnected?(false)
            onState?("Failed: \(error.localizedDescription)")
            connection = nil
        case .cancelled:
            appLog("Icom[\(label)]: connection cancelled")
            onConnected?(false)
            connection = nil
        default:
            break
        }
    }

    private func startReceive() {
        connection?.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let error {
                appLog("Icom[\(self.label)]: receive error: \(error)")
                self.connection?.cancel()
                self.onConnected?(false)
                return
            }
            if let content, !content.isEmpty {
                // Rebase to startIndex 0 so absolute offsets work.
                self.dispatchReceive(Data(content))
            }
            self.startReceive()
        }
    }

    private func dispatchReceive(_ data: Data) {
        current = data
        if checkRetransmitRequest() { return }
        receive(data: data)
    }

    /// Called once the socket is ready. Default: kick off the handshake.
    func startConnection() {
        disconnecting = false
        send(data: builder.disconnectPacket())
        armResendTimer()
        retryPacket = builder.areYouTherePacket()
        send(data: retryPacket)
    }

    /// Per-stream packet handling. Override in subclasses.
    func receive(data: Data) {}

    // MARK: Sending

    func send(data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    // MARK: Handshake helpers (shared across streams)

    /// Handle the two common 16-byte control replies. Returns true if handled.
    func handleControlHandshake(onIAmHere: () -> Void, onIAmReady: () -> Void) -> Bool {
        typealias c = ControlField
        guard current.count == ControlField.dataLength else { return false }
        switch current[c.type].u16 {
        case ControlPacketType.iAmHere:
            builder.remoteId = current[c.sendId].u32
            appLog("Icom[\(label)]: I-am-here, remoteId=\(builder.remoteId.map { String(format: "%08x", $0) } ?? "?")")
            onIAmHere()
            return true
        case ControlPacketType.iAmReady:
            appLog("Icom[\(label)]: I-am-ready")
            onIAmReady()
            return true
        default:
            return false
        }
    }

    func receivePing() {
        typealias c = ControlField
        typealias p = PingField
        if current[p.request].boolByte {
            if current[c.sequence].u16 == lastPingSeq {
                let latency = lastPingSentAt.timeIntervalSinceNow * -500.0
                _ = latency  // available for future UI
            }
        } else if current[c.recvId].u32 == builder.myId {
            send(data: builder.pingReply(to: current))
        } else {
            send(data: builder.disconnectPacket(replyTo: current))
        }
    }

    // MARK: Retransmit

    private func checkRetransmitRequest() -> Bool {
        typealias c = ControlField
        guard current.count >= ControlField.dataLength else { return false }
        guard current[c.type].u16 == ControlPacketType.retransmit else { return false }
        let sequences = parseRetransmitRequest(current)
        for s in sequences { send(data: tracked(sequence: s)) }
        totalRetransmit &+= sequences.count
        return true
    }

    private func parseRetransmitRequest(_ data: Data) -> [UInt16] {
        typealias c = ControlField
        if data.count == ControlField.dataLength {
            return [data[c.sequence].u16]
        }
        var result: [UInt16] = []
        var i = 16
        while i + 2 <= data.count {
            result.append(Data(data[i..<i+2]).u16)
            i += 4
        }
        return result
    }

    func track(data: Data) {
        typealias c = ControlField
        let s = data[c.sequence].u16
        if trackedOrder.count >= IcomUDPStream.trackDepth {
            let old = trackedOrder.removeFirst()
            trackedData.removeValue(forKey: old)
        }
        trackedOrder.append(s)
        trackedData[s] = data
    }

    private func tracked(sequence: UInt16) -> Data {
        trackedData[sequence] ?? builder.idlePacket(withSequence: sequence)
    }

    // MARK: Timers

    private func makeTimer(interval: TimeInterval, repeats: Bool, _ handler: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        if repeats {
            t.schedule(deadline: .now() + interval, repeating: interval)
        } else {
            t.schedule(deadline: .now() + interval)
        }
        t.setEventHandler(handler: handler)
        t.resume()
        return t
    }

    func armResendTimer() {
        resendTimer?.cancel()
        resendTimer = makeTimer(interval: retryInterval, repeats: false) { [weak self] in
            guard let self else { return }
            self.send(data: self.retryPacket)
            self.armIdleTimer()
            self.armResendTimer()
        }
    }

    func invalidateResendTimer() {
        resendTimer?.cancel()
        resendTimer = nil
    }

    func armIdleTimer() {
        idleTimer?.cancel()
        idleTimer = makeTimer(interval: idleInterval, repeats: false) { [weak self] in
            self?.onIdleTimer()
        }
    }

    func armPingTimer() {
        pingTimer?.cancel()
        pingTimer = makeTimer(interval: pingInterval, repeats: false) { [weak self] in
            guard let self else { return }
            typealias c = ControlField
            let packet = self.builder.pingPacket()
            self.lastPingSeq = packet[c.sequence].u16
            self.lastPingSentAt = Date()
            self.armIdleTimer()
            self.armPingTimer()
            self.send(data: packet)
        }
    }

    func onIdleTimer() {
        if disconnecting {
            invalidateTimers()
            disconnecting = false
            onState?("Disconnected \(label)")
            onConnected?(false)
            connection?.cancel()
        } else {
            armIdleTimer()
            send(data: builder.idlePacket())
        }
    }

    func invalidateTimers() {
        pingTimer?.cancel(); pingTimer = nil
        idleTimer?.cancel(); idleTimer = nil
        resendTimer?.cancel(); resendTimer = nil
    }

    func cancel() {
        invalidateTimers()
        connection?.cancel()
        connection = nil
    }
}
