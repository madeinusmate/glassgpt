@preconcurrency import CoreLocation
import Foundation

@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published private(set) var isSharingEnabled: Bool
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var latestLocation: CLLocation?

    private let locationManager = CLLocationManager()
    private let sharingPreferenceKey = "locationSharingEnabled"

    override init() {
        isSharingEnabled = UserDefaults.standard.bool(forKey: sharingPreferenceKey)
        authorizationStatus = locationManager.authorizationStatus
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100

        if isSharingEnabled {
            beginLocationUpdates()
        }
    }

    func setSharingEnabled(_ enabled: Bool) {
        isSharingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: sharingPreferenceKey)

        if enabled {
            beginLocationUpdates()
        } else {
            locationManager.stopUpdatingLocation()
            latestLocation = nil
        }
    }

    /// A compact, explicit context string sent with each model turn only when
    /// the user has opted in to location sharing.
    func realtimeContext() -> String? {
        guard isSharingEnabled else { return nil }
        guard let latestLocation else {
            return "Private context: Location sharing is enabled, but a current location is unavailable. Do not infer the user's location."
        }

        let latitude = String(format: "%.5f", latestLocation.coordinate.latitude)
        let longitude = String(format: "%.5f", latestLocation.coordinate.longitude)
        let accuracy = Int(latestLocation.horizontalAccuracy.rounded())
        let timestamp = ISO8601DateFormatter().string(from: latestLocation.timestamp)
        return "Private context: The user's current location is latitude \(latitude), longitude \(longitude), accurate to approximately \(accuracy) meters, captured at \(timestamp). Use this only when it helps answer the user's request."
    }

    var statusLabel: String {
        guard isSharingEnabled else { return "Not sharing" }
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return latestLocation == nil ? "Finding location…" : "Sharing current location"
        case .notDetermined:
            return "Permission needed"
        case .denied, .restricted:
            return "Permission unavailable"
        @unknown default:
            return "Unavailable"
        }
    }

    fileprivate func didChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isSharingEnabled {
            beginLocationUpdates()
        }
    }

    fileprivate func didUpdateLocations(_ locations: [CLLocation]) {
        latestLocation = locations.last
    }

    fileprivate func didFailLocationUpdate() {
        // Keep the last known location for the current opted-in session.
    }

    private func beginLocationUpdates() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            locationManager.requestLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }
}

extension LocationManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        didChangeAuthorization(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        didUpdateLocations(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        didFailLocationUpdate()
    }
}
