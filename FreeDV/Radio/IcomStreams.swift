//
//  IcomStreams.swift
//  FreeDV
//
//  Concrete Icom LAN streams: control (login/token/capabilities), serial
//  (CI-V transport), and audio (RX/TX PCM). See IcomUDPStream for the shared
//  handshake/keepalive/retransmit machinery.
//

import Foundation
import Network

// MARK: - Control stream

final class IcomControlStream: IcomUDPStream {
    private var haveToken = false
    private var radioName = ""
    private let civPort: UInt16
    private let audioPort: UInt16
    private let enableTx: Bool
    private var tokenRenewTimer: DispatchSourceTimer?
    private let tokenRenewInterval = 60.0

    /// Fired when the radio's capabilities arrive (name + CI-V address).
    var onRadioInfo: ((_ name: String, _ civAddr: UInt8) -> Void)?
    /// Fired once the control link is fully established (capabilities received).
    var onFullyConnected: (() -> Void)?

    init(host: String, controlPort: UInt16, civPort: UInt16, audioPort: UInt16,
         enableTx: Bool, builder: IcomPacketBuilder) {
        self.civPort = civPort
        self.audioPort = audioPort
        self.enableTx = enableTx
        super.init(label: "control", host: host, port: controlPort, builder: builder)
    }

    func disconnect() {
        onState?("Disconnecting…")
        send(data: builder.connInfoPacket(radioName: radioName, civPort: civPort,
                                          audioPort: audioPort, enableRx: false, enableTx: false))
        send(data: builder.disconnectPacket())
        invalidateTimers()
        disconnecting = true
        if haveToken {
            send(data: builder.tokenPacket(type: TokenType.remove))
        }
        armIdleTimer()
    }

    override func invalidateTimers() {
        tokenRenewTimer?.cancel(); tokenRenewTimer = nil
        super.invalidateTimers()
    }

    override func receive(data: Data) {
        switch current.count {
        case ControlField.dataLength:
            _ = handleControlHandshake(onIAmHere: {
                armResendTimer()
                retryPacket = builder.areYouReadyPacket()
                send(data: retryPacket)
            }, onIAmReady: {
                armResendTimer()
                retryPacket = builder.loginPacket()
                send(data: retryPacket)
                onState?("Logging in…")
            })

        case PingField.dataLength:
            receivePing()

        case TokenField.dataLength:
            receiveToken()

        case StatusField.dataLength:
            typealias t = TokenField
            if current[t.reqReply].u8 == 0 {
                send(data: builder.statusReply(to: current))
            }

        case LoginResponseField.dataLength:
            receiveLoginResponse()

        case ConnInfoField.dataLength:
            typealias t = TokenField
            if current[t.reqReply].u8 == 0 {
                send(data: builder.connInfoReply(to: current))
            } else {
                invalidateResendTimer()
            }

        case CapabilitiesField.dataLength:
            receiveCapabilities()

        default:
            break
        }
    }

    private func receiveLoginResponse() {
        typealias t = TokenField
        typealias l = LoginResponseField
        // 0x30 error field non-zero => login rejected.
        let error = Data(current[(0x30, 4)]).u32
        if error != 0 {
            appLog("Icom[control]: LOGIN FAILED (error=\(String(format: "%08x", error)), check username/password)")
            onState?("Login failed — check credentials")
            return
        }
        builder.token = current[t.token].u32
        appLog("Icom[control]: login OK, token=\(builder.token.map { String(format: "%08x", $0) } ?? "?"), conn=\(current[l.netType].asciiString)")
        retryPacket = builder.tokenPacket(type: TokenType.acknowledge)
        send(data: retryPacket)
        armResendTimer()
        onState?("Acknowledging token…")
    }

    private func receiveToken() {
        typealias t = TokenField
        invalidateResendTimer()
        if current[t.res].u16 == TokenType.remove {
            invalidateTimers()
            haveToken = false
            disconnecting = true
            armIdleTimer()
            send(data: builder.disconnectPacket())
        }
    }

