
// ============================================================
// WHEELP — Auth Flow (Sign In + Sign Up + Biometrics)
// Añade este archivo como AuthViews.swift en tu proyecto Xcode
// ============================================================

import SwiftUI
import LocalAuthentication

// MARK: - Auth State Manager
@Observable
class AuthManager {
    var isLoggedIn: Bool = false
    var currentUser: WheelpUser? = nil
    var biometricsEnabled: Bool = UserDefaults.standard.bool(forKey: "biometricsEnabled")

    // Simulated user store — reemplazar con backend real (Firebase, Supabase, etc.)
    private var users: [String: WheelpUser] = [:]

    var biometricType: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return "none" }
        return context.biometryType == .faceID ? "Face ID" : "Touch ID"
    }

    func signIn(username: String, password: String) -> AuthResult {
        guard !username.isEmpty, !password.isEmpty else { return .emptyFields }
        guard let user = users[username.lowercased()], user.password == password else { return .wrongCredentials }
        currentUser = user
        isLoggedIn = true
        return .success
    }

    func signUp(firstName: String, lastName: String, email: String, username: String, password: String) -> AuthResult {
        guard !firstName.isEmpty, !lastName.isEmpty, !email.isEmpty, !username.isEmpty, !password.isEmpty else { return .emptyFields }
        guard email.contains("@") else { return .invalidEmail }
        guard password.count >= 6 else { return .weakPassword }
        guard users[username.lowercased()] == nil else { return .usernameTaken }

        let newUser = WheelpUser(firstName: firstName, lastName: lastName, email: email, username: username, password: password)
        users[username.lowercased()] = newUser
        currentUser = newUser
        isLoggedIn = true
        return .success
    }

    func authenticateWithBiometrics(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                localizedReason: "Accede a Wheelp rápidamente") { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    func enableBiometrics(completion: @escaping (Bool) -> Void) {
        authenticateWithBiometrics { success in
            if success {
                self.biometricsEnabled = true
                UserDefaults.standard.set(true, forKey: "biometricsEnabled")
            }
            completion(success)
        }
    }
}

struct WheelpUser {
    let firstName: String
    let lastName: String
    let email: String
    let username: String
    let password: String
}

enum AuthResult {
    case success, emptyFields, wrongCredentials, invalidEmail, weakPassword, usernameTaken

    var message: String {
        switch self {
        case .success:           return ""
        case .emptyFields:       return "Por favor rellena todos los campos"
        case .wrongCredentials:  return "Usuario o contraseña incorrectos"
        case .invalidEmail:      return "El correo electrónico no es válido"
        case .weakPassword:      return "La contraseña debe tener al menos 6 caracteres"
        case .usernameTaken:     return "Ese nombre de usuario ya está en uso"
        }
    }
}

// MARK: - Sign In View
struct SignInView: View {
    @Environment(AuthManager.self) var auth
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var showSignUp = false
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Logo
                    WheelpLogoView()
                        .padding(.top, 80)
                        .padding(.bottom, 60)

                    // Form card
                    VStack(spacing: 0) {
                        WheelpTextField(
                            placeholder: "Nombre de usuario",
                            text: $username,
                            icon: "person"
                        )

                        Divider().padding(.horizontal, 20)

                        WheelpSecureField(
                            placeholder: "Contraseña",
                            text: $password,
                            icon: "lock"
                        )
                    }
                    .background(Color(white: 0.97))
                    .cornerRadius(16)
                    .padding(.horizontal, 24)

