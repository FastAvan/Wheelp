
// ============================================================
// WHEELP — SwiftUI iOS App
// Arquitectura: NavigationStack + @StateObject + AVSpeechSynthesizer
// Target: iOS 17+ / iPhone
// ============================================================

import SwiftUI
import MapKit
import AVFoundation
import Combine

// MARK: - Color Palette
extension Color {
    static let wheelpGreen   = Color(red: 0.310, green: 0.722, blue: 0.282)
    static let wheelpBlack   = Color.black
    static let wheelpWhite   = Color.white
    static let wheelpGray    = Color(white: 0.95)
}

// MARK: - App State
enum DisabilityType: String, CaseIterable {
    case fisica   = "Física"
    case auditiva = "Auditiva"
    case visual   = "Visual"
}

class AppState: ObservableObject {
    @Published var hasDisability: Bool?        = nil
    @Published var disabilityType: DisabilityType? = nil
    @Published var setupComplete: Bool          = false
    @Published var microphoneGranted: Bool      = false
    @Published var currentScreen: AppScreen     = .splash
}

enum AppScreen {
    case splash
    case microphonePermission
    case onboardingQuestion
    case disabilityType
    case configuringA
    case configuringB
    case configDone
    case main
    case noRoute
    case volunteerETA
}

// MARK: - Speech Helper
class SpeechHelper: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-ES")
        utterance.rate  = 0.45
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

// MARK: - Root View
@main
struct WheelpApp: App {
    @State var auth = AuthManager()
    
    var body: some Scene {
        WindowGroup {
            if auth.isLoggedIn {
                MainMapView()
            } else {
                SignInView()
            }
        }
        .environment(auth)
    }
}


import CoreLocation
import AVFoundation

class PermissionsManager {
    static let shared = PermissionsManager()
    
    func requestAll(completion: @escaping () -> Void) {
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async {
                let manager = CLLocationManager()
                manager.requestWhenInUseAuthorization()
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                completion()
            }
        }
    }
}

struct RootView: View {
    @StateObject var appState   = AppState()
    @StateObject var speech     = SpeechHelper()

    var body: some View {
        Group {
            switch appState.currentScreen {
            case .splash:
                SplashView()
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            appState.currentScreen = .microphonePermission
                        }
                    }
            case .microphonePermission:
                MicrophonePermissionView()
            case .onboardingQuestion:
                OnboardingQuestionView()
            case .disabilityType:
                DisabilityTypeView()
            case .configuringA:
                ConfiguringAView()
            case .configuringB:
                ConfiguringBView()
            case .configDone:
                ConfigDoneView()
            case .main:
                MainMapView()
            case .noRoute:
                NoRouteView()
            case .volunteerETA:
                VolunteerETAView()
            }
        }
        .environmentObject(appState)
        .environmentObject(speech)
        .animation(.easeInOut(duration: 0.35), value: appState.currentScreen)
    }
}

// MARK: - Screen 1: Splash
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            WheelpLogo(colorScheme: .dark)
                .frame(width: 280)
        }
    }
}

// MARK: - Screen 2: Microphone Permission
struct MicrophonePermissionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Permiso para acceder al micrófono")
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text("Para ofrecer la mejor experiencia a todos los usuarios es necesario el uso del micrófono")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Divider()

                HStack(spacing: 0) {
                    Button("Rechazar") {
                        appState.microphoneGranted = false
                        appState.currentScreen     = .onboardingQuestion
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.blue)

                    Divider().frame(height: 20)

                    Button("Aceptar") {
                        AVAudioApplication.requestRecordPermission { granted in
                            DispatchQueue.main.async {
                                appState.microphoneGranted = granted
                                appState.currentScreen     = .onboardingQuestion
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.blue)
                    .fontWeight(.semibold)
                }
            }
            .padding(24)
            .background(Color.white)
            .cornerRadius(14)
            .padding(.horizontal, 40)
        }
    }
}

