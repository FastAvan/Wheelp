import SwiftUI

/// Segunda capa de información del art. 13 RGPD: el resumen va en el registro y
/// en Ajustes, y el detalle vive aquí.
///
/// Va embebida en la app a propósito, no como enlace al navegador: una persona
/// ciega sin cobertura tiene el mismo derecho a leerla, y "ábrelo en la web" no
/// es una respuesta aceptable en una app de accesibilidad.
///
/// OJO: esto NO es la política de privacidad completa. Faltan los puntos que
/// dependen de terceros y de revisión jurídica —transferencias fuera del EEE,
/// encargados del art. 28, plazos de conservación— y la identidad del
/// responsable, bloqueada hasta constituir la SL. Ver docs/Inventario-de-datos.md.
struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PrivacyBlock(title: "Lo que se guarda en el servidor", content:
                        "Tu correo, para mantener tu cuenta.\n\nY una zona aproximada de unos dos kilómetros mientras tienes una petición de ayuda abierta, para encontrar ayudantes cerca. Esa zona se borra cuando la petición termina."
                    )

                    PrivacyBlock(title: "Lo que no sale de este iPhone", content:
                        "Tus favoritos, tu historial de rutas, el tipo de accesibilidad que has elegido y la navegación paso a paso.\n\nTu posición exacta se usa para guiarte, pero no se envía a ningún servidor de Wheelp."
                    )

                    PrivacyBlock(title: "Lo que Wheelp no puede leer", highlighted: true, content:
                        "El punto de encuentro y los mensajes con tu ayudante. Van cifrados de extremo a extremo y se borran al terminar."
                    )

                    PrivacyBlock(title: "Con quién se comparte", content:
                        "El destino que buscas se envía a Google Maps y a OpenStreetMap para calcular la ruta.\n\nSi tienes las notificaciones activadas, Apple recibe un identificador de tu dispositivo y el texto del aviso. Ese aviso nunca incluye información sobre tu discapacidad."
                    )

                    PrivacyBlock(title: "Si eres ayudante", content:
                        "Mientras tienes un turno activo, tu zona aproximada de unos dos kilómetros se actualiza en el servidor, también con la app cerrada. Se guarda solo la última zona conocida, sin historial de tus movimientos. Al terminar el turno deja de actualizarse.\n\nPara verificar tu identidad usamos Didit: tu documento se comprueba en tu propio dispositivo y no pasa por Wheelp.\n\nTu nombre y tu foto los ve la persona a la que ayudas."
                    )

                    PrivacyBlock(title: "Tus derechos", content:
                        "Puedes pedir acceso a tus datos, rectificarlos, borrarlos, llevártelos a otro servicio u oponerte a que se traten.\n\nPara borrarlo todo no hace falta que escribas a nadie: en Ajustes tienes «Eliminar mi cuenta».\n\nPara lo demás, escribe a hola@wheelp.app.\n\nSi crees que no hemos respetado tus derechos, puedes reclamar ante la Agencia Española de Protección de Datos, en aepd.es."
                    )
                }
                .padding(24)
            }
            .navigationTitle("Privacidad y datos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }
}

private struct PrivacyBlock: View {
    let title: String
    var highlighted: Bool = false
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(highlighted ? Color.wheelpGreen : .primary)
            Text(content)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Aviso de la primera activación de un turno de disponibilidad.
///
/// NO es una casilla de consentimiento, y el botón no dice "Acepto" a propósito:
/// la base jurídica es el art. 6.1.b) RGPD, ejecución del contrato. Sin saber en
/// qué zona estás no se te pueden asignar peticiones. Presentarlo como
/// consentimiento implicaría que se puede retirar manteniendo el servicio, y no
/// es el caso.
struct HelperShiftNoticeView: View {
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var tituloEnfocado: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Antes de activar tu primer turno")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($tituloEnfocado)

                    Text("Para poder avisarte de peticiones cercanas, Wheelp necesita saber en qué zona estás mientras tienes el turno activo. Conviene que sepas exactamente cómo funciona.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    PrivacyBlock(title: "Qué se comparte", content:
                        "Una zona aproximada de unos dos kilómetros. No tu calle, no tu portal, no tu posición exacta."
                    )
                    PrivacyBlock(title: "Cuándo", content:
                        "Solo mientras el turno está activo, y también con la app cerrada o en segundo plano. Tú eliges si el turno dura dos, cuatro u ocho horas. Al terminar, deja de compartirse."
                    )
                    PrivacyBlock(title: "Qué se guarda", content:
                        "Solo tu última zona conocida, que se sobrescribe cada vez. No hay historial de por dónde has pasado, ni ahora ni después."
                    )
                    PrivacyBlock(title: "Quién lo ve", content:
                        "Nadie ve tu zona en un mapa. El sistema la usa para decidir a qué ayudantes avisar de una petición cercana. La persona a la que ayudas ve tu nombre y tu foto solo cuando aceptas su petición."
                    )
                    PrivacyBlock(title: "Cortes automáticos", content:
                        "Ningún turno pasa de ocho horas. A las once de la noche se cierra, salvo que hayas declarado disponibilidad nocturna. Te avisaremos treinta minutos antes de que termine y cuando termine."
                    )
                    PrivacyBlock(title: "Cómo pararlo", content:
                        "Desactiva la disponibilidad en cualquier momento desde Ajustes. Si tu turno caduca, el servidor deja de considerarte disponible aunque la app no llegue a apagarlo."
                    )

                    Text("Compartir la zona durante el turno es necesario para ejercer como ayudante: sin ella no podemos asignarte peticiones. Si prefieres no compartirla, puedes seguir usando Wheelp como usuario.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        Button {
                            dismiss()
                            onAccept()
                        } label: {
                            Text("Entendido, activar turno")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.wheelpGreen)
                        .controlSize(.large)

                        Button("Ahora no") { dismiss() }
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { tituloEnfocado = true }
    }
}