    private func receiveCapabilities() {
        typealias c = CapabilitiesField
        haveToken = true
        radioName = current[c.radio].asciiString
        let civAddr = current[c.civAddr].u8
        appLog("Icom[control]: capabilities — radio=\"\(radioName)\" civAddr=\(String(format: "0x%02x", civAddr))")
        // Dump the capability region that carries conntype / sample-rate support.
        if current.count >= 0xa8 {
            let region = current[(0x90, 0x18)].map { String(format: "%02x", $0) }.joined(separator: " ")
            let rxCap = Data(current[(0x95, 2)]).u16
            let txCap = Data(current[(0x97, 2)]).u16
            appLog("Icom[control]: caps[0x90..0xa8]=\(region)  rxSampleCap=\(String(format:"0x%04x",rxCap)) txSampleCap=\(String(format:"0x%04x",txCap))")
        }
        armTokenRenewTimer()
        armPingTimer()
        armIdleTimer()
        invalidateResendTimer()
        onRadioInfo?(radioName, civAddr)
        onState?("Connected")
        onConnected?(true)
        // Request the radio to start streaming audio to us.
        send(data: builder.connInfoPacket(radioName: radioName, civPort: civPort,
                                          audioPort: audioPort, enableRx: true, enableTx: enableTx))
        onFullyConnected?()
    }

    private func armTokenRenewTimer() {
        tokenRenewTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tokenRenewInterval, repeating: tokenRenewInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.retryPacket = self.builder.tokenPacket(type: TokenType.renew)
            self.track(data: self.retryPacket)
            self.armIdleTimer()
            self.send(data: self.retryPacket)
            self.armResendTimer()
            appLog("Icom[control]: token renewed")
        }
        t.resume()
        tokenRenewTimer = t
    }
}

// MARK: - Serial (CI-V) stream

final class IcomSerialStream: IcomUDPStream {
    /// Raw CI-V payload (fe fe … fd) received from the radio.
    var onCivData: ((Data) -> Void)?

    init(host: String, port: UInt16, builder: IcomPacketBuilder) {
        super.init(label: "serial", host: host, port: port, builder: builder)
    }

    func disconnect() {
        onState?("Disconnecting…")
        invalidateTimers()
        disconnecting = true
        send(data: builder.disconnectPacket())
        send(data: builder.openClosePacket(open: false))
        armIdleTimer()
    }

    /// Send a raw CI-V payload (already framed fe fe … fd).
    func sendCiv(_ civData: Data) {
        appLog("Icom[civ] tx: \(civData.map { String(format: "%02x", $0) }.joined(separator: " "))")
        let packet = builder.civPacket(civData: civData)
        track(data: packet)
        send(data: packet)
    }

    override func receive(data: Data) {
        typealias civ = CIVField
        if current.count > civ.headerLength && current[civ.cmd].u8 == PacketCode.civ {
            let civData = Data(current.dropFirst(civ.headerLength))
            onCivData?(civData)
            return
        }
        switch current.count {
        case ControlField.dataLength:
            _ = handleControlHandshake(onIAmHere: {
                armResendTimer()
                retryPacket = builder.areYouReadyPacket()
                send(data: retryPacket)
            }, onIAmReady: {
                invalidateResendTimer()
                send(data: builder.openClosePacket(open: true))
                onState?("Serial connected")
                onConnected?(true)
                armIdleTimer()
                armPingTimer()
            })
        case PingField.dataLength:
            receivePing()
        default:
            break
        }
    }
}

// MARK: - Audio stream

final class IcomAudioStream: IcomUDPStream {
    /// Decoded 16-bit LPCM samples received from the radio (RX audio).
    var onRxAudio: (([Int16]) -> Void)?

    /// Whether the conninfo requested a TX audio path (drives the paced stream).
    private let enableTx: Bool

    init(host: String, port: UInt16, enableTx: Bool, builder: IcomPacketBuilder) {
        self.enableTx = enableTx
        super.init(label: "audio", host: host, port: port, builder: builder)
    }

