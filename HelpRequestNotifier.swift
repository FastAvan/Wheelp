import Foundation

/// Detecta solicitudes de ayuda nuevas para notificar al ayudante.
/// El push real lo dispara el backend (trigger `push_new_request` → `send-push` → APNs).
/// Este notifier responde al silent push en `AppDelegate` y muestra la notificación local.
/// El sondeo periódico es solo un fallback por si el push llega tarde o el sistema lo suprime.
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

    /// Comprobación puntual desde `AppDelegate` cuando llega el silent push del servidor.
    func checkOnce() async {
        await check()
    }

    private func check() async {
        // Sin filtro de ubicación en background: el backend ya restringió el push a helpers.
        // La distancia exacta la ve el ayudante al abrir HelperRequestsView.
        let requests = await HelperService.fetchPending(near: nil)
        let ids = Set(requests.map { $0.id })
        defer {
            knownIds = ids
            primed = true
        }
        guard primed else { return }
        let newCount = ids.subtracting(knownIds).count
        guard newCount > 0 else { return }
        NotificationService.notify(
            title: "Wheelp: nueva petición de ayuda",
            body: newCount == 1
                ? "Alguien cerca necesita ayuda. Ábrela para ver los detalles."
                : "\(newCount) nuevas peticiones de ayuda cerca de ti."
        )
    }
}
