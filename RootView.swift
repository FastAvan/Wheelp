import SwiftUI

/// Enruta la app según el estado: Splash → Login → Onboarding → Home.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var showSplash = true

    var body: some View {
        Group {
            if showSplash {
                SplashView()
                    .task {
                        // Restaura la sesión (instantánea si está guardada) y
                        // muestra el logo solo lo justo para que no parpadee.
                        await appState.bootstrap()
                        try? await Task.sleep(for: .seconds(0.5))
                        withAnimation(.easeInOut(duration: 0.4)) { showSplash = false }
                    }
            } else if !appState.isSignedIn {
                LoginView()
            } else if !appState.hasCompletedOnboarding {
                OnboardingFlowView()
            } else {
                HomeView()
            }
        }
        .animation(.easeInOut, value: appState.isSignedIn)
        .animation(.easeInOut, value: appState.hasCompletedOnboarding)
        .onChange(of: appState.isSignedIn) { _, signedIn in
            if !signedIn { ChatNotifier.shared.stop() }
        }
    }
}

/// Pantalla inicial con el logo centrado.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            WheelpLogo(variant: .black)
                .frame(maxWidth: 220)
                .padding(40)
        }
    }
}
