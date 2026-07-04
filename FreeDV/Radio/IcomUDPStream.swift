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

    // Ping every 500 ms (wfview's PING_PERIOD): during transmit the HF field
    // stresses the 2.4 GHz link, and at 3 s cadence a couple of lost pings
    // meant 6-9 s of silence — enough for the radio's watchdog to drop the
    // session right around the end of an over.
    private let pingInterval = 0.5
    private let idleInterval = 1.0
    private let retryInterval = 5.0

    // MARK: Link watchdog
    //
    // The radio (or its ping replies) is heard every few hundred ms on a
    // healthy stream. If nothing arrives for `linkTimeout` seconds the link
    // is declared dead via onConnected(false) — without this the app never
    // notices the radio dropped the session.
    private var lastReceiveDate = Date()
    private var linkWatchdogTimer: DispatchSourceTimer?
    private var linkDeclaredDead = false
    /// Seconds of receive silence tolerated before declaring the link dead.
    var linkTimeout: TimeInterval = 0
    /// Date the watchdog measures silence against. Default: any received
    /// packet. The audio stream overrides this to track PCM specifically —
    /// its port stays chatty with pings even when the radio has silently
    /// stopped streaming audio.
    var linkWatchdogReferenceDate: Date { lastReceiveDate }
    /// Subclasses can suppress the watchdog during phases where silence is
    /// expected (the audio stream while we transmit — the radio may pause
    /// its RX PCM stream then).
    var linkWatchdogSuppressed: Bool { false }

    // Retransmit tracking (bounded). 64 packets ≈ 1.3 s of paced TX audio —
    // deep enough to answer retransmit requests after a WiFi loss burst.
    private static let trackDepth = 64
    private var trackedOrder: [UInt16] = []
    private var trackedData: [UInt16: Data] = [:]
    private var totalRetransmit = 0

    private var lastPingSentAt = Date()
    private var lastPingSeq = UInt16(0)

    /// Network service class for this stream's packets. The audio stream
    /// overrides this to `.voice` (WMM voice queue + no WiFi power-save
    /// batching) so paced audio doesn't stall during WiFi housekeeping.
    var serviceClass: NWParameters.ServiceClass { .responsiveData }

    init(label: String, host: String, port: UInt16, builder: IcomPacketBuilder) {
        self.label = label
        self.host = host
        self.port = port
        self.builder = builder
        // Timely delivery matters more than throughput on these queues —
        // the audio stream in particular runs a strict 20 ms pacing timer.
        self.queue = DispatchQueue(label: "com.freedv.icom.\(label)", qos: .userInitiated)
    }

    // MARK: Lifecycle

    func start() {
        let params = NWParameters.udp
        params.allowFastOpen = true
        params.allowLocalEndpointReuse = true
        params.serviceClass = serviceClass
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
            // Pre-handshake dead-stream detection: if the handshake (or the
            // PCM flow, for the audio stream) doesn't materialize within
            // linkTimeout, declare the stream dead — a local-port bind
            // collision (EADDRINUSE right after a reconnect) otherwise
            // leaves a silently stuck stream nobody watches.
            armLinkWatchdog()
        case .waiting(let error):
            // Typically EADDRINUSE while the previous socket is still
            // releasing — visible here, resolved by the watchdog + reconnect.
            appLog("Icom[\(label)]: connection waiting: \(error)")
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
        lastReceiveDate = Date()
        linkDeclaredDead = false
        current = data
        if checkRetransmitRequest() { return }
        receive(data: data)
    }

    /// Start (or restart) the receive-silence watchdog. Call once the stream
    /// is fully established and `linkTimeout` is set.
    func armLinkWatchdog() {
        guard linkTimeout > 0 else { return }
        linkWatchdogTimer?.cancel()
        lastReceiveDate = Date()
        linkDeclaredDead = false
        linkWatchdogTimer = makeTimer(interval: 1.0, repeats: true) { [weak self] in
            guard let self, !self.disconnecting, !self.linkDeclaredDead,
                  !self.linkWatchdogSuppressed else { return }
            let silence = Date().timeIntervalSince(self.linkWatchdogReferenceDate)
            if silence > self.linkTimeout {
                self.linkDeclaredDead = true
                appLog("Icom[\(self.label)]: link dead — nothing received for \(Int(silence)) s")
                self.onConnected?(false)
            }
        }
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
                // Half round-trip in ms; surface only unhealthy readings so a
                // struggling WiFi link is visible in the log during TX.
                let latency = lastPingSentAt.timeIntervalSinceNow * -500.0
                if latency > 100 {
                    appLog("Icom[\(label)]: ping RTT/2 ≈ \(Int(latency)) ms — WiFi link degraded")
                }
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
        // Direct evidence of packet loss on the WiFi link (e.g. HF RF
        // desensing 2.4 GHz during transmit) — worth surfacing every time.
        appLog("Icom[\(label)]: radio requested retransmit of \(sequences.count) packet(s) (total \(totalRetransmit))")
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
        linkWatchdogTimer?.cancel(); linkWatchdogTimer = nil
    }

    func cancel() {
        invalidateTimers()
        connection?.cancel()
        connection = nil
    }
}
