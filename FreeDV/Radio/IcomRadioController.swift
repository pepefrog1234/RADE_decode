//
//  IcomRadioController.swift
//  FreeDV
//
//  Top-level orchestrator for an IC-705 WiFi connection. Owns the control,
//  serial (CI-V), and audio UDP streams, drives the login/token handshake,
//  exposes radio state to SwiftUI, and bridges RX/TX audio to AudioManager.
//
//  This is a plain ObservableObject (not @MainActor): @Published state is
//  always written on the main queue, while audio/CI-V I/O can be driven from
//  any thread (the streams are internally serialized on their own queues).
//

import Foundation
import Combine

final class IcomRadioController: ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    // MARK: Published state (written on main)
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var statusText = ""
    @Published private(set) var radioName = ""
    @Published private(set) var frequencyHz: UInt64 = 0
    @Published private(set) var mode: RadioMode = .usb
    @Published private(set) var dataMode = false
    @Published private(set) var isTransmitting = false

    var isConnected: Bool { connectionState == .connected }

    /// RX modem samples from the radio (8 kHz 16-bit mono). Called on the audio
    /// stream's queue — do NOT touch the main queue here.
    var onRxAudio: (([Int16]) -> Void)?

    // MARK: Streams (guarded by streamsLock)
    private let streamsLock = NSLock()
    private var controlStream: IcomControlStream?
    private var serialStream: IcomSerialStream?
    private var audioStream: IcomAudioStream?
    private let civ = CIVController()

    private var host = RadioSettings.defaultHost
    private let audioFormat = IcomAudioFormat.freeDVDefault
    /// Last frequency seen by the CI-V parser (serial-queue only) — used to
    /// detect 10 MHz sideband-convention crossings.
    private var lastFrequencyOnSerial: UInt64 = 0

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - Connect / disconnect

    // Auto-reconnect state (main-thread confined).
    private var userInitiatedDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    /// Main thread only (called from the UI).
    func connect() {
        guard connectionState == .disconnected || isFailed else { return }
        userInitiatedDisconnect = false
        reconnectAttempts = 0
        openConnection()
    }

    /// Build and start the control stream (also used by auto-reconnect).
    private func openConnection() {
        host = RadioSettings.host
        let username = RadioSettings.username
        let password = RadioSettings.password
        let computer = RadioSettings.computer
        let controlPort = RadioSettings.controlPort

        appLog("Icom: connecting to \(host):\(controlPort) user=\(username) computer=\(computer)")
        onMain {
            self.connectionState = .connecting
            self.statusText = "Connecting…"
        }

        let control = IcomControlStream(host: host, controlPort: controlPort,
                                        civPort: RadioSettings.serialPort,
                                        audioPort: RadioSettings.audioPort,
                                        enableTx: RadioSettings.enableTx,
                                        builder: makeBuilder(username, password, computer))
        // Watchdog runs from socket-ready: a connect that can't complete its
        // handshake (radio off, port bind collision) — or an established
        // session that goes silent — is declared dead within 5 s. (Our pings
        // run every 3 s to match the Android cadence, so the timeout must
        // exceed one ping period plus jitter.)
        control.linkTimeout = 5
        control.onState = { [weak self] text in self?.onMain { self?.statusText = text } }
        control.onConnected = { [weak self] up in self?.handleControlConnected(up) }
        control.onRadioInfo = { [weak self] name, civAddr in
            self?.onMain { self?.radioName = name }
            self?.civ.radioAddr = civAddr
        }
        control.onFullyConnected = { [weak self] in self?.startMediaStreams() }

        streamsLock.lock(); controlStream = control; streamsLock.unlock()
        control.start()
    }

    /// Main thread only (called from the UI).
    func disconnect() {
        appLog("Icom: disconnecting")
        userInitiatedDisconnect = true
        teardownStreams(sendGoodbye: true)
        onMain {
            self.connectionState = .disconnected
            self.statusText = "Disconnected"
            self.isTransmitting = false
        }
    }

    /// Detach and shut down all streams. Goodbye packets are only worth
    /// sending on a live link (user-initiated disconnect); on a dead one the
    /// streams are just cancelled. Stale callbacks are cleared so a dying
    /// stream's events can't re-trigger reconnect logic.
    private func teardownStreams(sendGoodbye: Bool) {
        streamsLock.lock()
        let control = controlStream, serial = serialStream, audio = audioStream
        controlStream = nil; serialStream = nil; audioStream = nil
        streamsLock.unlock()

        for stream in [control as IcomUDPStream?, serial, audio] {
            stream?.onConnected = nil
            stream?.onState = nil
        }
        if sendGoodbye {
            control?.disconnect()
            serial?.disconnect()
            audio?.disconnect()
            // Short grace for the goodbye datagrams to flush, then release
            // the sockets quickly — the fixed local ports (50001-3) must be
            // free before any reconnect, or the new streams hit EADDRINUSE
            // and hang in .waiting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                control?.cancel(); serial?.cancel(); audio?.cancel()
            }
        } else {
            control?.cancel(); serial?.cancel(); audio?.cancel()
        }
    }

    private func makeBuilder(_ user: String, _ password: String, _ computer: String) -> IcomPacketBuilder {
        IcomPacketBuilder(username: user, password: password,
                          computer: computer, audioFormat: audioFormat)
    }

    private var isFailed: Bool {
        if case .failed = connectionState { return true }
        return false
    }

    // Whether the lightweight conninfo nudge has already been tried for the
    // current audio-death episode (main-confined).
    private var audioNudgeAttempted = false

    /// The radio stopped streaming PCM. First try re-sending the conninfo
    /// over the (still healthy) control link — that usually restarts the
    /// radio's audio session in under a second. Only if PCM stays dead for
    /// another watchdog period escalate to a full reconnect. Main thread.
    private func handleAudioDeath() {
        guard !userInitiatedDisconnect, connectionState == .connected else {
            handleControlConnected(false)
            return
        }
        if !audioNudgeAttempted {
            audioNudgeAttempted = true
            appLog("Icom: audio PCM stopped — nudging with a fresh conninfo before reconnecting")
            streamsLock.lock()
            let control = controlStream, audio = audioStream
            streamsLock.unlock()
            control?.queue.async { control?.resendConnInfo() }
            audio?.queue.async { audio?.rearmAfterNudge() }
            // The flag is cleared only by onPcmResumed — if PCM stays dead,
            // the next watchdog firing escalates to a full reconnect.
        } else {
            appLog("Icom: conninfo nudge didn't revive the audio stream — full reconnect")
            audioNudgeAttempted = false
            handleControlConnected(false)
        }
    }

    private func handleControlConnected(_ up: Bool) {
        onMain {
            if up {
                self.connectionState = .connected
                self.reconnectAttempts = 0
                return
            }
            guard !self.userInitiatedDisconnect,
                  self.connectionState != .disconnected else { return }
            if self.connectionState == .connected {
                // Established session died (radio watchdog dropped us after a
                // WiFi stall, radio powered off, …) — reconnect automatically.
                self.scheduleReconnect()
            } else if self.reconnectAttempts == 0 {
                // Initial user-initiated connect failed — no auto-retry.
                self.connectionState = .failed(self.statusText)
            }
            // else: noise during a reconnect attempt (stale stream events);
            // the attempt-timeout below drives the next retry.
        }
    }

    /// Tear down and schedule the next reconnect attempt. Main thread only.
    private func scheduleReconnect() {
        teardownStreams(sendGoodbye: false)
        guard reconnectAttempts < maxReconnectAttempts else {
            appLog("Icom: giving up after \(maxReconnectAttempts) reconnect attempts")
            connectionState = .failed("Connection lost")
            statusText = "Connection lost"
            return
        }
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        // First retry almost immediately (the sockets were just released);
        // back off only if the radio stays unreachable.
        let delay = attempt == 1 ? 0.5 : min(Double(attempt - 1) * 2.0, 8.0)
        connectionState = .connecting
        statusText = "Connection lost — reconnecting (\(attempt)/\(maxReconnectAttempts))…"
        appLog("Icom: link lost — reconnect attempt \(attempt)/\(maxReconnectAttempts) in \(String(format: "%.1f", delay)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.userInitiatedDisconnect,
                  self.reconnectAttempts == attempt,
                  self.connectionState == .connecting else { return }
            self.openConnection()
            // If this attempt hasn't established within 6 s, move on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self, !self.userInitiatedDisconnect,
                      self.reconnectAttempts == attempt,
                      self.connectionState == .connecting else { return }
                appLog("Icom: reconnect attempt \(attempt) timed out")
                self.scheduleReconnect()
            }
        }
    }

    private func startMediaStreams() {
        streamsLock.lock()
        let alreadyStarted = serialStream != nil
        streamsLock.unlock()
        guard !alreadyStarted else { return }

        let username = RadioSettings.username
        let password = RadioSettings.password
        let computer = RadioSettings.computer

        // CI-V callbacks (fire on serial queue → hop to main for @Published).
        civ.onFrequency = { [weak self] hz in
            guard let self else { return }
            // Auto-flip the sideband when the dial crosses the 10 MHz
            // convention boundary (LSB-D below, USB-D above).
            let previous = self.lastFrequencyOnSerial
            self.lastFrequencyOnSerial = hz
            if previous > 0, self.freeDVMode(forHz: previous) != self.freeDVMode(forHz: hz) {
                let mode = self.freeDVMode(forHz: hz)
                appLog("Icom: dial crossed 10 MHz — switching to \(mode)-D")
                self.withSerial {
                    $0.sendCiv(self.civ.setModeDataFrame(mode, dataOn: true))
                    $0.sendCiv(self.civ.readModeDataFrame())
                }
            }
            self.onMain { self.frequencyHz = hz }
        }
        civ.onMode = { [weak self] mode, data in
            appLog("Icom: mode readback = \(mode)\(data ? "-D" : "") (dataMode=\(data))")
            self?.onMain { self?.mode = mode; self?.dataMode = data }
        }
        civ.onPTT = { [weak self] tx in self?.onMain { self?.isTransmitting = tx } }

        let serial = IcomSerialStream(host: host, port: RadioSettings.serialPort,
                                      builder: makeBuilder(username, password, computer))
        serial.onCivData = { [weak self] data in
            appLog("Icom[civ] rx: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
            self?.civ.parse(data)
        }
        serial.onState = { [weak self] text in self?.onMain { self?.statusText = text } }

        let audio = IcomAudioStream(host: host, port: RadioSettings.audioPort,
                                    enableTx: RadioSettings.enableTx,
                                    builder: makeBuilder(username, password, computer))
        // From socket-ready: no PCM within 6 s (handshake stuck on a port
        // bind collision, or the radio not streaming) → declared dead.
        // Healthy PCM is a continuous 100 pkt/s, so 6 s is unambiguous.
        audio.linkTimeout = 6
        audio.onRxAudio = { [weak self] samples in self?.onRxAudio?(samples) }
        audio.onState = { text in appLog("Icom[audio]: \(text)") }
        audio.onConnected = { [weak self] up in
            appLog("Icom[audio]: connected=\(up)")
            // The radio can silently stop streaming PCM while its control
            // session stays alive (a firmware quirk after some overs).
            if !up { self?.onMain { self?.handleAudioDeath() } }
        }
        audio.onPcmResumed = { [weak self] in
            self?.onMain { self?.audioNudgeAttempted = false }
        }

        streamsLock.lock(); serialStream = serial; audioStream = audio; streamsLock.unlock()
        serial.start()
        audio.start()

        // If this is an auto-reconnect while the user is still holding PTT,
        // the fresh audio stream must resume transmitting (and re-key, since
        // the radio dropped PTT with the old session).
        onMain {
            if self.isTransmitting {
                appLog("Icom: reconnected while PTT held — re-keying")
                self.withSerial { $0.sendCiv(self.civ.setPTTFrame(true)) }
                audio.queue.async { audio.setTxActive(true) }
            }
        }

        // Poll current frequency and mode once the serial link settles.
        serial.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            serial.sendCiv(self.civ.readFrequencyFrame())
            serial.sendCiv(self.civ.readModeFrame())
        }

        // Once the initial poll has answered, put the radio into FreeDV
        // operating mode (LSB-D/USB-D per band + DATA MOD=WLAN) so RX decode
        // works immediately — without this the radio may sit on the wrong
        // sideband and RADE never syncs.
        scheduleInitialFreeDVConfig()
    }

    /// Run the connect-time FreeDV mode configuration — but only once the
    /// frequency readback has arrived, so the sideband choice is real
    /// (a blind config at freq=0 once forced USB-D on a 40 m dial).
    private func scheduleInitialFreeDVConfig(attempt: Int = 1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.isConnected else { return }
            if self.frequencyHz == 0 {
                guard attempt < 4 else {
                    // Frequency never arrived — run the freq-unknown-safe
                    // config: data mode + DATA MOD=WLAN in the radio's CURRENT
                    // sideband (configureForFreeDVTransmit's hz==0 branch never
                    // guesses the sideband, so the old blind-USB-D-on-40m
                    // hazard doesn't apply). Leaving this to the first PTT was
                    // not safe: its fast path skips the WLAN assertion when
                    // the radio already sits in the right sideband-D.
                    appLog("Icom: frequency still unknown — configuring data mode + DATA MOD=WLAN in current sideband")
                    self.configureForFreeDVTransmit()
                    return
                }
                appLog("Icom: frequency not read yet — delaying FreeDV config (try \(attempt))")
                self.withSerial { serial in
                    // The CI-V pipe may never have opened (the open request
                    // is a single unacknowledged packet) — re-open with the
                    // retry, then poll again.
                    serial.resendOpen()
                    serial.sendCiv(self.civ.readFrequencyFrame())
                }
                self.scheduleInitialFreeDVConfig(attempt: attempt + 1)
                return
            }
            self.configureForFreeDVTransmit()
        }
    }

    // MARK: - Control API

    private func withSerial(_ block: @escaping (IcomSerialStream) -> Void) {
        streamsLock.lock(); let serial = serialStream; streamsLock.unlock()
        guard let serial else { return }
        serial.queue.async { block(serial) }
    }

    func setFrequency(_ hz: UInt64) {
        appLog("Icom: set frequency \(hz) Hz")
        withSerial {
            $0.sendCiv(self.civ.setFrequencyFrame(hz))
            // Read back: the radio doesn't broadcast CI-V-commanded changes,
            // so without this the app keeps showing the old frequency. The
            // readback also drives the 10 MHz sideband auto-switch.
            $0.sendCiv(self.civ.readFrequencyFrame())
        }
    }

    func setMode(_ mode: RadioMode) {
        appLog("Icom: set mode \(mode)")
        withSerial {
            $0.sendCiv(self.civ.setModeFrame(mode))
            $0.sendCiv(self.civ.readModeDataFrame())
        }
    }

    /// Amateur-band sideband convention: LSB below 10 MHz, USB at/above.
    /// Unknown frequency (0, not yet read back) falls back to USB.
    private func freeDVMode(forHz hz: UInt64) -> RadioMode {
        (hz > 0 && hz < 10_000_000) ? .lsb : .usb
    }

    /// Configure for FreeDV only when the radio isn't already in the target
    /// sideband-D mode — skips ~5 CI-V round-trips on every PTT press, so
    /// keying is snappier once the radio is set up.
    func configureForFreeDVTransmitIfNeeded() {
        let target = freeDVMode(forHz: frequencyHz)
        if mode == target && dataMode {
            // Mode and filter are right — but never trust the DATA MOD input:
            // the connect-time config is skipped entirely when the frequency
            // readback times out, the cached mode/dataMode survive reconnects,
            // and the 0119 readback is never parsed, so a radio keyed with its
            // own DATA MOD default (USB/MIC) transmits near-silence while
            // everything else looks normal (found while triaging a quiet-TX
            // field report; that radio turned out to be set correctly, but
            // the hole is real). One idempotent set-frame per keyup guarantees
            // the WLAN source and keeps the fast-path latency win (no
            // mode/filter dance).
            appLog("Icom: FreeDV mode already \(target)-D — re-asserting DATA MOD=WLAN")
            withSerial {
                $0.sendCiv(self.civ.setDataModInputFrame(.wlan))
                $0.sendCiv(self.civ.readDataModInputFrame())
            }
            return
        }
        configureForFreeDVTransmit()
    }

    /// Put the radio in sideband + data mode (LSB-D below 10 MHz, USB-D above)
    /// with the WLAN audio stream as the modulation source — required before
    /// FreeDV transmit.
    func configureForFreeDVTransmit() {
        let hz = frequencyHz
        if hz == 0 {
            // Frequency unknown (early-session CI-V silence): never guess the
            // sideband — a blind USB-D once hit a 40 m dial. Turn on data mode
            // in the radio's CURRENT mode and set the WLAN input; the sideband
            // rule applies as soon as the frequency readback lands.
            appLog("Icom: configuring data mode + DATA MOD=WLAN (frequency unknown — keeping current sideband)")
            withSerial {
                $0.sendCiv(self.civ.setDataModeFrame(on: true))
                $0.sendCiv(self.civ.setDataModInputFrame(.wlan))
                $0.sendCiv(self.civ.readModeDataFrame())
                $0.sendCiv(self.civ.readDataModInputFrame())
                $0.sendCiv(self.civ.readFrequencyFrame())
            }
            return
        }
        let mode = freeDVMode(forHz: hz)
        appLog("Icom: configuring \(mode)-D + DATA MOD=WLAN for FreeDV TX (freq=\(hz) Hz)")
        withSerial {
            // Atomic mode+data+filter set (reliable on IC-705).
            $0.sendCiv(self.civ.setModeDataFrame(mode, dataOn: true))
            // Route TX modulation from the WLAN audio stream. The radio keys up
            // without this, but modulates from its DATA MOD default (USB/MIC),
            // so the WiFi audio never reaches the transmitter.
            $0.sendCiv(self.civ.setDataModInputFrame(.wlan))
            // Read back so the log shows the radio's actual mode/mod-input state.
            $0.sendCiv(self.civ.readModeDataFrame())
            $0.sendCiv(self.civ.readDataModInputFrame())
            // Refresh the cached frequency so the next PTT picks the right
            // sideband even if CI-V transceive updates are disabled.
            $0.sendCiv(self.civ.readFrequencyFrame())
        }
    }

    func setPTT(_ transmit: Bool) {
        appLog("Icom: PTT \(transmit ? "ON" : "OFF")")
        // Let the audio stream classify FIFO drains (mid-over vs flush).
        streamsLock.lock(); let audio = audioStream; streamsLock.unlock()
        audio?.queue.async { audio?.setTxActive(transmit) }
        withSerial { $0.sendCiv(self.civ.setPTTFrame(transmit)) }
        onMain { self.isTransmitting = transmit }
    }

    // MARK: - Audio

    /// Queue TX modem samples (8 kHz 16-bit mono) for the radio; the audio
    /// stream sends them at a steady 20 ms cadence. Safe to call from any thread.
    func sendTxAudio(_ samples: [Int16]) {
        streamsLock.lock(); let audio = audioStream; streamsLock.unlock()
        guard let audio else { return }
        audio.queue.async { audio.sendAudio(samples) }
    }

    /// Mark the end of TX audio (PTT released, EOO + padding queued) so the
    /// audio stream classifies the final FIFO drain as a normal flush. The
    /// stream keeps sending (silence) frames until PTT actually drops —
    /// stopping frames while the radio is still keyed makes it declare the
    /// client disconnected and kill the audio session.
    func noteTxAudioFlushing() {
        streamsLock.lock(); let audio = audioStream; streamsLock.unlock()
        audio?.queue.async { audio?.noteFlushing() }
    }
}
