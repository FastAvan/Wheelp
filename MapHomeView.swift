import SwiftUI
import MapKit

/// Modelo de la pantalla principal: búsqueda → ficha del destino → ruta.
@MainActor
@Observable
final class MapHomeModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = ""
    var results: [MKMapItem] = []
    /// Sugerencias de autocompletado mientras se escribe (hasta 5).
    var completions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    /// Destino seleccionado pendiente de confirmar (fase "ficha").
    var previewItem: MKMapItem?
    var previewAccessibility: DestinationAccessibility?

    /// Destino y ruta una vez el usuario pulsa "Ir".
    var destination: MKMapItem?
    var route: MKRoute?

    var isCalculating = false
    var isLoadingAccessibility = false
    var errorMessage: String?
    /// Aviso si la última aportación de accesibilidad no se pudo guardar.
    var contributionNotice: String?

    // MARK: Navegación paso a paso
    var isNavigating = false
    var currentStepIndex = 0
    /// Pasos con indicación (se fijan al calcular la ruta).
    private(set) var steps: [MKRoute.Step] = []

    // MARK: Obstáculos del camino (OpenStreetMap)
    /// Obstáculos a lo largo de la ruta actual (todos; se filtran por versión).
    private(set) var routeObstacles: [RouteObstacle] = []
    /// Aviso vigente de obstáculo cercano (se borra solo pasados unos segundos).
    var obstacleWarning: String?
    private var warnedObstacleIds: Set<Int> = []
    private var obstacleClearTask: Task<Void, Never>?

    /// Avisa una sola vez de cada obstáculo relevante al acercarse (<45 m).
    func checkObstacles(at location: CLLocation, for type: DisabilityType) {
        guard isNavigating else { return }
        let accuracy = location.horizontalAccuracy
        guard accuracy > 0, accuracy <= 65 else { return }
        for obstacle in routeObstacles
        where obstacle.matters(for: type) && !warnedObstacleIds.contains(obstacle.id) {
            let target = CLLocation(latitude: obstacle.coordinate.latitude, longitude: obstacle.coordinate.longitude)
            let meters = location.distance(from: target)
            if meters < 45 {
                warnedObstacleIds.insert(obstacle.id)
                obstacleWarning = "\(obstacle.title) a \(Int(meters.rounded())) metros"
                obstacleClearTask?.cancel()
                obstacleClearTask = Task {
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { obstacleWarning = nil }
                }
                return
            }
        }
    }

    var currentStep: MKRoute.Step? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }
    var isLastStep: Bool { currentStepIndex >= steps.count - 1 }
    var stepProgressText: String {
        guard !steps.isEmpty else { return "" }
        return "Paso \(currentStepIndex + 1) de \(steps.count)"
    }

    // MARK: Favoritos e historial
    var favorites: [SavedPlace] = []
    var recents: [SavedPlace] = []

    /// ¿El destino en ficha ya es favorito?
    var previewFavorite: SavedPlace? {
        guard let item = previewItem else { return nil }
        let coordinate = item.placemark.coordinate
        return favorites.first {
            abs($0.latitude - coordinate.latitude) < 0.0005
                && abs($0.longitude - coordinate.longitude) < 0.0005
        }
    }

    // MARK: Ayudantes (versión de prueba)
    /// Petición de ayuda activa del usuario (pendiente o aceptada).
    var activeHelpRequest: HelpRequest?
    private var helpPollTask: Task<Void, Never>?

    /// Pide un ayudante para el trayecto actual (ficha o ruta en curso),
    /// con el punto de encuentro elegido por el usuario.
    func requestHelp(
        disabilityType: DisabilityType,
        requesterName: String?,
        origin: CLLocationCoordinate2D?,
        meeting: HelpRequest.MeetingPoint,
        meetingName: String?,
        meetingCoordinate: CLLocationCoordinate2D
    ) async {
        guard activeHelpRequest == nil else { return }
        guard let item = destination ?? previewItem else { return }
        await NotificationService.requestPermission()
        if let request = await HelperService.create(
            placeName: item.name ?? "Destino",
            coordinate: item.placemark.coordinate,
            disabilityType: disabilityType,
            requesterName: requesterName,
            origin: origin,
            meeting: meeting,
            meetingName: meetingName,
            meetingCoordinate: meetingCoordinate
        ) {
            activeHelpRequest = request
            startHelpPolling()
        }
    }

    /// Sondea el estado de la petición cada 8 s hasta que termine.
    private func startHelpPolling() {
        helpPollTask?.cancel()
        helpPollTask = Task {
            while !Task.isCancelled, let current = activeHelpRequest {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let updated = await HelperService.fetch(id: current.id) else { continue }
                // Notificación local en el momento en que alguien acepta.
                if current.status == .pending, updated.status == .accepted {
                    NotificationService.notify(
                        title: "¡Tienes ayudante!",
                        body: "\(updated.helperName ?? "Un ayudante") ha aceptado tu petición en \(updated.placeName)."
                    )
                }
                activeHelpRequest = updated
                if updated.status == .completed || updated.status == .cancelled {
                    activeHelpRequest = nil
                    break
                }
            }
        }
    }

    func cancelHelp() {
        guard let request = activeHelpRequest else { return }
        helpPollTask?.cancel()
        activeHelpRequest = nil
        Task { await HelperService.updateStatus(request.id, to: .cancelled) }
    }

    /// Lugar que se debe mostrar con marcador en el mapa.
    var focusedItem: MKMapItem? { destination ?? previewItem }

    private var searchTask: Task<Void, Never>?

    /// Carga favoritos y recientes del usuario.
    func loadSavedPlaces() async {
        async let favs = SavedPlacesService.fetchFavorites()
        async let recs = SavedPlacesService.fetchRecents()
        favorites = await favs
        recents = await recs
    }

    /// Añade o quita el destino en ficha de favoritos.
    func toggleFavorite(alias: String?) async {
        guard let item = previewItem else { return }
        if let existing = previewFavorite {
            await SavedPlacesService.removeFavorite(existing)
        } else {
            await SavedPlacesService.addFavorite(item: item, alias: alias)
        }
        favorites = await SavedPlacesService.fetchFavorites()
    }

    /// Sugerencias de autocompletado mientras se escribe (buscador del mapa).
    /// Usa MKLocalSearchCompleter, que ofrece muchas más opciones que una
    /// búsqueda directa con texto parcial.
    func suggest(near center: CLLocationCoordinate2D?) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            completions = []
            completer.queryFragment = ""
            return
        }
        if let center {
            completer.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: 30000,
                longitudinalMeters: 30000
            )
        }
        completer.queryFragment = text
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let top = Array(completer.results.prefix(5))
        Task { @MainActor in
            self.completions = top
        }
    }

    /// Resuelve una sugerencia a un lugar concreto y abre su ficha.
    func selectCompletion(_ completion: MKLocalSearchCompletion, profile: AccessibilityProfile) async {
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            errorMessage = "No se pudo abrir ese lugar. Prueba con otro resultado."
            return
        }
        preview(item, profile: profile)
    }

    /// Busca lugares que coincidan con el texto completo (dictado por voz).
    func search(near center: CLLocationCoordinate2D?) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else {
            results = []
            return
        }
        searchTask = Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            if let center {
                request.region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: 30000,
                    longitudinalMeters: 30000
                )
            }
            do {
                let response = try await MKLocalSearch(request: request).start()
                if !Task.isCancelled {
                    results = response.mapItems
                }
            } catch {
                // Búsqueda cancelada o sin resultados: dejamos la lista como está.
            }
        }
    }

    /// Muestra la ficha del destino y carga su accesibilidad real desde Supabase.
    func preview(_ item: MKMapItem, profile: AccessibilityProfile) {
        previewItem = item
        previewAccessibility = nil
        isLoadingAccessibility = true
        results = []
        completions = []
        completer.queryFragment = ""
        query = ""
        route = nil
        destination = nil
        errorMessage = nil
        contributionNotice = nil
        Task { await loadAccessibility(for: item, profile: profile) }
    }

    private func loadAccessibility(for item: MKMapItem, profile: AccessibilityProfile) async {
        let coordinate = item.placemark.coordinate

        // Fuente principal: Google Places. Aportaciones de comunidad en paralelo.
        async let googleResult = GooglePlacesAccessibilityService.fetch(near: coordinate, name: item.name)
        let key = AccessibilityService.placeKey(for: item)
        let reports = (try? await AccessibilityService.fetchReports(
            placeKey: key,
            disabilityType: profile.type
        )) ?? []

        let google = await googleResult
        var base = google.statuses
        var sourceName: String? = google.found ? "Google Places" : nil

        // Respaldo gratuito: si Google no aporta datos, probamos OpenStreetMap.
        if base.isEmpty {
            let osmTags = await OSMAccessibilityService.fetchTags(near: coordinate, name: item.name)
            let osmStatuses = DestinationAccessibility.osmStatuses(for: profile, tags: osmTags)
            if !osmStatuses.isEmpty {
                base = osmStatuses
                sourceName = "OpenStreetMap"
            }
        }

        let accessibility = DestinationAccessibility.combined(
            base: base,
            sourceName: sourceName,
            reports: reports,
            profile: profile
        )

        // Solo aplica si seguimos en la ficha del mismo lugar.
        guard previewItem === item else { return }
        previewAccessibility = accessibility
        isLoadingAccessibility = false
    }

    /// Guarda la aportación del usuario y recarga la accesibilidad del lugar.
    func submitContribution(
        _ features: [String: DestinationAccessibility.Feature.Status],
        profile: AccessibilityProfile
    ) async {
        guard let item = previewItem else { return }
        contributionNotice = nil
        do {
            try await AccessibilityService.submit(item: item, disabilityType: profile.type, features: features)
            isLoadingAccessibility = true
            await loadAccessibility(for: item, profile: profile)
        } catch {
            // Antes el fallo era silencioso y parecía que la aportación no hacía nada.
            print("Wheelp: error al guardar la aportación de accesibilidad: \(error)")
            contributionNotice = "No se pudo guardar tu aportación. Comprueba la conexión e inténtalo de nuevo."
        }
    }

    /// Calcula la ruta hacia el destino en ficha al pulsar "Ir".
    func startRoute(from source: CLLocationCoordinate2D?, transport: MKDirectionsTransportType) async {
        guard let item = previewItem else { return }
        guard let source else {
            errorMessage = "No podemos obtener tu ubicación. Activa los permisos para calcular la ruta."
            return
        }

        isCalculating = true
        errorMessage = nil
        defer { isCalculating = false }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = item
        request.transportType = transport

        do {
            let response = try await MKDirections(request: request).calculate()
            if let first = response.routes.first {
                destination = item
                route = first
                steps = first.steps.filter { !$0.instructions.isEmpty }
                currentStepIndex = 0
                isNavigating = false
                previewItem = nil
                // Obstáculos del camino en segundo plano (no bloquea la ruta).
                routeObstacles = []
                warnedObstacleIds = []
                obstacleWarning = nil
                Task { routeObstacles = await RouteObstaclesService.fetch(along: first) }
                // Guarda la visita en el historial (no bloquea la navegación).
                Task {
                    await SavedPlacesService.recordVisit(item: item)
                    recents = await SavedPlacesService.fetchRecents()
                }
            } else {
                errorMessage = "No encontramos una ruta hasta ese destino."
            }
        } catch {
            errorMessage = "No se pudo calcular la ruta. Inténtalo de nuevo."
        }
    }

    /// Vuelve a la búsqueda limpia.
    func reset() {
        // Una petición aún sin aceptar no tiene sentido sin destino: se cancela.
        if activeHelpRequest?.status == .pending { cancelHelp() }
        route = nil
        destination = nil
        previewItem = nil
        previewAccessibility = nil
        contributionNotice = nil
        query = ""
        results = []
        completions = []
        completer.queryFragment = ""
        errorMessage = nil
        isNavigating = false
        currentStepIndex = 0
        steps = []
        routeObstacles = []
        warnedObstacleIds = []
        obstacleWarning = nil
        obstacleClearTask?.cancel()
    }

    // MARK: - Navegación paso a paso

    func startNavigation() {
        guard route != nil, !steps.isEmpty else { return }
        currentStepIndex = 0
        isNavigating = true
    }

    func stopNavigation() {
        isNavigating = false
    }

    /// Avanza manualmente al siguiente paso.
    func advanceStep() {
        if currentStepIndex < steps.count - 1 { currentStepIndex += 1 }
    }

    /// Avanza automáticamente según la posición del usuario.
    ///
    /// Mejoras sobre un umbral fijo:
    /// - Descarta lecturas GPS malas (imprecisas o antiguas).
    /// - Umbral adaptativo: crece con la imprecisión del GPS (20–50 m).
    /// - Detecta pasos saltados: si el usuario está ya en un tramo posterior de la
    ///   ruta, salta directamente a ese paso en lugar de quedarse atascado.
    func updateProgress(_ location: CLLocation) {
        guard isNavigating, !isLastStep else { return }

        // 1. Filtrar lecturas poco fiables: sin precisión válida, muy imprecisas
        //    (>65 m no sirve para decidir maniobras) o antiguas (>15 s).
        let accuracy = location.horizontalAccuracy
        guard accuracy > 0, accuracy <= 65,
              location.timestamp.timeIntervalSinceNow > -15 else { return }

        // 2. Umbral de llegada adaptativo a la calidad de la señal.
        let arrivalThreshold = min(max(20, accuracy * 1.5), 50)

        // 3. ¿Hemos llegado al final de algún paso pendiente? Miramos el paso
        //    actual y unos pocos por delante (por si el GPS "revive" más adelante
        //    o el usuario cruzó en diagonal y se saltó una maniobra).
        let lookahead = min(currentStepIndex + 3, steps.count - 1)
        for index in (currentStepIndex...lookahead).reversed() {
            if let end = Self.lastCoordinate(of: steps[index].polyline),
               location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) < arrivalThreshold {
                // Fin del paso `index` alcanzado → la indicación vigente es la siguiente.
                currentStepIndex = min(index + 1, steps.count - 1)
                return
            }
        }

        // 4. Si no estamos al final de ningún paso, comprobar si el usuario está
        //    claramente "dentro" de un tramo posterior (paso saltado a mitad).
        for index in ((currentStepIndex + 1)...lookahead).reversed() where index > currentStepIndex {
            if Self.distance(from: location, toPolyline: steps[index].polyline) < arrivalThreshold {
                currentStepIndex = index
                return
            }
        }
    }

    /// Distancia hasta la próxima maniobra (fin del paso actual).
    func distanceToNextManeuver(from location: CLLocation?) -> CLLocationDistance? {
        guard let location, let step = currentStep,
              let end = Self.lastCoordinate(of: step.polyline) else { return nil }
        return location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    /// Distancia restante hasta el destino (próxima maniobra + tramos pendientes).
    func remainingDistance(from location: CLLocation?) -> CLLocationDistance? {
        guard let toNext = distanceToNextManeuver(from: location) else { return nil }
        let pending = steps.dropFirst(currentStepIndex + 1).reduce(0) { $0 + $1.distance }
        return toNext + pending
    }

    /// Tiempo restante estimado, proporcional al avance sobre la ruta original.
    func remainingTime(from location: CLLocation?) -> TimeInterval? {
        guard let route, route.distance > 0,
              let remaining = remainingDistance(from: location) else { return nil }
        return route.expectedTravelTime * min(remaining / route.distance, 1)
    }

    private static func lastCoordinate(of polyline: MKPolyline) -> CLLocationCoordinate2D? {
        guard polyline.pointCount > 0 else { return nil }
        return polyline.points()[polyline.pointCount - 1].coordinate
    }

    /// Distancia mínima desde una ubicación a los vértices de una polilínea.
    /// (Aproximación por vértices: suficiente para pasos peatonales, que son cortos.)
    private static func distance(from location: CLLocation, toPolyline polyline: MKPolyline) -> CLLocationDistance {
        let points = polyline.points()
        var minDistance = CLLocationDistance.greatestFiniteMagnitude
        for i in 0..<polyline.pointCount {
            let coordinate = points[i].coordinate
            let vertex = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            minDistance = min(minDistance, location.distance(from: vertex))
        }
        return minDistance
    }
}

