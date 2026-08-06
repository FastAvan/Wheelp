import SwiftUI
import PhotosUI

/// Página de ajustes del usuario: cuenta, versión de accesibilidad y sesión.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var previewSpeech = SpeechAnnouncer()

    var body: some View {
        NavigationStack {
            List {
                accountSection
                if !appState.isHelper { versionSection }
                paceSection
                if appState.disabilityType == .visual {
                    voiceSection
                }
                if appState.isHelper {
                    helperSection
                }
                if isAdmin {
                    adminSection
                }
                securitySection
                onboardingSection
                privacySection
                signOutSection
                deleteAccountSection
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isUploadingAvatar {
                        ProgressView()
                            .tint(Color.wheelpGreen)
                    } else {
                        Button("Listo") { dismiss() }
                    }
                }
            }
        }
        // Las llamadas a Supabase se lanzan aquí, fuera de la propiedad computada,
        // para que SwiftUI gestione el ciclo de vida del task correctamente y no
        // lo reinicie en cada re-render de body.
        .sheet(isPresented: $showTerms) { TermsView() }
        .sheet(isPresented: $showAdminApplications) { AdminApplicationsView() }
        .alert("Eliminar cuenta permanentemente", isPresented: $showDeleteConfirmation) {
            Button("Eliminar", role: .destructive) {
                Task {
                    do { try await appState.deleteAccount() }
                    catch { showDeleteError = true }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borrarán todos tus datos de los servidores y del dispositivo. Esta acción no se puede deshacer.")
        }
        .alert("No se pudo eliminar la cuenta", isPresented: $showDeleteError) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text("Comprueba tu conexión e inténtalo de nuevo. Si el problema persiste, contacta con el equipo de Wheelp.")
        }
        .photosPicker(isPresented: $showAvatarPicker, selection: $avatarPickerItem, matching: .images)
        .alert("No se pudo guardar la foto", isPresented: $showUploadError) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text("Comprueba tu conexión o que el servidor esté configurado e inténtalo de nuevo.")
        }
        .task(id: appState.isHelper) {
            guard appState.isHelper else { return }
            guard let userId = await HelperService.currentUserId() else { return }
            async let rating = HelperService.averageRating(for: userId)
            async let avatarURL = HelperService.currentAvatarURL()
            helperAvgRating = await rating
            // Cache-busting: fuerza a AsyncImage a cargar la imagen actual del servidor.
            helperAvatarURL = await avatarURL
        }
        .onChange(of: avatarPickerItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data) else {
                    avatarPickerItem = nil
                    return
                }
                imageToCrop = uiImage
                avatarPickerItem = nil
            }
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerView(
                onSelect: { phone in
                    appState.trustedContactPhone = phone
                    showContactPicker = false
                },
                onDismiss: { showContactPicker = false }
            )
            .presentationBackground(.clear)
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(
            get: { imageToCrop != nil },
            set: { if !$0 { imageToCrop = nil } }
        )) {
            if let img = imageToCrop {
                AvatarCropView(
                    image: img,
                    onConfirm: { cropped in
                        localAvatarImage = cropped   // muestra inmediato, sin esperar subida
                        isUploadingAvatar = true      // bloquea "Listo" antes de lanzar el Task
                        imageToCrop = nil
                        Task {
                            defer { isUploadingAvatar = false }
                            guard let data = cropped.jpegData(compressionQuality: 0.6) else {
                                showUploadError = true
                                return
                            }
                            if let url = await HelperService.uploadAvatar(data) {
                                helperAvatarURL = url
                            } else {
                                showUploadError = true
                            }
                        }
                    },
                    onCancel: { imageToCrop = nil }
                )
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

    /// El estado solo fuerza el refresco de la sección al reiniciar el ritmo.
    @State private var paceWasReset = false

    private var paceSection: some View {
        Section {
            HStack {
                Label("Tu ritmo", systemImage: "figure.walk")
                Spacer()
                Text(WalkingPaceService.paceDescription(for: appState.disabilityType ?? .none))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if WalkingPaceService.learnedSeconds > 0 {
                Button(role: .destructive) {
                    WalkingPaceService.reset()
                    paceWasReset.toggle()
                } label: {
                    Label("Reiniciar ritmo aprendido", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("Ritmo de marcha")
        } footer: {
            Text(WalkingPaceService.hasReliablePace
                 ? "Aprendido de tus trayectos reales. Los tiempos estimados se ajustan a tu ritmo. Se guarda solo en tu iPhone."
                 : "Valor típico de tu versión. La app aprenderá tu ritmo real mientras navegas (se guarda solo en tu iPhone).")
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

    private var isAdmin: Bool { appState.userName == "aelguer@icloud.com" }

    private var adminSection: some View {
        Section {
            Button {
                showAdminApplications = true
            } label: {
                HStack {
                    Label("Solicitudes de ayudante", systemImage: "person.badge.clock.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Administración")
        } footer: {
            Text("Revisa y aprueba las solicitudes de alta como ayudante.")
        }
    }

    @State private var helperAvgRating: Double? = nil
    @State private var helperAvatarURL: String? = nil
    @State private var avatarPickerItem: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var showAvatarPicker = false
    @State private var imageToCrop: UIImage? = nil
    /// Imagen recortada en memoria: se muestra de inmediato sin esperar a AsyncImage.
    @State private var localAvatarImage: UIImage? = nil
    @State private var showUploadError = false
    @State private var showContactPicker = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var showTerms = false
    @State private var showAdminApplications = false
    private var helperSection: some View {
        Section {
            HStack {
                Label("Eres ayudante verificado", systemImage: "hand.raised.fill")
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.wheelpGreen)
                    .accessibilityHidden(true)
            }
            // Foto de perfil del ayudante.
            HStack(spacing: 12) {
                HelperAvatarView(url: helperAvatarURL, size: 52, localImage: localAvatarImage)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Foto de perfil")
                        .font(.subheadline)
                    Text("La verá el usuario al aceptar su petición")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showAvatarPicker = true } label: {
                    if isUploadingAvatar {
                        ProgressView()
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "camera.fill")
                            .frame(width: 44, height: 44)
                            .foregroundStyle(Color.wheelpGreen)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isUploadingAvatar)
                .accessibilityLabel("Cambiar foto de perfil")
            }
            if let avg = helperAvgRating {
                HStack {
                    Label("Valoración media", systemImage: "star.fill")
                    Spacer()
                    Text(String(format: "%.1f / 5", avg))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: Double(star) <= avg.rounded() ? "star.fill" : "star")
                                .font(.caption)
                                .foregroundStyle(Color.yellow)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
        } header: {
            Text("Ayudantes")
        } footer: {
            Text("Verás las peticiones de ayuda cercanas desde el botón de la mapa. El alta de ayudantes la gestiona el equipo de Wheelp.")
        }
    }

    private var securitySection: some View {
        Section {
            HStack {
                Label("Contacto SOS", systemImage: "person.badge.shield.checkmark.fill")
                Spacer()
                Button { showContactPicker = true } label: {
                    if appState.trustedContactPhone.isEmpty {
                        Label("Elegir", systemImage: "person.crop.circle.badge.plus")
                            .font(.subheadline)
                            .foregroundStyle(Color.wheelpGreen)
                    } else {
                        Text(appState.trustedContactPhone)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appState.trustedContactPhone.isEmpty
                    ? "Elegir contacto de emergencia"
                    : "Contacto: \(appState.trustedContactPhone). Tocar para cambiar")
            }
            if !appState.trustedContactPhone.isEmpty {
                Button(role: .destructive) {
                    appState.trustedContactPhone = ""
                } label: {
                    Label("Eliminar contacto SOS", systemImage: "trash")
                }
            }
        } header: {
            Text("Seguridad")
        } footer: {
            Text("Al pulsar el botón SOS durante una sesión de ayuda puedes llamar al 112 o enviar un mensaje de aviso a este número. El número se guarda solo en tu iPhone.")
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

    private var privacySection: some View {
        Section {
            HStack {
                Label("Versión", systemImage: "info.circle")
                Spacer()
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                Text("\(version) (\(build))")
                    .foregroundStyle(.secondary)
            }
            Button {
                showTerms = true
            } label: {
                Label("Términos y condiciones", systemImage: "doc.text")
                    .foregroundStyle(.primary)
            }
        } header: {
            Text("Privacidad y datos")
        } footer: {
            Text("Tu correo se guarda en el servidor para gestionar la sesión. La ubicación, los destinos y los favoritos permanecen solo en este iPhone. Las solicitudes de ayuda y los mensajes viajan cifrados de extremo a extremo y se borran al terminar.")
        }
    }

    private var deleteAccountSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Eliminar mi cuenta", systemImage: "person.crop.circle.badge.minus")
            }
        } footer: {
            Text("Borra permanentemente tu cuenta y todos tus datos de los servidores y del dispositivo. Esta acción no se puede deshacer.")
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
