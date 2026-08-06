import SwiftUI

/// Pantalla de administración para revisar solicitudes de ayudante pendientes.
/// Solo accesible desde la cuenta de administrador (aelguer@icloud.com).
struct AdminApplicationsView: View {
    @State private var applications: [HelperApplication] = []
    @State private var isLoading = true
    @State private var actionError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if isLoading && applications.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Cargando solicitudes…").foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                } else if applications.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.wheelpGreen)
                        Text("Sin solicitudes pendientes")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Cuando alguien envíe una solicitud aparecerá aquí.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(applications) { app in
                        applicationRow(app)
                    }
                }

                if let error = actionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Solicitudes pendientes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .status) {
                    if !applications.isEmpty {
                        Text("\(applications.count) pendiente\(applications.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func applicationRow(_ app: HelperApplication) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "person.badge.clock.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.headline)
                    Text(app.city)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let date = app.createdAt {
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let phone = app.phone, !phone.isEmpty {
                Label(phone, systemImage: "phone")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            if let motivation = app.motivation, !motivation.isEmpty {
                Text("\"\(motivation)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    Task { await reject(app) }
                } label: {
                    Label("Rechazar", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .lineLimit(1)
                }
                .buttonStyle(.wheelpOutline)
                .frame(maxWidth: .infinity)

                Button {
                    Task { await approve(app) }
                } label: {
                    Label("Aprobar", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .lineLimit(1)
                }
                .buttonStyle(.wheelpPrimary)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }

    private func load() async {
        isLoading = true
        actionError = nil
        applications = await HelperService.fetchPendingApplications()
        isLoading = false
    }

    private func approve(_ app: HelperApplication) async {
        actionError = nil
        if await HelperService.approveApplication(id: app.id) {
            withAnimation { applications.removeAll { $0.id == app.id } }
        } else {
            actionError = "No se pudo aprobar. Comprueba que las funciones SQL estén creadas en Supabase."
        }
    }

    private func reject(_ app: HelperApplication) async {
        actionError = nil
        if await HelperService.rejectApplication(id: app.id) {
            withAnimation { applications.removeAll { $0.id == app.id } }
        } else {
            actionError = "No se pudo rechazar. Comprueba tu conexión e inténtalo de nuevo."
        }
    }
}
