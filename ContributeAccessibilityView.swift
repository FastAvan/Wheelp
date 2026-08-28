import SwiftUI
import MapKit

/// Envoltorio identificable para presentar la hoja de aportación de un lugar
/// concreto (p. ej. el destino recién visitado al finalizar una ruta).
struct ContributionTarget: Identifiable {
    let id = UUID()
    let item: MKMapItem
}

/// Hoja para que el usuario aporte la accesibilidad de un destino.
///
/// Admite aportar para varias discapacidades a la vez: un ayudante recorre el
/// sitio sin tener ninguna, y puede observar la rampa, el bucle magnético y el
/// pavimento podotáctil en el mismo viaje. Con un solo tipo (usuario con
/// discapacidad aportando sobre la suya) el selector no aparece.
struct ContributeAccessibilityView: View {
    let placeName: String
    /// Tipos para los que se puede aportar. Uno solo → sin selector.
    let types: [DisabilityType]
    /// Estado inicial por tipo y criterio (lo ya conocido del lugar).
    let initial: [DisabilityType: [String: DestinationAccessibility.Feature.Status]]
    /// Devuelve solo los tipos donde se marcó algo distinto de "sin datos".
    let onSubmit: ([DisabilityType: [String: DestinationAccessibility.Feature.Status]]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [DisabilityType: [String: DestinationAccessibility.Feature.Status]] = [:]
    @State private var selectedType: DisabilityType

    init(
        placeName: String,
        types: [DisabilityType],
        initial: [DisabilityType: [String: DestinationAccessibility.Feature.Status]] = [:],
        onSubmit: @escaping ([DisabilityType: [String: DestinationAccessibility.Feature.Status]]) -> Void
    ) {
        self.placeName = placeName
        self.types = types.isEmpty ? [.none] : types
        self.initial = initial
        self.onSubmit = onSubmit
        _selectedType = State(initialValue: types.first ?? .none)
    }

    /// Conveniencia para el caso de un único perfil.
    init(
        profile: AccessibilityProfile,
        placeName: String,
        initial: [String: DestinationAccessibility.Feature.Status],
        onSubmit: @escaping ([String: DestinationAccessibility.Feature.Status]) -> Void
    ) {
        self.init(
            placeName: placeName,
            types: [profile.type],
            initial: [profile.type: initial],
            onSubmit: { byType in onSubmit(byType[profile.type] ?? [:]) }
        )
    }

    private var criteria: [(icon: String, title: String)] {
        DestinationAccessibility.criteria(for: selectedType)
    }

    /// Tipos en los que el usuario ya ha marcado algo, para señalarlos en el
    /// selector y que no se le olvide ninguno a medias.
    private func hasAnswers(_ type: DisabilityType) -> Bool {
        (values[type] ?? [:]).values.contains { $0 != .unknown }
    }

    var body: some View {
        NavigationStack {
            Form {
                if types.count > 1 {
                    Section {
                        Picker("Tipo de accesibilidad", selection: $selectedType) {
                            ForEach(types) { type in
                                Text(hasAnswers(type) ? "\(type.title) ✓" : type.title).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("Puedes aportar para varias. Se guardará solo lo que marques.")
                    }
                }

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
                        // Solo los tipos con alguna respuesta real: enviar un tipo
                        // entero en "sin datos" contaría como un informe vacío.
                        onSubmit(values.filter { _, v in v.values.contains { $0 != .unknown } })
                        dismiss()
                    }
                }
            }
            .onAppear(perform: seedValues)
            .onChange(of: selectedType) { _, _ in seedValues() }
        }
    }

    /// Parte de lo ya conocido para el tipo visible; el resto en "sin datos".
    private func seedValues() {
        var current = values[selectedType] ?? [:]
        let known = initial[selectedType] ?? [:]
        for criterion in DestinationAccessibility.criteria(for: selectedType) where current[criterion.title] == nil {
            current[criterion.title] = known[criterion.title] ?? .unknown
        }
        values[selectedType] = current
    }

    private func binding(for title: String) -> Binding<DestinationAccessibility.Feature.Status> {
        Binding(
            get: { values[selectedType]?[title] ?? .unknown },
            set: { values[selectedType, default: [:]][title] = $0 }
        )
    }
}
