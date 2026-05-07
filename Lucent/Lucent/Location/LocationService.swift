import CoreLocation
import Foundation
@preconcurrency import MapKit
import Observation

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum LocationError: Error, LocalizedError {
        case denied
        case restricted
        case unavailable
        case noPostalCode
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .denied: return "Location permission denied. Enter a postal code in Settings."
            case .restricted: return "Location is restricted on this Apple TV."
            case .unavailable: return "Location is unavailable right now."
            case .noPostalCode: return "Couldn't determine a postal code for this location."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    struct Postcode: Sendable, Equatable {
        let postalCode: String
        let country: String
    }

    private let manager: CLLocationManager
    private var authContinuation: CheckedContinuation<Void, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
    }

    func requestPostalCode() async throws -> Postcode {
        try await ensureAuthorized()
        let location = try await fetchOneLocation()
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw LocationError.unavailable
        }
        let mapItems = try await request.mapItems
        guard
            let placemark = mapItems.first?.placemark,
            let zip = placemark.postalCode
        else {
            throw LocationError.noPostalCode
        }
        let iso = placemark.countryCode ?? "US"
        return Postcode(postalCode: zip, country: iso == "US" ? "USA" : iso)
    }

    private func ensureAuthorized() async throws {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return
        case .denied:
            throw LocationError.denied
        case .restricted:
            throw LocationError.restricted
        case .notDetermined:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.authContinuation = cont
                manager.requestWhenInUseAuthorization()
            }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: return
            case .denied: throw LocationError.denied
            case .restricted: throw LocationError.restricted
            default: throw LocationError.unavailable
            }
        @unknown default:
            throw LocationError.unavailable
        }
    }

    private func fetchOneLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { cont in
            self.locationContinuation = cont
            manager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if let cont = self.authContinuation {
                self.authContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            if let cont = self.locationContinuation {
                self.locationContinuation = nil
                cont.resume(returning: loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let cont = self.locationContinuation {
                self.locationContinuation = nil
                cont.resume(throwing: LocationError.underlying(error))
            }
        }
    }
}
