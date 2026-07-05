//
//  IcomPacketBuilder.swift
//  FreeDV
//
//  Builds outgoing Icom LAN packets and maintains the per-stream sequence
//  counters, local/remote station IDs, and token/login state. Ported from
//  NetworkIcom's `PacketCreate` (GPLv3-compatible reference), adapted to the
//  Data helpers in IcomProtocol.swift.
//

import Foundation

final class IcomPacketBuilder {
    /// Random 32-bit local station ID, sent as `sentid`.
    let myId: UInt32
    /// Radio's station ID, learned from the "I am here" reply.
    var remoteId: UInt32?

    /// Session token, learned from the login response.
    var token: UInt32?
    private let tokenRequest: UInt16

    private let username: String
    private let password: String
    private let computer: String
    private let audioFormat: IcomAudioFormat

    private var seq: UInt16 = 0
    private var pingSeqCounter: UInt16 = 0
    private var civSeqCounter: UInt16 = 0
    private var innerSeqCounter: UInt8 = 0
    /// Dedicated, contiguous sequence for the audio stream's `sendseq` (0x12).
    private var audioSeqCounter: UInt16 = 0

    private var pingDataA = UInt16(0)
    private let pingDataB = UInt16.random(in: .min ... .max)

    private var idleTemplate: Data?
    private var pingTemplate: Data?
    private var tokenTemplate: Data?
    private var civHeaderTemplate: Data?

    init(username: String, password: String, computer: String,
         audioFormat: IcomAudioFormat, myId: UInt32 = UInt32.random(in: .min ... .max)) {
        self.username = username
        self.password = password
        self.computer = computer
        self.audioFormat = audioFormat
        self.myId = myId
        self.tokenRequest = UInt16.random(in: .min ... .max)
    }

    // MARK: - Sequence counters

    private func nextSeq() -> UInt16 { seq &+= 1; return seq }
    private func nextPingSeq() -> UInt16 { pingSeqCounter &+= 1; return pingSeqCounter }
    private func nextCivSeq() -> UInt16 { civSeqCounter &+= 1; return civSeqCounter }
    private func nextInnerSeq() -> UInt8 { innerSeqCounter &+= 1; return innerSeqCounter }

    // MARK: - Control packets

    func idlePacket(withSequence: UInt16? = nil) -> Data {
        typealias c = ControlField
        let s = withSequence ?? nextSeq()
        if idleTemplate == nil {
            var p = Data(count: c.dataLength)
            p[c.length] = Data(le: UInt32(c.dataLength))
            p[c.type] = Data(le: ControlPacketType.idle)
            p[c.sendId] = Data(le: myId)
            p[c.sequence] = Data(le: s)
            if let remoteId { p[c.recvId] = Data(le: remoteId); idleTemplate = p }
            return p
        }
        idleTemplate![c.sequence] = Data(le: s)
        return idleTemplate!
    }

    /// Ask the radio to resend a tracked packet we never received (type 0x01).
    func retransmitRequestPacket(sequence: UInt16) -> Data {
        typealias c = ControlField
        var p = Data(count: c.dataLength)
        p[c.length] = Data(le: UInt32(c.dataLength))
        p[c.type] = Data(le: ControlPacketType.retransmit)
        p[c.sequence] = Data(le: sequence)
        p[c.sendId] = Data(le: myId)
        if let remoteId { p[c.recvId] = Data(le: remoteId) }
        return p
    }

    func areYouTherePacket() -> Data {
        typealias c = ControlField
        var p = Data(count: c.dataLength)
        p[c.length] = Data(le: UInt32(c.dataLength))
        p[c.type] = Data(le: ControlPacketType.areYouThere)
        p[c.sendId] = Data(le: myId)
        return p
    }

    func areYouReadyPacket() -> Data {
        typealias c = ControlField
        var p = Data(count: c.dataLength)
        p[c.length] = Data(le: UInt32(c.dataLength))
        p[c.type] = Data(le: ControlPacketType.areYouReady)
        p[c.sendId] = Data(le: myId)
        p[c.sequence] = Data(le: UInt16(1))
        if let remoteId { p[c.recvId] = Data(le: remoteId) }
        return p
    }

    func disconnectPacket() -> Data {
        typealias c = ControlField
        var p = Data(count: c.dataLength)
        p[c.length] = Data(le: UInt32(c.dataLength))
        p[c.type] = Data(le: ControlPacketType.disconnect)
        p[c.sendId] = Data(le: myId)
        p[c.sequence] = Data(le: UInt16(1))
        if let remoteId { p[c.recvId] = Data(le: remoteId) }
        return p
    }

