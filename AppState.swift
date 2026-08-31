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
        didSet {
            defaults.set(isHelper, forKey: Keys.helper)
            enforceHelperStandardVersion()
        }
    }

    /// Guard retroactivo: un ayudante usa SIEMPRE la versión Estándar. Corrige el
    /// tipo ya guardado en dispositivos afectados por el `ForEach` invertido de
    /// `SettingsView`, que durante tres semanas ofreció a los ayudantes física/
    /// auditiva/visual y les rompía el carrusel de accesibilidad del destino.
    ///
    /// No toca `nil`: `nil` significa "onboarding pendiente" y `OnboardingFlowView`
    /// se saltaría la encuesta si lo convirtiéramos en `.none`.
    private func enforceHelperStandardVersion() {
        guard isHelper, let type = disabilityType, type != .none else { return }
        setDisability(.none)
    }
    var needsPasswordReset = false

    /// El ayudante ha activado su disponibilidad para recibir peticiones de ayuda.
    /// Se persiste en UserDefaults (inicio rápido) y se sincroniza con Supabase al cambiar.
    /// El ayudante ha declarado que también trabaja de noche. Sin esto, el turno
    /// no se prolonga más allá del corte nocturno.
    var worksAtNight: Bool {
        didSet { defaults.set(worksAtNight, forKey: Keys.worksAtNight) }
    }

    /// Admin: lo dice el servidor en cada sesión y NO se persiste. Un flag de
    /// autorización guardado en el dispositivo es un flag que se puede editar.
    var isAdmin = false

    var isHelperAvailable: Bool {
        didSet { defaults.set(isHelperAvailable, forKey: Keys.helperAvailable) }
    }

    /// El ayudante ya ha visto el aviso de qué se comparte durante un turno.
    /// No es un consentimiento (la base es el art. 6.1.b), sino la prueba de que
    /// la información se facilitó ANTES del tratamiento, que es lo que exige el
    /// art. 13 RGPD.
    var hasSeenHelperShiftNotice: Bool {
        didSet { defaults.set(hasSeenHelperShiftNotice, forKey: Keys.helperShiftNotice) }
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
        static let worksAtNight = "wheelp.worksAtNight"
        static let helper = "wheelp.isHelper"
        static let helperShiftNotice = "wheelp.helperShiftNoticeSeen"
    }

    /// Consulta el estado de ayudante y lo aplica SOLO si el servidor respondió.
    /// Si la consulta falló (`nil`) se conserva el último valor conocido: perder
    /// el modo ayudante por un 401 deja al ayudante sin poder recibir peticiones.
    private func refreshHelperStatus() async {
        if let registered = await HelperService.isRegisteredHelper() {
            isHelper = registered
        }
        // Antes esto era una comparación con el correo del admin, a fuego y
        // repetida en los tres caminos de inicio de sesión. Ahora hay un solo
        // sitio y la fuente es la tabla admins.
        if let admin = await HelperService.isAdmin() {
            isAdmin = admin
            if admin { AdminNotifier.shared.start() }
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
        // Disponibilidad: false por defecto. Antes arrancaba en true para no
        // interrumpir a ayudantes existentes, pero ahora estar disponible
        // implica compartir la zona en segundo plano: eso no puede quedar
        // activado por omisión, tiene que declararlo la persona. El estado real
        // lo confirma el servidor en refreshAvailabilityShift().
        isHelperAvailable = defaults.bool(forKey: Keys.helperAvailable)
        worksAtNight = defaults.bool(forKey: Keys.worksAtNight)
        hasSeenHelperShiftNotice = defaults.bool(forKey: Keys.helperShiftNotice)
        isHelper = defaults.bool(forKey: Keys.helper)
        // Los `didSet` no se disparan desde el init, así que el guard hay que
        // llamarlo a mano: un ayudante ya persistido debe quedar corregido al
        // arrancar aunque no haya red para `refreshHelperStatus`.
        enforceHelperStandardVersion()
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
    }

    /// Cambia la disponibilidad del ayudante: actualiza estado local, UserDefaults y Supabase.
    /// Duraciones de turno que puede elegir el ayudante. El servidor recorta
    /// cualquier cosa por encima de 8 h.
    static let shiftOptions: [Int] = [2, 4, 8]

    /// Hora a la que termina el turno declarado (nil si no está disponible).
    var availableUntil: Date?

    /// A partir de esta hora no se prolonga un turno salvo que el ayudante haya
    /// declarado disponibilidad nocturna: la ubicación de noche es la que revela
    /// el domicilio, y es el dato que más daño hace si hay una brecha.
    private static let nightCutoffHour = 23

    /// Recorta el fin de turno al corte nocturno si procede.
    private func applyNightCutoff(_ end: Date) -> Date {
        guard !worksAtNight else { return end }
        let calendar = Calendar.current
        guard let cutoff = calendar.date(
            bySettingHour: Self.nightCutoffHour, minute: 0, second: 0, of: Date()
        ), cutoff > Date() else { return end }
        return min(end, cutoff)
    }

    /// Texto para la pantalla de ajustes: hasta cuándo se comparte la zona.
    var availabilityStatusText: String? {
        guard isHelperAvailable, let until = availableUntil else { return nil }
        let f = DateFormatter()
        f.timeStyle = .short
        return "Compartiendo tu zona aproximada hasta las \(f.string(from: until))"
    }

    /// Activa el turno durante `hours`, o lo apaga.
    func setHelperAvailability(_ available: Bool, forHours hours: Int = 4) {
        isHelperAvailable = available
        if available {
            let end = applyNightCutoff(Date().addingTimeInterval(TimeInterval(hours) * 3600))
            availableUntil = end
            HelpRequestNotifier.shared.start()
            scheduleAvailabilityReminders(until: end)
        } else {
            availableUntil = nil
            HelpRequestNotifier.shared.stop()
            cancelAvailabilityReminders()
        }
        Task { await HelperService.updateAvailability(available, until: availableUntil) }
    }

    // MARK: Recordatorios del turno

    private static let reminderID = "wheelp.availability.reminder"
    private static let expiryID   = "wheelp.availability.expiry"

    /// Avisa si el ayudante se deja el turno puesto y se va, y cuando expira.
    ///
    /// iOS no permite detectar de forma fiable que se cierra la app
    /// (`applicationWillTerminate` no se llama al matarla desde el selector), así
    /// que en vez de reaccionar al cierre se programa el aviso y se reprograma
    /// cada vez que vuelve a abrirla. Si sigue usándola no lo ve; si se fue, le
    /// llega. Eso es lo que impide que la disponibilidad sea un estado pasivo.
    func scheduleAvailabilityReminders(until end: Date) {
        cancelAvailabilityReminders()
        let checkIn = Date().addingTimeInterval(30 * 60)
        if checkIn < end {
            NotificationService.schedule(
                at: checkIn,
                title: "¿Sigues disponible?",
                body: "Mientras lo estés, Wheelp comparte tu zona aproximada. Abre la app para continuar o desactívalo.",
                id: Self.reminderID
            )
        }
        NotificationService.schedule(
            at: end,
            title: "Turno terminado",
            body: "Ya no estás disponible y Wheelp ha dejado de compartir tu zona.",
            id: Self.expiryID
        )
    }

    func cancelAvailabilityReminders() {
        NotificationService.cancel(id: Self.reminderID)
        NotificationService.cancel(id: Self.expiryID)
    }

    /// Comprueba al abrir la app si el turno ya expiró, y reprograma el aviso si
    /// sigue vigente. La caducidad la impone también el servidor, por si la app
    /// no llegó a abrirse.
    func refreshAvailabilityShift() async {
        guard isHelper else { return }
        let until = await HelperService.availableUntil()
        availableUntil = until
        if let until {
            isHelperAvailable = true
            scheduleAvailabilityReminders(until: until)
        } else if isHelperAvailable {
            isHelperAvailable = false
            cancelAvailabilityReminders()
        }
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
        isAdmin = false
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
    /// Borra también el tipo de discapacidad: `RootView` se lo pasa a
    /// `OnboardingFlowView` como `preselectedDisability`, y con un valor
    /// presente el flujo arranca directo en `.configuring` y se salta la
    /// encuesta. "Repetir configuración" tiene que preguntar de nuevo.
    func restartOnboarding() {
        hasCompletedOnboarding = false
        disabilityType = nil
        defaults.set(false, forKey: Keys.onboarded)
        defaults.removeObject(forKey: Keys.disability)
    }
}
