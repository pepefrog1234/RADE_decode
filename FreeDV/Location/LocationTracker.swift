import CoreLocation

/// Location tracker for reception GPS logging.
/// Background location updates are enabled only with "Always" authorization.
class LocationTracker: NSObject, CLLocationManagerDelegate {
    
    private let manager = CLLocationManager()
    
    /// Most recent location (updated continuously)
    private(set) var currentLocation: CLLocation?
    
    /// Whether location updates are actively running
    private(set) var isTracking = false
    
    /// User preference for GPS coordinate logging in reception sessions.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "gpsTrackingEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "gpsTrackingEnabled") }
    }
    
    override init() {
        super.init()
        manager.delegate = self
        // Use reduced accuracy (cell/WiFi) for minimal battery impact.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        // Don't auto-pause while RX is active
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
    /// Background updates are enabled only with "Always" authorization.
    func startTracking() {
        guard isEnabled else {
            appLog("LocationTracker: disabled by user setting")
            return
        }

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            appLog("LocationTracker: requesting authorization")
            return
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            appLog("LocationTracker: not authorized (status=\(status.rawValue))")
            return
        }

        let allowBackground = (status == .authorizedAlways)
        manager.allowsBackgroundLocationUpdates = allowBackground
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
        isTracking = true

        if allowBackground {
            appLog("LocationTracker: started with Always authorization")
        } else {
            appLog("LocationTracker: started (When In Use only; background location unavailable)")
        }
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
        if isEnabled && (status == .authorizedWhenInUse || status == .authorizedAlways) && !isTracking {
            let allowBackground = (status == .authorizedAlways)
            manager.allowsBackgroundLocationUpdates = allowBackground
            manager.showsBackgroundLocationIndicator = false
            manager.startUpdatingLocation()
            isTracking = true
            if allowBackground {
                appLog("LocationTracker: auto-started with Always authorization")
            } else {
                appLog("LocationTracker: auto-started (When In Use only)")
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLog("LocationTracker: error — \(error.localizedDescription)")
    }
}
