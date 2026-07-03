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

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - Connect / disconnect

    func connect() {
        guard connectionState == .disconnected || isFailed else { return }
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

    func disconnect() {
        appLog("Icom: disconnecting")
        streamsLock.lock()
        let control = controlStream, serial = serialStream, audio = audioStream
        controlStream = nil; serialStream = nil; audioStream = nil
        streamsLock.unlock()

        control?.disconnect()
        serial?.disconnect()
        audio?.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            control?.cancel(); serial?.cancel(); audio?.cancel()
        }
        onMain {
            self.connectionState = .disconnected
            self.statusText = "Disconnected"
            self.isTransmitting = false
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

    private func handleControlConnected(_ up: Bool) {
        onMain {
            if up {
                self.connectionState = .connected
            } else if self.connectionState != .disconnected {
                self.connectionState = .failed(self.statusText)
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
        civ.onFrequency = { [weak self] hz in self?.onMain { self?.frequencyHz = hz } }
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
                                    builder: makeBuilder(username, password, computer))
        audio.onRxAudio = { [weak self] samples in self?.onRxAudio?(samples) }
        audio.onState = { text in appLog("Icom[audio]: \(text)") }
        audio.onConnected = { up in appLog("Icom[audio]: connected=\(up)") }

        streamsLock.lock(); serialStream = serial; audioStream = audio; streamsLock.unlock()
        serial.start()
        audio.start()

        // Poll current frequency and mode once the serial link settles.
        serial.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            serial.sendCiv(self.civ.readFrequencyFrame())
            serial.sendCiv(self.civ.readModeFrame())
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
        withSerial { $0.sendCiv(self.civ.setFrequencyFrame(hz)) }
    }

    func setMode(_ mode: RadioMode) {
        appLog("Icom: set mode \(mode)")
        withSerial { $0.sendCiv(self.civ.setModeFrame(mode)) }
    }

    /// Put the radio in USB + data mode with the WLAN audio stream as the
    /// modulation source — required before FreeDV transmit.
    func configureForFreeDVTransmit() {
        appLog("Icom: configuring USB-D + DATA MOD=WLAN for FreeDV TX")
        withSerial {
            // Atomic mode+data+filter set (reliable on IC-705).
            $0.sendCiv(self.civ.setModeDataFrame(.usb, dataOn: true))
            // Route TX modulation from the WLAN audio stream. The radio keys up
            // without this, but modulates from its DATA MOD default (USB/MIC),
            // so the WiFi audio never reaches the transmitter.
            $0.sendCiv(self.civ.setDataModInputFrame(.wlan))
            // Read back so the log shows the radio's actual mode/mod-input state.
            $0.sendCiv(self.civ.readModeDataFrame())
            $0.sendCiv(self.civ.readDataModInputFrame())
        }
    }

    func setPTT(_ transmit: Bool) {
        appLog("Icom: PTT \(transmit ? "ON" : "OFF")")
        withSerial { $0.sendCiv(self.civ.setPTTFrame(transmit)) }
        onMain { self.isTransmitting = transmit }
    }

    // MARK: - Audio

    /// Send one packet of TX modem samples (8 kHz 16-bit mono) to the radio.
    /// Safe to call from any thread.
    func sendTxAudio(_ samples: [Int16]) {
        streamsLock.lock(); let audio = audioStream; streamsLock.unlock()
        guard let audio else { return }
        audio.queue.async { audio.sendAudio(samples) }
    }
}
