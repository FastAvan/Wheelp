import CoreLocation
import Observation

/// Envoltorio observable de `CLLocationManager` para obtener la ubicación del usuario.
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var authorizationStatus: CLAuthorizationStatus
    var lastLocation: CLLocation?

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Navegación peatonal: el sistema optimiza los fixes para este uso.
        manager.activityType = .otherNavigation
        // Actualizaciones cada ~3 m: suficiente para avanzar pasos sin gastar batería.
        manager.distanceFilter = 3
    }

    /// Pide permiso de ubicación si aún no se ha decidido y empieza a actualizar.
    func requestPermission() {
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silencioso: el usuario verá un aviso al intentar calcular ruta sin ubicación.
    }
}