// MARK: - Screen 3: Onboarding Question
struct OnboardingQuestionView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var speech:   SpeechHelper

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                WheelpLogo(colorScheme: .dark)
                    .frame(width: 240)
                    .padding(.top, 16)

                Text("Esto se escuchará en alto")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .padding(.top, 24)

                Text("Hola, soy Wheelp.\nVoy a ayudarle\na configurar la app.")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.wheelpGreen)
                    .padding(.top, 12)

                Text("Lo primero de todo,\n¿tiene alguna\ndiscapacidad?")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.wheelpGreen)
                    .padding(.top, 24)

                Text("Puede responder en\nvoz alta o\ntocar la pantalla.")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.wheelpGreen)
                    .padding(.top, 24)

                Spacer()

                HStack(spacing: 24) {
                    BigButton(label: "SÍ") {
                        speech.stop()
                        appState.hasDisability   = true
                        appState.currentScreen   = .disabilityType
                    }
                    BigButton(label: "NO") {
                        speech.stop()
                        appState.hasDisability   = false
                        appState.currentScreen   = .configuringA
                    }
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            speech.speak("Hola, soy Wheelp. Voy a ayudarle a configurar la app. Lo primero de todo, ¿tiene alguna discapacidad? Puede responder en voz alta o tocar la pantalla.")
        }
    }
}

// MARK: - Screen 4: Disability Type
struct DisabilityTypeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var speech:   SpeechHelper

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                WheelpLogo(colorScheme: .dark)
                    .frame(width: 240)
                    .padding(.top, 16)

                Text("¿Qué tipo de\ndiscapacidad tiene?")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.wheelpGreen)
                    .multilineTextAlignment(.center)
                    .padding(.top, 40)

                VStack(spacing: 16) {
                    ForEach(DisabilityType.allCases, id: \.self) { type in
                        Button(action: {
                            speech.stop()
                            appState.disabilityType  = type
                            appState.currentScreen   = .configuringA
                        }) {
                            Text(type.rawValue)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Color.wheelpGreen)
                                .cornerRadius(50)
                        }
                    }
                }
                .padding(.top, 40)
                .padding(.horizontal, 32)

                Spacer()
            }
        }
        .onAppear {
            speech.speak("¿Qué tipo de discapacidad tiene? Física, Auditiva o Visual.")
        }
    }
}

// MARK: - Screen 5: Configuring A
struct ConfiguringAView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.wheelpGreen.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                WheelpLogo(colorScheme: .light)
                    .frame(width: 220)
                    .padding(.top, 16)

                Spacer()

                Text("Estamos configurando\nla aplicación para\nusted.")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.bottom, 60)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                appState.currentScreen = .configuringB
            }
        }
    }
}

// MARK: - Screen 6: Configuring B
struct ConfiguringBView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.wheelpGreen.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                WheelpLogo(colorScheme: .light)
                    .frame(width: 220)
                    .padding(.top, 16)

                Spacer()

                Text("Usando la información que nos ha dado, vamos a ofrecerle la forma más rápida de llegar a sus destinos escogiendo los caminos que mejor se adapten a sus necesidades")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white)
                    .padding(.bottom, 60)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                appState.currentScreen = .configDone
            }
        }
    }
}

// MARK: - Screen 7: Config Done
struct ConfigDoneView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var speech:   SpeechHelper

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                WheelpLogo(colorScheme: .dark)
                    .frame(width: 240)
                    .padding(.top, 16)

                Spacer()

                Text("La aplicación ya está configurada y preparada para que la use.")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.wheelpGreen)
                    .padding(.bottom, 80)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            speech.speak("La aplicación ya está configurada y preparada para que la use.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                appState.setupComplete   = true
                appState.currentScreen   = .main
            }
        }
    }
}


// MARK: - Screen 8: Main Map View
struct MainMapView: View {
    @EnvironmentObject var appState: AppState
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var searchText = ""
    @State private var showSheet  = true

    // Mock favorites
    let favorites: [(String, String, String)] = [
        ("house.fill", "Casa",    "Calle Lagasca, 87"),
        ("briefcase.fill", "Trabajo", "Alberto Aguilera, 23"),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position)
                .ignoresSafeArea()

