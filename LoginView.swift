import SwiftUI

/// Pantalla de inicio de sesión / registro con email y contraseña (Supabase).
struct LoginView: View {
    @Environment(AppState.self) private var appState

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var isLoading = false

    enum Mode {
        case signIn, signUp
        var title: String { self == .signIn ? "Iniciar sesión" : "Crear cuenta" }
        var cta: String { self == .signIn ? "Entrar" : "Registrarme" }
        var togglePrompt: String {
            self == .signIn ? "¿No tienes cuenta? Crear una" : "¿Ya tienes cuenta? Inicia sesión"
        }
    }

    private var isFormValid: Bool {
        email.contains("@") && password.count >= 6
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

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

            Button(mode.togglePrompt) {
                withAnimation {
                    mode = (mode == .signIn) ? .signUp : .signIn
                    errorMessage = nil
                    infoMessage = nil
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.wheelpGreen)

            Spacer()
        }
        .padding(.horizontal, 28)
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
}
