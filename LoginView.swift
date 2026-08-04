import SwiftUI
import AuthenticationServices
import CryptoKit

/// Pantalla de inicio de sesión / registro con email y contraseña (Supabase).
struct LoginView: View {
    @Environment(AppState.self) private var appState

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var isLoading = false
    @State private var privacyAccepted = false
    @State private var termsAccepted = false
    @State private var showTerms = false
    @State private var currentNonce = ""

    enum Mode {
        case signIn, signUp
        var title: String { self == .signIn ? "Iniciar sesión" : "Crear cuenta" }
        var cta: String { self == .signIn ? "Entrar" : "Registrarme" }
        var togglePrompt: String {
            self == .signIn ? "¿No tienes cuenta? Crear una" : "¿Ya tienes cuenta? Inicia sesión"
        }
    }

    private var isFormValid: Bool {
        email.contains("@") && password.count >= 6 && (mode == .signIn || (privacyAccepted && termsAccepted))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                WheelpLogo(variant: .black)
                    .frame(maxWidth: 220)

                Text(mode.title)
                    .font(.title.bold())

                VStack(spacing: 14) {
                    TextField("Correo electrónico", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding()
                        .background(fieldBackground)

                    SecureField("Contraseña", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                        .padding()
                        .background(fieldBackground)
                }

                if mode == .signUp {
                    privacyConsentView
                    termsConsentView
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                if let infoMessage {
                    Text(infoMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.wheelpGreen)
                        .multilineTextAlignment(.center)
                }

                Button(action: submit) {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text(mode.cta)
                    }
                }
                .buttonStyle(.wheelpPrimary)
                .disabled(!isFormValid || isLoading)
                .opacity(isFormValid && !isLoading ? 1 : 0.5)

                HStack {
                    Rectangle().frame(height: 1).foregroundStyle(Color(.separator))
                    Text("o").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 8)
                    Rectangle().frame(height: 1).foregroundStyle(Color(.separator))
                }

                SignInWithAppleButton(.continue) { request in
                    let nonce = randomNonceString()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = sha256(nonce)
                } onCompletion: { result in
                    handleAppleSignIn(result)
                }
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(isLoading)

                Button(mode.togglePrompt) {
                    withAnimation {
                        mode = (mode == .signIn) ? .signUp : .signIn
                        errorMessage = nil
                        infoMessage = nil
                        privacyAccepted = false
                        termsAccepted = false
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.wheelpGreen)
            }
            .padding(.horizontal, 28)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showTerms) {
            TermsView { termsAccepted = true }
        }
    }

    private var termsConsentView: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $termsAccepted)
                .labelsHidden()
                .tint(Color.wheelpGreen)
            VStack(alignment: .leading, spacing: 4) {
                Text("He leído y acepto los **términos y condiciones** de uso.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ver condiciones →") { showTerms = true }
                    .font(.footnote)
                    .foregroundStyle(Color.wheelpGreen)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var privacyConsentView: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $privacyAccepted)
                .labelsHidden()
                .tint(Color.wheelpGreen)
            Text("He leído y acepto cómo se tratan mis datos: el correo se guarda en el servidor para gestionar la sesión; la ubicación y los destinos permanecen solo en este iPhone. Puedo eliminar mi cuenta en cualquier momento desde Ajustes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemBackground))
    }

    private func submit() {
        errorMessage = nil
        infoMessage = nil
        isLoading = true
        Task {
            do {
                switch mode {
                case .signIn:
                    try await appState.signIn(email: email, password: password)
                case .signUp:
                    let active = try await appState.signUp(email: email, password: password)
                    appState.hasAcceptedTerms = true  // el usuario aceptó durante el registro
                    if !active {
                        infoMessage = "Te hemos enviado un correo para confirmar tu cuenta."
                    }
                }
            } catch {
                errorMessage = "No se pudo completar. Revisa tus datos e inténtalo de nuevo."
            }
            isLoading = false
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Error al procesar la credencial de Apple."
                return
            }
            let fullName = credential.fullName
            isLoading = true
            Task {
                do {
                    try await appState.signInWithApple(idToken: idToken, nonce: currentNonce)
                    // Apple solo envía el nombre en el primer login; lo guardamos si el alias está vacío
                    if let components = fullName {
                        let name = PersonNameComponentsFormatter().string(from: components)
                        if !name.trimmingCharacters(in: .whitespaces).isEmpty,
                           appState.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                            appState.displayName = name
                        }
                    }
                } catch {
                    errorMessage = "No se pudo iniciar sesión con Apple."
                }
                isLoading = false
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = "Error al iniciar sesión con Apple."
            }
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        while result.count < length {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { continue }
            if Int(byte) < charset.count { result.append(charset[Int(byte)]) }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
}
