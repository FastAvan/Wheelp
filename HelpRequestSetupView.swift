import SwiftUI
import MapKit

/// Página previa a pedir un ayudante: muestra el trayecto del usuario y le
/// pide elegir dónde quiere encontrarse con el ayudante (en el punto de
/// inicio, en el destino o en otro punto de la ruta). El usuario también puede
/// programar una cita para una fecha y hora concretas.
struct HelpRequestSetupView: View {
    let profile: AccessibilityProfile
    let destinationName: String
    let originCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D
    let steps: [MKRoute.Step]
    let onConfirm: (HelpRequest.MeetingPoint, String?, CLLocationCoordinate2D, Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var meeting: HelpRequest.MeetingPoint = .destination
    @State private var selectedRouteIndex = 0
    @State private var consentAccepted = false
    @State private var isScheduled = false
    @State private var scheduledDate: Date = Calendar.current.date(
        byAdding: .hour, value: 1, to: Date()
    ) ?? Date().addingTimeInterval(3600)

    private var minDate: Date { Date().addingTimeInterval(30 * 60) }
    private var maxDate: Date { Date().addingTimeInterval(7 * 24 * 3600) }

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
                // MARK: Trayecto
                Section("Tu trayecto") {
                    Label("Desde: tu ubicación actual", systemImage: "location.fill")
                        .font(profile.bodyFont)
                    Label("Hasta: \(destinationName)", systemImage: "mappin.and.ellipse")
                        .font(profile.bodyFont)
                }

                // MARK: Cuándo
                Section {
                    Picker("Cuándo", selection: $isScheduled) {
                        Text("Ahora").tag(false)
                        Text("Programar").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .font(profile.bodyFont)

                    if isScheduled {
                        DatePicker(
                            "Fecha y hora",
                            selection: $scheduledDate,
                            in: minDate...maxDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .font(profile.bodyFont)
                        .environment(\.locale, Locale(identifier: "es"))
                    }
                } header: {
                    Text("¿Cuándo necesitas al ayudante?")
                } footer: {
                    if isScheduled {
                        Text("El ayudante verá la cita con suficiente antelación. Recibirás un aviso cuando alguien la acepte.")
                    } else {
                        Text("Los ayudantes cercanos recibirán el aviso ahora mismo.")
                    }
                }

                // MARK: Punto de encuentro
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

                // MARK: Consentimiento
                Section {
                    Button {
                        consentAccepted.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: consentAccepted ? "checkmark.square.fill" : "square")
                                .font(.title3)
                                .foregroundStyle(Color.wheelpGreen)
                            Text("Acepto compartir mi nombre y las ubicaciones de este trayecto con los ayudantes cercanos, solo para esta petición.")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Consentimiento para compartir mi nombre y ubicación con los ayudantes")
                    .accessibilityAddTraits(consentAccepted ? .isSelected : [])
                } footer: {
                    Text("Sin tu consentimiento no se envía nada. El resto de tus datos nunca sale de tu iPhone.")
                }

                // MARK: Botón confirmar
                Section {
                    Button {
                        let (name, coordinate) = resolvedMeeting()
                        let date = isScheduled ? scheduledDate : nil
                        onConfirm(meeting, name, coordinate, date)
                        dismiss()
                    } label: {
                        Label(
                            isScheduled ? "Programar cita" : "Pedir ayudante",
                            systemImage: isScheduled ? "calendar.badge.clock" : "hand.raised.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.wheelpPrimary)
                    .frame(maxWidth: .infinity, minHeight: profile.controlMinHeight)
                    .disabled(!consentAccepted)
                    .opacity(consentAccepted ? 1 : 0.5)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle(isScheduled ? "Programar ayudante" : "Pedir ayudante")
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
