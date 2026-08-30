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

    // MARK: - Turno del ayudante (ubicación en segundo plano)

    /// Arranca el seguimiento de zona mientras el ayudante tiene turno activo.
    ///
    /// Usa cambios significativos (~500 m) y no ubicación continua: la
    /// granularidad que hace falta para filtrar por radios de 5-20 km es esa, no
    /// la métrica, y así el consumo es mucho menor y sigue funcionando con la
    /// app cerrada. No se declara el modo de segundo plano `location` a
    /// propósito: este servicio relanza la app sin él, y pedir más permiso del
    /// necesario contradice la minimización.
    func startAvailabilityTracking() {
        guard authorizationStatus == .authorizedAlways else { return }
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopAvailabilityTracking() {
        manager.stopMonitoringSignificantLocationChanges()
    }

    /// Sube a "Siempre" al activar el turno por primera vez, nunca en el
    /// onboarding: pedirlo de entrada se rechaza en App Review y es señal de que
    /// no se está minimizando.
    func requestAlwaysAuthorizationForAvailability() {
        guard authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    // MARK: - Fix puntual bajo demanda

    private var pendingFixes: [CheckedContinuation<CLLocation?, Never>] = []
    private var fixTimeout: Task<Void, Never>?

    /// Ubicación actual con una antigüedad máxima. Si la última conocida ya
    /// cumple, se devuelve tal cual; si no, se pide un fix nuevo y se espera.
    ///
    /// Existe porque `helpers.location` en el servidor solo se refresca con la
    /// app en primer plano: al abrir un push puede tener horas o días. Antes de
    /// enseñar peticiones "cercanas" hay que saber dónde está el ayudante de
    /// verdad, no dónde estaba la última vez que abrió la app.
    ///
    /// Usa `requestLocation()`, que Apple describe como la vía más eficiente:
    /// entrega un único fix y apaga el hardware sola.
    func currentLocation(maxAge: TimeInterval = 60, timeout: TimeInterval = 8) async -> CLLocation? {
        if let last = lastLocation, -last.timestamp.timeIntervalSinceNow < maxAge {
            return last
        }
        guard isAuthorized else { return lastLocation }

        return await withCheckedContinuation { continuation in
            pendingFixes.append(continuation)
            manager.requestLocation()
            // Sin red o bajo techo el fix puede no llegar nunca: se responde con
            // lo último conocido antes que dejar la vista colgada.
            if fixTimeout == nil {
                fixTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.resolveFixes(with: self.lastLocation)
                }
            }
        }
    }

    private func resolveFixes(with location: CLLocation?) {
        fixTimeout?.cancel()
        fixTimeout = nil
        let waiting = pendingFixes
        pendingFixes = []
        for continuation in waiting { continuation.resume(returning: location) }
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
        if !pendingFixes.isEmpty { resolveFixes(with: locations.last) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silencioso: el usuario verá un aviso al intentar calcular ruta sin ubicación.
        // Quien espere un fix puntual recibe lo último conocido en vez de quedarse colgado.
        if !pendingFixes.isEmpty { resolveFixes(with: lastLocation) }
    }
}
