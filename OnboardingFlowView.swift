import SwiftUI

/// Flujo de configuración inicial guiado por el asistente Wheelp.
/// Pasos: welcome → intro → (tipo de discapacidad | aviso sin discapacidad) → configurando.
/// El asistente lee cada paso en voz alta y se puede responder hablando o tocando.
/// Con VoiceOver activo, la voz propia se calla pero el micrófono sigue disponible.
struct OnboardingFlowView: View {
    @Environment(AppState.self) private var appState
    @State private var step: Step
    @State private var selectedDisability: DisabilityType

    init(preselectedDisability: DisabilityType? = nil) {
        _step = State(initialValue: preselectedDisability != nil ? .configuring : .welcome)
        _selectedDisability = State(initialValue: preselectedDisability ?? .none)
    }
    @State private var speech = SpeechAnnouncer()
    @State private var recognizer = SpeechRecognizer()
    /// Evita reaccionar dos veces a la misma respuesta (voz y toque comparten flujo).
    @State private var answerMatched = false
    @State private var showHelperApplication = false
    @State private var helperApplicationSubmitted = false

    enum Step {
        case welcome          // Pantalla de bienvenida con las 3 propuestas de valor
        case intro            // "¿Tiene alguna discapacidad?"
        case chooseType       // Física / Auditiva / Visual
        case noDisability     // Sin discapacidad: estándar (ayudantes) o elegir versión
        case configuring      // Pantallas verdes de configuración
    }

