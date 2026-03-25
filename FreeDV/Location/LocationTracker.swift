import CoreLocation

/// Location tracker that serves two purposes:
/// 1. Background keep-alive: location updates keep the app running in background
///    (always active when RX is running, regardless of user preference)
/// 2. GPS logging: records coordinates for reception sessions
///    (only when user enables "Track Location During RX" in Settings)
class LocationTracker: NSObject, CLLocationManagerDelegate {
    
    private let manager = CLLocationManager()
    
    /// Most recent location (updated continuously)
    private(set) var currentLocation: CLLocation?
    
    /// Whether location updates are actively running
    private(set) var isTracking = false
    
    /// User preference for GPS coordinate logging in reception sessions.
    /// This does NOT control whether location updates run — those always run
    /// when RX is active to keep the app alive in background.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "gpsTrackingEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "gpsTrackingEnabled") }
    }
    
    override init() {
        super.init()
        manager.delegate = self
        // Use reduced accuracy (cell/WiFi) for minimal battery impact.
        // distanceFilter = none ensures iOS keeps delivering updates even when
        // stationary, which is critical for keeping the app alive in background.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        // Don't auto-pause — we need continuous updates for background reception
        manager.pausesLocationUpdatesAutomatically = false
    }
    
    /// Request "Always" authorization for background location updates.
    /// Must be called after the user has already granted "When In Use".
    func requestAlwaysAuthorization() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }
    
    /// Start location updates when RX begins.
    /// Always starts if authorized — background keep-alive requires continuous
    /// location updates regardless of the GPS logging preference.
    func startTracking() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            appLog("LocationTracker: requesting authorization")
            return
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            appLog("LocationTracker: not authorized (status=\(status.rawValue)) — background keep-alive unavailable")
            return
        }
        
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = (status == .authorizedWhenInUse)
        manager.startUpdatingLocation()
        isTracking = true
        appLog("LocationTracker: started (auth=\(status.rawValue), gpsLogging=\(isEnabled))")
    }
    
    /// Stop tracking when RX stops.
    func stopTracking() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isTracking = false
        appLog("LocationTracker: stopped")
    }
    
    /// Current latitude — only returns value when GPS logging is enabled
    var latitude: Double? { isEnabled ? currentLocation?.coordinate.latitude : nil }
    
    /// Current longitude — only returns value when GPS logging is enabled
    var longitude: Double? { isEnabled ? currentLocation?.coordinate.longitude : nil }
    
    /// Current altitude — only returns value when GPS logging is enabled
    var altitude: Double? { isEnabled ? currentLocation?.altitude : nil }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        appLog("LocationTracker: auth changed to \(status.rawValue)")
        
        // Auto-start if we were waiting for authorization
        if (status == .authorizedWhenInUse || status == .authorizedAlways) && !isTracking {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = (status == .authorizedWhenInUse)
            manager.startUpdatingLocation()
            isTracking = true
            appLog("LocationTracker: auto-started after auth grant")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLog("LocationTracker: error — \(error.localizedDescription)")
    }
}
