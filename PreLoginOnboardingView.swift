import SwiftUI

/// Selección de discapacidad ANTES del login.
/// Se muestra una sola vez cuando el usuario abre la app por primera vez.
struct PreLoginOnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var step: Step = .welcome

    enum Step { case welcome, intro, chooseType, noDisability }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                PLWelcomeView { go(.intro) }
            case .intro:
                PLIntroView(
                    onYes: { go(.chooseType) },
                    onNo:  { go(.noDisability) }
                )
            case .chooseType:
                PLDisabilityTypeView { type in
                    appState.setPreLoginDisability(type)
                }
            case .noDisability:
                PLNoDisabilityView(
                    onContinue: { appState.setPreLoginDisability(.none) },
                    onBack:     { go(.intro) }
                )
            }
        }
        .animation(.easeInOut(duration: 0.35), value: step)
    }

    private func go(_ next: Step) {
        withAnimation { step = next }
    }
}

// MARK: - Paso 0: Bienvenida

private struct PLWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WheelpLogo(variant: .black)
                .frame(maxWidth: 200)
                .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 28) {
                Text("Bienvenido a Wheelp")
                    .font(.title.bold())

                VStack(alignment: .leading, spacing: 20) {
                    PLFeatureRow(icon: "map.fill",          color: .wheelpGreen, title: "Rutas adaptadas",    subtitle: "Caminos sin obstáculos, adaptados a tus necesidades")
                    PLFeatureRow(icon: "hand.raised.fill",  color: .blue,        title: "Red de ayudantes",   subtitle: "Solicita ayuda humana en ruta cuando la necesites")
                    PLFeatureRow(icon: "lock.shield.fill",  color: .orange,      title: "Solo en tu iPhone",  subtitle: "Tus datos no salen del dispositivo salvo lo imprescindible")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Button("Continuar", action: onContinue)
                .buttonStyle(.wheelpPrimary)
        }
        .padding(28)
    }
}

// MARK: - Paso 1: ¿Tienes discapacidad?

private struct PLIntroView: View {
    let onYes: () -> Void
    let onNo:  () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WheelpLogo(variant: .black)
                .frame(maxWidth: 200)
                .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Text("Antes de empezar,\n¿tienes alguna discapacidad?")
                    .font(.title2.weight(.semibold))

                Text("Adaptamos la app a tus necesidades para que sea lo más cómoda posible.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            HStack(spacing: 16) {
                Button("SÍ", action: onYes).buttonStyle(.wheelpPrimary)
                Button("NO", action: onNo).buttonStyle(.wheelpOutline)
            }
        }
        .padding(28)
    }
}

// MARK: - Paso 2a: Tipo de discapacidad

private struct PLDisabilityTypeView: View {
    let onSelect: (DisabilityType) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WheelpLogo(variant: .black)
                .frame(maxWidth: 200)
                .padding(.top, 24)

            Spacer()

            Text("¿Qué tipo de\ndiscapacidad tienes?")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Spacer()

            VStack(spacing: 16) {
                ForEach(DisabilityType.selectable) { type in
                    Button { onSelect(type) } label: {
                        Label(type.title, systemImage: type.icon)
                    }
                    .buttonStyle(.wheelpPrimary)
                    .accessibilityLabel("Discapacidad \(type.title)")
                }
            }
        }
        .padding(28)
    }
}

// MARK: - Paso 2b: Sin discapacidad → propuesta de ayudante

private struct PLNoDisabilityView: View {
    let onContinue: () -> Void
    let onBack:     () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").fontWeight(.semibold)
                        Text("Volver")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.wheelpGreen)
                }
                Spacer()
                WheelpLogo(variant: .black).frame(maxWidth: 120)
                Spacer()
                // Espacio simétrico para centrar el logo
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Volver")
                }
                .font(.subheadline)
                .hidden()
            }
            .padding(.top, 16)

            Spacer()

            VStack(alignment: .leading, spacing: 24) {
                Text("Esta app está pensada para personas con discapacidad")
                    .font(.title2.bold())

                Text("Si no tienes ninguna, puedes unirte como ayudante y acompañar a personas en sus trayectos.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 20) {
                    PLFeatureRow(icon: "figure.walk.motion",      color: .blue,        title: "Acompañar en trayectos",  subtitle: "Ayudas a personas a llegar de A a B en su ciudad")
                    PLFeatureRow(icon: "clock.badge.checkmark",   color: .wheelpGreen, title: "Cuando tú puedas",        subtitle: "Sin compromisos fijos, solo cuando te encaje")
                    PLFeatureRow(icon: "doc.badge.plus",          color: .orange,      title: "Verificación previa",     subtitle: "Necesitamos DNI y certificado de antecedentes penales")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            VStack(spacing: 14) {
                Button("Continuar como ayudante", action: onContinue)
                    .buttonStyle(.wheelpPrimary)

                Button("Solo quiero explorar la app", action: onContinue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }
}

// MARK: - Helper view

private struct PLFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
