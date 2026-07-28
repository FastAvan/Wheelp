import SwiftUI

/// Muestra el código de 6 dígitos que ambas partes deben comparar
/// para confirmar que están con la persona correcta.
struct MeetingCodeView: View {
    let code: String
    /// true en el dispositivo del solicitante, false en el del ayudante.
    let isRequester: Bool

    var body: some View {
        VStack(spacing: 10) {
            Label("Código de verificación", systemImage: "shield.lefthalf.filled.badge.checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.wheelpGreen)

            Text(formatted)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(.primary)
                .accessibilityLabel("Código \(code.map(String.init).joined(separator: " "))")

            Text(isRequester
                 ? "Muestra este número al ayudante y confirma que coincide con el suyo."
                 : "Confirma que este número coincide con el que te muestra el usuario.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var formatted: String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
