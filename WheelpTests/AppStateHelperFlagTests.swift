import XCTest
@testable import Wheelp

/// El modo ayudante debe sobrevivir a un arranque en el que la consulta a
/// `helpers` falle (401 por token caducado, red caída). Si no se persiste,
/// el ayudante se queda sin recibir peticiones hasta el siguiente arranque bueno.
@MainActor
final class AppStateHelperFlagTests: XCTestCase {

    private let key = "wheelp.isHelper"
    private let availableKey = "wheelp.helperAvailable"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: availableKey)
        super.tearDown()
    }

    func testIsHelperSePersisteEntreArranques() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(AppState().isHelper, "sin dato previo, por defecto no es ayudante")

        let state = AppState()
        state.isHelper = true
        XCTAssertTrue(AppState().isHelper, "un arranque posterior debe recordar el modo ayudante")
    }

    /// Si `fetchAvailability()` devuelve nil (401, red caída) no se toca
    /// `isHelperAvailable`, así que el valor persistido es el que queda en pie.
    ///
    /// El valor por defecto cambió a `false` a propósito. Antes arrancaba en
    /// `true` para no interrumpir a ayudantes ya dados de alta, pero desde que
    /// estar disponible implica compartir la zona en segundo plano, dejarlo
    /// activo por omisión sería tratar datos de ubicación sin que nadie lo haya
    /// declarado. Este test protege esa decisión: si alguien vuelve a poner
    /// `?? true` en el init, aquí se entera.
    func testIsHelperAvailableSePersisteYPorDefectoEsFalse() {
        UserDefaults.standard.removeObject(forKey: availableKey)
        XCTAssertFalse(AppState().isHelperAvailable,
                       "sin declaración previa no puede compartirse la zona del ayudante")

        let state = AppState()
        state.isHelperAvailable = true
        XCTAssertTrue(AppState().isHelperAvailable,
                      "un arranque posterior debe recordar que se declaró disponible")
    }
}
