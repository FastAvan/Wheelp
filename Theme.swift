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
            .frame(maxWidth: .infinity, minHeight: 50)
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

    // MARK: - Pantallas bajas (iPhone Duo, apaisado, Dynamic Type grande)
    //
    // La pantalla exterior del iPhone Duo es más baja que la de cualquier
    // iPhone, y en apaisado (modo tienda) más aún. Con letra grande, lo que
    // antes cabía se cortaba por abajo: botones como "Continuar" o el SOS
    // quedaban fuera de la pantalla sin forma de llegar a ellos.

    /// Tarjeta pegada a un borde: crece con su contenido hasta `maxHeight` y a
    /// partir de ahí se desplaza. Mientras quepa se ve exactamente igual que
    /// antes. La identidad de la vista no cambia al plegar/desplegar, así que
    /// no se pierde estado de lo que lleva dentro (diálogo del SOS, foco de
    /// VoiceOver).
    func scrollable(beyond maxHeight: CGFloat) -> some View {
        ScrollView { self }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Contenido centrado que ocupa el espacio disponible: igual que antes si
    /// cabe, desplazable si no. Misma identidad siempre (ver arriba). No sirve
    /// para pilas con `Spacer`: dentro de un scroll se encogen.
    func scrollableWhenTooTall() -> some View {
        GeometryReader { proxy in
            ScrollView {
                self.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Para pantallas de onboarding hechas con `Spacer`: se dejan tal cual si
    /// caben y solo pasan a un scroll si no. Al cruzar el umbral la vista se
    /// recrea, así que úsalo solo en vistas sin estado propio.
    func scrollableIfClipped() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self }
        }
    }
}
