import XCTest
@testable import Wheelp

/// "Repetir configuración inicial" debe rehacer la encuesta de discapacidad.
/// `RootView` pasa `appState.disabilityType` como `preselectedDisability` a
/// `OnboardingFlowView`, y ese init arranca en `.configuring` si no es nil.
/// Si `restartOnboarding()` deja el tipo puesto, el asistente se salta la
/// encuesta y va directo a las pantallas de "estamos configurando la app".
@MainActor
final class AppStateOnboardingRestartTests: XCTestCase {

    private let onboardedKey = "wheelp.hasCompletedOnboarding"
    private let disabilityKey = "wheelp.disabilityType"
    private let helperKey = "wheelp.isHelper"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: onboardedKey)
        UserDefaults.standard.removeObject(forKey: disabilityKey)
        UserDefaults.standard.removeObject(forKey: helperKey)
        super.tearDown()
    }

    func testRepetirConfiguracionBorraElTipoDeDiscapacidad() {
        let state = AppState()
        state.completeOnboarding(disability: .physical)
        XCTAssertTrue(state.hasCompletedOnboarding)

        state.restartOnboarding()

        XCTAssertFalse(state.hasCompletedOnboarding, "el onboarding debe quedar pendiente")
        XCTAssertNil(state.disabilityType, "sin tipo preseleccionado el flujo arranca en .welcome, no en .configuring")
    }

    /// Si el usuario mata la app a mitad de la reconfiguración, el siguiente
    /// arranque tampoco debe recuperar el tipo antiguo desde UserDefaults.
    func testElBorradoSobreviveAlSiguienteArranque() {
        let state = AppState()
        state.completeOnboarding(disability: .visual)
        state.restartOnboarding()

        let relanzada = AppState()
        XCTAssertNil(relanzada.disabilityType)
        XCTAssertFalse(relanzada.hasCompletedOnboarding)
    }

    /// El ayudante es Estándar por definición, pero `restartOnboarding` debe
    /// dejar el tipo en nil igual que a cualquier otro: con `.none` puesto el
    /// init de `OnboardingFlowView` arranca en `.configuring` y se salta la
    /// pantalla que le confirma el modo Estándar. El `.none` se lo pone el
    /// propio flujo al confirmar, vía `completeOnboarding(disability: .none)`.
    func testElAyudanteTambienQuedaConTipoNilAlRepetirConfiguracion() {
        let state = AppState()
        state.isHelper = true
        state.completeOnboarding(disability: .none)

        state.restartOnboarding()

        XCTAssertNil(state.disabilityType, "con .none el ayudante se saltaría la confirmación de Estándar")
    }

    // MARK: - Guard retroactivo (ayudante siempre Estándar)

    func testAlPasarAAyudanteSeCorrigeUnTipoYaElegido() {
        let state = AppState()
        state.completeOnboarding(disability: .physical)

        state.isHelper = true

        XCTAssertEqual(state.disabilityType, DisabilityType.none, "un ayudante no puede tener discapacidad declarada")
    }

    func testElGuardNoConvierteNilEnNone() {
        let state = AppState()
        XCTAssertNil(state.disabilityType)

        state.isHelper = true

        XCTAssertNil(state.disabilityType, "nil = onboarding pendiente; con .none se saltaría la encuesta")
    }

    /// El bug lleva semanas en producción: el tipo malo ya está en UserDefaults
    /// y hay que corregirlo al arrancar, no solo al cambiar `isHelper`.
    func testElArranqueCorrigeUnAyudanteYaGuardadoMal() {
        UserDefaults.standard.set(true, forKey: helperKey)
        UserDefaults.standard.set(DisabilityType.visual.rawValue, forKey: disabilityKey)

        let state = AppState()

        XCTAssertEqual(state.disabilityType, DisabilityType.none)
        XCTAssertEqual(UserDefaults.standard.string(forKey: disabilityKey), DisabilityType.none.rawValue)
    }
}
