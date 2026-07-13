import SwiftUI
import MapKit

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
    /// Al terminar una ruta se invita a aportar la accesibilidad del destino.
    @State private var finishedContribution: ContributionTarget?
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
                if request.hasExactDetails {
                    Marker(request.placeName, coordinate: request.coordinate)
                        .tint(.blue)
                    Marker("Encuentro", systemImage: "figure.2", coordinate: request.meetingCoordinate)
                        .tint(.purple)
                } else {
                    // Antes de aceptar solo se conoce la zona aproximada.
                    MapCircle(center: request.meetingCoordinate, radius: 700)
                        .foregroundStyle(Color.blue.opacity(0.15))
                        .stroke(Color.blue, lineWidth: 2)
                }
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
        // Invitación a aportar la accesibilidad del destino recién visitado.
        .sheet(item: $finishedContribution) { target in
            ContributeAccessibilityView(
                profile: profile,
                placeName: target.item.name ?? "este lugar",
                initial: [:]
            ) { features in
                Task { await model.submitContribution(for: target.item, features, profile: profile) }
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
                        // Tecla "buscar": resultados ordenados por accesibilidad.
                        .onSubmit {
                            model.search(near: location.lastLocation?.coordinate, profile: profile)
                        }
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                            model.results = []
                            model.resultScores = [:]
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

            if !model.results.isEmpty, model.previewItem == nil, model.route == nil {
                searchResultsList
            } else if !model.completions.isEmpty {
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
                    // Tiempo a la velocidad típica de su versión (no al ritmo
                    // del ayudante); coincide con la estimación base del usuario.
                    let requesterType = DisabilityType(rawValue: request.disabilityType) ?? .none
                    Text("\(formattedDistance(route.distance)) · el usuario llega en \(formattedTime(WalkingPaceService.defaultEstimatedTime(distance: route.distance, type: requesterType)))")
                        .font(.subheadline)
                } else if request.originCoordinate == nil {
                    Text("Zona aproximada de recogida (círculo azul). El trayecto exacto se descifra al aceptar.")
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
                    request.hasExactDetails
                        ? "Encuentro \(request.meetingPointLabel): \(request.meetingName ?? request.placeName)"
                        : "Va hacia: \(request.placeName)",
                    systemImage: request.hasExactDetails ? "figure.2" : "lock.shield"
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

    /// Resultados de la búsqueda, ordenados por accesibilidad conocida y con
    /// su insignia de puntuación para la versión del usuario.
    private var searchResultsList: some View {
        VStack(spacing: 0) {
            Label("Ordenados por accesibilidad para ti", systemImage: "accessibility")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            ForEach(Array(model.results.enumerated()), id: \.offset) { index, item in
                Button {
                    searchFocused = false
                    withAnimation { model.preview(item, profile: profile) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Color.wheelpGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Lugar")
                                .font(profile.bodyFont.weight(.medium))
                                .foregroundStyle(.primary)
                            if let subtitle = item.placemark.title {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        searchScoreBadge(model.score(for: item))
                    }
                    .padding(.vertical, profile.largeTouchTargets ? 14 : 10)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(resultAccessibilityLabel(item))

                if index < model.results.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .wheelpCard(profile, cornerRadius: 16)
    }

    @ViewBuilder
    private func searchScoreBadge(_ score: Int?) -> some View {
        if let score {
            Text("\(score)%")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DestinationAccessibility.scoreColor(score), in: Capsule())
        } else {
            Text("?")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary, in: Capsule())
        }
    }

    private func resultAccessibilityLabel(_ item: MKMapItem) -> String {
        var label = item.name ?? "Lugar"
        if let score = model.score(for: item) {
            label += ", accesibilidad \(score) por ciento"
        } else {
            label += ", sin datos de accesibilidad"
        }
        return label
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
                        Text("\(formattedDistance(route.distance)) · \(formattedTime(model.estimatedTravelTime(for: route, type: profile.type)))")
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
                // El usuario acaba de estar en el destino: momento perfecto
                // para pedirle su aportación de accesibilidad.
                let finished = model.destination
                withAnimation { model.reset() }
                if profile.voiceGuidance { speech.announce("Ruta finalizada.") }
                if let finished { finishedContribution = ContributionTarget(item: finished) }
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
        text += "\(formattedTime(model.estimatedTravelTime(for: route, type: profile.type))) a tu ritmo."
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
