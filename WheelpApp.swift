import SwiftUI

@main
struct WheelpApp: App {
    /// Estado global de la app (sesión, onboarding y tipo de discapacidad).
    @State private var appState = AppState()

    init() {
        NotificationService.setUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}
