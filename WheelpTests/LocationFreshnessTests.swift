import XCTest
import CoreLocation
@testable import Wheelp

/// `currentLocation(maxAge:)` decide si vale la ubicación que ya hay o si hay
/// que pedir un fix nuevo. Equivocarse por un lado gasta batería de más; por el
/// otro, enseña al ayudante distancias de otro día como si fueran de ahora.
@MainActor
final class LocationFreshnessTests: XCTestCase {

    private func location(secondsAgo: TimeInterval) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.42, longitude: -3.69),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: Date().addingTimeInterval(-secondsAgo)
        )
    }

    /// Una ubicación de hace 10 s con maxAge 60 s se reutiliza: no se pide fix.
    func testUbicacionRecienteSeReutiliza() async {
        let manager = LocationManager()
        manager.lastLocation = location(secondsAgo: 10)

        let result = await manager.currentLocation(maxAge: 60, timeout: 1)

        XCTAssertEqual(result?.timestamp, manager.lastLocation?.timestamp,
                       "Con la ubicación aún fresca debe devolverse tal cual")
    }

    /// Sin permiso no se puede pedir fix: se devuelve lo último conocido en vez
    /// de dejar a quien llama esperando el timeout completo.
    func testSinPermisoDevuelveLoUltimoConocido() async {
        let manager = LocationManager()
        let vieja = location(secondsAgo: 99_999)
        manager.lastLocation = vieja

        let result = await manager.currentLocation(maxAge: 60, timeout: 1)

        XCTAssertEqual(result?.timestamp, vieja.timestamp)
    }

    /// Sin ubicación previa y sin permiso, nil — pero sin colgarse.
    func testSinUbicacionNiPermisoDevuelveNilSinColgarse() async {
        let manager = LocationManager()

        let result = await manager.currentLocation(maxAge: 60, timeout: 1)

        XCTAssertNil(result)
    }

    /// Una ubicación con más antigüedad que maxAge no se da por buena sin más.
    /// En el simulador de tests no hay permiso, así que acaba devolviendo la
    /// vieja por el camino de degradación — lo que importa es que retorna y no
    /// se queda esperando indefinidamente.
    func testUbicacionCaducadaNoCuelgaLaLlamada() async {
        let manager = LocationManager()
        manager.lastLocation = location(secondsAgo: 3_600)

        let inicio = Date()
        _ = await manager.currentLocation(maxAge: 60, timeout: 2)
        let transcurrido = Date().timeIntervalSince(inicio)

        XCTAssertLessThan(transcurrido, 3, "No debe superar el timeout configurado")
    }
}
