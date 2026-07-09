import SwiftUI

/// Pantalla principal tras el onboarding.
/// Presenta el mapa compartido configurado con el perfil de accesibilidad
/// correspondiente a la "versión" elegida (Física / Auditiva / Visual / Estándar).
struct HomeView: View {
    @Environment(AppState.self) private var appState

    private var profile: AccessibilityProfile {
        .make(for: appState.disabilityType ?? .none)
    }

    var body: some View {
        Group {
            // La versión Visual usa una interfaz por voz; el resto, el mapa.
            if profile.type == .visual {
                VoiceHomeView(profile: profile)
            } else {
                MapHomeView(profile: profile)
            }
        }
        // Recrea la pantalla al cambiar de versión para reaplicar voz/contraste.
        .id(appState.disabilityType)
        // Avisa de mensajes nuevos del chat de ayuda mientras la app está abierta.
        .task { ChatNotifier.shared.start() }
    }
}
