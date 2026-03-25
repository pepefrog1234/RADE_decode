import SwiftUI
import CoreLocation
import Combine

struct ContentView: View {
    @State private var reporter = FreeDVReporter()
    @State private var powerManager = PowerManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    
    var body: some View {
        TabView {
            TransceiverView(reporter: reporter, powerManager: powerManager)
                .tabItem {
                    Label("Receiver", systemImage: "antenna.radiowaves.left.and.right")
                }
            
            ReporterStationsView(reporter: reporter)
                .tabItem {
                    Label("Stations", systemImage: "globe")
                }
            
            ReceptionLogView()
                .tabItem {
                    Label("Log", systemImage: "list.bullet.rectangle")
                }
            
            NavigationStack {
                ReceptionMapView()
            }
            .tabItem {
                Label("Map", systemImage: "map")
            }
            
            NavigationStack {
                SettingsView(reporter: reporter, powerManager: powerManager)
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            hasCompletedOnboarding = true
        }) {
            OnboardingView {
                showOnboarding = false
                hasCompletedOnboarding = true
            }
            .interactiveDismissDisabled()
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    var onComplete: () -> Void
    @StateObject private var locationHelper = OnboardingLocationHelper()
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // App icon area
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .padding(.bottom, 16)
            
            Text("RADE Decode")
                .font(.system(size: 28, weight: .bold))
                .padding(.bottom, 4)
            
            Text("Digital Voice Receiver")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .padding(.bottom, 32)
            
            // Feature cards
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "waveform",
                    color: .green,
                    title: "Decode RADE Signals",
                    description: "Receive and decode digital voice signals using neural network modem technology."
                )
                FeatureRow(
                    icon: "moon.fill",
                    color: .indigo,
                    title: "Background Reception",
                    description: "Keep receiving even when the screen is off or other apps are in use."
                )
                FeatureRow(
                    icon: "location.fill",
                    color: .blue,
                    title: "Reception Logging",
                    description: "Record GPS coordinates when signals are received for comparing reception at different locations."
                )
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            // Authorization flow
            VStack(spacing: 12) {
                switch locationHelper.step {
                case .ready:
                    Text("RADE Decode uses location to keep receiving in the background and log GPS coordinates when signals are decoded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    
                    Button(action: { locationHelper.requestAuthorization() }) {
                        Text("Enable Location")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                    Button("Skip for Now", action: onComplete)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    
                case .whenInUseGranted:
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                        .padding(.bottom, 4)
                    
                    Text("Almost there")
                        .font(.system(size: 17, weight: .semibold))
                    
                    Text("Location is set to **\"While Using\"** only. To keep receiving in the background, go to **Settings → RADE Decode → Location** and select **\"Always\"**.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    
                    Text("You can change this anytime in iOS Settings.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                    
                    Button(action: {
                        AudioManager.gpsTrackingEnabled = true
                        onComplete()
                    }) {
                        Text("Continue")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(white: 0.25))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                case .alwaysGranted:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                        .padding(.bottom, 4)
                    
                    Text("Background reception enabled")
                        .font(.system(size: 17, weight: .semibold))
                    
                    Text("RADE Decode will continue receiving even when the screen is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    
                    Button(action: {
                        AudioManager.gpsTrackingEnabled = true
                        onComplete()
                    }) {
                        Text("Get Started")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.green)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                case .denied:
                    Image(systemName: "location.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                        .padding(.bottom, 4)
                    
                    Text("Location access denied")
                        .font(.system(size: 17, weight: .semibold))
                    
                    Text("Without location access, iOS may stop reception when the app is in the background. You can enable it later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    
                    Button(action: { openAppSettings() }) {
                        Label("Open Settings", systemImage: "gear")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                    Button("Continue Without Location", action: onComplete)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
    }
    
    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Onboarding Location Helper

class OnboardingLocationHelper: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Step {
        case ready
        case whenInUseGranted
        case alwaysGranted
        case denied
    }
    
    @Published var step: Step = .ready
    private let manager = CLLocationManager()
    
    override init() {
        super.init()
        manager.delegate = self
        // Check if already authorized (e.g. reinstall with existing permissions)
        updateStep(for: manager.authorizationStatus)
    }
    
    /// Request location authorization.
    /// "Always" is required for reliable background location updates.
    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.updateStep(for: manager.authorizationStatus)
        }
    }
    
    private func updateStep(for status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            step = .alwaysGranted
        case .authorizedWhenInUse:
            step = .whenInUseGranted
        case .denied, .restricted:
            step = .denied
        case .notDetermined:
            step = .ready
        @unknown default:
            step = .ready
        }
    }
}

#Preview {
    ContentView()
}
