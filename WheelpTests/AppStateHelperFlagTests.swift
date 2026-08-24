import XCTest
@testable import Wheelp

/// El modo ayudante debe sobrevivir a un arranque en el que la consulta a
/// `helpers` falle (401 por token caducado, red caída). Si no se persiste,
/// el ayudante se queda sin recibir peticiones hasta el siguiente arranque bueno.
@MainActor
final class AppStateHelperFlagTests: XCTestCase {

    private let key = "wheelp.isHelper"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testIsHelperSePersisteEntreArranques() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(AppState().isHelper, "sin dato previo, por defecto no es ayudante")

        let state = AppState()
        state.isHelper = true
        XCTAssertTrue(AppState().isHelper, "un arranque posterior debe recordar el modo ayudante")
    }
}
