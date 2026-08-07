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
    @State private var pendingEmail = ""
    @State private var otpEmail = ""
    @State private var otpCode = ""
    @State private var speech = SpeechAnnouncer()

    private var isVisual: Bool { appState.disabilityType == .visual }
    private var isStandard: Bool { appState.disabilityType == .none }

    enum Mode {
        case signIn, signUp, pendingVerification, otpVerification
        var title: String {
            switch self {
            case .signIn: "Iniciar sesión"
            case .signUp: "Crear cuenta"
            case .pendingVerification: "Verifica tu correo"
            case .otpVerification: "Código de verificación"
            }
        }
    }

    private var isFormValid: Bool {
        switch mode {
        case .signIn: email.contains("@") && password.count >= 6
        case .signUp: email.contains("@") && password.count >= 6 && privacyAccepted && termsAccepted
        case .pendingVerification: true
        case .otpVerification: otpCode.count == 6
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: isVisual ? 28 : 22) {
                WheelpLogo(variant: .black)
                    .frame(maxWidth: 220)

                Text(mode.title)
                    .font(isVisual ? .largeTitle.bold() : .title.bold())

                if isStandard && mode == .signIn {
                    standardModeNotice
                }

                if mode == .pendingVerification {
                    pendingVerificationView
                } else if mode == .otpVerification {
                    otpVerificationView
                } else {
                    loginFormView
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showTerms) {
            TermsView { termsAccepted = true }
        }
        .task {
            if isVisual {
                speech.isEnabled = true
                speech.configureSession()
                speech.announce("Pantalla de inicio de sesión de Wheelp. Introduce tu correo electrónico y contraseña, o usa Continuar con Apple.")
            }
        }
    }

    private var standardModeNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.wheelpGreen)
            Text("Modo estándar. Si eres ayudante verificado, inicia sesión para atender solicitudes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Subviews

    private var otpVerificationView: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 60))
                .foregroundStyle(Color.wheelpGreen)
                .padding(.top, 8)

            Text("Hemos enviado un código de verificación a\n**\(otpEmail)**")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("000000", text: $otpCode)
                .keyboardType(.numberPad)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .tracking(8)
                .padding()
                .background(fieldBackground)
                .onChange(of: otpCode) { _, new in
                    otpCode = String(new.filter { $0.isNumber }.prefix(6))
                }
                .accessibilityLabel("Código de verificación de 6 dígitos")

            if let msg = errorMessage {
                Text(msg).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if let msg = infoMessage {
                Text(msg).font(.footnote).foregroundStyle(Color.wheelpGreen).multilineTextAlignment(.center)
            }

            Button(action: submit) {
                if isLoading { ProgressView().tint(.white) } else { Text("Verificar") }
            }
            .buttonStyle(.wheelpPrimary)
            .disabled(!isFormValid || isLoading)
            .opacity(isFormValid && !isLoading ? 1 : 0.5)

            Button("Reenviar código") { resendOTP() }
                .font(.subheadline)
                .foregroundStyle(Color.wheelpGreen)
                .disabled(isLoading)

            Button("Volver al inicio de sesión") {
                withAnimation { mode = .signIn; errorMessage = nil; infoMessage = nil; otpCode = "" }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var pendingVerificationView: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 60))
                .foregroundStyle(Color.wheelpGreen)
                .padding(.top, 8)

            Text("Hemos enviado un correo a\n**\(pendingEmail)**\n\nHaz clic en el enlace que contiene para activar tu cuenta.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let msg = errorMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if let msg = infoMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(Color.wheelpGreen)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Reenviar correo")
                }
            }
            .buttonStyle(.wheelpPrimary)
            .disabled(isLoading)
            .opacity(isLoading ? 0.5 : 1)

            Button("Volver al inicio de sesión") {
                withAnimation {
                    mode = .signIn
                    errorMessage = nil
                    infoMessage = nil
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.wheelpGreen)
        }
    }

    private var loginFormView: some View {
        VStack(spacing: 22) {
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

                if mode == .signIn {
                    HStack {
                        Spacer()
                        Button("¿Olvidaste tu contraseña?") { forgotPassword() }
                            .font(.footnote)
                            .foregroundStyle(Color.wheelpGreen)
                    }
                }
            }

            if mode == .signUp {
                privacyConsentView
                termsConsentView
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if let msg = infoMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(Color.wheelpGreen)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(mode == .signIn ? "Entrar" : "Registrarme")
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
            .frame(maxWidth: .infinity, minHeight: 50)
            .clipShape(Capsule())
            .disabled(isLoading)

            Button(mode == .signIn ? "¿No tienes cuenta? Crear una" : "¿Ya tienes cuenta? Inicia sesión") {
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

    // MARK: - Actions

    private func submit() {
        errorMessage = nil
        infoMessage = nil
        isLoading = true
        Task {
            do {
                switch mode {
                case .signIn:
                    try await appState.initiateSignIn(email: email, password: password)
                    otpEmail = email
                    withAnimation { mode = .otpVerification }
                case .otpVerification:
                    try await appState.verifyOTPAndSignIn(email: otpEmail, code: otpCode)
                case .signUp:
                    let active = try await appState.signUp(email: email, password: password)
                    appState.hasAcceptedTerms = true
                    if !active {
                        pendingEmail = email
                        withAnimation { mode = .pendingVerification }
                    }
                case .pendingVerification:
                    try await appState.resendVerification(email: pendingEmail)
                    infoMessage = "Correo reenviado. Revisa tu bandeja de entrada."
                }
            } catch {
                let desc = error.localizedDescription.lowercased()
                if desc.contains("not confirmed") || desc.contains("email not confirmed") {
                    errorMessage = "Confirma tu correo antes de entrar. Revisa tu bandeja de entrada."
                } else {
                    errorMessage = "No se pudo completar. Revisa tus datos e inténtalo de nuevo."
                }
            }
            isLoading = false
        }
    }

    private func forgotPassword() {
        guard email.contains("@") else {
            errorMessage = "Introduce tu correo para recuperar la contraseña."
            return
        }
        errorMessage = nil
        infoMessage = nil
        isLoading = true
        Task {
            do {
                try await appState.resetPassword(email: email)
                infoMessage = "Te hemos enviado un enlace para restablecer tu contraseña."
            } catch {
                errorMessage = "No se pudo enviar el correo. Inténtalo de nuevo."
            }
            isLoading = false
        }
    }

    private func resendOTP() {
        errorMessage = nil
        infoMessage = nil
        isLoading = true
        Task {
            do {
                try await appState.resendLoginOTP(email: otpEmail)
                infoMessage = "Código reenviado. Revisa tu correo."
            } catch {
                errorMessage = "No se pudo reenviar el código. Inténtalo de nuevo."
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