    func disconnectPacket(replyTo: Data) -> Data {
        typealias c = ControlField
        var p = Data(count: c.dataLength)
        p[c.length] = Data(le: UInt32(c.dataLength))
        p[c.type] = Data(le: ControlPacketType.disconnect)
        p[c.sendId] = replyTo[c.recvId]
        p[c.recvId] = replyTo[c.sendId]
        p[c.sequence] = Data(le: UInt16(1))
        return p
    }

    // MARK: - Ping

    func pingPacket() -> Data {
        typealias c = ControlField
        typealias p = PingField
        let s = nextPingSeq()
        if pingTemplate == nil {
            var pkt = Data(count: p.dataLength)
            pkt[c.length] = Data(le: UInt32(p.dataLength))
            pkt[c.type] = Data(le: PingPacketType.ping)
            pkt[c.sendId] = Data(le: myId)
            pkt[p.dataA] = Data(le: pingDataA)
            pingDataA = UInt16.random(in: .min ... .max)
            pkt[p.dataB] = Data(le: pingDataB)
            pkt[c.sequence] = Data(le: s)
            if let remoteId { pkt[c.recvId] = Data(le: remoteId); pingTemplate = pkt }
            return pkt
        }
        pingTemplate![c.sequence] = Data(le: s)
        return pingTemplate!
    }

    func pingReply(to request: Data) -> Data {
        typealias c = ControlField
        typealias p = PingField
        var r = request
        r[c.length] = Data(le: UInt32(PingField.dataLength))
        r[c.sendId] = request[c.recvId]
        r[c.recvId] = request[c.sendId]
        r[p.request] = Data(le: UInt8(1))
        return r
    }

    // MARK: - Open/close (serial + audio stream request)

    func openClosePacket(open: Bool) -> Data {
        typealias c = ControlField
        typealias o = OpenCloseField
        var p = Data(count: o.dataLength)
        p[c.length] = Data(le: UInt32(o.dataLength))
        p[c.sendId] = Data(le: myId)
        p[c.sequence] = Data(le: nextSeq())
        if let remoteId { p[c.recvId] = Data(le: remoteId) }
        p[o.cmd] = Data(le: PacketCode.openClose)
        p[o.length] = Data(le: UInt16(1))
        p[o.sequence] = Data(le: nextCivSeq().bigEndian)
        p[o.request] = Data(le: open ? OpenCloseRequest.open : OpenCloseRequest.close)
        return p
    }

    // MARK: - Token / login

    func loginPacket() -> Data {
        typealias c = ControlField
        typealias t = TokenField
        typealias l = LoginField
        var p = Data(count: l.dataLength)
        p[c.length] = Data(le: UInt32(l.dataLength))
        p[c.sequence] = Data(le: nextSeq())
        p[t.sequence] = Data(le: nextInnerSeq())
        p[c.sendId] = Data(le: myId)
        p[t.tokRequest] = Data(le: tokenRequest)
        p[t.code] = Data(le: PacketCode.login)
        p[l.userName] = icomEncode(username)
        p[l.password] = icomEncode(password)
        p[l.computer] = Data(ascii: computer)
        if let remoteId { p[c.recvId] = Data(le: remoteId) }
        return p
    }

    func tokenPacket(type: UInt16) -> Data {
        typealias c = ControlField
        typealias t = TokenField
        let s = nextSeq()
        if tokenTemplate == nil {
            var p = Data(count: t.dataLength)
            p[c.length] = Data(le: UInt32(t.dataLength))
            p[c.sendId] = Data(le: myId)
            p[t.tokRequest] = Data(le: tokenRequest)
            p[t.code] = Data(le: PacketCode.token)
            p[t.res] = Data(le: type)
            p[c.sequence] = Data(le: s)
            p[t.sequence] = Data(le: nextInnerSeq())
            if let remoteId, let token {
                p[c.recvId] = Data(le: remoteId)
                p[t.token] = Data(le: token)
                tokenTemplate = p
            }
            return p
        }
        tokenTemplate![t.res] = Data(le: type)
        tokenTemplate![c.sequence] = Data(le: s)
        tokenTemplate![t.sequence] = Data(le: nextInnerSeq())
        return tokenTemplate!
    }

