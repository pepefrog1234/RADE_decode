//
//  RadioCredentialsStore.swift
//  FreeDV
//
//  Persists IC-705 connection settings: host/port/username/computer in
//  UserDefaults, password in the Keychain. Defaults target the IC-705 WiFi
//  Access-Point mode.
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// Which source feeds the RADE demodulator.
enum AudioInputSource: String {
    case device        // iPhone mic / USB sound card (existing behaviour)
    case icomRadio     // IC-705 over WiFi
}

enum RadioSettings {
    private static let d = UserDefaults.standard

    // Keys
    private static let kHost = "radioHost"
    private static let kControlPort = "radioControlPort"
    private static let kUsername = "radioUsername"
    private static let kComputer = "radioComputer"
    private static let kAudioSource = "audioInputSource"
    private static let kEnableTx = "radioEnableTx"

    // Defaults (IC-705 AP mode)
    static let defaultHost = "192.168.0.1"
    static let defaultControlPort: UInt16 = 50001

    static var host: String {
        get { d.string(forKey: kHost) ?? defaultHost }
        set { d.set(newValue, forKey: kHost) }
    }

    static var controlPort: UInt16 {
        get {
            let v = d.integer(forKey: kControlPort)
            return v > 0 ? UInt16(v) : defaultControlPort
        }
        set { d.set(Int(newValue), forKey: kControlPort) }
    }

    /// CI-V / audio ports follow the control port (50002 / 50003 by default).
    static var serialPort: UInt16 { controlPort &+ 1 }
    static var audioPort: UInt16 { controlPort &+ 2 }

    static var username: String {
        get { d.string(forKey: kUsername) ?? "" }
        set { d.set(newValue, forKey: kUsername) }
    }

    static var computer: String {
        get {
            if let name = d.string(forKey: kComputer), !name.isEmpty { return name }
            #if os(iOS)
            return UIDevice.current.name
            #else
            return "FreeDV-iOS"
            #endif
        }
        set { d.set(newValue, forKey: kComputer) }
    }

    static var audioInputSource: AudioInputSource {
        get { AudioInputSource(rawValue: d.string(forKey: kAudioSource) ?? "") ?? .device }
        set { d.set(newValue.rawValue, forKey: kAudioSource) }
    }

    static var enableTx: Bool {
        get { d.object(forKey: kEnableTx) as? Bool ?? true }
        set { d.set(newValue, forKey: kEnableTx) }
    }

    static var password: String {
        get { RadioKeychain.password ?? "" }
        set { RadioKeychain.password = newValue }
    }
}

/// Minimal Keychain wrapper for the radio password.
enum RadioKeychain {
    private static let account = "ic705.password"
    private static let service = "yakumo2683.FreeDV.radio"

    static var password: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: service
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue, let data = newValue.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