    /// El usuario puede desactivar el micrófono en Ajustes y usar solo toques.
    private var voiceEnabled: Bool { appState.voiceControlEnabled }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView { answer { go(to: .intro) } }
            case .intro:
                AssistantIntroView(
                    onYes: { answer { go(to: .chooseType) } },
                    onNo: { answer { go(to: .noDisability) } }
                )
            case .chooseType:
                DisabilityTypeView { type in
                    answer {
                        selectedDisability = type
                        go(to: .configuring)
                    }
                }
            case .noDisability:
                if appState.isHelper {
                    NoDisabilityNoticeView(isHelper: true) {
                        answer { continueWithoutDisability() }
                    }
                } else {
                    HelperIntroView(
                        onApply: { answer { showHelperApplication = true } },
                        onBack: { answer { go(to: .intro) } },
                        onSignOut: { Task { await appState.signOut() } }
                    )
                }
            case .configuring:
                ConfiguringView(disability: selectedDisability) {
                    appState.completeOnboarding(disability: selectedDisability)
                }
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
        .overlay(alignment: .topTrailing) { listeningIndicator }
        .task {
            speech.isEnabled = true
            speech.rate = Float(appState.voiceRate)
            speech.configureSession()
            announceStep()
        }
        .onChange(of: step) { _, _ in
            recognizer.stop()
            answerMatched = false
            announceStep()
        }
        .onChange(of: recognizer.transcript) { _, text in
            handleTranscript(text)
        }
        .onChange(of: recognizer.status) { _, status in
            // Si la escucha se apaga sin respuesta reconocida, se reintenta.
            guard status == .idle, voiceEnabled, !answerMatched, step != .configuring else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !recognizer.isListening, !answerMatched, !speech.isSpeaking, step != .configuring {
                    try? recognizer.start()
                }
            }
        }
        .sheet(isPresented: $showHelperApplication, onDismiss: {
            guard helperApplicationSubmitted else { return }
            helperApplicationSubmitted = false
            selectedDisability = .none
            go(to: .configuring)
        }) {
            HelperApplicationView(userName: appState.publicName, onSubmit: {
                helperApplicationSubmitted = true
            })
        }
    }

    /// Único punto de transición del flujo (voz y toque pasan por aquí).
    /// Un ayudante verificado usa siempre la versión Estándar —no hay ayudantes
    /// con discapacidad—, así que nunca se le pregunta el tipo: los pasos de la
    /// encuesta se redirigen a la confirmación de modo Estándar.
    private func go(to next: Step) {
        var next = next
        if appState.isHelper, next == .intro || next == .chooseType {
            next = .noDisability
        }
        withAnimation(.easeInOut(duration: 0.35)) { step = next }
    }

    /// Respuesta aceptada (por voz o por toque): apaga voz y micro y actúa.
    private func answer(_ action: () -> Void) {
        answerMatched = true
        recognizer.stop()
        speech.stop()
        action()
    }

    /// "No tengo discapacidad": los ayudantes verificados usan la versión
    /// estándar; el resto debe elegir una de las tres versiones.
    private func continueWithoutDisability() {
        if appState.isHelper {
            selectedDisability = .none
            go(to: .configuring)
        } else {
            go(to: .chooseType)
        }
    }

    // MARK: - Voz: lectura del paso y escucha de la respuesta

    @ViewBuilder
    private var listeningIndicator: some View {
        if recognizer.isListening {
            Label("Escuchando", systemImage: "mic.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.wheelpGreen, in: Capsule())
                .padding(.trailing, 16)
                .accessibilityLabel("Micrófono activo. Puede responder con la voz.")
        }
    }

    private func announceStep() {
        guard step != .configuring else { return }
        let text = prompt(for: step)
        guard !text.isEmpty else { return }
        speech.announce(text) { listenIfEnabled() }
    }

    private func prompt(for step: Step) -> String {
        switch step {
        case .welcome:
            "Bienvenido a la app de navegación adaptada. Toca continuar o di continuar para empezar."
        case .intro:
            "¿Tiene alguna discapacidad? Responda sí o no."
        case .chooseType:
            "¿Qué tipo de discapacidad tiene? Diga física, auditiva o visual."
        case .noDisability:
            appState.isHelper
                ? "Tu cuenta es de ayudante verificado. Usarás la versión estándar de Wheelp. Diga continuar para empezar."
                : ""  // Sin discapacidad: sin voz, solo toque
        case .configuring:
            ""
        }
    }

    private func listenIfEnabled() {
        guard voiceEnabled, step != .configuring else { return }
        Task {
            guard await recognizer.requestAuthorization() else { return }
            try? recognizer.start()
        }
    }

    private func handleTranscript(_ raw: String) {
        guard voiceEnabled, !answerMatched, !raw.isEmpty else { return }
        let normalized = raw.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let words = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ options: Set<String>) -> Bool { !words.isDisjoint(with: options) }

        switch step {
        case .welcome:
            if has(["continuar", "empezar", "si", "ok", "vale", "adelante", "inicio"]) {
                answer { go(to: .intro) }
            }
        case .intro:
            // "No" primero: "no tengo ninguna" no debe confundirse con un sí.
            if has(["no", "ninguna", "ninguno"]) {
                answer { go(to: .noDisability) }
            } else if has(["si", "tengo"]) {
                answer { go(to: .chooseType) }
            }
        case .chooseType:
            if has(["fisica", "motora", "movilidad", "silla"]) {
                answer { selectedDisability = .physical; go(to: .configuring) }
            } else if has(["auditiva", "sorda", "sordo", "oido", "oir", "oigo", "escuchar", "escucho"]) {
                answer { selectedDisability = .hearing; go(to: .configuring) }
            } else if has(["visual", "vista", "ciega", "ciego", "ver", "veo"]) {
                answer { selectedDisability = .visual; go(to: .configuring) }
            }
        case .noDisability:
            if appState.isHelper {
                if has(["continuar", "vale", "ok", "si", "adelante", "empezar"]) {
                    answer { continueWithoutDisability() }
                }
            }
            // No-ayudantes: sin control por voz en este paso
        case .configuring:
            break
        }
    }
}

// MARK: - Paso 0: Bienvenida

private struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WheelpLogo(variant: .black)
                .frame(maxWidth: 200)
                .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 28) {
                Text("Bienvenido a Wheelp")
                    .font(.title.bold())

                VStack(alignment: .leading, spacing: 20) {
                    OnboardingFeatureRow(
                        icon: "map.fill",
                        color: .wheelpGreen,
                        title: "Rutas adaptadas",
                        subtitle: "Caminos sin obstáculos, adaptados a tus necesidades"
                    )
                    OnboardingFeatureRow(
                        icon: "hand.raised.fill",
                        color: .blue,
                        title: "Red de ayudantes",
                        subtitle: "Solicita ayuda humana en ruta cuando la necesites"
                    )
                    OnboardingFeatureRow(
                        icon: "lock.shield.fill",
                        color: .orange,
                        title: "Solo en tu iPhone",
                        subtitle: "Tus datos no salen del dispositivo salvo lo imprescindible"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Button("Continuar", action: onContinue)
                .buttonStyle(.wheelpPrimary)
        }
        .padding(28)
    }
}