            // Top bar
            HStack {
                Button(action: {}) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.black)
                }
                Spacer()
                WheelpLogo(colorScheme: .dark)
                    .frame(width: 140)
                Spacer()
                Color.clear.frame(width: 22)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // Bottom sheet
            VStack(spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    // Drag handle
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 40, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        TextField("Search Maps", text: $searchText)
                        Spacer()
                        Image("user-avatar")
                            .resizable()
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.gray.opacity(0.3)))
                    }
                    .padding(12)
                    .background(Color.wheelpGray)
                    .cornerRadius(12)
                    .padding(.horizontal, 16)

                    // Siri suggestions
                    Text("Siri Suggestions")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dentista")
                                .font(.system(size: 16, weight: .medium))
                            Text("Calle de Diego de León, 59")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .onTapGesture { appState.currentScreen = .noRoute }

                    // Favorites
                    HStack {
                        Text("Favoritos")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("More") {}
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(favorites, id: \.1) { fav in
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.wheelpGray)
                                            .frame(width: 56, height: 56)
                                        Image(systemName: fav.0)
                                            .foregroundColor(.blue)
                                            .font(.system(size: 22))
                                    }
                                    Text(fav.1)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(fav.2)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 80)
                                }
                            }
                            // Add button
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(Color.wheelpGray)
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "plus")
                                        .foregroundColor(.primary)
                                        .font(.system(size: 22))
                                }
                                Text("Add")
                                    .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .padding(.bottom, 20)
                }
                .background(Color.white)
                .cornerRadius(16, corners: [.topLeft, .topRight])
                .shadow(color: .black.opacity(0.1), radius: 8, y: -2)
            }
        }
    }
}

// MARK: - Screen 9: No Accessible Route
struct NoRouteView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var speech:   SpeechHelper

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                WheelpLogo(colorScheme: .dark)
                    .frame(width: 200)
                    .padding(.top, 16)

                Spacer()

                Text("DENTISTA\nCalle de Diego de\nLeón, 59")
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("Este destino actualmente no dispone de una ruta accesible.")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.wheelpGreen)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                Spacer()

                VStack(spacing: 16) {
                    Button(action: {
                        speech.stop()
                        appState.currentScreen = .volunteerETA
                    }) {
                        Text("Contactar con un voluntario")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color.wheelpGreen)
                            .cornerRadius(50)
                    }

                    Button("No, gracias") {
                        appState.currentScreen = .main
                    }
                    .foregroundColor(.wheelpGreen)
                    .font(.system(size: 16))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            speech.speak("Este destino actualmente no dispone de una ruta accesible. ¿Desea contactar con un voluntario?")
        }
    }
}

// MARK: - Screen 10: Volunteer ETA
struct VolunteerETAView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var speech:   SpeechHelper
    @State private var minutes = 5

    var body: some View {
        ZStack {
            Color.wheelpGreen.ignoresSafeArea()

            VStack(spacing: 0) {
                WheelpLogo(colorScheme: .light)
                    .frame(width: 200)
                    .padding(.top, 16)

                Spacer()

                // Volunteer avatar
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 110, height: 110)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                    )

                Text("Tomás García, 25 años")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 20)

                Text("Llega en:")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .padding(.top, 12)

                Text("\(minutes)")
                    .font(.system(size: 100, weight: .bold))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())

                Text("Minutos")
                    .font(.system(size: 20))
                    .foregroundColor(.white)

                Spacer()

                HStack(spacing: 80) {
                    Button(action: {}) {
                        Image(systemName: "phone")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                    Button(action: {}) {
                        Image(systemName: "message")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            speech.speak("Tomás García llegará en \(minutes) minutos.")
            // Count down simulation
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                if minutes > 0 { minutes -= 1 } else { timer.invalidate() }
            }
        }
    }
}

// MARK: - Reusable Components

struct WheelpLogo: View {
    enum ColorScheme { case dark, light }
    let colorScheme: ColorScheme

    private var fg: Color { colorScheme == .dark ? .white : .white }
    private var bg: Color { colorScheme == .dark ? .black : .white }
    private var textColor: Color { colorScheme == .dark ? .black : Color.wheelpGreen }

    var body: some View {
        HStack(spacing: 0) {
            // "W"
            Text("W")
                .font(.system(size: 28, weight: .black, design: .default))
                .foregroundColor(bg == .black ? .white : .black)

            // "HE" circle
            ZStack {
                Circle().fill(bg == .black ? Color.black : Color.black)
                Text("HE")
                    .font(.system(size: 22, weight: .black))
                    .foregroundColor(.white)
            }
            .frame(width: 52, height: 52)

            // "E"
            Text("E")
                .font(.system(size: 28, weight: .black))
                .foregroundColor(bg == .black ? .white : .black)

            // "LP" circle
            ZStack {
                Circle().fill(bg == .black ? Color.black : Color.black)
                Text("LP")
                    .font(.system(size: 22, weight: .black))
                    .foregroundColor(.white)
            }
            .frame(width: 52, height: 52)
        }
    }
}

struct BigButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 100, height: 100)
                .background(Color.wheelpGreen)
                .clipShape(Circle())
        }
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
