import SwiftUI
import MapKit

/// Pantalla principal de la versión Visual: manos libres por voz (o solo toques).
/// Flujo: decir/escribir destino → opciones (di el número o tócalo) →
/// confirmar ("ir") → en ruta el micrófono está apagado hasta que se activa.
struct VoiceHomeView: View {
    let profile: AccessibilityProfile
    @Environment(AppState.self) private var appState

    @State private var location = LocationManager()
    @State private var model = MapHomeModel()
    @State private var recognizer = SpeechRecognizer()
    @State private var speech = SpeechAnnouncer()

    @State private var showSettings = false
    @State private var showContribute = false
    @State private var chatRequest: HelpRequest?
    @State private var listenMode: ListenMode = .destination
    @State private var awaitingSearch = false
    @State private var commandMatched = false
    /// Esperando que el usuario diga dónde encontrarse con el ayudante.
    @State private var awaitingMeetingPoint = false
    @State private var showHelpSetup = false

    enum ListenMode { case destination, command }
    enum Phase { case idle, results, confirm, routing }

    /// El usuario puede desactivar el micrófono en Ajustes y usar solo toques.
    private var voiceEnabled: Bool { appState.voiceControlEnabled }

    private var phase: Phase {
        if model.route != nil { return .routing }
        if model.previewItem != nil { return .confirm }
        if !model.results.isEmpty { return .results }
        return .idle
    }

