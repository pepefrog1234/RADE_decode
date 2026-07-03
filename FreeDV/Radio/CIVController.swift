//
//  CIVController.swift
//  FreeDV
//
//  Builds and parses Icom CI-V frames carried over the serial UDP stream.
//  A CI-V frame is: FE FE <dest> <src> <cmd> [sub] [data…] FD.
//  IC-705 default transceiver address is 0xA4; the host uses 0xE0.
//

import Foundation

/// Operating modes (CI-V mode byte from command 0x04/0x06).
enum RadioMode: UInt8, CaseIterable, CustomStringConvertible {
    case lsb  = 0x00
    case usb  = 0x01
    case am   = 0x02
    case cw   = 0x03
    case rtty = 0x04
    case fm   = 0x05
    case wfm  = 0x06
    case cwr  = 0x07
    case rttyr = 0x08
    case dv   = 0x17

    var description: String {
        switch self {
        case .lsb: return "LSB"
        case .usb: return "USB"
        case .am: return "AM"
        case .cw: return "CW"
        case .rtty: return "RTTY"
        case .fm: return "FM"
        case .wfm: return "WFM"
        case .cwr: return "CW-R"
        case .rttyr: return "RTTY-R"
        case .dv: return "DV"
        }
    }
}

/// Modulation input source selectable via CI-V 0x1A 0x05 registers 0118/0119
/// (IC-705 values; wfview rigs/IC-705.rig "Data Off Mod Input"/"DATA1 Mod Input").
enum ModInputSource: UInt8 {
    case mic    = 0x00
    case usb    = 0x01
    case micUsb = 0x02
    case wlan   = 0x03
}

final class CIVController {
    /// Radio (transceiver) CI-V address. IC-705 default 0xA4; overwritten from
    /// the capabilities packet once known.
    var radioAddr: UInt8 = 0xA4
    let hostAddr: UInt8 = 0xE0

    // Parsed-state callbacks (invoked on the serial stream queue).
    var onFrequency: ((UInt64) -> Void)?
    var onMode: ((RadioMode, _ dataMode: Bool) -> Void)?
    var onPTT: ((Bool) -> Void)?

    // MARK: - Frame building

    private func frame(cmd: UInt8, sub: UInt8? = nil, data: Data? = nil) -> Data {
        var bytes: [UInt8] = [0xFE, 0xFE, radioAddr, hostAddr, cmd]
        if let sub { bytes.append(sub) }
        var frame = Data(bytes)
        if let data { frame.append(data) }
        frame.append(0xFD)
        return frame
    }

    func readFrequencyFrame() -> Data { frame(cmd: 0x03) }
    func readModeFrame() -> Data { frame(cmd: 0x04) }
    func readPTTFrame() -> Data { frame(cmd: 0x1C, sub: 0x00) }

    func setFrequencyFrame(_ hz: UInt64) -> Data {
        frame(cmd: 0x00, data: CIVController.freqToBCD(hz))
    }

    func setModeFrame(_ mode: RadioMode, filter: UInt8 = 0x01) -> Data {
        frame(cmd: 0x06, data: Data([mode.rawValue, filter]))
    }

    /// Set the data-mode flag (USB-D / LSB-D). `on` enables data mode; `filter`
    /// selects FIL1/2/3. Command 0x1A 0x06.
    func setDataModeFrame(on: Bool, filter: UInt8 = 0x01) -> Data {
        frame(cmd: 0x1A, sub: 0x06, data: Data([on ? 0x01 : 0x00, filter]))
    }

    /// Read the data-mode flag (command 0x1A 0x06, no data).
    func readDataModeFrame() -> Data { frame(cmd: 0x1A, sub: 0x06) }

    /// Set mode + data-mode + filter atomically (command 0x26). This is the
    /// reliable way to engage USB-D on the IC-705.
    /// `26 00 <mode> <data 00/01> <filter 01-03>`
    func setModeDataFrame(_ mode: RadioMode, dataOn: Bool, filter: UInt8 = 0x01) -> Data {
        frame(cmd: 0x26, sub: 0x00, data: Data([mode.rawValue, dataOn ? 0x01 : 0x00, filter]))
    }

