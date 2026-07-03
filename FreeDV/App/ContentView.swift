import SwiftUI
import CoreLocation
import Combine

struct ContentView: View {
    @State private var reporter = FreeDVReporter()
    /// Shared IC-705 controller — same instance drives the Receiver and Settings tabs.
    @StateObject private var radioController = IcomRadioController()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    
    var body: some View {
        TabView {
            TransceiverView(reporter: reporter, radioController: radioController)
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
                CombinedMapView(reporter: reporter)
            }
            .tabItem {
                Label("Map", systemImage: "map")
            }
            
            NavigationStack {
                SettingsView(reporter: reporter, radioController: radioController)
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
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                reporter.suspendForBackground()
            case .active:
                reporter.resumeFromBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Combined Map View

struct CombinedMapView: View {
    var reporter: FreeDVReporter
    @State private var selectedMap: MapMode = .reception

    enum MapMode: String, CaseIterable {
        case reception = "Reception"
        case reporter = "Reporter"
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch selectedMap {
            case .reception:
                ReceptionMapView()
            case .reporter:
                ReporterMapView(reporter: reporter)
            }

            Picker("Map", selection: $selectedMap) {
                ForEach(MapMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    var onComplete: () -> Void
    @StateObject private var locationHelper = OnboardingLocationHelper()
    @State private var currentPage = 0
    
    private let totalPages = 6
    
    var body: some View {
        TabView(selection: $currentPage) {
            // Page 0: Welcome
            VStack(spacing: 0) {
                Spacer()
                
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 27))
                    .padding(.bottom, 20)
                
                Text("RADE Decode")
                    .font(.system(size: 28, weight: .bold))
                    .padding(.bottom, 4)
                
                Text("Digital Voice Receiver")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
                
                Text("Decode RADE digital voice signals from your radio using on-device neural network modem technology.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                Spacer()
                
                Text("Swipe to learn more >")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 50)
            }
            .tag(0)
            
            // Page 1: Setup
            OnboardingPageView(
                icon: "cable.connector",
                iconColor: .blue,
                title: "Connect Your Radio"
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    SetupStepRow(
                        step: 1,
                        icon: "dial.low",
                        text: "Tune your radio to a RADE frequency\n(e.g. **14236 kHz USB**)"
                    )
                    SetupStepRow(
                        step: 2,
                        icon: "iphone.radiowaves.left.and.right",
                        text: "Place your iPhone near the radio speaker, or connect via audio cable"
                    )
                    SetupStepRow(
                        step: 3,
                        icon: "play.circle.fill",
                        text: "Press **Start** on the Receiver tab"
                    )
                }
                .padding(.horizontal, 8)
                
                Text("All decoding runs locally — no internet needed.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }
            .tag(1)
            
            // Page 2: Real-time Decode
            OnboardingPageView(
                icon: "waveform",
                iconColor: .green,
                title: "Watch Signals Come Alive"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(
                        icon: "chart.bar.fill",
                        color: .cyan,
                        title: "Spectrum & Waterfall",
                        description: "Real-time frequency display shows signals as they arrive."
                    )
                    FeatureRow(
                        icon: "person.wave.2",
                        color: .green,
                        title: "Callsign Decoding",
                        description: "Decoded callsigns appear instantly on screen."
                    )
                    FeatureRow(
                        icon: "speaker.wave.3.fill",
                        color: .blue,
                        title: "Voice Playback",
                        description: "Hear decoded voice through the speaker in real time."
                    )
                }
            }
            .tag(2)
            
            // Page 3: Background Reception
            OnboardingPageView(
                icon: "moon.fill",
                iconColor: .indigo,
                title: "Receive in the Background"
            ) {
                Text("Lock your screen or switch apps — RADE Decode keeps recording. When you return, background audio is automatically analyzed.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                
                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(
                        icon: "clock.arrow.circlepath",
                        color: .indigo,
                        title: "Background Capture",
                        description: "Audio is recorded while the screen is off."
                    )
                    FeatureRow(
                        icon: "waveform.and.magnifyingglass",
                        color: .blue,
                        title: "Automatic Analysis",
                        description: "Captured audio is decoded when you return."
                    )
                    FeatureRow(
                        icon: "bell.badge.fill",
                        color: .orange,
                        title: "Results in Log",
                        description: "Decoded sessions appear in the Reception Log."
                    )
                }
            }
            .tag(3)
            
            // Page 4: Log & Map
            OnboardingPageView(
                icon: "list.bullet.rectangle",
                iconColor: .orange,
                title: "Track Every Signal"
            ) {
                Text("Each session is logged with timestamps, SNR, sync status, and GPS coordinates.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                
                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(
                        icon: "chart.xyaxis.line",
                        color: .orange,
                        title: "Session Analytics",
                        description: "SNR charts and sync timeline for each session."
                    )
                    FeatureRow(
                        icon: "mappin.and.ellipse",
                        color: .teal,
                        title: "Reception Map",
                        description: "View reception locations on an interactive map."
                    )
                    FeatureRow(
                        icon: "globe",
                        color: .blue,
                        title: "FreeDV Reporter",
                        description: "Share reception reports with the ham radio community."
                    )
                }
            }
            .tag(4)
            
            // Page 5: Get Started (Location Permission)
            locationPermissionPage
                .tag(5)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Location Permission Page
    
    @ViewBuilder
    private var locationPermissionPage: some View {
        VStack(spacing: 0) {
            Spacer()
            
            Image(systemName: "location.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
                .padding(.bottom, 16)
            
            Text("Enable Location")
                .font(.system(size: 24, weight: .bold))
                .padding(.bottom, 8)
            
            Text("Location keeps reception active in the background and logs GPS coordinates when signals are decoded.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
            
            VStack(spacing: 12) {
                switch locationHelper.step {
                case .ready:
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
                    
                    Text("Location is set to **\"While Using\"** only. To keep receiving in the background, go to **Settings > RADE Decode > Location** and select **\"Always\"**.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    
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
                    
                    Text("Without location access, iOS may stop reception in the background. You can enable it later in Settings.")
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
    }
    
    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Onboarding Page Template

private struct OnboardingPageView<Content: View, Footer: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(iconColor)
                .padding(.bottom, 16)
            
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .padding(.bottom, subtitle != nil ? 4 : 8)
            
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            
            content
                .padding(.horizontal, 24)
            
            Spacer()
            
            footer
                .padding(.bottom, 50)
        }
    }
}

extension OnboardingPageView where Footer == EmptyView {
    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = EmptyView()
    }
}

// MARK: - Setup Step Row

private struct SetupStepRow: View {
    let step: Int
    let icon: String
    let text: LocalizedStringKey
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 36, height: 36)
                Text("\(step)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.blue)
            }
            
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 7)
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
