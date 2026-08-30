import Foundation

/// Mantiene el estado de solicitudes de ayuda del ayudante actualizado en background.
/// El backend envía un alert push directamente (send-push v4 con alert + content-available),
/// así que este notifier NO muestra notificaciones locales para evitar duplicados.
/// Solo actualiza el estado interno para que HelperRequestsView tenga datos frescos al abrirse.
@MainActor
final class HelpRequestNotifier {
    static let shared = HelpRequestNotifier()

    private var pollTask: Task<Void, Never>?
    private var knownIds: Set<UUID> = []
    /// false hasta completar la primera carga, para no notificar sobre solicitudes ya existentes.
    private var primed = false

    private init() {}

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        knownIds = []
        primed = false
    }

    /// Llamado desde `AppDelegate` cuando llega el push con content-available del servidor.
    /// Refresca el estado sin mostrar notificación (el backend ya envió el alert push).
    func checkOnce() async {
        await check()
    }

    private func check() async {
        // Ya no sondea. Antes pedía todas las peticiones pendientes y guardaba
        // sus ids, pero nadie los leía: el aviso al ayudante lo manda el
        // servidor (send-push) y la lista la carga HelperRequestsView al
        // abrirse. Era una llamada cada 30 s cuyo resultado se descartaba.
        //
        // Además, desde que el filtrado por distancia está en el servidor
        // (nearby_pending_requests) haría falta una ubicación para consultar,
        // y aquí no hay ninguna fiable: sondear sin ella devolvería vacío
        // siempre, dando la falsa impresión de que no hay peticiones.
        primed = true
    }
}
