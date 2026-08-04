import SwiftUI
import CoreLocation

/// Pantalla del ayudante: peticiones inmediatas cercanas, citas programadas
/// y las que ya ha aceptado. Se refresca por sondeo mientras está abierta.
struct HelperRequestsView: View {
    let userLocation: CLLocation?
    var onVisualize: ((HelpRequest) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var pending: [HelpRequest] = []
    @State private var scheduled: [HelpRequest] = []
    @State private var accepted: [HelpRequest] = []
    @State private var isLoading = true
    @State private var chatRequest: HelpRequest?
    /// Códigos de verificación por petición (derivados de la clave compartida).
    @State private var meetingCodes: [UUID: String] = [:]
    /// false si el ayudante no tiene foto de perfil: bloquea aceptar peticiones.
    @State private var helperHasAvatar = false
    @State private var showSettingsForAvatar = false

    var body: some View {
        NavigationStack {
            List {
                // Aviso de foto de perfil obligatoria.
                if !helperHasAvatar {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                "Añade una foto de perfil para que los usuarios puedan reconocerte al aceptar.",
                                systemImage: "person.crop.circle.badge.exclamationmark.fill"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            Button {
                                showSettingsForAvatar = true
                            } label: {
                                Label("Añadir foto ahora", systemImage: "camera.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.wheelpPrimary)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.orange.opacity(0.08))
                    }
                }

                // Peticiones que este ayudante ya ha aceptado.
                if !accepted.isEmpty {
                    Section("Estás ayudando a") {
                        ForEach(accepted) { request in
                            acceptedRow(request)
                        }
                    }
                }

                // Citas programadas pendientes (aún sin ayudante).
                if !scheduled.isEmpty {
                    Section {
                        ForEach(scheduled) { request in
                            scheduledRow(request)
                        }
                    } header: {
                        Text("Citas programadas")
                    } footer: {
                        Text("El usuario las publicó con antelación. Al aceptar recibirás recordatorios.")
                    }
                }

                // Peticiones inmediatas.
                Section {
                    if isLoading && pending.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Buscando peticiones cercanas…")
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)
                    } else if pending.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "hand.raised.slash")
                                .font(.title)
                                .foregroundStyle(.secondary)
                            Text("Sin peticiones cerca ahora mismo")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("La lista se actualiza sola cada 10 segundos.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(pending) { request in
                            pendingRow(request)
                        }
                    }
                } header: {
                    Text("Peticiones cercanas")
                } footer: {
                    Text("Versión de prueba: sin verificación de identidad. La lista se actualiza sola.")
                }
            }
            .navigationTitle("Ayudar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await pollLoop() }
            .refreshable { await refresh() }
            .sheet(item: $chatRequest) { request in
                HelpChatView(request: request)
            }
            .sheet(isPresented: $showSettingsForAvatar) {
                SettingsView()
            }
            .onChange(of: showSettingsForAvatar) { _, isShowing in
                guard !isShowing else { return }
                Task { helperHasAvatar = (await HelperService.currentAvatarURL()) != nil }
            }
        }
    }

    // MARK: - Filas

    private func pendingRow(_ request: HelpRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: DisabilityType(rawValue: request.disabilityType)?.icon ?? "person.fill")
                    .foregroundStyle(Color.wheelpGreen)
                Text(request.requesterName ?? "Alguien")
                    .font(.headline)
                Spacer()
                if let distance = distanceText(request) {
                    Text(distance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Trayecto: hasta \(request.placeName)")
                .font(.subheadline)
            Label(
                "Recogida en zona aproximada; el punto exacto se descifra al aceptar",
                systemImage: "lock.shield"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.wheelpGreen)

            HStack(spacing: 10) {
                if let onVisualize {
                    Button {
                        onVisualize(request)
                    } label: {
                        Label("Visualizar", systemImage: "map.fill")
                    }
                    .buttonStyle(.wheelpOutline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .accessibilityLabel("Visualizar el trayecto en el mapa")
                }

                Button {
                    Task {
                        if await HelperService.accept(request, helperName: appState.publicName) {
                            await refresh()
                        }
                    }
                } label: {
                    Label("Aceptar", systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .lineLimit(1)
                }
                .buttonStyle(.wheelpPrimary)
                .frame(maxWidth: .infinity)
                .disabled(!helperHasAvatar)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Alguien va hacia \(request.placeName) y necesita ayuda en una zona cercana")
    }

    private func scheduledRow(_ request: HelpRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: DisabilityType(rawValue: request.disabilityType)?.icon ?? "person.fill")
                    .foregroundStyle(Color.wheelpGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.requesterName ?? "Alguien")
                        .font(.headline)
                    if let date = request.scheduledForText {
                        Label(date, systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.wheelpGreen)
                    }
                }
                Spacer()
                if let distance = distanceText(request) {
                    Text(distance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Trayecto: hasta \(request.placeName)")
                .font(.subheadline)
            Label(
                "Zona aproximada; el trayecto exacto se comparte al aceptar",
                systemImage: "lock.shield"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.wheelpGreen)

            HStack(spacing: 10) {
                if let onVisualize {
                    Button {
                        onVisualize(request)
                    } label: {
                        Label("Visualizar", systemImage: "map.fill")
                    }
                    .buttonStyle(.wheelpOutline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                }

                Button {
                    Task {
                        if await HelperService.accept(request, helperName: appState.publicName) {
                            scheduleReminders(for: request)
                            await refresh()
                        }
                    }
                } label: {
                    Label("Aceptar cita", systemImage: "calendar.badge.checkmark")
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .lineLimit(1)
                }
                .buttonStyle(.wheelpPrimary)
                .frame(maxWidth: .infinity)
                .disabled(!helperHasAvatar)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(scheduledAccessibilityLabel(request))
    }

    private func acceptedRow(_ request: HelpRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "figure.2")
                    .foregroundStyle(Color.wheelpGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.requesterName ?? "Alguien")
                        .font(.headline)
                    if let date = request.scheduledForText {
                        Label(date, systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.wheelpGreen)
                    }
                }
                Spacer()
                if let distance = distanceText(request) {
                    Text(distance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Trayecto: hasta \(request.placeName)")
                .font(.subheadline)
            Label(
                "Encuentro \(request.meetingPointLabel): \(request.meetingName ?? request.placeName)",
                systemImage: "figure.2"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.wheelpGreen)

            // Código de verificación del encuentro (solo cuando la petición está aceptada).
            if request.status == .accepted {
                if let code = meetingCodes[request.id] {
                    MeetingCodeView(code: code, isRequester: false)
                } else {
                    Label("Calculando código de verificación…", systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let onVisualize {
                Button {
                    onVisualize(request)
                } label: {
                    Label("Visualizar trayecto", systemImage: "map.fill")
                }
                .buttonStyle(.wheelpOutline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }

            HStack(spacing: 10) {
                Button {
                    chatRequest = request
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .lineLimit(1)
                }
                .buttonStyle(.wheelpOutline)
                .frame(maxWidth: .infinity)

                if request.status == .accepted {
                    // Confirmar encuentro y arrancar la sesión.
                    Button {
                        Task {
                            if await HelperService.markInProgress(request.id) {
                                await refresh()
                            }
                        }
                    } label: {
                        Label("Comenzar trayecto", systemImage: "figure.2.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .lineLimit(1)
                    }
                    .buttonStyle(.wheelpOutline)
                    .frame(maxWidth: .infinity)
                } else {
                    // Sesión en curso → puede marcarla como completada.
                    Button {
                        Task {
                            cancelReminders(for: request)
                            await HelperService.close(request.id)
                            await refresh()
                        }
                    } label: {
                        Label("Completada", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .lineLimit(1)
                    }
                    .buttonStyle(.wheelpOutline)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 10)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Recordatorios de cita

    /// Programa dos notificaciones locales al aceptar una cita: 30 min antes y al inicio.
    private func scheduleReminders(for request: HelpRequest) {
        guard let date = request.scheduledAt else { return }
        let place = request.placeName
        let thirty = date.addingTimeInterval(-30 * 60)
        NotificationService.schedule(
            at: thirty,
            title: "Cita de ayuda en 30 minutos",
            body: "Tu cita en \(place) empieza en 30 minutos.",
            id: reminderID(request.id, suffix: "30")
        )
        NotificationService.schedule(
            at: date,
            title: "Cita de ayuda ahora",
            body: "Tu cita en \(place) comienza ahora.",
            id: reminderID(request.id, suffix: "0")
        )
    }

    private func cancelReminders(for request: HelpRequest) {
        NotificationService.cancel(id: reminderID(request.id, suffix: "30"))
        NotificationService.cancel(id: reminderID(request.id, suffix: "0"))
    }

    private func reminderID(_ id: UUID, suffix: String) -> String {
        "wheelp.appt.\(id.uuidString).\(suffix)"
    }

    // MARK: - Datos

    private func refresh() async {
        async let pendingList   = HelperService.fetchPending(near: userLocation?.coordinate)
        async let scheduledList = HelperService.fetchScheduled(near: userLocation?.coordinate)
        async let acceptedList  = HelperService.fetchAccepted()
        pending   = await pendingList
        scheduled = await scheduledList
        accepted  = await acceptedList
        isLoading = false
        // Cargar códigos de verificación para peticiones aceptadas.
        for request in accepted where request.status == .accepted {
            if meetingCodes[request.id] == nil {
                if let code = await HelperService.meetingCode(for: request) {
                    meetingCodes[request.id] = code
                }
            }
        }
    }

    private func pollLoop() async {
        // Comprobar foto de perfil una sola vez al abrir la pantalla.
        helperHasAvatar = (await HelperService.currentAvatarURL()) != nil
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            await refresh()
        }
    }

    private func distanceText(_ request: HelpRequest) -> String? {
        guard let userLocation else { return nil }
        let meters = HelperService.distance(from: userLocation, to: request)
        if meters < 1000 { return "a \(Int(meters)) m" }
        return String(format: "a %.1f km", meters / 1000)
    }

    private func scheduledAccessibilityLabel(_ request: HelpRequest) -> String {
        var label = "Cita programada hacia \(request.placeName)"
        if let date = request.scheduledForText { label += " el \(date)" }
        return label
    }
}
