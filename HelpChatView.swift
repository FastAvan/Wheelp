import SwiftUI

/// Chat entre el solicitante y su ayudante para una petición aceptada.
/// Los mensajes se refrescan por sondeo mientras el chat está abierto, y
/// se notifica localmente si llega un mensaje del otro.
struct HelpChatView: View {
    let request: HelpRequest
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [HelpMessage] = []
    @State private var draft = ""
    @State private var myUserId: UUID?
    @State private var isLoading = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if isLoading && messages.isEmpty {
                                ProgressView().padding(.top, 40)
                            } else if messages.isEmpty {
                                Text("Escribe el primer mensaje para coordinaros.")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 40)
                            }
                            ForEach(messages) { message in
                                bubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.last?.id) { _, lastId in
                        if let lastId {
                            withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    TextField("Mensaje…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                        .focused($inputFocused)

                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.wheelpGreen)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Enviar mensaje")
                }
                .padding(12)
            }
            .navigationTitle(chatTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task {
                // Con el chat a la vista, sus mensajes no generan notificación.
                ChatNotifier.shared.openChatRequestId = request.id
                myUserId = await HelperService.currentUserId()
                await pollLoop()
            }
            .onDisappear {
                if ChatNotifier.shared.openChatRequestId == request.id {
                    ChatNotifier.shared.openChatRequestId = nil
                }
            }
        }
    }

    private var chatTitle: String {
        if myUserId == request.helperId {
            return request.requesterName ?? "Chat"
        }
        return request.helperName ?? "Chat"
    }

    private func isMine(_ message: HelpMessage) -> Bool {
        guard let myUserId, let senderId = message.senderId else { return false }
        return myUserId == senderId
    }

    private func bubble(_ message: HelpMessage) -> some View {
        HStack {
            if isMine(message) { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                if !isMine(message) {
                    Text(chatTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(message.text ?? "🔒 Mensaje cifrado")
                    .font(.body)
                    .foregroundStyle(isMine(message) ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isMine(message) ? Color.wheelpGreen : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
            }
            if !isMine(message) { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine(message) ? "Tú" : chatTitle): \(message.text ?? "mensaje cifrado")")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            // El texto viaja cifrado; el nombre ya se intercambió cifrado al aceptar.
            await HelperService.sendMessage(request: request, text: text)
            draft = ""
            await refresh()
        }
    }

    private func refresh() async {
        // Con el chat abierto no se notifica: los mensajes se ven llegar.
        // Fuera del chat avisa ChatNotifier.
        messages = await HelperService.fetchMessages(request: request)
        isLoading = false
    }

    /// Refresca cada 3 s mientras el chat está abierto.
    private func pollLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            await refresh()
        }
    }
}
