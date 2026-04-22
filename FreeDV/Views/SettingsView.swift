import SwiftUI
import SwiftData
import AVFoundation
import CoreLocation
import Combine

/// Settings page for audio device selection and app configuration.
struct SettingsView: View {
    @Bindable var reporter: FreeDVReporter
    @StateObject private var deviceManager = AudioDeviceManager()
    @StateObject private var locationHelper = LocationHelper()
    @AppStorage("fftEnabledPreference") private var fftEnabledPreference = true
    @AppStorage("rxInputGainDb") private var rxInputGainDb = 0.0
    @AppStorage("rxEqCompensationEnabled") private var rxEqCompensationEnabled = false
    @AppStorage("rxEqCompensationGainDb") private var rxEqCompensationGainDb = 4.5
    
    var body: some View {
        Form {
            // FreeDV Reporter section
            Section("FreeDV Reporter") {
                Toggle("Enable Reporting", isOn: $reporter.isEnabled)
                
                if reporter.isEnabled {
                    HStack {
                        Text("Callsign")
                        Spacer()
                        TextField("e.g. BV2ABC", text: $reporter.callsign)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160)
                    }
                    
                    HStack {
                        Text("Grid Square")
                        Spacer()
                        TextField("e.g. PL04qf", text: $reporter.gridSquare)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 130)
                        Button {
                            locationHelper.requestLocation { grid in
                                reporter.gridSquare = grid
                            }
                        } label: {
                            Image(systemName: locationHelper.isLocating
                                  ? "location.fill" : "location")
                        }
                        .disabled(locationHelper.isLocating)
                    }
                    
                    NavigationLink {
                        FrequencyPickerView(frequencyHz: $reporter.frequencyHz)
                    } label: {
                        LabeledContent("Frequency", value: formatFrequency(reporter.frequencyHz))
                    }
                    
                    HStack {
                        Text("Status Message")
                        Spacer()
                        TextField("Optional", text: $reporter.statusMessage)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }
                    
                    // Connection status
                    HStack {
                        Text("Connection")
                        Spacer()
                        if reporter.isConnected {
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Text(reporter.isReady ? "Connected" : "Connecting...")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Circle().fill(.gray).frame(width: 8, height: 8)
                                Text("Disconnected")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                    
                    // Online station count
                    if reporter.isConnected {
                        LabeledContent("Online Stations", value: "\(reporter.stations.count)")
                    }
                }
            }
            
            // Audio devices section
            Section("Transceiver Audio Devices") {
                #if os(iOS)
                if !deviceManager.availableInputs.isEmpty {
                    if deviceManager.currentInputName == kUnknownAudioDeviceName {
                        NavigationLink("Select Input Device") {
                            InputDevicePickerView(deviceManager: deviceManager)
                        }
                    } else {
                        NavigationLink("Input:  " + deviceManager.currentInputName) {
                            InputDevicePickerView(deviceManager: deviceManager)
                        }
                    }
                }
                if !deviceManager.availableOutputs.isEmpty {
                    if deviceManager.currentOutputName == kUnknownAudioDeviceName {
                        NavigationLink("Select Output Device") {
                            OutputDevicePickerView(deviceManager: deviceManager)
                        }
                    } else {
                        NavigationLink("Output:  " + deviceManager.currentOutputName) {
                            OutputDevicePickerView(deviceManager: deviceManager)
                        }
                    }
                }
                #endif
                
                Toggle("Show FFT / Waterfall", isOn: $fftEnabledPreference)
                Text("Disable to reduce CPU load and avoid RX chunk drops. Recommended on older devices to improve decode performance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("RX Input Gain")
                        Spacer()
                        Text(String(format: "%.1f dB", rxInputGainDb))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $rxInputGainDb, in: 0...18, step: 0.5)
                    Text("Digital preamp before demod. Increase if weak devices decode poorly; too high can clip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Toggle("RX EQ Compensation", isOn: $rxEqCompensationEnabled)
                if rxEqCompensationEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Mid Boost")
                            Spacer()
                            Text(String(format: "%.1f dB", rxEqCompensationGainDb))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $rxEqCompensationGainDb, in: 0...9, step: 0.5)
                        Text("Peaking EQ centered near 1.6 kHz (Q≈1.15) to compensate iPhone mic mid-band dip.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // User audio devices section (speaker + microphone)
            Section("User Audio Devices") {
                #if os(iOS)
                if !deviceManager.availableInputs.isEmpty {
                    if deviceManager.userInputName == kUnknownAudioDeviceName {
                        NavigationLink("Select Microphone") {
                            UserInputDevicePickerView(deviceManager: deviceManager)
                        }
                    } else {
                        NavigationLink("Mic:  " + deviceManager.userInputName) {
                            UserInputDevicePickerView(deviceManager: deviceManager)
                        }
                    }
                }
                if !deviceManager.availableOutputs.isEmpty {
                    if deviceManager.userOutputName == kUnknownAudioDeviceName {
                        NavigationLink("Select Speaker") {
                            UserOutputDevicePickerView(deviceManager: deviceManager)
                        }
                    } else {
                        NavigationLink("Speaker:  " + deviceManager.userOutputName) {
                            UserOutputDevicePickerView(deviceManager: deviceManager)
                        }
                    }
                }
                #endif
            }
            
            // GPS tracking & background location
            Section("GPS Tracking") {
                Toggle("Track Location During RX", isOn: Binding(
                    get: { AudioManager.gpsTrackingEnabled },
                    set: { AudioManager.gpsTrackingEnabled = $0 }
                ))
                Text("Records your location when receiving signals. Useful for comparing reception at different locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if AudioManager.gpsTrackingEnabled {
                    BackgroundLocationStatusView()
                }
            }
            
            // Recording settings
            Section("Reception Log") {
                // Auto-record toggle uses @AppStorage
                RecordingSettingsSection()
            }
            
            // RADE info section
            Section("RADE Info") {
                LabeledContent("Modem Sample Rate", value: "8000 Hz")
                LabeledContent("Speech Sample Rate", value: "16000 Hz")
                LabeledContent("OFDM Carriers", value: "30")
                LabeledContent("Bandwidth", value: "~1.3 kHz")
                LabeledContent("Modem Frame", value: "120 ms")
            }
            
            // About section
            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("License", value: "LGPL-2.1-or-later")
                Text("This app includes third-party components under their respective licenses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Please use TestFlight feedback to report issues. If you are willing, include your email so we can follow up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("FreeDV Project", destination: URL(string: "https://freedv.org")!)
                Link("Privacy Policy", destination: URL(string: "https://freedv.org/privacy")!)
            }
            
            Section("Open Source Licenses") {
                VStack(alignment: .leading, spacing: 12) {
                    LicenseRow(
                        name: "RADE Modem Library",
                        copyright: "David Rowe and contributors",
                        license: "BSD-2-Clause"
                    )
                    LicenseRow(
                        name: "Opus / FARGAN / LPCNet",
                        copyright: "Xiph.Org Foundation / Amazon",
                        license: "BSD-3-Clause"
                    )
                    LicenseRow(
                        name: "radae_decoder",
                        copyright: "Peter Marks",
                        license: "BSD-2-Clause"
                    )
                    LicenseRow(
                        name: "EOO Callsign Codec",
                        copyright: "David Rowe et al. / Mooneer Salem et al.",
                        license: "LGPL-2.1-or-later"
                    )
                }
                .padding(.vertical, 4)

                Text("See repository notices for full third-party license details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onDisappear {
            // Send updated status message when leaving settings
            if reporter.isReady {
                reporter.sendMessageUpdate()
            }
        }
    }
    
    private func formatFrequency(_ hz: UInt64) -> String {
        String(format: "%.3f MHz", Double(hz) / 1_000_000)
    }
}

// MARK: - Frequency Picker

struct FrequencyPickerView: View {
    @Binding var frequencyHz: UInt64
    @State private var customKHz: String = ""
    
    let commonFrequencies: [(String, UInt64)] = [
        ("20m – 14.236 MHz", 14_236_000),
        ("40m – 7.177 MHz",   7_177_000),
        ("80m – 3.625 MHz",   3_625_000),
        ("15m – 21.313 MHz", 21_313_000),
        ("10m – 28.330 MHz", 28_330_000),
        ("17m – 18.118 MHz", 18_118_000),
    ]
    
    var body: some View {
        List {
            Section("Common Frequencies") {
                ForEach(commonFrequencies, id: \.1) { name, freq in
                    Button {
                        frequencyHz = freq
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            if frequencyHz == freq {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            
            Section("Custom Frequency") {
                HStack {
                    Text("kHz")
                    TextField("14236", text: $customKHz)
                        .keyboardType(.decimalPad)
                    Button("Set") {
                        if let kHz = Double(customKHz) {
                            frequencyHz = UInt64(kHz * 1000)
                        }
                    }
                    .disabled(customKHz.isEmpty)
                }
            }
            
            Section {
                LabeledContent("Current", value: String(format: "%.3f MHz", Double(frequencyHz) / 1_000_000))
            }
        }
        .navigationTitle("Frequency")
    }
}

#if os(iOS)
/// Picker for selecting audio output device
struct OutputDevicePickerView: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    
    var body: some View {
        List(deviceManager.availableOutputs) { device in
            Button(action: {
                deviceManager.selectOutput(device)
            }) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(device.portType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.id == deviceManager.selectedOutputId {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .navigationTitle("Output Device")
    }
}

/// Picker for selecting audio input device
struct InputDevicePickerView: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    
    var body: some View {
        List(deviceManager.availableInputs, id: \.uid) { port in
            Button(action: {
                deviceManager.selectInput(port)
            }) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(port.portName)
                        Text(port.portType.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if port.portName == deviceManager.currentInputName {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .navigationTitle("Input Device")
    }
}

/// Picker for selecting user speaker output device
struct UserOutputDevicePickerView: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    
    var body: some View {
        List(deviceManager.availableOutputs) { device in
            Button(action: {
                deviceManager.selectUserOutput(device)
            }) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(device.portType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.id == deviceManager.selectedUserOutputId {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .navigationTitle("User Speaker")
    }
}

/// Picker for selecting user microphone input device
struct UserInputDevicePickerView: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    
    var body: some View {
        List(deviceManager.availableInputs, id: \.uid) { port in
            Button(action: {
                deviceManager.selectUserInput(port)
            }) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(port.portName)
                        Text(port.portType.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if port.uid == deviceManager.selectedUserInputUID {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .navigationTitle("User Microphone")
    }
}
#endif

// MARK: - Recording Settings

struct RecordingSettingsSection: View {
    @AppStorage("autoRecordEnabled") private var autoRecordEnabled = true
    @AppStorage("maxStorageMB") private var maxStorageMB = 2000  // 2 GB default
    @Environment(\.modelContext) private var modelContext
    @State private var usedSpace: String = NSLocalizedString("Calculating...", comment: "Storage size is being calculated")
    @State private var showClearConfirm = false
    
    var body: some View {
        Toggle("Auto Record WAV", isOn: $autoRecordEnabled)
        
        Picker("Max Storage", selection: $maxStorageMB) {
            Text("500 MB").tag(500)
            Text("1 GB").tag(1000)
            Text("2 GB").tag(2000)
            Text("5 GB").tag(5000)
        }
        
        LabeledContent("Used Space", value: usedSpace)
            .onAppear { updateUsedSpace() }
        
        Button("Delete All Recordings", role: .destructive) {
            showClearConfirm = true
        }
        .confirmationDialog("Delete all recordings and session data?", isPresented: $showClearConfirm) {
            Button("Delete All", role: .destructive) {
                clearRecordings()
            }
        }
    }
    
    private func updateUsedSpace() {
        let bytes = WAVRecorder.totalRecordingsSize
        if bytes > 1_000_000 {
            usedSpace = String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else {
            usedSpace = String(format: "%.0f KB", Double(bytes) / 1_000)
        }
    }
    
    private func clearRecordings() {
        // Delete WAV files from disk
        let dir = WAVRecorder.recordingsDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        
        // Delete all ReceptionSession records from SwiftData
        // (cascade deletes associated snapshots, sync events, and callsign events)
        do {
            try modelContext.delete(model: ReceptionSession.self)
            try modelContext.save()
        } catch {
            appLog("Failed to delete session records: \(error)")
        }
        
        updateUsedSpace()
    }
}

// MARK: - Location Helper

/// Requests a single location fix and converts it to a Maidenhead grid square.
class LocationHelper: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isLocating = false
    
    private let manager = CLLocationManager()
    private var completion: ((String) -> Void)?
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    
    func requestLocation(completion: @escaping (String) -> Void) {
        self.completion = completion
        isLocating = true
        
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            isLocating = false
            self.completion = nil
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            if isLocating {
                manager.requestLocation()
            }
        } else if manager.authorizationStatus == .denied ||
                  manager.authorizationStatus == .restricted {
            isLocating = false
            completion = nil
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let grid = Self.maidenhead(latitude: location.coordinate.latitude,
                                   longitude: location.coordinate.longitude)
        DispatchQueue.main.async {
            self.completion?(grid)
            self.isLocating = false
            self.completion = nil
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLog("Location error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isLocating = false
            self.completion = nil
        }
    }
    
    /// Convert latitude/longitude to 6-character Maidenhead grid locator.
    static func maidenhead(latitude: Double, longitude: Double) -> String {
        let lon = longitude + 180.0
        let lat = latitude + 90.0
        
        // Field (2 uppercase letters)
        let fieldLon = Int(lon / 20.0)
        let fieldLat = Int(lat / 10.0)
        
        // Square (2 digits)
        let squareLon = Int((lon - Double(fieldLon) * 20.0) / 2.0)
        let squareLat = Int((lat - Double(fieldLat) * 10.0) / 1.0)
        
        // Subsquare (2 lowercase letters)
        let subLon = Int(((lon - Double(fieldLon) * 20.0 - Double(squareLon) * 2.0) / 2.0) * 24.0)
        let subLat = Int(((lat - Double(fieldLat) * 10.0 - Double(squareLat) * 1.0) / 1.0) * 24.0)
        
        let f1 = Character(UnicodeScalar(65 + min(fieldLon, 17))!)
        let f2 = Character(UnicodeScalar(65 + min(fieldLat, 17))!)
        let s1 = Character(UnicodeScalar(48 + min(squareLon, 9))!)
        let s2 = Character(UnicodeScalar(48 + min(squareLat, 9))!)
        let sub1 = Character(UnicodeScalar(97 + min(subLon, 23))!)
        let sub2 = Character(UnicodeScalar(97 + min(subLat, 23))!)
        
        return String([f1, f2, s1, s2, sub1, sub2])
    }
}

// MARK: - Background Location Status

/// Shows location authorization status and guides the user to enable "Always" for background RX.
struct BackgroundLocationStatusView: View {
    @StateObject private var helper = BackgroundLocationHelper()
    
    var body: some View {
        switch helper.authStatus {
        case .authorizedAlways:
            Label("Background reception enabled", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            
        case .authorizedWhenInUse:
            VStack(alignment: .leading, spacing: 8) {
                Label("Background reception requires \"Always\" location", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Open Settings → Location → select \"Always\" to keep receiving when the screen is off.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .font(.caption.weight(.medium))
                }
            }
            
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 8) {
                Label("Location access denied", systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Open Settings to grant location access for background reception.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .font(.caption.weight(.medium))
                }
            }
            
        case .notDetermined:
            Button {
                helper.requestAlways()
            } label: {
                Label("Enable Location Access", systemImage: "location")
                    .font(.caption.weight(.medium))
            }
            
        @unknown default:
            EmptyView()
        }
    }
}

/// Monitors CLLocationManager authorization changes for the settings UI.
class BackgroundLocationHelper: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authStatus: CLAuthorizationStatus
    
    private let manager = CLLocationManager()
    
    override init() {
        authStatus = CLLocationManager().authorizationStatus
        super.init()
        manager.delegate = self
    }
    
    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }
    
    func requestAlways() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authStatus = manager.authorizationStatus
        }
    }
}

// MARK: - License Row

private struct LicenseRow: View {
    let name: String
    let copyright: String
    let license: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 14, weight: .semibold))
            Text("\u{00A9} \(copyright)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Licensed under \(license)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView(reporter: FreeDVReporter())
    }
}
