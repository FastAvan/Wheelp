import SwiftUI

/// Flujo de configuración inicial guiado por el asistente Wheelp.
/// Pasos: intro → (tipo de discapacidad | aviso sin discapacidad) → configurando.
/// El asistente lee cada paso en voz alta y se puede responder hablando o tocando.
/// Con VoiceOver activo, la voz propia se calla pero el micrófono sigue disponible.
struct OnboardingFlowView: View {
    @Environment(AppState.self) private var appState
    @State private var step: Step = .intro
    @State private var selectedDisability: DisabilityType = .none
    @State private var speech = SpeechAnnouncer()
    @State private var recognizer = SpeechRecognizer()
    /// Evita reaccionar dos veces a la misma respuesta (voz y toque comparten flujo).
    @State private var answerMatched = false

    enum Step {
        case intro            // "Hola, soy Wheelp... ¿tiene alguna discapacidad?"
        case chooseType       // Física / Auditiva / Visual
        case noDisability     // Sin discapacidad: estándar (ayudantes) o elegir versión
        case configuring      // Pantallas verdes de configuración
    }

    /// El usuario puede desactivar el micrófono en Ajustes y usar solo toques.
    private var voiceEnabled: Bool { appState.voiceControlEnabled }

    var body: some View {
        ZStack {
            switch step {
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
                NoDisabilityNoticeView(isHelper: appState.isHelper) {
                    answer { continueWithoutDisability() }
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
    }

    private func go(to next: Step) {
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
        speech.announce(prompt(for: step)) { listenIfEnabled() }
    }

    private func prompt(for step: Step) -> String {
        switch step {
        case .intro:
            "Hola, soy Wheelp. Voy a ayudarte a configurar la app. ¿Tiene alguna discapacidad? Responda sí o no."
        case .chooseType:
            "¿Qué tipo de discapacidad tiene? Diga física, auditiva o visual."
        case .noDisability:
            appState.isHelper
                ? "Tu cuenta es de ayudante verificado. Usarás la versión estándar de Wheelp. Diga continuar para empezar."
                : "Esta aplicación está diseñada para personas con discapacidad. Diga continuar para elegir la versión que mejor se adapte a la persona que va a usarla."
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
            if has(["continuar", "vale", "ok", "si", "adelante", "empezar", "elegir"]) {
                answer { continueWithoutDisability() }
            }
        case .configuring:
            break
        }
    }
}

// MARK: - Paso 1: Presentación del asistente

private struct AssistantIntroView: View {
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WheelpLogo(variant: .black)
                .frame(maxWidth: 200)
                .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 20) {
                Text("Hola, soy Wheelp.\nVoy a ayudarte a configurar la app.")
                    .font(.title2.weight(.semibold))

                Text("Lo primero de todo, ¿tiene alguna discapacidad?")
                    .font(.title3)

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

// MARK: - Paso alternativo: sin discapacidad

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
