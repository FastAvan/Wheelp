import SwiftUI
import MapKit

/// Configuración de presentación y preferencias de ruta derivada del tipo de
/// discapacidad. Es la pieza que permite que una misma pantalla se adapte a cada
/// "versión" de la app (Física / Auditiva / Visual / Estándar).
struct AccessibilityProfile {
    let type: DisabilityType

    /// Texto más grande en toda la interfaz.
    var largeText: Bool
    /// Mayor contraste en elementos clave (grosor de ruta, colores).
    var highContrast: Bool
    /// Guía hablada (pendiente de integrar voz; reservamos el flag).
    var voiceGuidance: Bool
    /// Pistas hápticas/visuales en lugar de sonido.
    var hapticCues: Bool
    /// Objetivos táctiles más grandes y separados.
    var largeTouchTargets: Bool
    /// Modo de transporte usado al calcular la ruta.
    var transportType: MKDirectionsTransportType
    /// Explicación de las preferencias de ruta aplicadas para esta versión.
    var routeNote: String

    static func make(for type: DisabilityType) -> AccessibilityProfile {
        switch type {
        case .physical:
            AccessibilityProfile(
                type: type,
                largeText: true,
                highContrast: false,
                voiceGuidance: false,
                hapticCues: false,
                largeTouchTargets: true,
                transportType: .walking,
                routeNote: "Ruta a pie accesible, evitando escaleras siempre que es posible."
            )
        case .visual:
            AccessibilityProfile(
                type: type,
                largeText: true,
                highContrast: true,
                voiceGuidance: true,
                hapticCues: false,
                largeTouchTargets: true,
                transportType: .walking,
                routeNote: "Guía por voz y alto contraste activados."
            )
        case .hearing:
            AccessibilityProfile(
                type: type,
                largeText: false,
                highContrast: false,
                voiceGuidance: false,
                hapticCues: true,
                largeTouchTargets: false,
                transportType: .walking,
                routeNote: "Avisos visuales y vibración en cada indicación."
            )
        case .none:
            AccessibilityProfile(
                type: type,
                largeText: false,
                highContrast: false,
                voiceGuidance: false,
                hapticCues: false,
                largeTouchTargets: false,
                transportType: .walking,
                routeNote: "Ruta a pie estándar."
            )
        }
    }

    // MARK: - Helpers de presentación

    /// Altura mínima recomendada para controles táctiles.
    var controlMinHeight: CGFloat { largeTouchTargets ? 60 : 50 }

    /// Grosor de la línea de la ruta sobre el mapa.
    var routeLineWidth: CGFloat { highContrast ? 10 : 7 }

    /// Fuente para textos principales (títulos de tarjeta).
    var titleFont: Font { largeText ? .title2.bold() : .headline }

    /// Fuente para texto de cuerpo (más peso en alto contraste).
    var bodyFont: Font {
        let base: Font = largeText ? .body : .subheadline
        return highContrast ? base.weight(.semibold) : base
    }
}