    /// Reply to a status request (radio asks us to confirm).
    func statusReply(to request: Data) -> Data {
        typealias c = ControlField
        typealias t = TokenField
        var r = request
        r[c.sendId] = request[c.recvId]
        r[c.recvId] = request[c.sendId]
        r[t.reqReply] = Data(le: UInt8(1))
        return r
    }

    // MARK: - Connection info (stream request)

    func connInfoPacket(radioName: String, civPort: UInt16, audioPort: UInt16,
                        enableRx: Bool, enableTx: Bool) -> Data {
        typealias c = ControlField
        typealias t = TokenField
        typealias ci = ConnInfoField
        var p = Data(count: ci.dataLength)
        p[c.length] = Data(le: UInt32(ci.dataLength))
        p[c.sequence] = Data(le: nextSeq())
        p[c.sendId] = Data(le: myId)
        p[t.code] = Data(le: PacketCode.connInfo)
        p[t.res] = Data(le: PacketCode.connInfoRes)
        p[t.sequence] = Data(le: nextInnerSeq())
        p[t.tokRequest] = Data(le: tokenRequest)
        p[t.commCap] = Data(le: CommonCap.value)
        p[ci.radio] = Data(ascii: radioName)
        p[ci.userName] = icomEncode(username)
        p[ci.enableRx] = Data(le: UInt8(enableRx ? 1 : 0))
        p[ci.enableTx] = Data(le: UInt8(enableTx ? 1 : 0))
        p[ci.rxCodec] = Data(le: audioFormat.codecByte)
        p[ci.txCodec] = Data(le: audioFormat.codecByte)
        p[ci.rxSample] = Data(le: UInt32(audioFormat.rate).bigEndian)
        p[ci.txSample] = Data(le: UInt32(audioFormat.rate).bigEndian)
        p[ci.civPort] = Data(le: UInt32(civPort).bigEndian)
        p[ci.audioPort] = Data(le: UInt32(audioPort).bigEndian)
        // TX jitter-buffer latency in ms, big-endian (wfview sends its latency
        // setting here). 150 ms matches the proven Android implementation;
        // the app-side 200 ms prebuffer covers encoder jitter on top.
        p[ci.txBuffer] = Data(le: UInt32(150).bigEndian)
        p[ci.convert] = Data(le: UInt8(1))
        if let remoteId { p[c.recvId] = Data(le: remoteId) }
        if let token { p[t.token] = Data(le: token) }
        return p
    }

    // MARK: - CI-V transport

    func civPacket(civData: Data) -> Data {
        typealias c = ControlField
        typealias civ = CIVField
        if civHeaderTemplate == nil {
            var h = Data(count: civ.headerLength)
            h[c.sendId] = Data(le: myId)
            if let remoteId { h[c.recvId] = Data(le: remoteId) }
            h[civ.cmd] = Data(le: PacketCode.civ)
            civHeaderTemplate = h
        }
        civHeaderTemplate![c.length] = Data(le: UInt32(civ.headerLength + civData.count))
        civHeaderTemplate![c.sequence] = Data(le: nextSeq())
        civHeaderTemplate![civ.length] = Data(le: UInt16(civData.count))
        civHeaderTemplate![civ.sequence] = Data(le: nextCivSeq())
        return civHeaderTemplate! + civData
    }

    // MARK: - Audio

    func audioPacket(samples: [Int16]) -> Data {
        typealias c = ControlField
        typealias a = AudioField
        let audioLen = samples.count * MemoryLayout<Int16>.size
        let s = nextSeq()
        let audioSeq = audioSeqCounter
        audioSeqCounter &+= 1
        var p = Data(count: a.headerLength)
        p[c.length] = Data(le: UInt32(a.headerLength + audioLen))
        if let remoteId { p[c.recvId] = Data(le: remoteId) }
        p[c.sendId] = Data(le: myId)
        p[c.sequence] = Data(le: s)
        // TX audio identifier the radio requires to route audio to the modulator
        // (wfview: 0x0080 for normal TX audio). Without this the radio accepts
        // the packets on the stream but never transmits them.
        p[a.ident] = Data(le: UInt16(0x0080))
        // Dedicated contiguous audio sequence (big-endian), not the control seq.
        p[a.sequence] = Data(le: audioSeq.bigEndian)
        p[a.length] = Data(le: UInt32(audioLen).bigEndian)
        let payload = samples.withUnsafeBytes { Data($0) }
        return p + payload
    }
}
