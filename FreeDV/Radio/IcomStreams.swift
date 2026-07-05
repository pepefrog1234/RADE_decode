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

    /// Re-send the stream request (conninfo). Nudges the radio's audio
    /// session back to life when it stops streaming PCM after an over —
    /// much gentler than a full reconnect. Call on the stream queue.
    func resendConnInfo() {
        appLog("Icom[control]: re-sending conninfo (audio session nudge)")
        send(data: builder.connInfoPacket(radioName: radioName, civPort: civPort,
                                          audioPort: audioPort, enableRx: true, enableTx: enableTx))
    }

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
        // Session-death detector: the radio (or its ping replies) is heard
        // sub-second on a healthy control link; 5 s of silence means the
        // session is gone and triggers the controller's auto-reconnect.
        linkTimeout = 5
        armLinkWatchdog()
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

    /// Re-send the CI-V open request. The initial open is a single UDP
    /// packet with no retry — losing it leaves the radio silently ignoring
    /// all CI-V traffic (observed as 17 s of unanswered frequency reads).
    func resendOpen() {
        send(data: builder.openClosePacket(open: true))
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

// MARK: - 8 kHz ↔ 48 kHz conversion (ported from the Android implementation)

/// 8 kHz → 48 kHz polyphase interpolator, ported from RADE_decode_Android's
/// audio_engine.cpp (designNetTxInterpFilter / fillNetTxFrame): windowed-sinc
/// prototype (4-term Blackman-Harris, cutoff 3.5 kHz), 6 phases × 24 taps,
/// each phase normalized to unity gain. History is carried across calls so
/// frames join seamlessly.
private final class ModemUpsampler {
    private static let L = 6
    private static let tpp = 24
    private static let phases: [[Float]] = {
        let total = L * tpp
        let m = Float(total - 1)
        let fc: Float = 3500.0 / 48000.0
        var proto = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let n = Float(i) - m / 2
            let h: Float = abs(n) < 1e-6 ? 2 * fc : sin(2 * Float.pi * fc * n) / (Float.pi * n)
            let w: Float = 0.35875
                - 0.48829 * cos(2 * Float.pi * Float(i) / m)
                + 0.14128 * cos(4 * Float.pi * Float(i) / m)
                - 0.01168 * cos(6 * Float.pi * Float(i) / m)
            proto[i] = h * w
        }
        var ph = [[Float]](repeating: [Float](repeating: 0, count: tpp), count: L)
        for p in 0..<L {
            var sum: Float = 0
            for k in 0..<tpp {
                let idx = k * L + p
                ph[p][k] = idx < total ? proto[idx] : 0
                sum += ph[p][k]
            }
            if abs(sum) > 1e-9 {
                for k in 0..<tpp { ph[p][k] /= sum }
            }
        }
        return ph
    }()
    private var hist = [Float](repeating: 0, count: ModemUpsampler.tpp)
    private var pos = 0

    func process(_ input: [Int16]) -> [Int16] {
        let L = ModemUpsampler.L, tpp = ModemUpsampler.tpp
        var out = [Int16]()
        out.reserveCapacity(input.count * L)
        for s in input {
            hist[pos] = Float(s)
            pos = (pos + 1) % tpp
            for p in 0..<L {
                let hp = ModemUpsampler.phases[p]
                var acc: Float = 0
                var idx = pos
                for k in 0..<tpp {
                    idx -= 1
                    if idx < 0 { idx = tpp - 1 }
                    acc += hist[idx] * hp[k]
                }
                out.append(Int16(max(-32767, min(32767, acc))))
            }
        }
        return out
    }
}

