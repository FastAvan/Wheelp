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
                guard !Task.isCancelled else { break }
                guard let updated = await HelperService.fetch(id: current.id) else {
                    // La fila ya no existe: la otra parte terminó la ayuda.
                    if current.status == .accepted {
                        HelpCrypto.forget(requestId: current.id)
                        activeHelpRequest = nil
                        break
                    }
                    continue
                }
                // Notificación local en el momento en que alguien acepta.
                if current.status == .pending, updated.status == .accepted {
                    NotificationService.notify(
                        title: "¡Tienes ayudante!",
                        body: "\(updated.helperName ?? "Un ayudante") ha aceptado tu petición en \(updated.placeName)."
                    )
                }
                activeHelpRequest = updated
            }
        }
    }

    func cancelHelp() {
        guard let request = activeHelpRequest else { return }
        helpPollTask?.cancel()
        activeHelpRequest = nil
        // Cancelar borra la petición, sus mensajes y la clave de cifrado.
        Task { await HelperService.close(request.id) }
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

    /// Puntuación de accesibilidad de cada resultado (clave: placeKey).
    var resultScores: [String: Int] = [:]

    /// Puntuación conocida de un resultado de búsqueda (nil = sin datos).
    func score(for item: MKMapItem) -> Int? {
        resultScores[AccessibilityService.placeKey(for: item)]
    }

    /// Puntúa los resultados con los mismos datos que la ficha (Google +
    /// aportaciones) y los ordena: mejor accesibilidad conocida primero,
    /// sin datos al final manteniendo la relevancia de la búsqueda.
    private func rankByAccessibility(
        _ items: [MKMapItem],
        profile: AccessibilityProfile
    ) async -> (items: [MKMapItem], scores: [String: Int]) {
        var scores: [String: Int] = [:]
        await withTaskGroup(of: (Int, Int?).self) { group in
            for index in items.indices {
                group.addTask {
                    (index, await Self.accessibilityScore(of: items[index], profile: profile))
                }
            }
            for await (index, score) in group {
                if let score {
                    scores[AccessibilityService.placeKey(for: items[index])] = score
                }
            }
        }
        func score(_ item: MKMapItem) -> Int? { scores[AccessibilityService.placeKey(for: item)] }
        let ordered = items.enumerated().sorted { a, b in
            switch (score(a.element), score(b.element)) {
            case let (x?, y?): x == y ? a.offset < b.offset : x > y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
        return (ordered, scores)
    }

    private static func accessibilityScore(
        of item: MKMapItem,
        profile: AccessibilityProfile
    ) async -> Int? {
        let coordinate = item.placemark.coordinate
        async let googleResult = GooglePlacesAccessibilityService.fetch(near: coordinate, name: item.name)
        let reports = (try? await AccessibilityService.fetchReports(
            placeKey: AccessibilityService.placeKey(for: item),
            disabilityType: profile.type
        )) ?? []
        let google = await googleResult
        let access = DestinationAccessibility.combined(
            base: google.statuses,
            sourceName: nil,
            reports: reports,
            profile: profile
        )
        return access.hasAnyKnownFeature ? access.score : nil
    }

    /// Busca lugares que coincidan con el texto completo (dictado por voz o
    /// tecla "buscar") y los ordena por accesibilidad para el perfil.
    func search(near center: CLLocationCoordinate2D?, profile: AccessibilityProfile) {
        searchTask?.cancel()
        completions = []
        completer.queryFragment = ""
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else {
            results = []
            resultScores = [:]
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
                guard !Task.isCancelled else { return }
                let ranked = await rankByAccessibility(
                    Array(response.mapItems.prefix(5)),
                    profile: profile
                )
                guard !Task.isCancelled else { return }
                results = ranked.items
                resultScores = ranked.scores
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
        resultScores = [:]
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

    /// Aportación para un lugar concreto aunque ya no haya ficha abierta
    /// (p. ej. el destino recién visitado al finalizar la ruta).
    func submitContribution(
        for item: MKMapItem,
        _ features: [String: DestinationAccessibility.Feature.Status],
        profile: AccessibilityProfile
    ) async {
        do {
            try await AccessibilityService.submit(item: item, disabilityType: profile.type, features: features)
        } catch {
            print("Wheelp: error al guardar la aportación de accesibilidad: \(error)")
            errorMessage = "No se pudo guardar tu aportación. Inténtalo desde la ficha del lugar."
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
        resultScores = [:]
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

    /// Última posición usada para medir el ritmo de marcha.
    private var lastPaceLocation: CLLocation?

    func startNavigation() {
        guard route != nil, !steps.isEmpty else { return }
        currentStepIndex = 0
        lastPaceLocation = nil
        isNavigating = true
    }

    func stopNavigation() {
        isNavigating = false
        lastPaceLocation = nil
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

        // Aprende el ritmo de marcha real con cada tramo recorrido.
        if let previous = lastPaceLocation {
            WalkingPaceService.record(
                distance: location.distance(from: previous),
                duration: location.timestamp.timeIntervalSince(previous.timestamp)
            )
        }
        lastPaceLocation = location

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

    /// Tiempo restante estimado al ritmo de marcha del usuario.
    func remainingTime(from location: CLLocation?, type: DisabilityType) -> TimeInterval? {
        guard let remaining = remainingDistance(from: location) else { return nil }
        return WalkingPaceService.estimatedTime(distance: remaining, type: type)
    }

    /// Duración estimada de una ruta al ritmo de marcha del usuario.
    func estimatedTravelTime(for route: MKRoute, type: DisabilityType) -> TimeInterval {
        WalkingPaceService.estimatedTime(distance: route.distance, type: type)
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