                    // Error
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .padding(.top, 12)
                            .padding(.horizontal, 24)
                    }

                    // Sign In button
                    Button(action: handleSignIn) {
                        Group {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Iniciar sesión")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.wheelpGreen)
                        .cornerRadius(50)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                    // Biometrics button
                    if auth.biometricsEnabled && auth.biometricType != "none" {
                        Button(action: handleBiometrics) {
                            HStack(spacing: 10) {
                                Image(systemName: auth.biometricType == "Face ID" ? "faceid" : "touchid")
                                    .font(.system(size: 22))
                                Text("Acceder con \(auth.biometricType)")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .foregroundColor(.wheelpGreen)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .overlay(
                                RoundedRectangle(cornerRadius: 50)
                                    .stroke(Color.wheelpGreen, lineWidth: 2)
                            )
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    }

                    Spacer()

                    // Sign Up
                    VStack(spacing: 8) {
                        Text("¿No tienes cuenta?")
                            .font(.system(size: 15))
                            .foregroundColor(.gray)

                        Button(action: { showSignUp = true }) {
                            Text("Crear cuenta")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(Color.black)
                                .cornerRadius(50)
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationDestination(isPresented: $showSignUp) {
                SignUpView()
            }
        }
    }

    private func handleSignIn() {
        isLoading = true
        errorMessage = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let result = auth.signIn(username: username, password: password)
            isLoading = false
            if result != .success { errorMessage = result.message }
        }
    }

    private func handleBiometrics() {
        auth.authenticateWithBiometrics { success in
            if !success { errorMessage = "No se pudo verificar la identidad" }
        }
    }
}

// MARK: - Sign Up View
struct SignUpView: View {
    @Environment(AuthManager.self) var auth
    @Environment(\.dismiss) var dismiss
    @State private var firstName  = ""
    @State private var lastName   = ""
    @State private var email      = ""
    @State private var username   = ""
    @State private var password   = ""
    @State private var errorMessage = ""
    @State private var showBiometricsPrompt = false
    @State private var accountCreated = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    WheelpLogoView()
                        .padding(.top, 40)
                        .padding(.bottom, 40)

                    Text("Crear cuenta")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.wheelpGreen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)

                    // Form fields
                    VStack(spacing: 0) {
                        WheelpTextField(placeholder: "Nombre", text: $firstName, icon: "person")
                        Divider().padding(.horizontal, 20)
                        WheelpTextField(placeholder: "Apellido", text: $lastName, icon: "person")
                        Divider().padding(.horizontal, 20)
                        WheelpTextField(placeholder: "Correo electrónico", text: $email, icon: "envelope", keyboard: .emailAddress)
                        Divider().padding(.horizontal, 20)
                        WheelpTextField(placeholder: "Nombre de usuario", text: $username, icon: "at")
                        Divider().padding(.horizontal, 20)
                        WheelpSecureField(placeholder: "Contraseña (mín. 6 caracteres)", text: $password, icon: "lock")
                    }
                    .background(Color(white: 0.97))
                    .cornerRadius(16)
                    .padding(.horizontal, 24)

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .padding(.top, 12)
                            .padding(.horizontal, 24)
                    }

                    // Create account button
                    Button(action: handleSignUp) {
                        Text("Crear cuenta")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color.wheelpGreen)
                            .cornerRadius(50)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationBarBackButtonHidden(false)
        .sheet(isPresented: $showBiometricsPrompt) {
            BiometricsPromptView(onComplete: {
                showBiometricsPrompt = false
            })
        }
    }

    private func handleSignUp() {
        errorMessage = ""
        let result = auth.signUp(
            firstName: firstName,
            lastName: lastName,
            email: email,
            username: username,
            password: password
        )
        if result == .success {
            // Preguntar si quiere activar biometría
            if auth.biometricType != "none" {
                showBiometricsPrompt = true
            }
        } else {
            errorMessage = result.message
        }
    }
}

// MARK: - Biometrics Prompt (sheet)
struct BiometricsPromptView: View {
    @Environment(AuthManager.self) var auth
    let onComplete: () -> Void
    @State private var statusMessage = ""

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 12)

            Image(systemName: auth.biometricType == "Face ID" ? "faceid" : "touchid")
                .font(.system(size: 60))
                .foregroundColor(.wheelpGreen)
                .padding(.top, 12)

            Text("Acceso rápido con \(auth.biometricType)")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Activa \(auth.biometricType) para entrar a Wheelp sin escribir tu contraseña cada vez.")
                .font(.system(size: 16))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 14))
                    .foregroundColor(.wheelpGreen)
            }

            VStack(spacing: 12) {
                Button(action: {
                    auth.enableBiometrics { success in
                        statusMessage = success ? "✓ \(auth.biometricType) activado" : "No se pudo activar"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { onComplete() }
                    }
                }) {
                    Text("Activar \(auth.biometricType)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.wheelpGreen)
                        .cornerRadius(50)
                }

                Button("Ahora no") { onComplete() }
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)

            Spacer()
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Reusable Field Components
struct WheelpTextField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.gray)
                .frame(width: 20)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }
}

struct WheelpSecureField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.gray)
                .frame(width: 20)
            if isVisible {
                TextField(placeholder, text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                SecureField(placeholder, text: $text)
            }
            Button(action: { isVisible.toggle() }) {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }
}

// MARK: - Logo Component
struct WheelpLogoView: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("W")
                .font(.system(size: 32, weight: .black))
            ZStack {
                Circle().fill(Color.black).frame(width: 58, height: 58)
                Text("HE").font(.system(size: 24, weight: .black)).foregroundColor(.white)
            }
            Text("E")
                .font(.system(size: 32, weight: .black))
            ZStack {
                Circle().fill(Color.black).frame(width: 58, height: 58)
                Text("LP").font(.system(size: 24, weight: .black)).foregroundColor(.white)
            }
        }
    }
}

// MARK: - Color extension
extension Color {
    static let wheelpGreen = Color(red: 0.310, green: 0.722, blue: 0.282)
}