    /// Read current mode/data/filter (command 0x26 0x00).
    func readModeDataFrame() -> Data { frame(cmd: 0x26, sub: 0x00) }

    /// Set the modulation input used while data mode is ON (SET > Connectors >
    /// MOD Input > DATA MOD). Command 0x1A 0x05 register 0119.
    func setDataModInputFrame(_ source: ModInputSource) -> Data {
        frame(cmd: 0x1A, sub: 0x05, data: Data([0x01, 0x19, source.rawValue]))
    }

    /// Read the DATA MOD input source (command 0x1A 0x05 register 0119).
    func readDataModInputFrame() -> Data {
        frame(cmd: 0x1A, sub: 0x05, data: Data([0x01, 0x19]))
    }

    func setPTTFrame(_ transmit: Bool) -> Data {
        frame(cmd: 0x1C, sub: 0x00, data: Data([transmit ? 0x01 : 0x00]))
    }

    // MARK: - Response parsing

    /// Parse an incoming CI-V payload and fire the relevant callback.
    func parse(_ civData: Data) {
        typealias f = CIVFrameField
        let bytes = Array(civData)
        guard bytes.count >= 6, bytes[0] == 0xFE, bytes[1] == 0xFE else { return }
        let dest = bytes[2]
        // Ignore frames not addressed to us or to broadcast (0x00).
        guard dest == hostAddr || dest == 0x00 else { return }
        let cmd = bytes[f.cmd.0]

        switch cmd {
        case 0x00, 0x03:
            // Operating frequency (5 BCD bytes at offset 5).
            guard bytes.count >= 5 + 5 + 1 else { return }
            let hz = CIVController.bcdToFreq(Data(bytes[5..<10]))
            onFrequency?(hz)

        case 0x01, 0x04:
            // Mode + filter (2 bytes at offset 5).
            guard bytes.count >= 5 + 1 + 1 else { return }
            if let mode = RadioMode(rawValue: bytes[5]) {
                onMode?(mode, false)
            }

        case 0x1A:
            // 0x1A 0x06 => data-mode read/echo.
            guard bytes.count >= 7, bytes[f.subCmd.0] == 0x06 else { return }
            let dataOn = bytes[6] != 0x00
            // Report data-mode state; keep last known base mode (USB assumed).
            onMode?(.usb, dataOn)

        case 0x26:
            // 0x26 0x00 => mode + data-mode + filter (read/echo).
            guard bytes.count >= 9, bytes[f.subCmd.0] == 0x00 else { return }
            if let mode = RadioMode(rawValue: bytes[6]) {
                let dataOn = bytes[7] != 0x00
                onMode?(mode, dataOn)
            }

        case 0x1C:
            // 0x1C 0x00 => PTT state.
            guard bytes.count >= 7, bytes[f.subCmd.0] == 0x00 else { return }
            onPTT?(bytes[6] != 0x00)

        default:
            break
        }
    }

    // MARK: - BCD helpers

    /// Encode a frequency in Hz to 5 little-endian packed-BCD bytes.
    static func freqToBCD(_ hz: UInt64) -> Data {
        var digits = [UInt8](repeating: 0, count: 10)
        var f = hz
        for i in 0..<10 { digits[i] = UInt8(f % 10); f /= 10 }
        var bytes = [UInt8](repeating: 0, count: 5)
        for i in 0..<5 { bytes[i] = digits[i * 2] | (digits[i * 2 + 1] << 4) }
        return Data(bytes)
    }

    /// Decode 5 little-endian packed-BCD bytes to a frequency in Hz.
    static func bcdToFreq(_ data: Data) -> UInt64 {
        var f: UInt64 = 0
        var mult: UInt64 = 1
        for byte in data {
            f += UInt64(byte & 0x0F) * mult; mult *= 10
            f += UInt64(byte >> 4) * mult; mult *= 10
        }
        return f
    }
}
