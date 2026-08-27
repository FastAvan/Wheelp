import SwiftUI
import MapKit
import UIKit

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
    /// Solo para helpers (perfil .none): accesibilidad por tipo de discapacidad.
    var previewAccessibilityByType: [DisabilityType: DestinationAccessibility] = [:]

    /// Destino y ruta una vez el usuario pulsa "Ir".
    var destination: MKMapItem?
    var route: MKRoute?

    enum TravelMode { case walking, transit }
    var travelMode: TravelMode = .walking
    var transitItinerary: TransitItinerary?
    /// Mensaje de alerta activo cuando el transporte está a punto de llegar.
    var transitAlertMessage: String?
    private var transitAlertIds: [String] = []
    /// IDs de las paradas cuya alerta ya se ha disparado (evita repetición).
    private var warnedTransitStopIds: Set<UUID> = []

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
        meetingCoordinate: CLLocationCoordinate2D,
        scheduledAt: Date? = nil
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
            meetingCoordinate: meetingCoordinate,
            scheduledAt: scheduledAt
        ) {
            activeHelpRequest = request
            startHelpPolling()
        }
    }

    /// Sondea el estado de la petición cada 8 s hasta que termine.
    private func startHelpPolling() {
        helpPollTask?.cancel()
        helpPollTask = Task {
            var consecutiveNilCount = 0
            while !Task.isCancelled, let current = activeHelpRequest {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { break }
                guard let updated = await HelperService.fetch(id: current.id) else {
                    consecutiveNilCount += 1
                    // Require 3 consecutive nil responses before concluding the
                    // session ended — a single nil is indistinguishable from a
                    // network blip, and calling forget() on a live session is
                    // unrecoverable.
                    if current.status == .accepted, consecutiveNilCount >= 3 {
                        HelpCrypto.forget(requestId: current.id)
                        activeHelpRequest = nil
                        break
                    }
                    continue
                }
                consecutiveNilCount = 0
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

    /// Fuerza una actualización inmediata del estado de la petición activa.
    func refreshActiveRequest() async {
        guard let current = activeHelpRequest,
              let updated = await HelperService.fetch(id: current.id) else { return }
        activeHelpRequest = updated
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

    /// Busca lugares que coincidan con el texto completo.
    ///
    /// La búsqueda NO consulta accesibilidad: antes se puntuaba cada resultado
    /// (5 llamadas a `google-places` por búsqueda, facturadas por llamada) solo
    /// para ordenar la lista, lo que agotaba la cuota y dejaba la ficha del
    /// destino sin datos. La accesibilidad se pide una sola vez, al abrir la
    /// ficha de un destino concreto (`loadAccessibility`).
    func search(near center: CLLocationCoordinate2D?, profile: AccessibilityProfile) {
        searchTask?.cancel()
        completions = []
        completer.queryFragment = ""
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
                guard !Task.isCancelled else { return }
                results = Array(response.mapItems.prefix(5))
            } catch {
                // Búsqueda cancelada o sin resultados.
            }
        }
    }

    /// Muestra la ficha del destino y carga su accesibilidad real desde Supabase.
    func preview(_ item: MKMapItem, profile: AccessibilityProfile) {
        previewItem = item
        previewAccessibility = nil
        previewAccessibilityByType = [:]
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
        let key = AccessibilityService.placeKey(for: item)

        // Helpers ven accesibilidad por cada tipo de discapacidad en carrusel.
        if profile.type == .none {
            async let googleResult = GooglePlacesAccessibilityService.fetch(near: coordinate, name: item.name)
            let google = await googleResult
            var base = google.statuses
            var sourceName: String? = google.found ? "Google Places" : nil

            if base.isEmpty {
                let osmTags = await OSMAccessibilityService.fetchTags(near: coordinate, name: item.name)
                if !osmTags.isEmpty { sourceName = "OpenStreetMap" }
                // OSM tags se interpretan por tipo más abajo
                for type in DisabilityType.selectable {
                    let osmStatuses = DestinationAccessibility.osmStatuses(
                        for: AccessibilityProfile.make(for: type), tags: osmTags)
                    let reports = (try? await AccessibilityService.fetchReports(
                        placeKey: key, disabilityType: type)) ?? []
                    let acc = DestinationAccessibility.combined(
                        base: osmStatuses, sourceName: sourceName, reports: reports,
                        profile: AccessibilityProfile.make(for: type))
                    guard previewItem === item else { return }
                    previewAccessibilityByType[type] = acc
                }
            } else {
                await withTaskGroup(of: (DisabilityType, DestinationAccessibility).self) { group in
                    for type in DisabilityType.selectable {
                        group.addTask {
                            let reports = (try? await AccessibilityService.fetchReports(
                                placeKey: key, disabilityType: type)) ?? []
                            let acc = DestinationAccessibility.combined(
                                base: base, sourceName: sourceName, reports: reports,
                                profile: AccessibilityProfile.make(for: type))
                            return (type, acc)
                        }
                    }
                    for await (type, acc) in group {
                        guard self.previewItem === item else { return }
                        self.previewAccessibilityByType[type] = acc
                    }
                }
            }
            guard previewItem === item else { return }
            isLoadingAccessibility = false
            return
        }

        // Usuarios con discapacidad: accesibilidad para su propio perfil.
        async let googleResult = GooglePlacesAccessibilityService.fetch(near: coordinate, name: item.name)
        let reports = (try? await AccessibilityService.fetchReports(
            placeKey: key,
            disabilityType: profile.type
        )) ?? []

        let google = await googleResult
        var base = google.statuses
        var sourceName: String? = google.found ? "Google Places" : nil

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
            print("Wheelp: error al guardar la aportación de accesibilidad: \(error)")
            contributionNotice = "No se pudo guardar tu aportación. Comprueba la conexión e inténtalo de nuevo."
        }
    }

    /// Aportación de un ayudante para un tipo de discapacidad concreto.
    /// Tras guardar, recarga los 3 tipos para que el carrusel refleje el cambio.
    func submitHelperContribution(
        _ features: [String: DestinationAccessibility.Feature.Status],
        forType type: DisabilityType
    ) async {
        guard let item = previewItem else { return }
        contributionNotice = nil
        do {
            try await AccessibilityService.submit(item: item, disabilityType: type, features: features)
            isLoadingAccessibility = true
            await loadAccessibility(for: item, profile: AccessibilityProfile.make(for: .none))
        } catch {
            print("Wheelp: error al guardar la aportación de accesibilidad: \(error)")
            contributionNotice = "No se pudo guardar tu aportación. Comprueba la conexión e inténtalo de nuevo."
        }
    }

    /// Aportación para un lugar concreto aunque ya no haya ficha abierta.
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

    /// Resumen de la elección de ruta (obstáculos del camino / evitados).
    var routeChoiceNote: String?
    /// ¿La ruta elegida sigue teniendo obstáculos relevantes? (→ ofrecer ayudante)
    var hasUnavoidableObstacles = false

    func startRoute(from source: CLLocationCoordinate2D?, profile: AccessibilityProfile) async {
        if travelMode == .transit {
            await startTransitRoute(from: source)
            return
        }
        await startWalkingRoute(from: source, profile: profile)
    }

    private func startTransitRoute(from source: CLLocationCoordinate2D?) async {
        guard let item = previewItem else { return }
        guard let source else {
            errorMessage = "No podemos obtener tu ubicación. Activa los permisos para calcular la ruta."
            return
        }
        isCalculating = true
        errorMessage = nil
        defer { isCalculating = false }

        if let itinerary = await TransitRoutingService.fetch(
            from: source,
            to: item.placemark.coordinate
        ) {
            destination = item
            transitItinerary = itinerary
            previewItem = nil
            Task {
                await SavedPlacesService.recordVisit(item: item)
                recents = await SavedPlacesService.fetchRecents()
            }
        } else {
            errorMessage = "No se encontró ruta en transporte público. Prueba a pie."
        }
    }

    // MARK: Alertas de transporte público (GPS)

    /// Programa notificaciones locales de respaldo (tiempo estimado)
    /// para cuando la app está en segundo plano.
    func scheduleTransitAlerts() {
        cancelTransitAlerts()
        guard let itinerary = transitItinerary else { return }
        var elapsedSeconds = 0
        for leg in itinerary.legs {
            defer { elapsedSeconds += leg.durationSeconds }
            guard leg.mode == .transit else { continue }
            // Notificación de respaldo: ~3 min antes de la salida estimada
            let alertOffset = max(0, elapsedSeconds - 180)
            let alertDate = Date().addingTimeInterval(TimeInterval(alertOffset))
            guard alertDate > Date().addingTimeInterval(60) else { continue }
            let id = "transit-\(leg.id.uuidString)"
            transitAlertIds.append(id)
            let stopText = leg.departureStop.map { " en \($0)" } ?? ""
            let lineName = leg.lineName ?? leg.lineShort ?? "transporte"
            NotificationService.schedule(
                at: alertDate,
                title: "\(leg.vehicleEmoji) \(lineName) llega pronto",
                body: "Prepárate para subir\(stopText)",
                id: id
            )
        }
    }

    /// Comprueba por GPS si el usuario está cerca de la parada de un tramo de transporte.
    /// Se llama en cada actualización de ubicación. El aviso se dispara una sola vez
    /// por parada al entrar en un radio de 200 m.
    func checkTransitProximity(at location: CLLocation, isVisualProfile: Bool) {
        guard let itinerary = transitItinerary else { return }
        let accuracy = location.horizontalAccuracy
        guard accuracy > 0, accuracy <= 80 else { return }

        for leg in itinerary.legs {
            guard leg.mode == .transit,
                  !warnedTransitStopIds.contains(leg.id),
                  let coord = leg.departureStopCoordinate else { continue }

            let stopLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            guard location.distance(from: stopLocation) < 200 else { continue }

            warnedTransitStopIds.insert(leg.id)
            // La notificación de respaldo ya no hace falta: cancelarla.
            NotificationService.cancel(id: "transit-\(leg.id.uuidString)")

            if isVisualProfile {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }

            let lineName = leg.lineName ?? leg.lineShort ?? "transporte"
            let stopText = leg.departureStop.map { " en \($0)" } ?? ""
            transitAlertMessage = "\(leg.vehicleEmoji) \(lineName): estás llegando a la parada\(stopText)"
            Task {
                try? await Task.sleep(for: .seconds(8))
                if transitAlertMessage != nil { transitAlertMessage = nil }
            }
            return  // Un aviso a la vez
        }
    }

    func cancelTransitAlerts() {
        transitAlertIds.forEach { NotificationService.cancel(id: $0) }
        transitAlertIds = []
        warnedTransitStopIds = []
        transitAlertMessage = nil
    }

    /// Calcula la RUTA ADAPTADA: pide alternativas, cuenta obstáculos por versión,
    /// elige la que menos tenga. Si quedan inevitables, se ofrece el ayudante.
    private func startWalkingRoute(from source: CLLocationCoordinate2D?, profile: AccessibilityProfile) async {
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
        request.transportType = profile.transportType
        request.requestsAlternateRoutes = true

        do {
            let response = try await MKDirections(request: request).calculate()
            let candidates = Array(response.routes.prefix(3))
            guard !candidates.isEmpty else {
                errorMessage = "No encontramos una ruta hasta ese destino."
                return
            }

            var scored: [(route: MKRoute, obstacles: [RouteObstacle])] = []
            var obstacleDataAvailable = true
            await withTaskGroup(of: (Int, [RouteObstacle]?).self) { group in
                for index in candidates.indices {
                    group.addTask {
                        (index, await RouteObstaclesService.fetch(along: candidates[index]))
                    }
                }
                var byIndex: [Int: [RouteObstacle]] = [:]
                for await (index, result) in group {
                    if let list = result { byIndex[index] = list } else { obstacleDataAvailable = false }
                }
                scored = candidates.enumerated().map { ($0.element, byIndex[$0.offset] ?? []) }
            }

            func relevantCount(_ entry: (route: MKRoute, obstacles: [RouteObstacle])) -> Int {
                entry.obstacles.filter { $0.matters(for: profile.type) }.count
            }
            let best = scored.min {
                let (a, b) = (relevantCount($0), relevantCount($1))
                return a == b ? $0.route.expectedTravelTime < $1.route.expectedTravelTime : a < b
            } ?? (candidates[0], [])

            destination = item
            route = best.route
            steps = best.route.steps.filter { !$0.instructions.isEmpty }
            currentStepIndex = 0
            isNavigating = false
            previewItem = nil
            routeObstacles = best.obstacles
            warnedObstacleIds = []
            obstacleWarning = nil

            let relevant = best.obstacles.filter { $0.matters(for: profile.type) }
            hasUnavoidableObstacles = !relevant.isEmpty
            let worstCount = scored.map(relevantCount).max() ?? 0
            routeChoiceNote = Self.routeSummary(
                relevant: relevant,
                avoided: worstCount - relevant.count,
                alternatives: scored.count,
                obstacleDataAvailable: obstacleDataAvailable
            )

            Task {
                await SavedPlacesService.recordVisit(item: item)
                recents = await SavedPlacesService.fetchRecents()
            }
        } catch {
            errorMessage = "No se pudo calcular la ruta. Inténtalo de nuevo."
        }
    }

    private static func routeSummary(relevant: [RouteObstacle], avoided: Int, alternatives: Int, obstacleDataAvailable: Bool) -> String {
        var parts: [String] = []
        if !obstacleDataAvailable {
            parts.append("No se pudo verificar si hay obstáculos en esta ruta")
        } else if relevant.isEmpty {
            parts.append("Sin obstáculos conocidos para ti en esta ruta")
        } else {
            let counts = Dictionary(grouping: relevant, by: \.title)
                .map { "\($0.value.count)× \($0.key.lowercased())" }
                .sorted()
            parts.append("En el camino: " + counts.joined(separator: ", "))
        }
        if avoided > 0, alternatives > 1 {
            parts.append("ruta elegida evitando \(avoided) obstáculo\(avoided == 1 ? "" : "s") de las alternativas")
        }
        return parts.joined(separator: "; ") + "."
    }

    /// Vuelve a la búsqueda limpia.
    func reset() {
        if activeHelpRequest?.status == .pending { cancelHelp() }
        cancelTransitAlerts()
        route = nil
        transitItinerary = nil
        travelMode = .walking
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
        routeChoiceNote = nil
        hasUnavoidableObstacles = false
    }

    // MARK: - Navegación paso a paso

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

    func advanceStep() {
        if currentStepIndex < steps.count - 1 { currentStepIndex += 1 }
    }

    /// Avanza automáticamente según la posición del usuario.
    func updateProgress(_ location: CLLocation) {
        guard isNavigating, !isLastStep else { return }

        let accuracy = location.horizontalAccuracy
        guard accuracy > 0, accuracy <= 65,
              location.timestamp.timeIntervalSinceNow > -15 else { return }

        if let previous = lastPaceLocation {
            WalkingPaceService.record(
                distance: location.distance(from: previous),
                duration: location.timestamp.timeIntervalSince(previous.timestamp)
            )
        }
        lastPaceLocation = location

        let arrivalThreshold = min(max(20, accuracy * 1.5), 50)

        let lookahead = min(currentStepIndex + 3, steps.count - 1)
        for index in (currentStepIndex...lookahead).reversed() {
            if let end = Self.lastCoordinate(of: steps[index].polyline),
               location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) < arrivalThreshold {
                currentStepIndex = min(index + 1, steps.count - 1)
                return
            }
        }

        for index in ((currentStepIndex + 1)...lookahead).reversed() where index > currentStepIndex {
            if Self.distance(from: location, toPolyline: steps[index].polyline) < arrivalThreshold {
                currentStepIndex = index
                return
            }
        }
    }

    func distanceToNextManeuver(from location: CLLocation?) -> CLLocationDistance? {
        guard let location, let step = currentStep,
              let end = Self.lastCoordinate(of: step.polyline) else { return nil }
        return location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    func remainingDistance(from location: CLLocation?) -> CLLocationDistance? {
        guard let toNext = distanceToNextManeuver(from: location) else { return nil }
        let pending = steps.dropFirst(currentStepIndex + 1).reduce(0) { $0 + $1.distance }
        return toNext + pending
    }

    func remainingTime(from location: CLLocation?, type: DisabilityType) -> TimeInterval? {
        guard let remaining = remainingDistance(from: location) else { return nil }
        return WalkingPaceService.estimatedTime(distance: remaining, type: type)
    }

    func estimatedTravelTime(for route: MKRoute, type: DisabilityType) -> TimeInterval {
        WalkingPaceService.estimatedTime(distance: route.distance, type: type)
    }

    private static func lastCoordinate(of polyline: MKPolyline) -> CLLocationCoordinate2D? {
        guard polyline.pointCount > 0 else { return nil }
        return polyline.points()[polyline.pointCount - 1].coordinate
    }

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
