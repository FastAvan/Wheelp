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
        [
            "Estamos configurando la aplicación para usted.",
            "Usando la información que nos ha dado, vamos a ofrecerte la forma más rápida de llegar a tus destinos, escogiendo los caminos que mejor se adapten a sus necesidades.",
            "La aplicación ya está configurada y preparada para que la use."
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
