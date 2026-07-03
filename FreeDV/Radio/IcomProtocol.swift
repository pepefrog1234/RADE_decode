//
//  IcomProtocol.swift
//  FreeDV
//
//  Icom OEM (RS-BA1 compatible) LAN protocol — packet layouts, type constants,
//  the username/password scramble, and a packet builder.
//
//  The wire format is reverse-engineered by the community (nonoo/kappanhang,
//  HA2NON, ES1AKOS) and implemented by wfview (GPLv3) and NetworkIcom (Swift).
//  Field offsets below mirror wfview's `packettypes.h`. All multi-byte control
//  fields are little-endian; a few audio/conninfo fields are big-endian and are
//  marked explicitly.
//
//  This file is platform-agnostic (Foundation only) so it compiles on the
//  simulator; the UDP transport that uses it is guarded separately.
//

import Foundation

// MARK: - Data helpers

/// Little-endian read/write + (offset,length) subscript used throughout the
/// Icom packet code. Scoped names (`u8`/`u16`/`u32`) avoid clashing with any
/// future Data extensions elsewhere in the app.
extension Data {
    /// First byte as Bool (non-zero == true).
    var boolByte: Bool { (self.first ?? 0) > 0 }

    var u8: UInt8 { readInt(UInt8.self) }
    var u16: UInt16 { readInt(UInt16.self) }
    var u32: UInt32 { readInt(UInt32.self) }

    /// ASCII string, dropping NUL padding.
    var asciiString: String {
        String(data: self.filter { $0 > 0 }, encoding: .utf8) ?? ""
    }

    /// Byte-offset + length subscript. Getter returns the sub-range; setter
    /// pads/truncates the assigned value to exactly `length` bytes.
    subscript(_ d: (Int, Int)) -> Data {
        get {
            let lower = startIndex + d.0
            let upper = Swift.min(lower + d.1, endIndex)
            guard lower <= upper, lower >= startIndex else { return Data() }
            return self[lower..<upper]
        }
        set {
            let lower = startIndex + d.0
            let upper = lower + d.1
            guard upper <= endIndex else { return }
            self[lower..<upper] = (newValue + Data(count: d.1)).prefix(d.1)
        }
    }

