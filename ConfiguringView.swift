import SwiftUI

/// Pantallas verdes que "configuran" la app según la discapacidad elegida.
/// Lee cada mensaje en voz alta, avanza sola y entra en la app directamente
/// tras el último mensaje (sin botón).
struct ConfiguringView: View {
    let disability: DisabilityType
    let onFinish: () -> Void

    @Environment(AppState.self) private var appState
    @State private var page = 0
    @State private var speech = SpeechAnnouncer()

    private var pages: [String] {
        let specific: String
        switch disability {
        case .physical:
            specific = "Hemos activado la versión de movilidad reducida: la app buscará rutas sin escaleras ni bordillos, te avisará de obstáculos en el camino y el mapa puede orientarse según tu dirección de marcha."
        case .hearing:
            specific = "Hemos activado la versión auditiva: cada indicación de ruta llega por pantalla y con vibración. No dependerás del audio para llegar a tu destino."
        case .visual:
            specific = "Hemos activado el control por voz: di el destino y navega manos libres. Wheelp te guiará hablando y puedes preguntar dónde estás en cualquier momento."
        case .none:
            specific = appState.isHelper
                ? "Tu versión de ayudante está lista. Verás las peticiones cercanas en el botón de la mano y podrás atenderlas directamente desde el mapa."
                : "La app está lista. Si en algún momento decides solicitar ser ayudante, puedes hacerlo desde Ajustes."
        }
        return [
            "Estamos configurando la aplicación para usted.",
            specific,
            "¡Todo listo! Ya puedes empezar."
        ]
    }

    var body: some View {
        ZStack {
            Color.wheelpGreen.ignoresSafeArea()

            VStack(spacing: 0) {
                WheelpLogo(variant: .white)
                    .frame(maxWidth: 200)
                    .padding(.top, 24)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        ConfiguringPage(
                            text: pages[index],
                            showLoader: index < pages.count - 1
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
        }
        .task {
            speech.isEnabled = true
            speech.rate = Float(appState.voiceRate)
            // Lee cada mensaje, avanza al terminar y lanza la app tras el último.
            for index in pages.indices {
                if index > 0 { withAnimation { page = index } }
                await read(pages[index])
            }
            onFinish()
        }
    }

    /// Lee el texto en voz alta y garantiza un tiempo mínimo por pantalla
    /// (con VoiceOver la voz propia se calla, pero la pantalla no corre).
    private func read(_ text: String) async {
        let start = Date()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            speech.announce(text) { continuation.resume() }
        }
        let remaining = 1.8 - Date().timeIntervalSince(start)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
    }
}

private struct ConfiguringPage: View {
    let text: String
    let showLoader: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text(text)
                .font(.title2.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if showLoader {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
    }
}
