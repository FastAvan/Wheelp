import Foundation

/// Monitoriza las solicitudes de ayudante pendientes para el admin.
/// Funciona igual que ChatNotifier: polling + notificación local cuando llegan solicitudes nuevas.
@MainActor
final class AdminNotifier {
    static let shared = AdminNotifier()

    private var pollTask: Task<Void, Never>?
    /// -1 = no inicializado (primera pasada solo aprende el estado actual, no notifica).
    private var knownCount = -1

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
        knownCount = -1
    }

    /// Comprobación puntual: se llama desde AppDelegate cuando llega un silent push.
    func checkOnce() async {
        await check()
    }

    private func check() async {
        let applications = await HelperService.fetchPendingApplications()
        let count = applications.count
        defer { knownCount = count }
        guard knownCount >= 0, count > knownCount else { return }
        let new = count - knownCount
        NotificationService.notify(
            title: "Wheelp: solicitud de ayudante",
            body: new == 1
                ? "Hay una nueva solicitud pendiente de revisión."
                : "Hay \(new) nuevas solicitudes pendientes de revisión."
        )
    }
}
