import Foundation
import CoreLocation

/// Aprende la velocidad real de marcha del usuario durante la navegación
/// y la usa para estimar tiempos de viaje personalizados.
///
/// Todo se guarda en UserDefaults (local, privado) y nunca sale del dispositivo.
enum WalkingPaceService {

    // Velocidades por defecto (m/s) para cuando aún no hay datos suficientes.
    private static let defaults: [DisabilityType: Double] = [
        .physical: 0.9,
        .visual:   1.0,
        .hearing:  1.3,
        .none:     1.35
    ]

    private static let speedKey   = "wheelp.pace.speed"
    private static let secondsKey = "wheelp.pace.seconds"

    /// Velocidad aprendida (m/s); nil si todavía no hay datos fiables.
    static var learnedSpeed: Double? {
        let v = UserDefaults.standard.double(forKey: speedKey)
        return v > 0 && learnedSeconds >= 180 ? v : nil
    }

    /// Segundos de marcha medidos en total.
    static var learnedSeconds: Double {
        UserDefaults.standard.double(forKey: secondsKey)
    }

    /// ¿Hay suficiente historial para confiar en el ritmo aprendido?
    static var hasReliablePace: Bool { learnedSeconds >= 180 }

    /// Descripción textual del ritmo actual para mostrarlo en Ajustes (min:ss / km).
    static func paceDescription(for type: DisabilityType) -> String {
        if let speed = learnedSpeed {
            return "\(minPerKm(speed)) (aprendido)"
        }
        return "\(minPerKm(defaults[type] ?? 1.0)) (estimado)"
    }

    private static func minPerKm(_ speedMs: Double) -> String {
        let secPerKm = 1000.0 / speedMs
        let mins = Int(secPerKm / 60)
        let secs = Int(secPerKm.truncatingRemainder(dividingBy: 60))
        return String(format: "%d:%02d min/km", mins, secs)
    }

    /// Registra un tramo recorrido durante la navegación.
    /// Usa una media ponderada exponencial, descartando velocidades irreales.
    static func record(distance: CLLocationDistance, duration: TimeInterval) {
        guard duration > 1, distance > 1 else { return }
        let speed = distance / duration
        guard speed >= 0.3, speed <= 3.0 else { return }

        let prevSpeed   = UserDefaults.standard.double(forKey: speedKey)
        let prevSeconds = learnedSeconds

        let newSeconds = min(prevSeconds + duration, 1800) // tope 30 min de historial
        let weight     = duration / newSeconds
        let newSpeed   = prevSpeed > 0
            ? prevSpeed * (1 - weight) + speed * weight
            : speed

        UserDefaults.standard.set(newSpeed,   forKey: speedKey)
        UserDefaults.standard.set(newSeconds, forKey: secondsKey)
    }

    /// Velocidad efectiva del usuario para el tipo de discapacidad dado.
    static func speed(for type: DisabilityType) -> Double {
        learnedSpeed ?? defaults[type] ?? 1.0
    }

    /// Tiempo estimado para el usuario (ritmo aprendido o por defecto).
    static func estimatedTime(distance: CLLocationDistance, type: DisabilityType) -> TimeInterval {
        distance / speed(for: type)
    }

    /// Tiempo estimado para OTRA persona (sin datos propios → usa el por defecto).
    static func defaultEstimatedTime(distance: CLLocationDistance, type: DisabilityType) -> TimeInterval {
        distance / (defaults[type] ?? 1.0)
    }

    /// Borra el historial aprendido.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: speedKey)
        UserDefaults.standard.removeObject(forKey: secondsKey)
    }
}