    /// The audio stream skips the disconnect-first step.
    override func startConnection() {
        disconnecting = false
        armResendTimer()
        retryPacket = builder.areYouTherePacket()
        send(data: retryPacket)
    }

    func disconnect() {
        onState?("Disconnecting…")
        invalidateTimers()
        disconnecting = true
        send(data: builder.disconnectPacket())
        armIdleTimer()
    }

    // RX audio flow diagnostics (all touched on the stream queue only).
    private var rxAudioStarted = false
    private var rxWindowPackets = 0
    private var rxWindowBytes = 0
    private var rxWindowStart: Date?

    /// TX audio gets the WMM voice queue and exemption from WiFi power-save
    /// batching — paced packets must not stall during WiFi housekeeping.
    override var serviceClass: NWParameters.ServiceClass { .interactiveVoice }

    // MARK: TX pacing
    //
    // The radio expects a steady 20 ms audio stream (RS-BA1/wfview send one
    // packet per audio-device callback). RADE produces modem samples in
    // ~120 ms bursts; sent as-is, one late burst underruns the radio's
    // jitter buffer and the SSB carrier drops out for a moment.
    // So: samples are queued in a FIFO and drained 160 samples (20 ms) per
    // timer tick, sending silence when the FIFO runs dry. Real audio only
    // starts draining once the FIFO holds `txPrebufferSamples` — that
    // pre-buffer is the steady-state cushion (production and consumption
    // rates are equal, so whatever depth draining starts with is kept),
    // absorbing late encoder bursts. All state is queue-confined.
    private var txFifo: [Int16] = []
    private var txPaceTimer: DispatchSourceTimer?
    private var txDraining = false
    private let txChunkSamples = 160                  // 20 ms @ 8 kHz
    private let txPrebufferSamples = 1600             // 200 ms cushion
    private let txFifoCap = 16000                     // 2 s safety cap
    private var txRealPacketCount = 0
    private var txUnderrunCount = 0
    /// Mirrors PTT (set via setTxActive) so drain events can be classified:
    /// PTT down = mid-over underrun (bad), PTT up = end-of-over flush (normal).
    private var txActive = false

    /// Called (on the stream queue) when PTT changes.
    func setTxActive(_ active: Bool) {
        txActive = active
        guard active, txPaceTimer != nil else { return }
        // Prime the pipeline: pre-fill the prebuffer with leading silence so
        // draining starts on the next tick instead of holding the first modem
        // burst back until the threshold fills — cuts ~200 ms off PTT-to-RF
        // while keeping the same cushion depth (as zeros at first).
        if !txDraining, txFifo.count < txPrebufferSamples {
            let padding = txPrebufferSamples - txFifo.count
            txFifo.insert(contentsOf: [Int16](repeating: 0, count: padding), at: 0)
        }
    }

    /// Queue TX modem samples; the pacing timer sends them at 20 ms cadence.
    func sendAudio(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        txFifo.append(contentsOf: samples)
        if txFifo.count > txFifoCap {
            txFifo.removeFirst(txFifo.count - txFifoCap)
        }
    }

