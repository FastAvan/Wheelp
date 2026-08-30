import SwiftUI

/// Términos y condiciones de uso de Wheelp.
/// Puede presentarse de forma informativa (sin onAccept) o como paso de registro
/// (con onAccept: la confirmación marca el toggle de consentimiento en LoginView).
struct TermsView: View {
    var onAccept: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Última actualización: julio de 2026")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TermsSection(title: "1. Alcance del servicio", content:
                        "Wheelp es una aplicación de movilidad adaptada que conecta a personas con discapacidad o movilidad reducida con voluntarios (ayudantes) para acompañarles durante un trayecto o desplazamiento concreto.\n\nEl servicio de Wheelp consiste exclusivamente en:\n• Calcular rutas accesibles entre dos puntos.\n• Facilitar el contacto con un ayudante voluntario que acompañe físicamente al usuario durante ese trayecto."
                    )

                    TermsSection(title: "2. Lo que Wheelp NO es", highlighted: true, content:
                        "Wheelp NO es, en ningún caso:\n• Un servicio de asistencia en el hogar.\n• Un servicio de cuidados personales, higiene o enfermería.\n• Un servicio de cuidado de mayores o personas dependientes.\n• Un servicio de transporte (el ayudante no conduce vehículos).\n• Un servicio de urgencias o emergencias médicas.\n• Un sustituto de los servicios sociales, sanitarios o de emergencias.\n\nSi en cualquier momento necesitas ayuda urgente, llama al 112."
                    )

                    TermsSection(title: "3. Los ayudantes de Wheelp", content:
                        "Los ayudantes son voluntarios que ofrecen su tiempo de forma libre y gratuita. No son profesionales de la salud, empleados de Wheelp ni cuidadores remunerados. Wheelp no garantiza la disponibilidad de ayudantes en todo momento ni en todas las zonas.\n\nEl uso del servicio de ayudantes para fines distintos al acompañamiento en trayectos está expresamente prohibido y puede dar lugar a la suspensión de la cuenta."
                    )

                    TermsSection(title: "4. Privacidad y cifrado", content:
                        "Las solicitudes de ayuda y los mensajes se transmiten cifrados de extremo a extremo: Wheelp no puede leer su contenido, y el punto de encuentro viaja dentro de ese cifrado.\n\nEn el servidor se guardan tu correo, para mantener la cuenta, y zonas aproximadas de unos dos kilómetros: la de una petición mientras está abierta, y la de un ayudante mientras tiene un turno activo. Tu posición exacta se usa para guiarte, pero no se envía a ningún servidor de Wheelp.\n\nTienes el detalle completo en Ajustes, en «Privacidad y tus derechos»."
                    )

                    TermsSection(title: "5. Responsabilidad", content:
                        "Wheelp actúa como plataforma de conexión entre usuarios y voluntarios. No asume responsabilidad por las acciones u omisiones de los ayudantes ni por incidencias ocurridas durante un trayecto. El usuario utiliza el servicio bajo su propia responsabilidad."
                    )

                    TermsSection(title: "6. Edad mínima", content:
                        "Para registrarse en Wheelp es necesario tener 16 años o más. Los menores de 16 años necesitan el consentimiento expreso de su tutor o tutora legal."
                    )

                    TermsSection(title: "7. Eliminación de cuenta", content:
                        "Puedes eliminar tu cuenta en cualquier momento desde Ajustes → Eliminar mi cuenta. Se borrarán todos tus datos de nuestros servidores y del dispositivo de forma permanente e irreversible."
                    )

                    TermsSection(title: "8. Contacto", content:
                        "Para cualquier consulta relacionada con estos términos o el tratamiento de datos, ponte en contacto con el equipo de Wheelp a través de los canales oficiales de la aplicación."
                    )
                }
                .padding(20)
            }
            .navigationTitle("Términos y condiciones")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if onAccept != nil {
                        Button("Aceptar") {
                            onAccept?()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.wheelpGreen)
                    } else {
                        Button("Cerrar") { dismiss() }
                    }
                }
            }
        }
    }
}

private struct TermsSection: View {
    let title: String
    var highlighted: Bool = false
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(highlighted ? .orange : .primary)
            Text(content)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(highlighted ? 14 : 0)
        .background(
            highlighted ? Color.orange.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}
