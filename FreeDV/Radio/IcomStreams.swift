//
//  IcomStreams.swift
//  FreeDV
//
//  Concrete Icom LAN streams: control (login/token/capabilities), serial
//  (CI-V transport), and audio (RX/TX PCM). See IcomUDPStream for the shared
//  handshake/keepalive/retransmit machinery.
//

import Foundation

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

    init(host: String, port: UInt16, builder: IcomPacketBuilder) {
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

    private var txSentCount = 0

    /// Send one TX audio packet (16-bit LPCM samples).
    func sendAudio(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let packet = builder.audioPacket(samples: samples)
        txSentCount += 1
        if txSentCount == 1 {
            let header = packet.prefix(0x18).map { String(format: "%02x", $0) }.joined(separator: " ")
            appLog("Icom[audio]: TX pkt#1 header(0x18)=\(header) totalBytes=\(packet.count) remoteId=\(builder.remoteId != nil ? "set" : "NIL")")
        } else if txSentCount % 50 == 0 {
            appLog("Icom[audio]: TX packet #\(txSentCount)")
        }
        // Track for retransmit (wfview sends TX audio via its tracked path).
        track(data: packet)
        send(data: packet)
    }

    override func receive(data: Data) {
        typealias a = AudioField
        if current.count > a.headerLength {
            let payload = current.dropFirst(a.headerLength)
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
                armPingTimer()
            }, onIAmReady: { })
        case PingField.dataLength:
            receivePing()
        default:
            break
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
