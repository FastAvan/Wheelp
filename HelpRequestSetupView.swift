import SwiftUI
import MapKit

/// Página previa a pedir un ayudante: muestra el trayecto del usuario y le
/// pide elegir dónde quiere encontrarse con el ayudante (en el punto de
/// inicio, en el destino o en otro punto de la ruta). Solo entonces se lanza
/// el aviso a los ayudantes, con toda la información del trayecto.
struct HelpRequestSetupView: View {
    let profile: AccessibilityProfile
    let destinationName: String
    /// Posición actual del usuario (origen del trayecto), si se conoce.
    let originCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D
    /// Pasos de la ruta calculada (vacío si aún no hay ruta).
    let steps: [MKRoute.Step]
    let onConfirm: (HelpRequest.MeetingPoint, String?, CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var meeting: HelpRequest.MeetingPoint = .destination
    @State private var selectedRouteIndex = 0

    /// Puntos intermedios elegibles: el final de cada paso con indicación.
    private var routeChoices: [(title: String, coordinate: CLLocationCoordinate2D)] {
        steps.compactMap { step in
            guard !step.instructions.isEmpty, step.polyline.pointCount > 0 else { return nil }
            let end = step.polyline.points()[step.polyline.pointCount - 1].coordinate
            return (step.instructions, end)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tu trayecto") {
                    Label("Desde: tu ubicación actual", systemImage: "location.fill")
                        .font(profile.bodyFont)
                    Label("Hasta: \(destinationName)", systemImage: "mappin.and.ellipse")
                        .font(profile.bodyFont)
                }

                Section {
                    meetingOption(
                        .origin,
                        title: "En el punto de inicio",
                        subtitle: originCoordinate == nil
                            ? "No conocemos tu ubicación todavía"
                            : "Donde estás ahora, para hacer el camino juntos",
                        icon: "figure.wave",
                        disabled: originCoordinate == nil
                    )
                    meetingOption(
                        .destination,
                        title: "En el destino",
                        subtitle: destinationName,
                        icon: "mappin.and.ellipse",
                        disabled: false
                    )
                    if !routeChoices.isEmpty {
                        meetingOption(
                            .route,
                            title: "En otro punto de la ruta",
                            subtitle: "Elige un punto del camino",
                            icon: "point.topleft.down.curvedto.point.bottomright.up",
                            disabled: false
                        )
                        if meeting == .route {
                            Picker("Punto del camino", selection: $selectedRouteIndex) {
                                ForEach(routeChoices.indices, id: \.self) { index in
                                    Text(routeChoices[index].title).tag(index)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(profile.bodyFont)
                        }
                    }
                } header: {
                    Text("¿Dónde quieres encontrarte con el ayudante?")
                } footer: {
                    Text("El ayudante verá tu trayecto completo y el punto de encuentro que elijas.")
                }

                Section {
                    Button {
                        let (name, coordinate) = resolvedMeeting()
                        onConfirm(meeting, name, coordinate)
                        dismiss()
                    } label: {
                        Label("Pedir ayudante", systemImage: "hand.raised.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.wheelpPrimary)
                    .frame(maxWidth: .infinity, minHeight: profile.controlMinHeight)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle("Pedir ayudante")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    private func meetingOption(
        _ option: HelpRequest.MeetingPoint,
        title: String,
        subtitle: String,
        icon: String,
        disabled: Bool
    ) -> some View {
        Button {
            meeting = option
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color.wheelpGreen)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(profile.bodyFont.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if meeting == option {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.wheelpGreen)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .frame(minHeight: profile.controlMinHeight - 10)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityAddTraits(meeting == option ? .isSelected : [])
    }

    /// Nombre y coordenada del punto de encuentro elegido.
    private func resolvedMeeting() -> (String?, CLLocationCoordinate2D) {
        switch meeting {
        case .origin:
            ("Punto de partida del usuario", originCoordinate ?? destinationCoordinate)
        case .destination:
            (destinationName, destinationCoordinate)
        case .route:
            routeChoices.indices.contains(selectedRouteIndex)
                ? (routeChoices[selectedRouteIndex].title, routeChoices[selectedRouteIndex].coordinate)
                : (destinationName, destinationCoordinate)
        }
    }
}