    private func startTxPacing() {
        guard enableTx, txPaceTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.sendPacedTxPacket() }
        t.resume()
        txPaceTimer = t
        appLog("Icom[audio]: TX pacing started (20 ms/packet, \(txPrebufferSamples / 8) ms prebuffer)")
    }

    private func sendPacedTxPacket() {
        if !txDraining, txFifo.count >= txPrebufferSamples {
            txDraining = true
        }
        let chunk: [Int16]
        if txDraining, txFifo.count >= txChunkSamples {
            chunk = Array(txFifo.prefix(txChunkSamples))
            txFifo.removeFirst(txChunkSamples)
            txRealPacketCount += 1
            if txRealPacketCount == 1 {
                appLog("Icom[audio]: first TX audio packet (remoteId=\(builder.remoteId != nil ? "set" : "NIL"))")
            } else if txRealPacketCount % 250 == 0 {
                appLog("Icom[audio]: TX audio #\(txRealPacketCount) fifo=\(txFifo.count) underruns=\(txUnderrunCount)")
            }
        } else {
            if txDraining {
                // Refill the whole prebuffer before resuming either way.
                txDraining = false
                txUnderrunCount += 1
                if txActive {
                    appLog("Icom[audio]: TX FIFO drained #\(txUnderrunCount) after \(txRealPacketCount) packets — MID-OVER UNDERRUN (encoder starved)")
                } else {
                    appLog("Icom[audio]: TX FIFO drained #\(txUnderrunCount) after \(txRealPacketCount) packets (end-of-over flush, normal)")
                }
            }
            // Full silence packet; queued samples stay intact so the modem
            // waveform remains sample-continuous when draining resumes.
            chunk = [Int16](repeating: 0, count: txChunkSamples)
        }
        let packet = builder.audioPacket(samples: chunk)
        // Track for retransmit (wfview sends TX audio via its tracked path).
        track(data: packet)
        send(data: packet)
    }

    override func invalidateTimers() {
        txPaceTimer?.cancel(); txPaceTimer = nil
        super.invalidateTimers()
    }

    override func receive(data: Data) {
        typealias a = AudioField
        if current.count > a.headerLength {
            let payload = current.dropFirst(a.headerLength)
            noteRxAudio(payload.count)
            deliverAudio(payload)
            return
        }
        switch current.count {
        case ControlField.dataLength:
            _ = handleControlHandshake(onIAmHere: {
                onConnected?(true)
                onState?("Audio connected")
                send(data: builder.areYouReadyPacket())
                invalidateTimers()
                armIdleTimer()
                armPingTimer()
                startTxPacing()
            }, onIAmReady: { })
        case PingField.dataLength:
            receivePing()
        default:
            break
        }
    }

    /// Log RX audio flow: first packet, then packet/sample rate every ~5 s.
    /// ~8000 samples/s confirms the negotiated 8 kHz LPCM stream is arriving.
    private func noteRxAudio(_ payloadBytes: Int) {
        if !rxAudioStarted {
            rxAudioStarted = true
            appLog("Icom[audio]: RX audio streaming started (\(payloadBytes)-byte payload)")
        }
        rxWindowPackets += 1
        rxWindowBytes += payloadBytes
        let now = Date()
        guard let start = rxWindowStart else { rxWindowStart = now; return }
        let dt = now.timeIntervalSince(start)
        if dt >= 5 {
            let samplesPerSec = Double(rxWindowBytes) / 2.0 / dt
            appLog(String(format: "Icom[audio]: RX %.1f pkt/s, ~%.0f samples/s",
                          Double(rxWindowPackets) / dt, samplesPerSec))
            rxWindowStart = now
            rxWindowPackets = 0
            rxWindowBytes = 0
        }
    }

    /// Convert little-endian 16-bit PCM bytes to [Int16]. (We always negotiate
    /// 16-bit LPCM, so this is the only format we expect.)
    private func deliverAudio(_ payload: Data.SubSequence) {
        let bytes = Array(payload)
        guard bytes.count >= 2 else { return }
        var samples = [Int16](repeating: 0, count: bytes.count / 2)
        for i in 0..<samples.count {
            let lo = UInt16(bytes[i * 2])
            let hi = UInt16(bytes[i * 2 + 1])
            samples[i] = Int16(bitPattern: lo | (hi << 8))
        }
        onRxAudio?(samples)
    }
}

// MARK: - Reply-to helpers

extension IcomPacketBuilder {
    /// Echo a conninfo poll back to the radio with the reply flag set.
    func connInfoReply(to request: Data) -> Data {
        typealias c = ControlField
        typealias t = TokenField
        var r = request
        r[c.sendId] = request[c.recvId]
        r[c.recvId] = request[c.sendId]
        r[t.code] = Data(le: PacketCode.connInfo)
        r[t.res] = Data(le: PacketCode.connInfoRes)
        return r
    }
}
