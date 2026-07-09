import SwiftUI

/// Hoja para que el usuario aporte la accesibilidad de un destino.
struct ContributeAccessibilityView: View {
    let profile: AccessibilityProfile
    let placeName: String
    /// Estado inicial por criterio (lo ya conocido del lugar).
    let initial: [String: DestinationAccessibility.Feature.Status]
    let onSubmit: ([String: DestinationAccessibility.Feature.Status]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: DestinationAccessibility.Feature.Status] = [:]

    private var criteria: [(icon: String, title: String)] {
        DestinationAccessibility.criteria(for: profile.type)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(criteria, id: \.title) { criterion in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(criterion.title, systemImage: criterion.icon)
                                .font(.headline)
                            // El título no se pinta en estilo segmentado, pero da
                            // nombre al control para VoiceOver.
                            Picker(criterion.title, selection: binding(for: criterion.title)) {
                                ForEach(DestinationAccessibility.Feature.Status.allCases, id: \.self) { status in
                                    Text(status.label).tag(status)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("¿Cómo de accesible es \(placeName)?")
                } footer: {
                    Text("Tu aportación ayuda a otras personas. Marca solo lo que conozcas.")
                }
            }
            .navigationTitle("Aportar accesibilidad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enviar") {
                        onSubmit(values)
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Parte de lo ya conocido; el resto en "sin datos".
                for criterion in criteria where values[criterion.title] == nil {
                    values[criterion.title] = initial[criterion.title] ?? .unknown
                }
            }
        }
    }

    private func binding(for title: String) -> Binding<DestinationAccessibility.Feature.Status> {
        Binding(
            get: { values[title] ?? .unknown },
            set: { values[title] = $0 }
        )
    }
}
