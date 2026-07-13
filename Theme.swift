import SwiftUI

extension Color {
    /// Verde principal de la marca Wheelp (tomado del logo).
    static let wheelpGreen = Color(red: 0.235, green: 0.710, blue: 0.290)
}

/// Logo de Wheelp con sus tres variantes de color.
struct WheelpLogo: View {
    enum Variant { case black, white, green }
    var variant: Variant = .black
    @Environment(\.colorScheme) private var colorScheme

    private var assetName: String {
        switch variant {
        // La variante negra va sobre fondos del sistema: en modo oscuro
        // pasa sola al logo blanco para que siga viéndose.
        case .black: colorScheme == .dark ? "logo_white" : "logo_black"
        case .white: "logo_white"
        case .green: "logo_green"
        }
    }

    var body: some View {
        Image(assetName)
            .renderingMode(variant == .green ? .template : .original)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.wheelpGreen) // Solo afecta a la variante .green (template).
            .accessibilityLabel("Wheelp")
    }
}

/// Botón tipo "píldora" usado en todo el onboarding.
/// `filled` = fondo verde con texto blanco; si es false, borde verde con texto verde.
struct WheelpPillButtonStyle: ButtonStyle {
    var filled: Bool = true
    var tint: Color = .wheelpGreen

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(filled ? .white : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Capsule().fill(filled ? tint : Color.clear))
            .overlay(Capsule().strokeBorder(tint, lineWidth: filled ? 0 : 2))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == WheelpPillButtonStyle {
    static var wheelpPrimary: WheelpPillButtonStyle { WheelpPillButtonStyle(filled: true) }
    static var wheelpOutline: WheelpPillButtonStyle { WheelpPillButtonStyle(filled: false) }
    /// Variante para pantallas verdes: píldora blanca con texto verde.
    static var wheelpOnGreen: WheelpPillButtonStyle {
        WheelpPillButtonStyle(filled: true, tint: .white)
    }
}

extension View {
    /// Fondo de tarjeta de la app. En alto contraste usa un fondo opaco con borde
    /// definido en lugar del material translúcido, para máxima legibilidad.
    @ViewBuilder
    func wheelpCard(_ profile: AccessibilityProfile, cornerRadius: CGFloat = 22) -> some View {
        if profile.highContrast {
            self
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.primary, lineWidth: 2)
                )
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