/// Pantalla principal compartida: mapa + buscador + ficha + ruta, adaptada por perfil.
struct MapHomeView: View {
    let profile: AccessibilityProfile
    @Environment(AppState.self) private var appState

    @State private var location = LocationManager()
    @State private var model = MapHomeModel()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var speech = SpeechAnnouncer()
    @State private var showRouteBanner = false
    @State private var showSettings = false
    @State private var showContribute = false
    @State private var showAliasPrompt = false
    @State private var aliasText = ""
    @State private var showHelperRequests = false
    @State private var showHelpSetup = false
    @State private var chatRequest: HelpRequest?
    // Visualización del trayecto de una petición (modo ayudante).
    @State private var visualizedRequest: HelpRequest?
    @State private var visualizedRoute: MKRoute?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()

            if let route = model.route {
                MapPolyline(route.polyline)
                    .stroke(Color.wheelpGreen, lineWidth: profile.routeLineWidth)
            }
            if let item = model.focusedItem {
                Marker(item.name ?? "Destino", coordinate: item.placemark.coordinate)
                    .tint(Color.wheelpGreen)
            }
            // Obstáculos del camino relevantes para esta versión.
            if model.isNavigating {
                ForEach(model.routeObstacles.filter { $0.matters(for: profile.type) }) { obstacle in
                    Marker(obstacle.title, systemImage: obstacle.icon, coordinate: obstacle.coordinate)
                        .tint(.orange)
                }
            }
            // Trayecto de la petición que el ayudante está visualizando.
            if let request = visualizedRequest {
                if let route = visualizedRoute {
                    MapPolyline(route.polyline)
                        .stroke(Color.blue, lineWidth: 6)
                }
                if let origin = request.originCoordinate {
                    Marker("Inicio de \(request.requesterName ?? "usuario")", systemImage: "figure.wave", coordinate: origin)
                        .tint(.blue)
                }
                Marker(request.placeName, coordinate: request.coordinate)
                    .tint(.blue)
                Marker("Encuentro", systemImage: "figure.2", coordinate: request.meetingCoordinate)
                    .tint(.purple)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea(edges: .bottom)
        // El teclado no debe recolocar el mapa ni sus paneles: la barra de
        // búsqueda está arriba y no lo necesita; sin esto, todo "salta".
        // Además del modificador exterior, cada panel debe ignorarlo por su
        // cuenta: el contenido de un safeAreaInset esquiva el teclado solo.
        .safeAreaInset(edge: .top) { searchPanel.ignoresSafeArea(.keyboard) }
        .safeAreaInset(edge: .bottom) { bottomCard.ignoresSafeArea(.keyboard) }
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .top) { routeReadyBanner }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHelperRequests) {
            HelperRequestsView(userLocation: location.lastLocation) { request in
                visualize(request)
            }
        }
        .sheet(isPresented: $showHelpSetup) {
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
        .sheet(item: $chatRequest) { request in
            HelpChatView(request: request)
        }
        .sheet(isPresented: $showContribute) {
            ContributeAccessibilityView(
                profile: profile,
                placeName: model.previewItem?.name ?? "este lugar",
                initial: currentFeatureStatuses()
            ) { features in
                Task { await model.submitContribution(features, profile: profile) }
            }
        }
        .task {
            location.requestPermission()
            speech.isEnabled = profile.voiceGuidance
            speech.rate = Float(appState.voiceRate)
            speech.configureSession()
            await model.loadSavedPlaces()
        }
        .alert("Guardar favorito", isPresented: $showAliasPrompt) {
            TextField("Nombre corto (casa, trabajo…)", text: $aliasText)
            Button("Guardar") {
                Task { await model.toggleFavorite(alias: aliasText.isEmpty ? nil : aliasText) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Podrás llegar más rápido y, en la versión de voz, pedirlo por su nombre.")
        }
        .onChange(of: appState.voiceRate) { _, newRate in
            speech.rate = Float(newRate)
        }
        .onChange(of: model.previewItem) { _, item in
            guard let item else { return }
            withAnimation(.easeInOut) {
                camera = .region(MKCoordinateRegion(
                    center: item.placemark.coordinate,
                    latitudinalMeters: 1200,
                    longitudinalMeters: 1200
                ))
            }
            announcePreview()
        }
        .onChange(of: model.route) { _, newRoute in
            guard let route = newRoute else { return }
            withAnimation(.easeInOut) {
                camera = .rect(route.polyline.boundingMapRect)
            }
            announceRoute()
            // Confirmación visual destacada para la versión Auditiva.
            if profile.hapticCues {
                withAnimation { showRouteBanner = true }
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { showRouteBanner = false }
                }
            }
        }
        // Vibración al obtener la ruta para la versión Auditiva.
        .sensoryFeedback(.success, trigger: model.route != nil) { _, current in
            profile.hapticCues && current
        }
        // Seguimiento de la posición para avanzar de paso automáticamente.
        .onChange(of: location.lastLocation) { _, newLocation in
            if let newLocation {
                model.updateProgress(newLocation)
                model.checkObstacles(at: newLocation, for: profile.type)
            }
        }
        // Aviso de obstáculo: vibración siempre y voz en la versión Visual.
        .sensoryFeedback(.warning, trigger: model.obstacleWarning) { _, new in
            new != nil
        }
        .onChange(of: model.obstacleWarning) { _, warning in
            if let warning, profile.voiceGuidance {
                speech.announce("Atención: \(warning).")
            }
        }
        // Vibración al cambiar de paso durante la navegación.
        .sensoryFeedback(.impact, trigger: model.currentStepIndex) { _, _ in
            profile.hapticCues && model.isNavigating
        }
        .onChange(of: model.currentStepIndex) { _, _ in
            if model.isNavigating { announceCurrentStep() }
        }
        .onChange(of: model.isNavigating) { _, navigating in
            if navigating { announceCurrentStep() }
        }
    }

    // MARK: - Banner de confirmación (versión Auditiva)

    @ViewBuilder
    private var routeReadyBanner: some View {
        if showRouteBanner {
            Label("Ruta lista", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.wheelpGreen, in: Capsule())
                .shadow(radius: 6, y: 3)
                .padding(.top, 120)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Buscador

    private var searchPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("¿A dónde quieres ir?", text: $model.query)
                        .accessibilityAddTraits(.isSearchField)
                        .font(profile.bodyFont)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onChange(of: model.query) { _, _ in
                            model.suggest(near: location.lastLocation?.coordinate)
                        }
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                            model.suggest(near: nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Borrar búsqueda")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: profile.controlMinHeight)
                .background(.regularMaterial, in: Capsule())

                if appState.isHelper {
                    Button {
                        showHelperRequests = true
                    } label: {
                        Image(systemName: "hand.raised.fill")
                            .font(.title2)
                            .foregroundStyle(Color.wheelpGreen)
                            .frame(width: profile.controlMinHeight, height: profile.controlMinHeight)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("Peticiones de ayuda cercanas")
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.title2)
                        .frame(width: profile.controlMinHeight, height: profile.controlMinHeight)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Perfil y ajustes")
            }

            if !model.completions.isEmpty {
                completionsList
            } else if searchFocused, model.previewItem == nil, model.route == nil,
                      !(model.favorites.isEmpty && model.recents.isEmpty) {
                savedPlacesList
            }

            visualizeBanner
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Visualización del trayecto de una petición (modo ayudante)

    /// Calcula y muestra en el mapa el trayecto del usuario que pide ayuda.
    /// La lista de peticiones se cierra: se decide desde el banner del mapa.
    private func visualize(_ request: HelpRequest) {
        visualizedRequest = request
        visualizedRoute = nil
        showHelperRequests = false
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(
                center: request.meetingCoordinate,
                latitudinalMeters: 1500,
                longitudinalMeters: 1500
            ))
        }
        guard let origin = request.originCoordinate else { return }
        Task {
            // El mismo cálculo a pie que ve el usuario, para que el tiempo
            // estimado coincida. (Pendiente: adaptarlo a la velocidad de cada
            // discapacidad cuando exista el ritmo personalizado.)
            let directions = MKDirections.Request()
            directions.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            directions.destination = MKMapItem(placemark: MKPlacemark(coordinate: request.coordinate))
            directions.transportType = .walking
            guard let route = try? await MKDirections(request: directions).calculate().routes.first,
                  visualizedRequest?.id == request.id else { return }
            visualizedRoute = route
            withAnimation(.easeInOut) {
                camera = .rect(route.polyline.boundingMapRect.insetBy(dx: -600, dy: -600))
            }
        }
    }

    @ViewBuilder
    private var visualizeBanner: some View {
        if let request = visualizedRequest {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Trayecto de \(request.requesterName ?? "usuario")")
                        .font(.headline)
                    Spacer()
                    Button {
                        visualizedRequest = nil
                        visualizedRoute = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cerrar visualización del trayecto")
                }
                if let route = visualizedRoute {
                    Text("\(formattedDistance(route.distance)) · el usuario llega en \(formattedTime(route.expectedTravelTime))")
                        .font(.subheadline)
                } else if request.originCoordinate == nil {
                    Text("Petición sin origen: se muestra solo el punto de encuentro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Calculando su trayecto…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Label(
                    "Encuentro \(request.meetingPointLabel): \(request.meetingName ?? request.placeName)",
                    systemImage: "figure.2"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.wheelpGreen)

                // La decisión se toma aquí mismo, sin volver a la lista.
                if request.status == .pending {
                    HStack(spacing: 10) {
                        Button("Rechazar") {
                            visualizedRequest = nil
                            visualizedRoute = nil
                            showHelperRequests = true
                        }
                        .buttonStyle(.wheelpOutline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel("Rechazar y volver a las peticiones")

                        Button {
                            acceptVisualized(request)
                        } label: {
                            Label("Aceptar", systemImage: "hand.raised.fill")
                        }
                        .buttonStyle(.wheelpPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Acepta la petición visualizada y vuelve a la lista (sección "ayudando a").
    private func acceptVisualized(_ request: HelpRequest) {
        Task {
            if await HelperService.accept(request, helperName: appState.publicName) {
                visualizedRequest = nil
                visualizedRoute = nil
                showHelperRequests = true
            }
        }
    }

    /// Las 5 sugerencias de autocompletado de Apple Maps.
    private var completionsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.completions.enumerated()), id: \.offset) { index, completion in
                Button {
                    searchFocused = false
                    Task { await model.selectCompletion(completion, profile: profile) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Color.wheelpGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                                .font(profile.bodyFont.weight(.medium))
                                .foregroundStyle(.primary)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, profile.largeTouchTargets ? 14 : 10)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < model.completions.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .wheelpCard(profile, cornerRadius: 16)
    }

    /// Favoritos y recientes, visibles al tocar el buscador vacío.
    private var savedPlacesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.favorites) { place in
                savedPlaceRow(place, icon: "star.fill")
            }
            if !model.favorites.isEmpty && !model.recents.isEmpty {
                Divider().padding(.leading, 44)
            }
            ForEach(model.recents) { place in
                savedPlaceRow(place, icon: "clock.arrow.circlepath")
            }
        }
        .wheelpCard(profile, cornerRadius: 16)
    }

    private func savedPlaceRow(_ place: SavedPlace, icon: String) -> some View {
        Button {
            searchFocused = false
            withAnimation { model.preview(place.mapItem, profile: profile) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color.wheelpGreen)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.displayTitle)
                        .font(profile.bodyFont.weight(.medium))
                        .foregroundStyle(.primary)
                    if place.alias?.isEmpty == false {
                        Text(place.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.vertical, profile.largeTouchTargets ? 14 : 10)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ir a \(place.displayTitle)")
    }

    // MARK: - Tarjeta inferior (ficha o ruta)

    @ViewBuilder
    private var bottomCard: some View {
        if model.isNavigating {
            navigationCard
        } else if model.route != nil {
            routeCard
        } else if model.previewItem != nil {
            destinationCard
        } else if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(profile.bodyFont)
                .foregroundStyle(.orange)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        } else if !model.favorites.isEmpty, !searchFocused {
            // Oculta la barra al escribir: los favoritos ya se ven bajo el buscador.
            favoritesBar
        }
    }

    // MARK: Barra de favoritos (acceso con un toque)

    /// Chips de favoritos en la parte inferior: 3 visibles, desplazable si hay más.
    private var favoritesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.favorites) { place in
                    Button {
                        withAnimation { model.preview(place.mapItem, profile: profile) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.headline)
                            Text(place.displayTitle)
                                .font(profile.bodyFont.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: profile.controlMinHeight + 12)
                        .background(Color.wheelpGreen, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .containerRelativeFrame(.horizontal, count: 3, spacing: 10)
                    .accessibilityLabel("Ir a \(place.displayTitle)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.bottom, 8)
    }

    // MARK: Ayudantes (estado y petición)

    @ViewBuilder
    private var helpSection: some View {
        if let request = model.activeHelpRequest {
            HStack(spacing: 10) {
                if request.status == .pending {
                    ProgressView()
                    Text("Buscando ayudante…")
                        .font(profile.bodyFont)
                } else {
                    Image(systemName: "figure.2")
                        .foregroundStyle(Color.wheelpGreen)
                    Text("Te ayudará \(request.helperName ?? "un ayudante")")
                        .font(profile.bodyFont.weight(.semibold))
                }
                Spacer()
                if request.status == .accepted {
                    Button {
                        chatRequest = request
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .tint(Color.wheelpGreen)
                }
                Button("Cancelar") { model.cancelHelp() }
                    .font(.caption)
                    .tint(.red)
                    .accessibilityLabel("Cancelar petición de ayuda")
            }
        } else {
            Button {
                showHelpSetup = true
            } label: {
                Label("Pedir ayudante", systemImage: "hand.raised")
                    .font(.caption.weight(.semibold))
            }
            .tint(Color.wheelpGreen)
        }
    }

    // MARK: Ficha del destino (accesibilidad + "Ir")

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.previewItem?.name ?? "Destino")
                        .font(profile.titleFont)
                        .lineLimit(2)
                    if let subtitle = model.previewItem?.placemark.title {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let distance = straightLineDistance() {
                        Text("A \(distance) de ti")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    if model.previewFavorite != nil {
                        Task { await model.toggleFavorite(alias: nil) }
                    } else {
                        aliasText = ""
                        showAliasPrompt = true
                    }
                } label: {
                    Image(systemName: model.previewFavorite != nil ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(Color.wheelpGreen)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(model.previewFavorite != nil ? "Quitar de favoritos" : "Guardar en favoritos")
                if let access = model.previewAccessibility {
                    scoreBadge(access)
                }
            }

            if model.isLoadingAccessibility {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Consultando accesibilidad…")
                        .font(profile.bodyFont)
                        .foregroundStyle(.secondary)
                }
            } else if let access = model.previewAccessibility {
                VStack(spacing: 10) {
                    ForEach(access.features) { feature in
                        HStack(spacing: 12) {
                            Image(systemName: feature.icon)
                                .frame(width: 24)
                                .foregroundStyle(.primary)
                            Text(feature.title)
                                .font(profile.bodyFont)
                            Spacer()
                            Label(feature.status.label, systemImage: feature.status.icon)
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(feature.status.color)
                        }
                        // VoiceOver lee cada criterio como una sola frase:
                        // "Entrada sin escalones, Disponible".
                        .accessibilityElement(children: .combine)
                    }
                }

                Text(access.sourceNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    showContribute = true
                } label: {
                    Label("Aportar accesibilidad", systemImage: "plus.bubble")
                        .font(.caption.weight(.semibold))
                }
                .tint(Color.wheelpGreen)
            }

            if let notice = model.contributionNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            helpSection

            HStack(spacing: 12) {
                Button("Cancelar") {
                    withAnimation { model.reset() }
                }
                .buttonStyle(.wheelpOutline)
                .frame(maxWidth: .infinity, minHeight: profile.controlMinHeight)

                Button {
                    Task {
                        await model.startRoute(
                            from: location.lastLocation?.coordinate,
                            transport: profile.transportType
                        )
                    }
                } label: {
                    HStack {
                        if model.isCalculating {
                            ProgressView().tint(.white)
                        } else {
                            Label("Ir", systemImage: "figure.walk")
                        }
                    }
                }
                .buttonStyle(.wheelpPrimary)
                .frame(maxWidth: .infinity, minHeight: profile.controlMinHeight)
                .disabled(model.isCalculating)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wheelpCard(profile)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func scoreBadge(_ access: DestinationAccessibility) -> some View {
        if access.hasAnyKnownFeature {
            VStack(spacing: 2) {
                Text("\(access.score)%")
                    .font(.headline.bold())
                Text("accesible")
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(access.scoreColor, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Accesibilidad \(access.score) por ciento")
        } else {
            VStack(spacing: 2) {
                Image(systemName: "questionmark")
                    .font(.headline.bold())
                Text("sin datos")
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sin datos de accesibilidad")
        }
    }

    // MARK: Tarjeta de ruta

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let route = model.route {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.destination?.name ?? "Destino")
                            .font(profile.titleFont)
                            .lineLimit(1)
                        Text("\(formattedDistance(route.distance)) · \(formattedTime(route.expectedTravelTime))")
                            .font(profile.bodyFont)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Label(profile.routeNote, systemImage: "figure.roll")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let steps = route.steps.filter { !$0.instructions.isEmpty }
                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(steps.prefix(3).enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.wheelpGreen))
                                Text(step.instructions)
                                    .font(profile.bodyFont)
                                Spacer()
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Cancelar") {
                        withAnimation { model.reset() }
                    }
                    .buttonStyle(.wheelpOutline)
                    .frame(maxWidth: .infinity, minHeight: profile.controlMinHeight)

                    Button {
                        withAnimation { model.startNavigation() }
                    } label: {
                        Label("Iniciar", systemImage: "location.north.line.fill")
                    }
                    .buttonStyle(.wheelpPrimary)
                    .frame(maxWidth: .infinity, minHeight: profile.controlMinHeight)
                    .disabled(model.steps.isEmpty)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wheelpCard(profile)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Tarjeta de navegación (turn-by-turn)

    private var navigationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.stepProgressText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.wheelpGreen)
                Spacer()
                if let distance = model.distanceToNextManeuver(from: location.lastLocation) {
                    Text("en \(formattedDistance(distance))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.turn.up.right")
                    .font(.title)
                    .foregroundStyle(Color.wheelpGreen)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                Text(model.currentStep?.instructions ?? "Sigue la ruta")
                    .font(profile.largeText ? .title2.bold() : .title3.weight(.semibold))
                Spacer()
            }

            if let warning = model.obstacleWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(profile.bodyFont.weight(.semibold))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            if model.isLastStep {
                Label("Estás llegando a tu destino", systemImage: "flag.checkered")
                    .font(profile.bodyFont)
                    .foregroundStyle(.secondary)
            }

            Label("La navegación avanza sola con tu posición", systemImage: "location.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            helpSection

            Button("Finalizar") {
                withAnimation { model.reset() }
                if profile.voiceGuidance { speech.announce("Ruta finalizada.") }
            }
            .buttonStyle(.wheelpOutline)
            .frame(maxWidth: .infinity, minHeight: profile.controlMinHeight)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wheelpCard(profile)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Anuncios por voz (versión Visual)

    private func announcePreview() {
        guard profile.voiceGuidance,
              let item = model.previewItem,
              let access = model.previewAccessibility else { return }
        var text = "\(item.name ?? "Destino"). Accesibilidad estimada \(access.score) por ciento."
        let available = access.features.filter { $0.status == .available }.map(\.title)
        if !available.isEmpty {
            text += " Dispone de: " + available.joined(separator: ", ") + "."
        }
        speech.announce(text)
    }

    private func announceRoute() {
        guard profile.voiceGuidance, let route = model.route else { return }
        var text = "Ruta calculada. \(formattedDistance(route.distance)), "
        text += "\(formattedTime(route.expectedTravelTime)) a pie."
        if let first = route.steps.first(where: { !$0.instructions.isEmpty }) {
            text += " Comienza: \(first.instructions)."
        }
        speech.announce(text)
    }

    /// Lee la indicación del paso actual (versión Visual).
    private func announceCurrentStep() {
        guard profile.voiceGuidance, let step = model.currentStep else { return }
        var text = step.instructions
        if model.isLastStep { text += ". Estás llegando a tu destino." }
        speech.announce(text)
    }

    // MARK: - Formato

    /// Estado actual por criterio, para precargar la hoja de aportación.
    private func currentFeatureStatuses() -> [String: DestinationAccessibility.Feature.Status] {
        var statuses: [String: DestinationAccessibility.Feature.Status] = [:]
        for feature in model.previewAccessibility?.features ?? [] {
            statuses[feature.title] = feature.status
        }
        return statuses
    }

    private func straightLineDistance() -> String? {
        guard let here = location.lastLocation, let item = model.previewItem else { return nil }
        let there = CLLocation(
            latitude: item.placemark.coordinate.latitude,
            longitude: item.placemark.coordinate.longitude
        )
        return formattedDistance(here.distance(from: there))
    }

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
