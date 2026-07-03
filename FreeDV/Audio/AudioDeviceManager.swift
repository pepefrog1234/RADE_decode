import SwiftUI
import AVFoundation
import Combine

#if os(iOS)
/// Represents an available audio output device.
struct OutputDevice: Identifiable {
    let id: String          // "default" or "speaker"
    let name: String        // Display name
    let portType: String    // Port type description
    let isSpeaker: Bool     // True if built-in speaker override
}
#endif

let kUnknownAudioDeviceName: String = "Unknown"

/// Manages iOS audio device enumeration and routing.
class AudioDeviceManager: ObservableObject {
    
    @Published var currentInputName: String = kUnknownAudioDeviceName
    @Published var currentOutputName: String = kUnknownAudioDeviceName
    
    #if os(iOS)
    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    @Published var availableOutputs: [OutputDevice] = []
    @Published var selectedOutputId: String = "default"
    
    // User audio device preferences (speaker + microphone, separate from transceiver)
    @Published var userInputName: String = kUnknownAudioDeviceName
    @Published var userOutputName: String = kUnknownAudioDeviceName
    @Published var selectedUserOutputId: String = "speaker"
    @Published var selectedUserInputUID: String?
    
    private static let kUserInputUIDKey = "userAudioInputUID"
    private static let kUserOutputIdKey = "userAudioOutputId"

    #endif
    
    init() {
        #if os(iOS)
        // Restore saved user audio preferences
        selectedUserInputUID = UserDefaults.standard.string(forKey: Self.kUserInputUIDKey)
        selectedUserOutputId = UserDefaults.standard.string(forKey: Self.kUserOutputIdKey) ?? "speaker"
        
        updateDeviceInfo()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        #else
        currentInputName = "Default Input"
        currentOutputName = "Default Output"
        #endif
    }
    
    func updateDeviceInfo() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        
        DispatchQueue.main.async {
            self.currentInputName = route.inputs.first?.portName ?? "None"
            self.currentOutputName = route.outputs.first?.portName ?? "None"
            self.availableInputs = session.availableInputs ?? []
            self.buildOutputList(route: route)
            self.resolveUserAudioDeviceNames()
        }
        #endif
    }
    
    #if os(iOS)
    /// Build available output device list from current route.
    private func buildOutputList(route: AVAudioSessionRouteDescription) {
        var outputs: [OutputDevice] = []
        
        // Add currently routed output as "default"
        if let current = route.outputs.first {
            // If current output IS the speaker, don't add it twice
            if current.portType != .builtInSpeaker {
                outputs.append(OutputDevice(
                    id: "default",
                    name: current.portName,
                    portType: current.portType.rawValue,
                    isSpeaker: false
                ))
            }
        }
        
        // Always offer built-in speaker
        outputs.append(OutputDevice(
            id: "speaker",
            name: "iPhone Speaker",
            portType: "Built-in Speaker",
            isSpeaker: true
        ))
        
        availableOutputs = outputs
    }
    
    /// Select an output device.
    /// Note: iOS treats USB audio as a paired input+output route.
    /// Switching output to speaker also changes input to built-in mic.
    /// There is no way to use USB input + speaker output simultaneously.
    func selectOutput(_ device: OutputDevice) {
        let session = AVAudioSession.sharedInstance()
        
        do {
            if device.isSpeaker {
                try session.overrideOutputAudioPort(.speaker)
                selectedOutputId = "speaker"
                appLog("Output → Speaker (input also changed to built-in mic)")
            } else {
                try session.overrideOutputAudioPort(.none)
                selectedOutputId = "default"
                appLog("Output → \(device.name)")
            }
            updateDeviceInfo()
        } catch {
            appLog("selectOutput FAILED: \(error)")
        }
    }
    
    /// Select a specific input port (e.g., USB audio device)
    func selectInput(_ port: AVAudioSessionPortDescription) {
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(port)
            updateDeviceInfo()
        } catch {
            print("Failed to select input: \(error)")
        }
    }
    
    /// Select user microphone input device and persist preference.
    func selectUserInput(_ port: AVAudioSessionPortDescription) {
        selectedUserInputUID = port.uid
        userInputName = port.portName
        UserDefaults.standard.set(port.uid, forKey: Self.kUserInputUIDKey)
    }
    
    /// Select user speaker output device and persist preference.
    func selectUserOutput(_ device: OutputDevice) {
        selectedUserOutputId = device.id
        userOutputName = device.name
        UserDefaults.standard.set(device.id, forKey: Self.kUserOutputIdKey)
    }
    
    /// Resolve user audio device display names from saved preferences.
    /// Clears preferences if the saved device is no longer available.
    private func resolveUserAudioDeviceNames() {
        // Resolve user input name from saved UID
        if let uid = selectedUserInputUID {
            if let match = availableInputs.first(where: { $0.uid == uid }) {
                userInputName = match.portName
            } else {
                // Saved device no longer available
                selectedUserInputUID = nil
                userInputName = kUnknownAudioDeviceName
                UserDefaults.standard.removeObject(forKey: Self.kUserInputUIDKey)
            }
        }
        
        // Resolve user output name ("speaker" is always valid)
        if selectedUserOutputId == "speaker" {
            userOutputName = "iPhone Speaker"
        } else if let match = availableOutputs.first(where: { $0.id == selectedUserOutputId }) {
            userOutputName = match.name
        } else {
            // Saved device no longer available — fall back to speaker
            selectedUserOutputId = "speaker"
            userOutputName = "iPhone Speaker"
            UserDefaults.standard.set("speaker", forKey: Self.kUserOutputIdKey)
        }
    }
    
    @objc private func routeChanged(_ notification: Notification) {
        updateDeviceInfo()
    }
    #endif
}