/// 48 kHz → 8 kHz FIR decimator, ported from RADE_decode_Android's
/// audio_engine.cpp (designDecimFilter / feedNetRx): windowed-sinc lowpass
/// with cutoff 4 kHz (output Nyquist), 48 taps per phase (288 total),
/// 4-term Blackman-Harris window, unity DC gain.
///
/// The 0.15 attenuation is Android's NET_RX_ATTEN, applied identically:
/// RS-BA1 network audio arrives near the radio's digital line level, much
/// hotter than the |x| ≈ 1.0 (int16/8192) scale the RADE decoder is
/// designed and tested around — the Android port decodes weak signals
/// better with this in place.
private final class ModemDownsampler {
    private static let factor = 6
    private static let totalTaps = 48 * 6
    private static let netRxAttenuation: Float = 0.15
    private static let taps: [Float] = {
        let total = totalTaps
        let m = Float(total - 1)
        let fc: Float = 8000.0 / (2.0 * 48000.0)
        var h = [Float](repeating: 0, count: total)
        var sum: Float = 0
        for i in 0..<total {
            let n = Float(i) - m / 2
            let s: Float = abs(n) < 1e-6 ? 2 * fc : sin(2 * Float.pi * fc * n) / (Float.pi * n)
            let w: Float = 0.35875
                - 0.48829 * cos(2 * Float.pi * Float(i) / m)
                + 0.14128 * cos(4 * Float.pi * Float(i) / m)
                - 0.01168 * cos(6 * Float.pi * Float(i) / m)
            h[i] = s * w
            sum += h[i]
        }
        for i in 0..<total { h[i] /= sum }
        return h
    }()
    private var hist = [Float](repeating: 0, count: ModemDownsampler.totalTaps)
    private var pos = 0
    private var phase = 0

    func process(_ input: [Int16]) -> [Int16] {
        let total = ModemDownsampler.totalTaps
        let taps = ModemDownsampler.taps
        var out = [Int16]()
        out.reserveCapacity(input.count / ModemDownsampler.factor + 1)
        for s in input {
            hist[pos] = Float(s)
            pos = (pos + 1) % total
            phase += 1
            if phase >= ModemDownsampler.factor {
                phase = 0
                var acc: Float = 0
                var idx = pos
                for k in 0..<total {
                    idx -= 1
                    if idx < 0 { idx = total - 1 }
                    acc += hist[idx] * taps[k]
                }
                acc *= ModemDownsampler.netRxAttenuation
                out.append(Int16(max(-32767, min(32767, acc))))
            }
        }
        return out
    }
}

/// In-order jitter buffer over the 16-bit outer packet sequence (Android
/// pattern, plus loss recovery): releases contiguous packets immediately;
/// when the next expected packet is missing while newer ones queue up, it
/// asks (once per sequence) for a retransmit from the radio — WiFi loss
/// bursts (iOS AWDL scans) then heal instead of punching holes in the modem
/// stream. If the gap still isn't filled by `maxDepth` packets, it skips
/// forward so audio never stalls. Single-threaded (audio stream queue only).
private final class AudioJitterBuffer {
    private var buf: [UInt16: [Int16]] = [:]
    private var expected = -1
    private let maxDepth = 24
    private let onSamples: ([Int16]) -> Void
    /// Ask the radio to resend this missing sequence.
    var onMissing: ((UInt16) -> Void)?
    private var requested: Set<UInt16> = []
    private(set) var lostPackets = 0
    private(set) var recoveredPackets = 0

    init(onSamples: @escaping ([Int16]) -> Void) {
        self.onSamples = onSamples
    }

    func add(seq: UInt16, samples: [Int16]) {
        if expected < 0 { expected = Int(seq) }
        let exp = UInt16(truncatingIfNeeded: expected)
        if seqLess(seq, exp) { return }
        if requested.contains(seq) { recoveredPackets += 1 }
        buf[seq] = samples
        drain()
        // Gap blocking the head: newer packets queued while `expected` is
        // missing — request it once, giving the retransmit a round trip to
        // land before the depth limit forces a skip.
        if !buf.isEmpty {
            let head = UInt16(truncatingIfNeeded: expected)
            if buf[head] == nil, buf.count >= 2, !requested.contains(head) {
                requested.insert(head)
                onMissing?(head)
            }
        }
        if buf.count > maxDepth {
            var oldest: UInt16?
            for k in buf.keys where oldest == nil || seqLess(k, oldest!) { oldest = k }
            if let o = oldest {
                lostPackets += (Int(o) - expected) & 0xFFFF
                expected = Int(o)
                drain()
            }
        }
        if requested.count > 64 { requested.removeAll(keepingCapacity: true) }
    }

    private func drain() {
        while let s = buf.removeValue(forKey: UInt16(truncatingIfNeeded: expected)) {
            if !s.isEmpty { onSamples(s) }
            expected = (expected + 1) & 0xFFFF
        }
    }

