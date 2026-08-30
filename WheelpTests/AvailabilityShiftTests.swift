import XCTest
@testable import Wheelp

/// El turno decide durante cuánto tiempo se comparte la zona del ayudante en
/// segundo plano. Un fallo aquí no rompe nada visible: simplemente se sigue
/// compartiendo ubicación más tiempo del declarado, que es justo la conducta
/// sancionada a Foodinho.
@MainActor
final class AvailabilityShiftTests: XCTestCase {

    private func nuevoEstado() -> AppState {
        // Cada test parte de UserDefaults limpio para las claves implicadas.
        UserDefaults.standard.removeObject(forKey: "wheelp.helperAvailable")
        UserDefaults.standard.removeObject(forKey: "wheelp.worksAtNight")
        let state = AppState()
        state.isHelper = true
        return state
    }

    func testLaDisponibilidadNoVieneActivadaPorDefecto() {
        let state = nuevoEstado()
        XCTAssertFalse(state.isHelperAvailable,
                       "Compartir zona no puede quedar activo sin que nadie lo declare")
        XCTAssertNil(state.availableUntil)
    }

    func testActivarFijaLaHoraDeFin() {
        let state = nuevoEstado()
        state.worksAtNight = true   // aparta el corte nocturno de este test
        let antes = Date()

        state.setHelperAvailability(true, forHours: 4)

        guard let until = state.availableUntil else { return XCTFail("Debe haber hora de fin") }
        let horas = until.timeIntervalSince(antes) / 3600
        XCTAssertEqual(horas, 4, accuracy: 0.05)
        XCTAssertTrue(state.isHelperAvailable)
    }

    func testDesactivarBorraLaHoraDeFin() {
        let state = nuevoEstado()
        state.worksAtNight = true
        state.setHelperAvailability(true, forHours: 4)

        state.setHelperAvailability(false)

        XCTAssertFalse(state.isHelperAvailable)
        XCTAssertNil(state.availableUntil, "Sin turno no debe quedar hora de fin colgando")
    }

    /// Sin disponibilidad nocturna declarada, el turno no debe pasar del corte.
    /// La ubicación de noche es la que revela el domicilio.
    func testElCorteNocturnoRecortaElTurno() throws {
        let state = nuevoEstado()
        state.worksAtNight = false

        // Solo tiene sentido comprobarlo si a esta hora el corte queda por
        // delante; de madrugada no hay nada que recortar.
        let calendar = Calendar.current
        guard let corte = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date()),
              corte > Date() else {
            throw XCTSkip("Ejecutado pasado el corte nocturno; caso no aplicable")
        }

        state.setHelperAvailability(true, forHours: 8)

        guard let until = state.availableUntil else { return XCTFail("Debe haber hora de fin") }
        XCTAssertLessThanOrEqual(until, corte.addingTimeInterval(1),
                                 "El turno no debe pasar de las 23:00 sin disponibilidad nocturna")
    }

    /// Con disponibilidad nocturna declarada, el corte no debe aplicarse.
    func testConDisponibilidadNocturnaNoSeRecorta() {
        let state = nuevoEstado()
        state.worksAtNight = true
        let antes = Date()

        state.setHelperAvailability(true, forHours: 8)

        guard let until = state.availableUntil else { return XCTFail("Debe haber hora de fin") }
        XCTAssertEqual(until.timeIntervalSince(antes) / 3600, 8, accuracy: 0.05)
    }

    func testLasOpcionesDeTurnoNoSuperanElTopeDelServidor() {
        XCTAssertEqual(AppState.shiftOptions, [2, 4, 8])
        XCTAssertLessThanOrEqual(AppState.shiftOptions.max() ?? 0, 8,
                                 "El servidor recorta a 8 h; ofrecer más engañaría al ayudante")
    }
}
