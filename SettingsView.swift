import SwiftUI

/// Página de ajustes del usuario: cuenta, versión de accesibilidad y sesión.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var previewSpeech = SpeechAnnouncer()

    var body: some View {
        NavigationStack {
            List {
                accountSection
                versionSection
                if appState.disabilityType == .visual {
                    voiceSection
                }
                if appState.isHelper {
                    helperSection
                }
                onboardingSection
                signOutSection
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }

    // MARK: - Secciones

    private var accountSection: some View {
        @Bindable var appState = appState
        return Section {
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.wheelpGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.publicName)
                        .font(.headline)
                    Text(appState.userName ?? "Sesión iniciada")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Label("Nombre o alias", systemImage: "person.text.rectangle")
                TextField("Ej.: Álvaro", text: $appState.displayName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Nombre o alias")
            }
        } header: {
            Text("Cuenta")
        } footer: {
            Text("Con este nombre te verán los demás al pedir o dar ayuda. Se guarda solo en tu iPhone; si lo dejas vacío, se usa la primera parte de tu correo.")
        }
    }

    private var versionSection: some View {
        Section {
            // La versión Estándar es solo para ayudantes verificados.
            ForEach(appState.isHelper ? DisabilityType.allCases : DisabilityType.selectable) { type in
                Button {
                    appState.setDisability(type)
                } label: {
                    HStack {
                        Label(type.title, systemImage: type.icon)
                            .foregroundStyle(.primary)
                        Spacer()
                        if appState.disabilityType == type {
                            Image(systemName: "checkmark")
                                .font(.headline)
                                .foregroundStyle(Color.wheelpGreen)
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
        } header: {
            Text("Versión de accesibilidad")
        } footer: {
            Text("Cambia cómo se presenta Wheelp y qué accesibilidad se prioriza en cada destino y ruta.")
        }
    }

    private var voiceSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { appState.voiceControlEnabled },
                set: { appState.voiceControlEnabled = $0 }
            )) {
                Label("Control por voz", systemImage: "mic.fill")
            }
            .tint(Color.wheelpGreen)

            VStack(alignment: .leading, spacing: 8) {
                Label("Velocidad de la voz", systemImage: "gauge.with.needle")
                HStack(spacing: 12) {
                    Image(systemName: "tortoise.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(
                        value: Binding(
                            get: { appState.voiceRate },
                            set: { appState.voiceRate = $0 }
                        ),
                        in: 0.3...0.65
                    ) { editing in
                        // Al soltar el control, lee una frase de prueba a esa velocidad.
                        if !editing {
                            previewSpeech.isEnabled = true
                            previewSpeech.rate = Float(appState.voiceRate)
                            previewSpeech.announce("Así de rápido hablaré.")
                        }
                    }
                    .tint(Color.wheelpGreen)
                    .accessibilityLabel("Velocidad de la voz")
                    Image(systemName: "hare.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        } header: {
            Text("Versión Visual")
        } footer: {
            Text("Si desactivas el control por voz, podrás usar Wheelp tocando la pantalla y escribiendo el destino, sin micrófono.")
        }
    }

    private var helperSection: some View {
        Section {
            HStack {
                Label("Eres ayudante verificado", systemImage: "hand.raised.fill")
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.wheelpGreen)
                    .accessibilityHidden(true)
            }
        } header: {
            Text("Ayudantes")
        } footer: {
            Text("Verás las peticiones de ayuda cercanas desde el botón de la mano en el mapa. El alta de ayudantes la gestiona el equipo de Wheelp.")
        }
    }

    private var onboardingSection: some View {
        Section {
            Button {
                appState.restartOnboarding()
                dismiss()
            } label: {
                Label("Repetir configuración inicial", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("Vuelve a abrir el asistente de Wheelp para configurar la app desde cero.")
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await appState.signOut() }
            } label: {
                Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}