    private func seqLess(_ a: UInt16, _ b: UInt16) -> Bool {
        let d = (Int(b) - Int(a)) & 0xFFFF
        return d != 0 && d < 0x8000
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
    /// Last time a PCM packet arrived — the link watchdog measures against
    /// this, not against pings, so "radio silently stopped streaming audio
    /// while still answering pings" is detected and triggers a reconnect.
    private var lastPcmDate = Date()
    /// Fired (on the stream queue) when PCM starts flowing again after a
    /// gap longer than the watchdog timeout — lets the controller know a
    /// nudge actually worked.
    var onPcmResumed: (() -> Void)?

    override var linkWatchdogReferenceDate: Date { lastPcmDate }

    /// Never judge PCM silence while we transmit — the radio may legitimately
    /// pause its RX stream during our TX.
    override var linkWatchdogSuppressed: Bool { txActive }

    /// After a conninfo nudge: restart the PCM silence window so the radio
    /// gets one more timeout period to resume streaming before the
    /// controller escalates to a full reconnect.
    func rearmAfterNudge() {
        lastPcmDate = Date()
        armLinkWatchdog()
    }

    /// Called when the end-of-over flush is queued (PTT stays keyed until
    /// the tail drains). Classification only — frames keep flowing until
    /// PTT actually drops.
    func noteFlushing() {
        txFlushing = true
    }

    /// TX audio gets the WMM voice queue and exemption from WiFi power-save
    /// batching — paced packets must not stall during WiFi housekeeping.
    override var serviceClass: NWParameters.ServiceClass { .interactiveVoice }

    // MARK: TX pacing
    //
    // The radio expects a steady 20 ms audio-frame stream. RADE produces
    // modem samples in ~120 ms bursts; sent as-is, one late burst underruns
    // the radio's jitter buffer and the SSB carrier drops out for a moment.
    // So: samples are upsampled to 48 kHz, queued in a FIFO, and drained one
    // 960-sample frame (20 ms) per timer tick — fragmented into the two
    // packet sizes the radio expects (1364 B + 556 B payloads, exactly like
    // the Android implementation) — sending silence when the FIFO runs dry.
    // Real audio only starts draining once the FIFO holds
    // `txPrebufferSamples`: that pre-buffer is the steady-state cushion
    // (production and consumption rates are equal, so whatever depth
    // draining starts with is kept), absorbing late encoder bursts.
    // All state is queue-confined.
    private var txFifo: [Int16] = []
    private var txPaceTimer: DispatchSourceTimer?
    private var txDraining = false
    private let txChunkSamples = 960                  // 20 ms @ 48 kHz
    private let txFragmentSamples = 682               // 1364 B first fragment
    private let txPrebufferSamples = 9600             // 200 ms cushion
    private let txFifoCap = 96000                     // 2 s safety cap
    private var txRealPacketCount = 0
    private var txUnderrunCount = 0
    private let txUpsampler = ModemUpsampler()
    private let rxDownsampler = ModemDownsampler()
    private lazy var rxJitter: AudioJitterBuffer = {
        let jitter = AudioJitterBuffer { [weak self] samples in
            self?.handleOrderedRxAudio(samples)
        }
        jitter.onMissing = { [weak self] seq in
            self?.requestRxRetransmit(seq)
        }
        return jitter
    }()
    private var rxRetransmitRequests = 0

    /// Ask the radio to resend a lost packet (double-send — the link just
    /// proved lossy). Recovered packets fill the jitter gap in order instead
    /// of leaving a hole in the modem stream.
    private func requestRxRetransmit(_ seq: UInt16) {
        let p = builder.retransmitRequestPacket(sequence: seq)
        send(data: p)
        send(data: p)
        rxRetransmitRequests += 1
        if rxRetransmitRequests <= 5 || rxRetransmitRequests % 25 == 0 {
            appLog("Icom[audio]: RX retransmit requested seq=\(seq) (req \(rxRetransmitRequests), lost \(rxJitter.lostPackets), recovered \(rxJitter.recoveredPackets))")
        }
    }
    /// Mirrors PTT. CRITICAL: while this is true the radio is keyed with
    /// WLAN as its modulation source and MUST keep receiving audio frames —
    /// starving it for a few hundred ms makes it declare the client
    /// disconnected (radio shows "connection interrupted") and kill the
    /// whole audio session. Silence frames are sent whenever the FIFO has
    /// no real audio and PTT is down.
    private var txActive = false
    /// End-of-over flush in progress (EOO queued, PTT still keyed for the
    /// drain) — used only to classify the FIFO-drained log line.
    private var txFlushing = false

    /// Called (on the stream queue) when PTT changes.
    func setTxActive(_ active: Bool) {
        txActive = active
        txFlushing = false
        // Restart the PCM-silence window at both PTT edges so the watchdog
        // never counts time spent transmitting (see linkWatchdogSuppressed).
        lastPcmDate = Date()
        guard active, txPaceTimer != nil else { return }
        // Prime the pipeline: pre-fill with leading silence so draining
        // starts on the next tick instead of holding the first modem burst
        // back until the threshold fills. Primed to 2× the prebuffer: the
        // encoder needs ~350 ms to spin up (first mic buffer + feature
        // accumulation), longer than the 200 ms threshold, and priming only
        // to the threshold guaranteed one underrun at the start of each over.
        let primeTarget = txPrebufferSamples * 2
        if !txDraining, txFifo.count < primeTarget {
            let padding = primeTarget - txFifo.count
            txFifo.insert(contentsOf: [Int16](repeating: 0, count: padding), at: 0)
        }
    }

    /// Queue TX modem samples (8 kHz — upsampled to 48 kHz here); the pacing
    /// timer sends them as 20 ms frames.
    func sendAudio(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        txFifo.append(contentsOf: txUpsampler.process(samples))
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
        appLog("Icom[audio]: TX pacing started (20 ms frames @48 kHz, \(txPrebufferSamples / 48) ms prebuffer)")
    }

    private func sendPacedTxPacket() {
        // Frames flow only while transmitting or draining the EOO tail — the
        // radio gets NO audio packets between overs, exactly like the Android
        // pump (`while isTxRunning || ring > 0`). Sub-frame leftovers after a
        // flush are trailing padding zeros; discard them.
        if !txActive && !txDraining {
            if !txFifo.isEmpty { txFifo.removeAll(keepingCapacity: true) }
            return
        }
        if !txDraining, txFifo.count >= txPrebufferSamples {
            txDraining = true
        }
        let frame: [Int16]
        if txDraining, txFifo.count >= txChunkSamples {
            frame = Array(txFifo.prefix(txChunkSamples))
            txFifo.removeFirst(txChunkSamples)
            txRealPacketCount += 1
            if txRealPacketCount == 1 {
                appLog("Icom[audio]: first TX audio frame (remoteId=\(builder.remoteId != nil ? "set" : "NIL"))")
            } else if txRealPacketCount % 250 == 0 {
                appLog("Icom[audio]: TX audio frame #\(txRealPacketCount) fifo=\(txFifo.count) underruns=\(txUnderrunCount)")
            }
        } else {
            if txDraining {
                // Refill the whole prebuffer before resuming either way.
                txDraining = false
                txUnderrunCount += 1
                if txActive && !txFlushing {
                    appLog("Icom[audio]: TX FIFO drained #\(txUnderrunCount) after \(txRealPacketCount) frames — MID-OVER UNDERRUN (encoder starved)")
                } else {
                    appLog("Icom[audio]: TX FIFO drained #\(txUnderrunCount) after \(txRealPacketCount) frames (end-of-over flush, normal)")
                }
            }
            // Full silence frame; queued samples stay intact so the modem
            // waveform remains sample-continuous when draining resumes.
            frame = [Int16](repeating: 0, count: txChunkSamples)
        }
        // One 20 ms frame = 1920 B, fragmented into the two packet sizes the
        // radio expects (1364 B + 556 B payloads — exactly like the Android
        // implementation); each fragment is tracked with its own sequence
        // (wfview sends TX audio via its tracked path too).
        let part1 = Array(frame[0..<txFragmentSamples])
        let part2 = Array(frame[txFragmentSamples...])
        for part in [part1, part2] {
            let packet = builder.audioPacket(samples: part)
            track(data: packet)
            send(data: packet)
        }
    }

    override func invalidateTimers() {
        txPaceTimer?.cancel(); txPaceTimer = nil
        super.invalidateTimers()
    }

    /// The audio stream must NOT send periodic idle packets: they consume the
    /// same outer sequence space as the audio data packets, so the radio sees
    /// a sequence gap in its audio stream once a second and treats it as
    /// packet loss (the Android implementation documents the same rule —
    /// "the audio stream sends NO periodic idle pkt0"). Keepalive comes from
    /// pings; the idle timer only completes disconnects.
    override func onIdleTimer() {
        if disconnecting {
            super.onIdleTimer()
        }
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
            typealias c = ControlField
            if current[c.type].u16 == ControlPacketType.idle {
                // The radio's idle keepalives share its tracked sequence
                // space with the audio packets — feed them to the jitter
                // buffer as empty fillers so they don't register as lost
                // audio (and retransmit-substituted idles close their gap).
                rxJitter.add(seq: current[c.sequence].u16, samples: [])
                return
            }
            _ = handleControlHandshake(onIAmHere: {
                onConnected?(true)
                onState?("Audio connected")
                send(data: builder.areYouReadyPacket())
                invalidateTimers()
                armPingTimer()
                // Restart the PCM watchdog (timeout comes from the controller;
                // reference date is PCM-specific, see linkWatchdogReferenceDate).
                lastPcmDate = Date()
                armLinkWatchdog()
                startTxPacing()
            }, onIAmReady: { })
        case PingField.dataLength:
            receivePing()
        default:
            break
        }
    }

