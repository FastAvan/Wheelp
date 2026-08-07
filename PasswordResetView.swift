import SwiftUI

struct PasswordResetView: View {
    @Environment(AppState.self) private var appState
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isValid: Bool {
        newPassword.count >= 6 && newPassword == confirmPassword
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                WheelpLogo(variant: .black)
                    .frame(maxWidth: 220)

                Text("Nueva contraseña")
                    .font(.title.bold())

                Text("Elige una contraseña nueva para tu cuenta de Wheelp.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 14) {
                    SecureField("Nueva contraseña (mín. 6 caracteres)", text: $newPassword)
                        .textContentType(.newPassword)
                        .padding()
                        .background(fieldBackground)

                    SecureField("Confirmar contraseña", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .padding()
                        .background(fieldBackground)
                }

                if !confirmPassword.isEmpty && newPassword != confirmPassword {
                    Text("Las contraseñas no coinciden.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let msg = errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: submit) {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Guardar contraseña")
                    }
                }
                .buttonStyle(.wheelpPrimary)
                .disabled(!isValid || isLoading)
                .opacity(isValid && !isLoading ? 1 : 0.5)
            }
            .padding(.horizontal, 28)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemBackground))
    }

    private func submit() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await appState.updatePassword(newPassword)
            } catch {
                errorMessage = "No se pudo actualizar la contraseña. Inténtalo de nuevo."
            }
            isLoading = false
        }
    }
}
