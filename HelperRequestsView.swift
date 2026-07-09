import SwiftUI
import CoreLocation

/// Pantalla del ayudante: peticiones de ayuda cercanas (pendientes) y las que
/// ya ha aceptado. Se refresca por sondeo mientras está abierta.
struct HelperRequestsView: View {
    let userLocation: CLLocation?
    /// Muestra el trayecto de la petición en el mapa (reduce esta hoja).
    var onVisualize: ((HelpRequest) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var pending: [HelpRequest] = []
    @State private var accepted: [HelpRequest] = []
    @State private var isLoading = true
    @State private var chatRequest: HelpRequest?

    var body: some View {
        NavigationStack {
            List {
                if !accepted.isEmpty {
                    Section("Estás ayudando a") {
                        ForEach(accepted) { request in
                            acceptedRow(request)
                        }
                    }
                }

                Section {
                    if isLoading && pending.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Buscando peticiones cercanas…")
                                .foregroundStyle(.secondary)
                        }
                    } else if pending.isEmpty {
                        Text("No hay peticiones de ayuda cerca ahora mismo.")
                            .foregroundStyle(.secondary)
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
                "Encuentro \(request.meetingPointLabel): \(request.meetingName ?? request.placeName)",
                systemImage: "figure.2"
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
                    .accessibilityLabel("Visualizar el trayecto de \(request.requesterName ?? "esta petición") en el mapa")
                }

                Button {
                    Task {
                        if await HelperService.accept(request, helperName: appState.publicName) {
                            await refresh()
                        }
                    }
                } label: {
                    Label("Aceptar", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.wheelpPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(request.requesterName ?? "Alguien") va hacia \(request.placeName) y quiere encontrarse \(request.meetingPointLabel)")
    }

    private func acceptedRow(_ request: HelpRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "figure.2")
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
                "Encuentro \(request.meetingPointLabel): \(request.meetingName ?? request.placeName)",
                systemImage: "figure.2"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.wheelpGreen)

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
                }
                .buttonStyle(.wheelpPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)

                Button {
                    Task {
                        await HelperService.updateStatus(request.id, to: .completed)
                        await refresh()
                    }
                } label: {
                    Label("Completada", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.wheelpOutline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            // Aire entre "Visualizar trayecto" y los botones de chat/completada.
            .padding(.top, 10)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Datos

    private func refresh() async {
        async let pendingList = HelperService.fetchPending(near: userLocation?.coordinate)
        async let acceptedList = HelperService.fetchAccepted()
        pending = await pendingList
        accepted = await acceptedList
        isLoading = false
    }

    /// Refresca cada 10 s mientras la pantalla está abierta.
    private func pollLoop() async {
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
}
