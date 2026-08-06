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
        let requests = await HelperService.fetchPending(near: nil)
        let ids = Set(requests.map { $0.id })
        knownIds = ids
        primed = true
    }
}
