import SwiftUI
import MessageUI

/// Botón de emergencia SOS: llama al 112 o envía mensaje al contacto de confianza.
/// Visible durante cualquier sesión activa (navegación o ayudante).
struct SOSButton: View {
    let meetingDescription: String
    let trustedPhone: String
    @State private var showOptions = false
    @State private var showComposer = false

    var body: some View {
        Button { showOptions = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("SOS")
            }
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.red, in: Capsule())
            .shadow(radius: 3, y: 2)
        }
        .accessibilityLabel("Emergencia SOS. Pulsa para llamar al 112 o avisar a tu contacto.")
        .confirmationDialog("¿Qué necesitas?", isPresented: $showOptions, titleVisibility: .visible) {
            Button("Llamar al 112", role: .destructive) {
                if let url = URL(string: "tel://112") {
                    UIApplication.shared.open(url)
                }
            }
            if !trustedPhone.isEmpty, MFMessageComposeViewController.canSendText() {
                Button("Avisar a mi contacto de confianza") { showComposer = true }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .sheet(isPresented: $showComposer) {
            MessageComposerView(recipients: [trustedPhone], body: emergencyMessage)
        }
    }

    private var emergencyMessage: String {
        "WHEELP: Estoy con mi ayudante. \(meetingDescription). Por favor, contacta conmigo si no tienes noticias."
    }
}

/// Wrapper de MFMessageComposeViewController para SwiftUI.
/// Usado para SOS y para el aviso de inicio de sesión al contacto de confianza.
struct MessageComposerView: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) { dismiss() }
    }
}