    /// Log RX audio flow: first packet, then packet/sample rate every ~5 s.
    /// ~48000 samples/s confirms the negotiated 48 kHz LPCM stream is arriving
    /// (~8000 would mean the radio ignored the rate and stayed at 8 kHz).
    private func noteRxAudio(_ payloadBytes: Int) {
        let now = Date()
        if linkTimeout > 0, now.timeIntervalSince(lastPcmDate) > linkTimeout {
            appLog("Icom[audio]: RX PCM resumed after \(Int(now.timeIntervalSince(lastPcmDate))) s gap")
            onPcmResumed?()
        }
        lastPcmDate = now
        if !rxAudioStarted {
            rxAudioStarted = true
            appLog("Icom[audio]: RX audio streaming started (\(payloadBytes)-byte payload)")
        }
        rxWindowPackets += 1
        rxWindowBytes += payloadBytes
        guard let start = rxWindowStart else { rxWindowStart = now; return }
        let dt = now.timeIntervalSince(start)
        if dt >= 5 {
            let samplesPerSec = Double(rxWindowBytes) / 2.0 / dt
            appLog(String(format: "Icom[audio]: RX %.1f pkt/s, ~%.0f samples/s (lost %d, recovered %d)",
                          Double(rxWindowPackets) / dt, samplesPerSec,
                          rxJitter.lostPackets, rxJitter.recoveredPackets))
            rxWindowStart = now
            rxWindowPackets = 0
            rxWindowBytes = 0
        }
    }

    /// Convert little-endian 16-bit PCM bytes to [Int16] and reorder by the
    /// packet's outer sequence — at 48 kHz the radio fragments the stream
    /// into 1364 B + 556 B packets, so out-of-order delivery would garble
    /// the reconstructed stream. (We always negotiate 16-bit LPCM.)
    private func deliverAudio(_ payload: Data.SubSequence) {
        typealias c = ControlField
        let bytes = Array(payload)
        guard bytes.count >= 2 else { return }
        var samples = [Int16](repeating: 0, count: bytes.count / 2)
        for i in 0..<samples.count {
            let lo = UInt16(bytes[i * 2])
            let hi = UInt16(bytes[i * 2 + 1])
            samples[i] = Int16(bitPattern: lo | (hi << 8))
        }
        rxJitter.add(seq: current[c.sequence].u16, samples: samples)
    }

    /// In-order 48 kHz PCM from the jitter buffer → decimate to the 8 kHz
    /// modem rate → decoder.
    private func handleOrderedRxAudio(_ samples: [Int16]) {
        let modemSamples = rxDownsampler.process(samples)
        if !modemSamples.isEmpty {
            onRxAudio?(modemSamples)
        }
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
