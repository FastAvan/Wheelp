import SwiftUI
import Supabase

/// Tipo de discapacidad que determina qué "versión" de la app se presenta.
enum DisabilityType: String, CaseIterable, Identifiable, Codable {
    case physical
    case hearing
    case visual
    case none // El usuario continúa sin discapacidad declarada.

    var id: String { rawValue }

    /// Opciones que se muestran al usuario (excluye `.none`).
    static var selectable: [DisabilityType] { [.physical, .hearing, .visual] }

    var title: String {
        switch self {
        case .physical: "Física"
        case .hearing: "Auditiva"
        case .visual: "Visual"
        case .none: "Estándar"
        }
    }

    var icon: String {
        switch self {
        case .physical: "figure.roll"
        case .hearing: "ear"
        case .visual: "eye"
        case .none: "person.fill"
        }
    }
}

/// Estado global: sesión (Supabase), progreso de onboarding y configuración.
/// La sesión la persiste el propio SDK de Supabase; el onboarding y el tipo de
/// discapacidad se guardan localmente en `UserDefaults`.
@Observable
final class AppState {
    var isSignedIn = false
    var hasCompletedOnboarding: Bool
    var disabilityType: DisabilityType?
    var userName: String?

    /// Alias elegido por el usuario. Se guarda solo en el dispositivo.
    var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }

    /// Nombre con el que te ven los demás (peticiones de ayuda y chat):
    /// el alias si lo hay; si no, la parte del correo antes de la arroba.
    var publicName: String {
        let alias = displayName.trimmingCharacters(in: .whitespaces)
        if !alias.isEmpty { return alias }
        if let email = userName, let prefix = email.split(separator: "@").first {
            return String(prefix)
        }
        return "Usuario de Wheelp"
    }

    /// Número de teléfono del contacto de confianza para el botón SOS.
    /// Se guarda solo en el dispositivo; nunca sale del teléfono.
    var trustedContactPhone: String {
        didSet { defaults.set(trustedContactPhone, forKey: Keys.trustedContact) }
    }

    /// Control por voz (versión Visual). Si está desactivado, la app se usa solo
    /// con toques en pantalla y no se activa el micrófono.
    var voiceControlEnabled: Bool {
        didSet { defaults.set(voiceControlEnabled, forKey: Keys.voiceControl) }
    }

    /// Velocidad de la voz (rate de AVSpeechUtterance, 0.3 lenta – 0.65 rápida).
    var voiceRate: Double {
        didSet { defaults.set(voiceRate, forKey: Keys.voiceRate) }
    }

    /// ¿Este usuario es ayudante? Se decide FUERA de la app: el equipo de Wheelp
    /// da de alta al usuario en la tabla `helpers` de Supabase y la app lo detecta.
    /// Se persiste en UserDefaults para que un fallo transitorio de red o de token
    /// no degrade a un ayudante a usuario normal (ver `refreshHelperStatus`).
    var isHelper: Bool {
        didSet { defaults.set(isHelper, forKey: Keys.helper) }
    }
    var needsPasswordReset = false

    /// El ayudante ha activado su disponibilidad para recibir peticiones de ayuda.
    /// Se persiste en UserDefaults (inicio rápido) y se sincroniza con Supabase al cambiar.
    var isHelperAvailable: Bool {
        didSet { defaults.set(isHelperAvailable, forKey: Keys.helperAvailable) }
    }

    /// El usuario ha aceptado los términos y condiciones (persiste en UserDefaults).
    var hasAcceptedTerms: Bool {
        didSet { defaults.set(hasAcceptedTerms, forKey: Keys.termsAccepted) }
    }

    static let defaultVoiceRate = 0.5

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let onboarded = "wheelp.hasCompletedOnboarding"
        static let disability = "wheelp.disabilityType"
        static let voiceControl = "wheelp.voiceControlEnabled"
        static let voiceRate = "wheelp.voiceRate"
        static let displayName = "wheelp.displayName"
        static let trustedContact = "wheelp.trustedContactPhone"
        static let termsAccepted = "wheelp.hasAcceptedTerms"
        static let helperAvailable = "wheelp.helperAvailable"
        static let helper = "wheelp.isHelper"
    }

    /// Consulta el estado de ayudante y lo aplica SOLO si el servidor respondió.
    /// Si la consulta falló (`nil`) se conserva el último valor conocido: perder
    /// el modo ayudante por un 401 deja al ayudante sin poder recibir peticiones.
    private func refreshHelperStatus() async {
        if let registered = await HelperService.isRegisteredHelper() {
            isHelper = registered
        }
        guard isHelper else { return }
        if let available = await HelperService.fetchAvailability() {
            isHelperAvailable = available
        }
        if isHelperAvailable { HelpRequestNotifier.shared.start() }
    }

    init() {
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
        displayName = defaults.string(forKey: Keys.displayName) ?? ""
        trustedContactPhone = defaults.string(forKey: Keys.trustedContact) ?? ""
        if let raw = defaults.string(forKey: Keys.disability) {
            disabilityType = DisabilityType(rawValue: raw)
        }
        // Por defecto activado en la versión Visual.
        voiceControlEnabled = (defaults.object(forKey: Keys.voiceControl) as? Bool) ?? true
        voiceRate = (defaults.object(forKey: Keys.voiceRate) as? Double) ?? Self.defaultVoiceRate
        hasAcceptedTerms = defaults.bool(forKey: Keys.termsAccepted)
        // Disponibilidad: true por defecto para no interrumpir ayudantes existentes.
        isHelperAvailable = (defaults.object(forKey: Keys.helperAvailable) as? Bool) ?? true
        isHelper = defaults.bool(forKey: Keys.helper)
    }

    // MARK: - Autenticación (Supabase)

    /// Restaura la sesión persistida por Supabase al arrancar la app.
    /// Usa la sesión guardada en el dispositivo para entrar al instante;
    /// solo va a la red si no hay ninguna. El estado de ayudante se
    /// comprueba en segundo plano para no retrasar el arranque.
    func bootstrap() async {
        // `supabase.auth.session` refresca el access token si está caducado;
        // `currentSession` devuelve el guardado tal cual y las primeras consultas
        // salían con un token muerto (401) mientras el refresco iba en paralelo.
        var session = try? await supabase.auth.session
        if session == nil {
            session = supabase.auth.currentSession
        }
        if let session {
            isSignedIn = true
            userName = session.user.email
            Task { @MainActor in await refreshHelperStatus() }
            if session.user.email == "aelguer@icloud.com" { AdminNotifier.shared.start() }
        }
    }

    /// Paso 1: verifica contraseña y envía OTP al correo (plantilla Magic Link or OTP).
    /// Cierra la sesión creada por el chequeo de contraseña inmediatamente: hasta que
    /// no se verifique el OTP no debe existir ninguna sesión persistida, o el segundo
    /// factor sería opcional (bootstrap() entraría con solo la contraseña).
    func initiateSignIn(email: String, password: String) async throws {
        _ = try await supabase.auth.signIn(email: email, password: password)
        try await supabase.auth.signOut()
        try await supabase.auth.signInWithOTP(email: email, shouldCreateUser: false)
    }

    /// Paso 2: verifica el código OTP (type .email) y completa el inicio de sesión.
    /// Espera a que isHelper se resuelva antes de devolver el control: si quedara en
    /// un Task desacoplado, la pantalla de onboarding (que decide su flujo mirando
    /// appState.isHelper) puede pintarse antes de que termine y tratar a un ayudante
    /// ya dado de alta como si no lo fuera.
    func verifyOTPAndSignIn(email: String, code: String) async throws {
        try await supabase.auth.verifyOTP(email: email, token: code, type: .email)
        userName = supabase.auth.currentSession?.user.email ?? email
        isSignedIn = true
        await refreshHelperStatus()
        if userName == "aelguer@icloud.com" { AdminNotifier.shared.start() }
    }

    func resendLoginOTP(email: String) async throws {
        try await supabase.auth.signInWithOTP(email: email, shouldCreateUser: false)
    }

    /// Registra un usuario nuevo. Devuelve `true` si la sesión queda activa,
    /// o `false` si el proyecto exige confirmar el email antes de entrar.
    @discardableResult
    func signUp(email: String, password: String) async throws -> Bool {
        let response = try await supabase.auth.signUp(email: email, password: password)
        if let session = response.session {
            userName = session.user.email
            isSignedIn = true
            return true
        }
        return false
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        let session = try await supabase.auth.signInWithIdToken(credentials: .init(
            provider: .apple,
            idToken: idToken,
            nonce: nonce
        ))
        userName = session.user.email
        isSignedIn = true
        await refreshHelperStatus()
        if session.user.email == "aelguer@icloud.com" { AdminNotifier.shared.start() }
    }

    /// Cambia la disponibilidad del ayudante: actualiza estado local, UserDefaults y Supabase.
    func setHelperAvailability(_ available: Bool) {
        isHelperAvailable = available
        if available {
            HelpRequestNotifier.shared.start()
        } else {
            HelpRequestNotifier.shared.stop()
        }
        Task { await HelperService.updateAvailability(available) }
    }

    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(
            email,
            redirectTo: URL(string: "wheelp://reset-password")
        )
    }

    func updatePassword(_ newPassword: String) async throws {
        try await supabase.auth.update(user: UserAttributes(password: newPassword))
        needsPasswordReset = false
        if let session = supabase.auth.currentSession {
            isSignedIn = true
            userName = session.user.email
        }
    }

    func handleDeepLink(_ url: URL) async {
        do {
            let session = try await supabase.auth.session(from: url)
            if url.host == "reset-password" {
                needsPasswordReset = true
            } else {
                isSignedIn = true
                userName = session.user.email
            }
        } catch {
            print("[Wheelp] Deep link error: \(error)")
        }
    }

    func resendVerification(email: String) async throws {
        try await supabase.auth.resend(email: email, type: .signup)
    }

    func signOut() async {
        HelpRequestNotifier.shared.stop()
        AdminNotifier.shared.stop()
        await PushTokenService.delete()
        try? await supabase.auth.signOut()
        isSignedIn = false
        userName = nil
        isHelper = false
    }

    /// Elimina todos los datos del usuario en Supabase (incluida la cuenta de auth)
    /// y borra los datos locales del dispositivo. Irreversible.
    /// Requiere que la función SQL `delete_own_account()` esté creada en Supabase
    /// (ver docs/Supabase-Ayudantes-Cifrado.md — 8ª parte).
    func deleteAccount() async throws {
        await PushTokenService.delete()
        try await supabase.rpc("delete_own_account").execute()
        try? await supabase.auth.signOut()
        [Keys.onboarded, Keys.disability, Keys.voiceControl,
         Keys.voiceRate, Keys.displayName, Keys.trustedContact,
         Keys.termsAccepted, Keys.helperAvailable, Keys.helper]
            .forEach { defaults.removeObject(forKey: $0) }
        // Delete saved places and route history from disk.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let url = appSupport?.appendingPathComponent("saved-places.json") {
            try? FileManager.default.removeItem(at: url)
        }
        // Clear E2E private keys from the Keychain.
        HelpCrypto.clearAllKeys()
        HelpRequestNotifier.shared.stop()
        AdminNotifier.shared.stop()
        isSignedIn = false
        userName = nil
        isHelper = false
        hasCompletedOnboarding = false
        disabilityType = nil
        displayName = ""
        trustedContactPhone = ""
        hasAcceptedTerms = false
    }

    // MARK: - Onboarding

    /// Marca el onboarding como completado con el tipo de discapacidad elegido.
    /// Guarda la discapacidad seleccionada en el flujo pre-login.
    func setPreLoginDisability(_ type: DisabilityType) {
        disabilityType = type
        defaults.set(type.rawValue, forKey: Keys.disability)
    }

    func completeOnboarding(disability: DisabilityType) {
        disabilityType = disability
        hasCompletedOnboarding = true
        defaults.set(disability.rawValue, forKey: Keys.disability)
        defaults.set(true, forKey: Keys.onboarded)
    }

    /// Cambia la "versión" (tipo de discapacidad) desde los ajustes.
    func setDisability(_ type: DisabilityType) {
        disabilityType = type
        defaults.set(type.rawValue, forKey: Keys.disability)
    }

    /// Vuelve a lanzar el onboarding (asistente Wheelp) manteniendo la sesión.
    func restartOnboarding() {
        hasCompletedOnboarding = false
        defaults.set(false, forKey: Keys.onboarded)
    }
}