    var body: some View {
        VStack(spacing: 24) {
            topBar
            Spacer(minLength: 0)
            Group {
                switch phase {
                case .routing: routingView
                // Resultados y ficha pueden crecer mucho con letra grande:
                // scroll para que nada quede cortado.
                case .confirm: ScrollView(showsIndicators: false) { confirmView }
                case .results: ScrollView(showsIndicators: false) { resultsView }
                case .idle: entryView
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            if recognizer.isListening && listenMode == .command {
                Label("Escuchando tu respuesta…", systemImage: "ear.fill")
                    .font(.headline)
                    .foregroundStyle(Color.wheelpGreen)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            location.requestPermission()
            speech.isEnabled = true
            speech.rate = Float(appState.voiceRate)
            speech.configureSession()
            await model.loadSavedPlaces()
            var welcome = voiceEnabled
                ? "Versión para discapacidad visual. Pulsa el botón grande del centro y di a dónde quieres ir."
                : "Versión para discapacidad visual. Escribe a dónde quieres ir."
            if voiceEnabled, !model.favorites.isEmpty {
                welcome += " También puedes decir el nombre de un favorito, como \(model.favorites[0].displayTitle)."
            }
            speech.announce(welcome)
        }
        .onChange(of: appState.voiceControlEnabled) { _, enabled in
            if !enabled { recognizer.stop() }
        }
        .onChange(of: appState.voiceRate) { _, newRate in
            speech.rate = Float(newRate)
        }
        .onChange(of: recognizer.status) { _, status in
            handleRecognizerStatus(status)
        }
        .onChange(of: recognizer.transcript) { _, text in
            handleCommandTranscript(text)
        }
        .onChange(of: model.results) { _, results in
            if !results.isEmpty {
                announceResults(results) { listenForCommandIfEnabled() }
            }
        }
        .onChange(of: model.isLoadingAccessibility) { _, loading in
            // Cuando termina de cargar la accesibilidad real, la leemos y escuchamos.
            if !loading, model.previewItem != nil, model.route == nil {
                announcePreview { listenForCommandIfEnabled() }
            }
        }
        .onChange(of: model.route) { _, route in
            if route != nil {
                recognizer.stop()
                announceRoute { listenForCommandIfEnabled() }
            }
        }
        .onChange(of: location.lastLocation) { _, newLocation in
            if let newLocation {
                model.updateProgress(newLocation)
                model.checkObstacles(at: newLocation, for: profile.type)
            }
        }
        // Aviso hablado de obstáculo cercano (semáforo, escaleras…).
        .onChange(of: model.obstacleWarning) { _, warning in
            if let warning { speech.announce("Atención: \(warning).") }
        }
        .onChange(of: model.currentStepIndex) { _, _ in
            // En navegación el micrófono queda apagado: solo se anuncia el paso.
            if model.isNavigating {
                recognizer.stop()
                announceCurrentStep()
            }
        }
        .onChange(of: model.isNavigating) { _, navigating in
            if navigating {
                recognizer.stop()
                announceCurrentStep()
            }
        }
        .onChange(of: model.activeHelpRequest) { old, new in
            // Avisa en voz alta cuando un ayudante acepta la petición.
            if let new, new.status == .accepted, old?.status != .accepted {
                speech.announce("\(new.helperName ?? "Un ayudante") ha aceptado tu petición de ayuda.")
            }
        }
        .sheet(item: $chatRequest) { request in
            HelpChatView(request: request)
        }
        .sheet(isPresented: $showHelpSetup) {
            // Página de punto de encuentro para quien usa la app sin voz.
            if let item = model.destination ?? model.previewItem {
                HelpRequestSetupView(
                    profile: profile,
                    destinationName: item.name ?? "Destino",
                    originCoordinate: location.lastLocation?.coordinate,
                    destinationCoordinate: item.placemark.coordinate,
                    steps: model.steps
                ) { meeting, meetingName, meetingCoordinate in
                    Task {
                        await model.requestHelp(
                            disabilityType: profile.type,
                            requesterName: appState.publicName,
                            origin: location.lastLocation?.coordinate,
                            meeting: meeting,
                            meetingName: meetingName,
                            meetingCoordinate: meetingCoordinate
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showContribute) {
            ContributeAccessibilityView(
                profile: profile,
                placeName: model.previewItem?.name ?? "este lugar",
                initial: currentFeatureStatuses()
            ) { features in
                Task {
                    await model.submitContribution(features, profile: profile)
                    // Si falló el guardado, se avisa en voz alta.
                    if let notice = model.contributionNotice { speech.announce(notice) }
                }
            }
        }
    }

    // MARK: - Barra superior

    private var topBar: some View {
        HStack {
            WheelpLogo(variant: .green)
                .frame(height: 32)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title)
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 56)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Ajustes")
        }
    }

    // MARK: - Entrada de destino (voz o texto)

    @ViewBuilder
    private var entryView: some View {
        if voiceEnabled {
            voiceEntryView
        } else {
            textEntryView
        }
    }

    private var voiceEntryView: some View {
        VStack(spacing: 28) {
            Text(recognizer.isListening ? "Escuchando…" : "¿A dónde quieres ir?")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Button {
                toggleDestinationListening()
            } label: {
                ZStack {
                    Circle()
                        .fill(recognizer.isListening ? Color.red : Color.wheelpGreen)
                        .frame(width: 220, height: 220)
                        .shadow(radius: 10)
                    Image(systemName: recognizer.isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 90, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor, isActive: recognizer.isListening)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recognizer.isListening ? "Tocar para terminar de hablar" : "Tocar para hablar")

            Text(recognizer.isListening ? "Toca de nuevo cuando termines" : "Pulsa para hablar")
                .font(.title3)
                .foregroundStyle(.secondary)

            if !recognizer.transcript.isEmpty {
                Text("“\(recognizer.transcript)”")
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }

            if recognizer.status == .denied {
                Text("Necesito permiso de micrófono. Actívalo en Ajustes del iPhone.")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var textEntryView: some View {
        VStack(spacing: 24) {
            Text("¿A dónde quieres ir?")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            TextField("Escribe tu destino", text: $model.query)
                .font(.title2)
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { runTextSearch() }

            Button("Buscar") { runTextSearch() }
                .buttonStyle(.wheelpPrimary)
                .frame(minHeight: 64)
                .disabled(model.query.trimmingCharacters(in: .whitespaces).count < 3)
        }
    }

    // MARK: - Resultados

    private var resultsView: some View {
        VStack(spacing: 18) {
            Text("Elige tu destino")
                .font(.largeTitle.bold())
            Text(voiceEnabled ? "Di el número o tócalo" : "Toca tu opción")
                .font(.title3)
                .foregroundStyle(.secondary)

            ForEach(Array(model.results.prefix(5).enumerated()), id: \.offset) { index, item in
                Button {
                    selectResult(index)
                } label: {
                    HStack(spacing: 16) {
                        Text("\(index + 1)")
                            .font(.title.bold())
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color.wheelpGreen))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? "Lugar")
                                .font(.title2.bold())
                                .foregroundStyle(.primary)
                            if let subtitle = item.placemark.title {
                                Text(subtitle)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Opción \(index + 1): \(item.name ?? "Lugar")")
            }

            Button("Cambiar destino") {
                changeDestination()
            }
            .buttonStyle(.wheelpOutline)
            .frame(minHeight: 60)
        }
    }

    // MARK: - Confirmar destino

    private var confirmView: some View {
        VStack(spacing: 22) {
            Text(model.previewItem?.name ?? "Destino")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            if model.isLoadingAccessibility {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Consultando accesibilidad…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else if let access = model.previewAccessibility {
                Text(access.hasAnyKnownFeature ? "\(access.score)% accesible" : "Sin datos")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(access.hasAnyKnownFeature ? access.scoreColor : Color.secondary, in: Capsule())

                VStack(spacing: 12) {
                    ForEach(access.features) { feature in
                        HStack(spacing: 14) {
                            Image(systemName: feature.status.icon)
                                .foregroundStyle(feature.status.color)
                                .accessibilityHidden(true)
                            Text(feature.title)
                                .font(.title3)
                            Spacer()
                            Text(feature.status.label)
                                .font(.headline)
                                .foregroundStyle(feature.status.color)
                        }
                        // VoiceOver lee cada criterio como una sola frase.
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 8)

                Text(access.sourceNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showContribute = true
                } label: {
                    Label("Aportar accesibilidad", systemImage: "plus.bubble")
                        .font(.headline)
                }
                .tint(Color.wheelpGreen)
            }

            helpStatusView

            if voiceEnabled {
                Text("Di “ir”, “guardar”, “ayuda” o “cambiar”")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button {
                startRoute()
            } label: {
                if model.isCalculating {
                    ProgressView().tint(.white)
                } else {
                    Label("Ir", systemImage: "figure.walk")
                }
            }
            .buttonStyle(.wheelpPrimary)
            .frame(minHeight: 70)
            .disabled(model.isCalculating)

            HStack(spacing: 12) {
                Button {
                    saveFavorite()
                } label: {
                    Label(
                        model.previewFavorite != nil ? "Quitar favorito" : "Guardar favorito",
                        systemImage: model.previewFavorite != nil ? "star.fill" : "star"
                    )
                }
                .buttonStyle(.wheelpOutline)
                .frame(maxWidth: .infinity, minHeight: 60)

                Button("Otro destino") {
                    changeDestination()
                }
                .buttonStyle(.wheelpOutline)
                .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }

    // MARK: - Ruta en marcha (micrófono apagado por defecto)

    @ViewBuilder
    private var routingView: some View {
        if model.isNavigating {
            navigatingView
        } else {
            routeSummaryView
        }
    }

    /// Resumen de la ruta recién calculada, antes de empezar a navegar.
    private var routeSummaryView: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.wheelpGreen)
                .accessibilityHidden(true)

            Text("Ruta a\n\(model.destination?.name ?? "tu destino")")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            if let route = model.route {
                Text("\(formattedDistance(route.distance)) · \(formattedTime(route.expectedTravelTime))")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            Button {
                withAnimation { model.startNavigation() }
            } label: {
                Label("Iniciar navegación", systemImage: "location.north.line.fill")
            }
            .buttonStyle(.wheelpPrimary)
            .frame(minHeight: 70)
            .disabled(model.steps.isEmpty)

            if voiceEnabled { voiceCommandButton }

            Button("Finalizar") { finishRoute() }
                .buttonStyle(.wheelpOutline)
                .frame(minHeight: 60)
        }
    }

    /// Navegación paso a paso.
    private var navigatingView: some View {
        VStack(spacing: 20) {
            Text(model.stepProgressText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.wheelpGreen)

            Text(model.currentStep?.instructions ?? "Sigue la ruta")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            if let distance = model.distanceToNextManeuver(from: location.lastLocation) {
                Text("en \(formattedDistance(distance))")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            if let warning = model.obstacleWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if model.isLastStep {
                Label("Estás llegando a tu destino", systemImage: "flag.checkered")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Label("La navegación avanza sola con tu posición", systemImage: "location.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

            helpStatusView

            if voiceEnabled { navigationMicButton }

            Button("Finalizar") { finishRoute() }
                .buttonStyle(.wheelpOutline)
                .frame(maxWidth: .infinity, minHeight: 64)
        }
    }

    /// Estado de la petición de ayuda (o botón para pedirla).
    @ViewBuilder
    private var helpStatusView: some View {
        if let request = model.activeHelpRequest {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if request.status == .pending {
                        ProgressView()
                        Text("Buscando ayudante…")
                            .font(.title3)
                    } else {
                        Image(systemName: "figure.2")
                            .foregroundStyle(Color.wheelpGreen)
                            .accessibilityHidden(true)
                        Text("Te ayudará \(request.helperName ?? "un ayudante")")
                            .font(.title3.weight(.semibold))
                    }
                }
                .accessibilityElement(children: .combine)

                if request.status == .accepted {
                    Button {
                        chatRequest = request
                    } label: {
                        Label("Abrir chat", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .buttonStyle(.wheelpOutline)
                    .frame(minHeight: 56)
                }
            }
        } else {
            Button {
                requestHelp()
            } label: {
                Label("Pedir ayudante", systemImage: "hand.raised")
            }
            .buttonStyle(.wheelpOutline)
            .frame(minHeight: 60)
        }
    }

    /// Botón grande central (como el de inicio) para hablar durante la navegación:
    /// preguntar cuánto falta, cambiar de destino o finalizar.
    private var navigationMicButton: some View {
        VStack(spacing: 10) {
            Button {
                if recognizer.isListening { recognizer.stop() } else { beginListening(.command) }
            } label: {
                ZStack {
                    Circle()
                        .fill(recognizer.isListening ? Color.red : Color.wheelpGreen)
                        .frame(width: 130, height: 130)
                        .shadow(radius: 8)
                    Image(systemName: recognizer.isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor, isActive: recognizer.isListening)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recognizer.isListening ? "Escuchando. Toca para parar" : "Tocar para hablar")

            Text(recognizer.isListening
                 ? "Di “cuánto falta”, “ayuda”, “cambiar” o “finalizar”"
                 : "Pulsa para preguntar o dar una orden")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Botón para activar el micrófono en el resumen de ruta.
    @ViewBuilder
    private var voiceCommandButton: some View {
        VStack(spacing: 6) {
            Button {
                if recognizer.isListening { recognizer.stop() } else { beginListening(.command) }
            } label: {
                Label(
                    recognizer.isListening ? "Escuchando…" : "Hablar",
                    systemImage: recognizer.isListening ? "waveform" : "mic.fill"
                )
            }
            .buttonStyle(recognizer.isListening ? .wheelpPrimary : .wheelpOutline)
            .frame(minHeight: 60)

            if recognizer.isListening {
                Text("Di “iniciar” o “finalizar”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Acciones (voz + toque comparten estas funciones)

    private func selectResult(_ index: Int) {
        commandMatched = true
        recognizer.stop()
        let items = Array(model.results.prefix(5))
        guard index < items.count else { return }
        withAnimation { model.preview(items[index], profile: profile) }
    }

    private func startRoute() {
        commandMatched = true
        recognizer.stop()
        Task {
            await model.startRoute(
                from: location.lastLocation?.coordinate,
                transport: profile.transportType
            )
        }
    }

    private func changeDestination() {
        commandMatched = true
        awaitingMeetingPoint = false
        recognizer.stop()
        withAnimation { model.reset() }
        if voiceEnabled {
            speech.announce("Dime el nuevo destino.") { beginListening(.destination) }
        } else {
            speech.announce("Escribe el nuevo destino.")
        }
    }

    private func finishRoute() {
        commandMatched = true
        awaitingMeetingPoint = false
        recognizer.stop()
        withAnimation { model.reset() }
        speech.announce("Ruta finalizada.")
    }

    private func runTextSearch() {
        let text = model.query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else { return }
        model.search(near: location.lastLocation?.coordinate)
    }

    // MARK: - Reconocimiento de voz

    private func listenForCommandIfEnabled() {
        if voiceEnabled { beginListening(.command) }
    }

    private func toggleDestinationListening() {
        if recognizer.isListening {
            recognizer.stop()
        } else {
            beginListening(.destination)
        }
    }

    private func beginListening(_ mode: ListenMode) {
        guard voiceEnabled else { return }
        listenMode = mode
        commandMatched = false
        Task {
            let granted = await recognizer.requestAuthorization()
            guard granted else {
                speech.announce("Necesito permiso para usar el micrófono. Actívalo en los Ajustes del iPhone.")
                return
            }
            if mode == .destination { awaitingSearch = true }
            do {
                try recognizer.start()
            } catch {
                awaitingSearch = false
                speech.announce("No he podido iniciar el micrófono. Inténtalo de nuevo.")
            }
        }
    }

    /// Procesa la transcripción en vivo cuando esperamos un comando.
    private func handleCommandTranscript(_ text: String) {
        guard listenMode == .command, !text.isEmpty, !commandMatched else { return }
        if awaitingMeetingPoint {
            handleMeetingTranscript(text)
            return
        }
        guard let command = parseCommand(text) else { return }
        commandMatched = true
        recognizer.stop()
        execute(command)
    }

    private func handleRecognizerStatus(_ status: SpeechRecognizer.Status) {
        guard status == .idle else { return }

        if listenMode == .destination, awaitingSearch {
            awaitingSearch = false
            let text = recognizer.transcript.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                speech.announce("No te he entendido. Toca el botón e inténtalo otra vez.")
            } else if let favorite = SavedPlacesService.match(text, in: model.favorites) {
                // Favorito reconocido ("casa", "trabajo"…): directo a la ficha.
                speech.announce("Vale, \(favorite.displayTitle).")
                withAnimation { model.preview(favorite.mapItem, profile: profile) }
            } else {
                model.query = text
                model.search(near: location.lastLocation?.coordinate)
                speech.announce("Buscando \(text).")
            }
            return
        }

        // En modo comando seguimos escuchando mientras haya opciones, confirmación
        // o el resumen de ruta en pantalla. Durante la navegación NO: el micrófono
        // queda apagado y se activa solo con el botón.
        // Mientras se espera el punto de encuentro, la escucha también se
        // reintenta aunque estemos navegando.
        let autoListenPhase = awaitingMeetingPoint || phase == .results || phase == .confirm
            || (phase == .routing && !model.isNavigating)
        if listenMode == .command, voiceEnabled, !commandMatched, autoListenPhase {
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if listenMode == .command, !recognizer.isListening, !commandMatched,
                   !speech.isSpeaking, autoListenPhase {
                    beginListening(.command)
                }
            }
        }
    }

    // MARK: - Comandos de voz

    enum VoiceCommand { case select(Int), go, change, finish, startNav, next, info, save, help }

    private func parseCommand(_ raw: String) -> VoiceCommand? {
        let normalized = raw.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let words = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ options: Set<String>) -> Bool { !words.isDisjoint(with: options) }

        switch phase {
        case .results:
            if has(["uno", "una", "primero", "primera", "1"]) { return .select(0) }
            if has(["dos", "segundo", "segunda", "2"]) { return .select(1) }
            if has(["tres", "tercero", "tercera", "3"]) { return .select(2) }
            if has(["cuatro", "cuarto", "cuarta", "4"]) { return .select(3) }
            if has(["cinco", "quinto", "quinta", "5"]) { return .select(4) }
            if has(["otro", "otra", "cambiar", "cambia", "repetir", "buscar"]) { return .change }
        case .confirm:
            if has(["ayuda", "ayudante", "asistencia", "ayudarme"]) { return .help }
            if has(["guardar", "guarda", "favorito", "favoritos"]) { return .save }
            if has(["ir", "si", "vale", "vamos", "empezar", "empieza", "confirmar", "adelante", "claro"]) { return .go }
            if has(["otro", "otra", "cambiar", "cambia", "no", "atras", "volver", "buscar"]) { return .change }
        case .routing:
            if has(["ayuda", "ayudante", "asistencia", "ayudarme"]) { return .help }
            // Preguntas de información ("¿cuánto falta para llegar?") primero,
            // para que "llegar/queda" no se confundan con otros comandos.
            if has(["cuanto", "cuanta", "falta", "queda", "quedan", "lejos", "distancia", "tiempo", "llegar", "llego", "llegamos"]) { return .info }
            if has(["finalizar", "terminar", "parar", "cancelar", "fin", "listo", "llegado"]) { return .finish }
            if has(["cambiar", "cambia", "otro", "otra", "destino"]) { return .change }
            if model.isNavigating {
                if has(["siguiente", "continuar", "continua", "avanza", "avanzar"]) { return .next }
            } else {
                if has(["iniciar", "empezar", "empieza", "comenzar", "vamos", "navegar"]) { return .startNav }
            }
        case .idle:
            break
        }
        return nil
    }

    private func execute(_ command: VoiceCommand) {
        switch command {
        case .select(let index): selectResult(index)
        case .go: startRoute()
        case .change: changeDestination()
        case .finish: finishRoute()
        case .startNav: withAnimation { model.startNavigation() }
        case .next: withAnimation { model.advanceStep() }
        case .info: announceRemaining()
        case .save: saveFavorite()
        case .help: requestHelp()
        }
    }

    /// Pide un ayudante (comando "ayuda" o botón). Primero se pregunta dónde
    /// quiere encontrarse el usuario; con la voz apagada se abre la página.
    private func requestHelp() {
        guard model.activeHelpRequest == nil else {
            speech.announce("Ya hay una petición de ayuda en marcha.")
            return
        }
        if voiceEnabled {
            awaitingMeetingPoint = true
            recognizer.stop()
            speech.announce("¿Dónde quieres encontrarte con el ayudante? Di inicio, para donde estás ahora, o destino. También puedes decir cancelar.") {
                listenForCommandIfEnabled()
            }
        } else {
            showHelpSetup = true
        }
    }

    /// Interpreta la respuesta al punto de encuentro ("inicio" / "destino").
    private func handleMeetingTranscript(_ raw: String) {
        let normalized = raw.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let words = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ options: Set<String>) -> Bool { !words.isDisjoint(with: options) }

        if has(["cancelar", "no", "nada", "dejalo"]) {
            awaitingMeetingPoint = false
            commandMatched = true
            recognizer.stop()
            speech.announce("Vale, no pido ayudante.") {
                if !model.isNavigating { listenForCommandIfEnabled() }
            }
        } else if has(["inicio", "salida", "partida", "aqui", "actual", "estoy", "empiezo"]) {
            chooseMeeting(.origin)
        } else if has(["destino", "final", "llegada", "llegar"]) {
            chooseMeeting(.destination)
        }
    }

    private func chooseMeeting(_ meeting: HelpRequest.MeetingPoint) {
        awaitingMeetingPoint = false
        commandMatched = true
        recognizer.stop()
        Task { await performHelpRequest(meeting) }
    }

    /// Envía la petición con el trayecto completo y el punto de encuentro.
    private func performHelpRequest(_ meeting: HelpRequest.MeetingPoint) async {
        guard let item = model.destination ?? model.previewItem else { return }
        let origin = location.lastLocation?.coordinate
        let destinationCoordinate = item.placemark.coordinate
        let meetingCoordinate = meeting == .origin ? (origin ?? destinationCoordinate) : destinationCoordinate
        let meetingName = meeting == .origin ? "Punto de partida del usuario" : (item.name ?? "Destino")
        await model.requestHelp(
            disabilityType: profile.type,
            requesterName: appState.publicName,
            origin: origin,
            meeting: meeting,
            meetingName: meetingName,
            meetingCoordinate: meetingCoordinate
        )
        if model.activeHelpRequest != nil {
            speech.announce("Petición de ayuda enviada. Te avisaré cuando alguien la acepte.") {
                if !model.isNavigating { listenForCommandIfEnabled() }
            }
        } else {
            speech.announce("No se pudo enviar la petición de ayuda. Inténtalo de nuevo.")
        }
    }

    /// Guarda el destino en ficha como favorito (comando "guardar").
    private func saveFavorite() {
        Task {
            let alreadySaved = model.previewFavorite != nil
            await model.toggleFavorite(alias: nil)
            speech.announce(alreadySaved ? "Quitado de favoritos." : "Guardado en favoritos.") {
                listenForCommandIfEnabled()
            }
        }
    }

    // MARK: - Anuncios por voz

    private func announceResults(_ results: [MKMapItem], then: @escaping () -> Void) {
        let top = results.prefix(5)
        var text = "He encontrado \(top.count) "
        text += top.count == 1 ? "resultado. " : "resultados. "
        for (index, item) in top.enumerated() {
            text += "\(index + 1): \(item.name ?? "lugar"). "
        }
        text += voiceEnabled ? "Di el número o tócalo." : "Toca tu opción."
        speech.announce(text, then: then)
    }

    private func announcePreview(then: @escaping () -> Void) {
        guard let item = model.previewItem, let access = model.previewAccessibility else {
            then()
            return
        }
        var text = "\(item.name ?? "Destino"). "
        if access.hasAnyKnownFeature {
            text += "Accesibilidad \(access.score) por ciento. "
            let available = access.features.filter { $0.status == .available }.map(\.title)
            if !available.isEmpty {
                text += "Dispone de: " + available.joined(separator: ", ") + ". "
            }
        } else {
            text += "Todavía no hay datos de accesibilidad para esta versión. "
        }
        text += voiceEnabled
            ? "Di ir para empezar, guardar para añadirlo a favoritos, o cambiar."
            : "Toca Ir para empezar."
        speech.announce(text, then: then)
    }

    /// Estado actual por criterio, para precargar la hoja de aportación.
    private func currentFeatureStatuses() -> [String: DestinationAccessibility.Feature.Status] {
        var statuses: [String: DestinationAccessibility.Feature.Status] = [:]
        for feature in model.previewAccessibility?.features ?? [] {
            statuses[feature.title] = feature.status
        }
        return statuses
    }

    private func announceRoute(then: @escaping () -> Void) {
        guard let route = model.route else {
            then()
            return
        }
        var text = "Ruta calculada. \(formattedDistance(route.distance)), "
        text += "\(formattedTime(route.expectedTravelTime)) a pie. "
        if let first = route.steps.first(where: { !$0.instructions.isEmpty }) {
            text += "Comienza: \(first.instructions). "
        }
        text += voiceEnabled ? "Di iniciar para empezar la navegación." : "Toca Iniciar navegación."
        speech.announce(text, then: then)
    }

    /// Lee la indicación del paso actual durante la navegación.
    private func announceCurrentStep() {
        guard let step = model.currentStep else { return }
        var text = step.instructions
        if model.isLastStep { text += ". Estás llegando a tu destino." }
        speech.announce(text)
    }

    /// Responde cuánto falta para llegar (comando de voz durante la navegación).
    private func announceRemaining() {
        guard let remaining = model.remainingDistance(from: location.lastLocation) else {
            speech.announce("Ahora mismo no puedo calcular lo que falta. Sigue la ruta.")
            return
        }
        var text = "Quedan \(formattedDistance(remaining))"
        if let time = model.remainingTime(from: location.lastLocation) {
            text += ", unos \(formattedTime(time)) caminando"
        }
        text += ", para llegar a \(model.destination?.name ?? "tu destino")."
        speech.announce(text)
    }

    // MARK: - Formato

    private func formattedDistance(_ meters: CLLocationDistance) -> String {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        return formatter.string(fromDistance: meters)
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
