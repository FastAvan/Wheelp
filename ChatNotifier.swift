import Foundation

/// Vigila los chats de ayuda del usuario mientras la app está en ejecución y
/// notifica los mensajes nuevos de la otra persona, salvo los del chat que
/// esté abierto en pantalla (ahí ya se ven llegar).
@MainActor
final class ChatNotifier {
    static let shared = ChatNotifier()

    /// Chat visible ahora mismo: sus mensajes no se notifican.
    var openChatRequestId: UUID?

    private var pollTask: Task<Void, Never>?
    private var knownIds: Set<UUID> = []
    /// La primera pasada solo aprende los mensajes ya existentes.
    private var primed = false
    private var myUserId: UUID?

    private init() {}

    /// Empieza a vigilar (una sola vez; las llamadas repetidas no hacen nada).
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            await NotificationService.requestPermission()
            myUserId = await HelperService.currentUserId()
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        knownIds = []
        primed = false
    }

    private func check() async {
        let messages = await HelperService.fetchRecentMessages()
        for message in messages {
            guard !knownIds.contains(message.id) else { continue }
            knownIds.insert(message.id)
            guard primed,
                  message.senderId != myUserId,
                  message.requestId != openChatRequestId else { continue }
            NotificationService.notify(
                title: message.senderName ?? "Nuevo mensaje",
                body: message.text
            )
        }
        primed = true
    }
}