private struct OnboardingFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Paso 1: Pregunta de discapacidad

private struct AssistantIntroView: View {
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WheelpLogo(variant: .black)
                .frame(maxWidth: 200)
                .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Text("Antes de empezar,\n¿tiene alguna discapacidad?")
                    .font(.title2.weight(.semibold))

                Text("Puede responder en voz alta o tocar la pantalla.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            HStack(spacing: 16) {
                Button("SÍ", action: onYes)
                    .buttonStyle(.wheelpPrimary)
                Button("NO", action: onNo)
                    .buttonStyle(.wheelpOutline)
            }
        }
        .padding(28)
    }
}

// MARK: - Paso 2: Tipo de discapacidad

private struct DisabilityTypeView: View {
    let onSelect: (DisabilityType) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WheelpLogo(variant: .black)
                .frame(maxWidth: 200)
                .padding(.top, 24)

            Spacer()

            Text("¿Qué tipo de\ndiscapacidad tiene?")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Spacer()

            VStack(spacing: 16) {
                ForEach(DisabilityType.selectable) { type in
                    Button { onSelect(type) } label: {
                        Label(type.title, systemImage: type.icon)
                    }
                    .buttonStyle(.wheelpPrimary)
                    .accessibilityLabel("Discapacidad \(type.title)")
                }
            }
        }
        .padding(28)
    }
}

// MARK: - Paso alternativo: sin discapacidad — propuesta de ser ayudante

private struct HelperIntroView: View {
    let onApply: () -> Void
    let onBack: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .fontWeight(.semibold)
                        Text("Volver")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.wheelpGreen)
                }
                Spacer()
                WheelpLogo(variant: .black)
                    .frame(maxWidth: 120)
                Spacer()
                // Hueco simétrico para centrar el logo
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Volver")
                    }
                    .font(.subheadline)
                }
                .hidden()
            }
            .padding(.top, 16)

            Spacer()

            VStack(alignment: .leading, spacing: 24) {
                Text("Esta app está pensada para personas con discapacidad")
                    .font(.title2.bold())

                Text("Si no tienes ninguna, puedes unirte como ayudante y acompañar a personas en sus trayectos.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 20) {
                    OnboardingFeatureRow(
                        icon: "figure.walk.motion",
                        color: .blue,
                        title: "Acompañar en trayectos",
                        subtitle: "Ayudas a personas a llegar de A a B en su ciudad"
                    )
                    OnboardingFeatureRow(
                        icon: "clock.badge.checkmark",
                        color: .wheelpGreen,
                        title: "Cuando tú puedas",
                        subtitle: "Aceptas las peticiones que te encajen, sin compromisos fijos"
                    )
                    OnboardingFeatureRow(
                        icon: "doc.badge.plus",
                        color: .orange,
                        title: "Verificación previa",
                        subtitle: "Necesitamos DNI y certificado de antecedentes penales"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            VStack(spacing: 16) {
                Button("Solicitar ser ayudante", action: onApply)
                    .buttonStyle(.wheelpPrimary)

                Button("Cerrar sesión", action: onSignOut)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }
}

// MARK: - Paso alternativo: sin discapacidad — ayudante verificado

private struct NoDisabilityNoticeView: View {
    let isHelper: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WheelpLogo(variant: .black)
                .frame(maxWidth: 200)
                .padding(.top, 24)

            Spacer()

            Text(isHelper
                 ? "Tu cuenta es de ayudante verificado.\n\nUsarás la versión estándar de Wheelp, pensada para ver y atender las peticiones de ayuda."
                 : "Esta aplicación está diseñada para personas con discapacidad.\n\nElige la versión que mejor se adapte a la persona que va a usarla.")
                .font(.title3)
                .multilineTextAlignment(.center)

            Spacer()

            Button(isHelper ? "Continuar" : "Elegir versión", action: onContinue)
                .buttonStyle(.wheelpPrimary)
        }
        .padding(28)
    }
}
