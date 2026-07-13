import Foundation
import CoreLocation

/// Ritmo de marcha personalizado: aprende la velocidad real del usuario
/// mientras navega y la usa para estimar tiempos de llegada.
/// Todo se guarda únicamente en el dispositivo (UserDefaults).
enum WalkingPaceService {
    private static let speedKey = "wheelp.pace.speed"     // m/s, media ponderada
    private static let secondsKey = "wheelp.pace.seconds" // segundos de marcha medidos

    /// Velocidades típicas por versión hasta tener datos propios (m/s).
    static func defaultSpeed(for type: DisabilityType) -> Double {
        switch type {
        case .physical: 0.9
        case .visual: 1.0
        case .hearing: 1.3
        case .none: 1.35
        }
    }

    /// Segundos de marcha real acumulados.
    static var learnedSeconds: Double {
        UserDefaults.standard.double(forKey: secondsKey)
    }

    /// Con al menos 3 minutos medidos, el ritmo propio ya es fiable.
    static var hasReliablePace: Bool { learnedSeconds >= 180 }

    /// Velocidad aprendida (m/s), si hay alguna muestra.
    static var learnedSpeed: Double? {
        let speed = UserDefaults.standard.double(forKey: speedKey)
        return speed > 0 ? speed : nil
    }

    /// Velocidad a usar en estimaciones: la aprendida si es fiable; si no,
    /// la típica de la versión.
    static func speed(for type: DisabilityType) -> Double {
        if hasReliablePace, let learnedSpeed { return learnedSpeed }
        return defaultSpeed(for: type)
    }

    /// Tiempo estimado al ritmo del usuario para una distancia.
    static func estimatedTime(distance: CLLocationDistance, type: DisabilityType) -> TimeInterval {
        max(distance, 0) / speed(for: type)
    }

    /// Tiempo estimado con la velocidad típica de una versión, sin usar el
    /// ritmo aprendido en este dispositivo (para peticiones de OTRA persona,
    /// p. ej. lo que ve el ayudante).
    static func defaultEstimatedTime(distance: CLLocationDistance, type: DisabilityType) -> TimeInterval {
        max(distance, 0) / defaultSpeed(for: type)
    }

    /// Registra un tramo caminado durante la navegación.
    /// Se descartan tramos poco fiables: demasiado cortos/largos en tiempo o
    /// con velocidades que no son de marcha (parado, vehículo, saltos de GPS).
    static func record(distance: CLLocationDistance, duration: TimeInterval) {
        guard duration >= 2, duration <= 60 else { return }
        let speed = distance / duration
        guard speed >= 0.2, speed <= 2.5 else { return }

        let defaults = UserDefaults.standard
        let previous = defaults.double(forKey: speedKey)
        let seconds = defaults.double(forKey: secondsKey)
        // Media ponderada por tiempo; el peso del pasado se limita a 30 min
        // para que el ritmo siga adaptándose (fatiga, cambios de temporada…).
        let weight = min(seconds, 1800)
        let updated = previous > 0
            ? (previous * weight + speed * duration) / (weight + duration)
            : speed
        defaults.set(updated, forKey: speedKey)
        defaults.set(seconds + duration, forKey: secondsKey)
    }

    /// Olvida el ritmo aprendido (vuelve a las velocidades típicas).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: speedKey)
        UserDefaults.standard.removeObject(forKey: secondsKey)
    }

    /// Texto del ritmo actual, p. ej. "12 min por kilómetro".
    static func paceDescription(for type: DisabilityType) -> String {
        let minutesPerKm = 1000 / speed(for: type) / 60
        return "\(Int(minutesPerKm.rounded())) min por kilómetro"
    }
}