    private func readInt<T: FixedWidthInteger>(_ type: T.Type) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0) }
        return value
    }

    /// Little-endian bytes of an integer.
    init<T: FixedWidthInteger>(le value: T) {
        self = Swift.withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// ASCII bytes of a string (no NUL terminator).
    init(ascii value: String) {
        self = Data(Array(value.utf8))
    }

    /// Multi-line hex + ASCII dump for diagnostics.
    var hexDump: String {
        let columns = 16
        var result = ""
        let bytes = Array(self)
        for i in stride(from: 0, to: bytes.count, by: columns) {
            let j = Swift.min(i + columns, bytes.count)
            var hex = bytes[i..<j].map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = bytes[i..<j].map { (32..<128).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            let pad = (columns - (j - i)) * 3
            if pad > 0 { hex += String(repeating: " ", count: pad) }
            result += String(format: "\n  %04x  ", i) + hex + "  " + ascii
        }
        return result
    }
}

// MARK: - Packet field offsets (offset, length)

enum ControlField {
    static let dataLength = 0x10
    static let length   = (0x00, 4)
    static let type     = (0x04, 2)
    static let sequence = (0x06, 2)
    static let sendId   = (0x08, 4)
    static let recvId   = (0x0c, 4)
}

enum WatchdogField {
    static let dataLength = 0x14
}

enum PingField {
    static let dataLength = 0x15
    static let request = (0x10, 1)   // 0 = request, 1 = reply
    static let dataA   = (0x11, 2)
    static let dataB   = (0x13, 2)
}

enum OpenCloseField {
    static let dataLength = 0x16
    static let cmd      = (0x10, 1)  // 0xc0
    static let length   = (0x11, 2)  // 0x0001
    static let sequence = (0x13, 2)  // big-endian civ sequence
    static let request  = (0x15, 1)  // open=0x04 close=0x00
}

enum CIVField {
    static let headerLength = 0x15
    static let cmd      = (0x10, 1)  // 0xc1
    static let length   = (0x11, 2)  // CI-V payload length (little-endian)
    static let sequence = (0x13, 2)
}

/// Offsets *within* the CI-V payload (fe fe dst src cmd ...).
enum CIVFrameField {
    static let dest   = (0x02, 1)
    static let src    = (0x03, 1)
    static let cmd    = (0x04, 1)
    static let subCmd = (0x05, 1)
}

enum RetransmitField {
    static let dataLength = 0x18
}

enum TokenField {
    static let dataLength = 0x40
    static let code     = (0x13, 2)
    static let res      = (0x15, 2)
    static let sequence = (0x17, 1)
    static let tokRequest = (0x1a, 2)
    static let token    = (0x1c, 4)
    static let commCap  = (0x27, 2)
    static let reqReply = (0x29, 1)
    static let macAddr  = (0x2a, 6)
}

enum StatusField {
    static let dataLength = 0x50
    static let civPort   = (0x40, 4)   // big-endian
    static let audioPort = (0x44, 4)   // big-endian
}

enum LoginResponseField {
    static let dataLength = 0x60
    static let netType = (0x40, 16)
}

enum LoginField {
    static let dataLength = 0x80
    static let userName = (0x40, 16)
    static let password = (0x50, 16)
    static let computer = (0x60, 16)
}

enum ConnInfoField {
    static let dataLength = 0x90
    static let radio     = (0x40, 16)
    static let userName  = (0x60, 16)
    static let enableRx  = (0x70, 1)
    static let enableTx  = (0x71, 1)
    static let rxCodec   = (0x72, 1)
    static let txCodec   = (0x73, 1)
    static let rxSample  = (0x74, 4)   // big-endian
    static let txSample  = (0x78, 4)   // big-endian
    static let civPort   = (0x7c, 4)   // big-endian
    static let audioPort = (0x80, 4)   // big-endian
    static let txBuffer  = (0x84, 4)
    static let convert   = (0x88, 1)
}

enum CapabilitiesField {
    static let dataLength = 0xa8
    static let radio    = (0x52, 16)
    static let civAddr  = (0x94, 1)
}

enum AudioField {
    static let headerLength = 0x18
    static let ident    = (0x10, 2)
    static let sequence = (0x12, 2)    // big-endian
    static let length   = (0x14, 4)    // big-endian
}

// MARK: - Packet type constants

enum ControlPacketType {
    static let idle        = UInt16(0)
    static let retransmit  = UInt16(1)
    static let areYouThere = UInt16(3)
    static let iAmHere     = UInt16(4)
    static let disconnect  = UInt16(5)
    static let areYouReady = UInt16(6)   // same value used for iAmReady
    static let iAmReady    = UInt16(6)
}

enum PingPacketType { static let ping = UInt16(7) }

enum OpenCloseRequest {
    static let open  = UInt8(4)
    static let close = UInt8(0)
}

enum TokenType {
    static let remove      = UInt16(1)
    static let acknowledge = UInt16(2)
    static let renew       = UInt16(5)
}

enum PacketCode {
    static let login     = UInt16(0x170)
    static let token     = UInt16(0x130)
    static let connInfo  = UInt16(0x180)
    static let connInfoRes = UInt16(0x03)
    static let openClose = UInt8(0xc0)
    static let civ       = UInt8(0xc1)
}

enum CommonCap { static let value = UInt32(0x8001) }

// MARK: - Username/password scramble (RS-BA1)

/// Encode a username or password into the 16-byte zero-padded scrambled form
/// the radio expects. Table taken verbatim from the reverse-engineered
/// protocol (wfview / NetworkIcom).
func icomEncode(_ text: String) -> Data {
    let length = 16
    let key: [UInt8] = [
        0x47,
        0x5d,0x4c,0x42,0x66,0x20,0x23,0x46,0x4e,0x57,0x45,0x3d,0x67,0x76,0x60,0x41,0x62,
        0x39,0x59,0x2d,0x68,0x7e,0x7c,0x65,0x7d,0x49,0x29,0x72,0x73,0x78,0x21,0x6e,0x5a,
        0x5e,0x4a,0x3e,0x71,0x2c,0x2a,0x54,0x3c,0x3a,0x63,0x4f,0x43,0x75,0x27,0x79,0x5b,
        0x35,0x70,0x48,0x6b,0x56,0x6f,0x34,0x32,0x6c,0x30,0x61,0x6d,0x7b,0x2f,0x4b,0x64,
        0x38,0x2b,0x2e,0x50,0x40,0x3f,0x55,0x33,0x37,0x25,0x77,0x24,0x26,0x74,0x6a,0x28,
        0x53,0x4d,0x69,0x22,0x5c,0x44,0x31,0x36,0x58,0x3b,0x7a,0x51,0x5f,0x52]
    let scrambled = text.prefix(length).utf8.enumerated().map { (index, item) -> UInt8 in
        let p = index + Int(item)
        return key[(p > 126 ? 32 + p % 127 : p) - 32]
    }
    let pad = Swift.max(0, length - scrambled.count)
    return Data(scrambled) + Data(count: pad)
}

// MARK: - Audio format descriptor

/// Describes the PCM format negotiated for the radio audio stream.
/// FreeDV defaults to 8 kHz / mono / 16-bit LPCM — exactly RADE's modem rate,
/// so no resampling is needed on the network audio path.
struct IcomAudioFormat {
    var rate: UInt16
    var channels: UInt8
    var size: UInt8       // bytes per sample (1 or 2)
    var uLaw: Bool

    static let freeDVDefault = IcomAudioFormat(rate: 8000, channels: 1, size: 2, uLaw: false)

    var bytesPerFrame: UInt8 { channels * size }

    /// Codec selector byte sent in the conninfo packet.
    var codecByte: UInt8 {
        if channels == 2 {
            if size == 1 { return uLaw ? 0x20 : 0x08 }
            return 0x10
        } else {
            if size == 1 { return uLaw ? 0x01 : 0x02 }
            return 0x04
        }
    }
}
