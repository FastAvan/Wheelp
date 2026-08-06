import SwiftUI
import DiditSDK

/// Formulario para solicitar el alta como ayudante de la red Wheelp.
/// La verificación de identidad la realiza Didit directamente en el dispositivo:
/// el DNI y la prueba de vida nunca pasan por los servidores de Wheelp.
struct HelperApplicationView: View {
    let userName: String
    var onSubmit: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var city = ""
    @State private var phone = ""
    @State private var motivation = ""
    @State private var isSubmitting = false
    @State private var didSubmit = false
    @State private var submitError: String?

    // Estado de la verificación KYC
    @State private var kycSessionId: String?
    @State private var kycFailed = false

    // Certificado de antecedentes penales
    @State private var criminalCheckConfirmed = false
    @State private var showCriminalCheckInfo = false

    init(userName: String, onSubmit: (() -> Void)? = nil) {
        self.userName = userName
        self.onSubmit = onSubmit
        _name = State(initialValue: userName)
    }

    var body: some View {
        NavigationStack {
            if didSubmit { successView } else { formView }
        }
        // El SDK de Didit gestiona el resultado de la verificación.
        // El documento va directo a Didit; Wheelp solo recibe el sessionId.
        .diditVerification { result in
            switch result {
            case .completed(let session):
                kycSessionId = session.sessionId
                kycFailed = false
            case .cancelled:
                break
            case .failed:
                kycFailed = true
            }
        }
    }

    // MARK: - Formulario

    private var formView: some View {
        Form {
            Section {
                HStack {
                    Label("Nombre o alias", systemImage: "person")
                    TextField("Tu nombre o alias", text: $name)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }
                HStack {
                    Label("Ciudad o zona", systemImage: "mappin.circle")
                    TextField("Ej: Madrid centro", text: $city)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }
                HStack {
                    Label("Teléfono", systemImage: "phone")
                    TextField("Ej: 612 345 678", text: $phone)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.phonePad)
                }
            } header: { Text("Sobre ti") }

            Section {
                if kycSessionId != nil {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundStyle(Color.wheelpGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Identidad verificada")
                                .font(.subheadline.weight(.medium))
                            Text("Verificación completada con Didit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Repetir") { startKYC() }
                            .font(.footnote)
                            .foregroundStyle(Color.wheelpGreen)
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button { startKYC() } label: {
                        Label("Verificar mi identidad", systemImage: "person.badge.shield.checkmark.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.wheelpGreen)

                    if kycFailed {
                        Text("La verificación no ha podido completarse. Comprueba la iluminación y vuelve a intentarlo.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Verificación de identidad")
            } footer: {
                Text("Didit escanea tu DNI/NIE y hace una prueba de vida. Tus documentos van directamente a Didit y no se almacenan en los servidores de Wheelp (art. 25 RGPD — privacidad desde el diseño).")
            }

            Section {
                if criminalCheckConfirmed {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundStyle(Color.wheelpGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Certificado confirmado")
                                .font(.subheadline.weight(.medium))
                            Text("Sin antecedentes penales")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cambiar") { criminalCheckConfirmed = false }
                            .font(.footnote)
                            .foregroundStyle(Color.wheelpGreen)
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                } else {
                    Toggle(isOn: $criminalCheckConfirmed) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Tengo el certificado de antecedentes penales y no tengo antecedentes")
                                .font(.subheadline)
                            Button {
                                showCriminalCheckInfo = true
                            } label: {
                                Text("¿Cómo obtenerlo? →")
                                    .font(.caption)
                                    .foregroundStyle(Color.wheelpGreen)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .tint(Color.wheelpGreen)
                }
            } header: {
                Text("Antecedentes penales")
            } footer: {
                Text("El certificado de antecedentes penales es obligatorio para ejercer como ayudante. El equipo de Wheelp lo solicitará durante la revisión de tu solicitud.")
            }
            .sheet(isPresented: $showCriminalCheckInfo) { criminalCheckInfoSheet }

            Section {
                ZStack(alignment: .topLeading) {
                    if motivation.isEmpty {
                        Text("Cuéntanos brevemente por qué quieres ayudar (opcional)")
                            .foregroundStyle(.secondary).font(.body)
                            .padding(.top, 8).padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $motivation).frame(minHeight: 80)
                }
            } header: { Text("Motivación (opcional)") }

            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.wheelpGreen).font(.subheadline)
                    Text("Los ayudantes acompañan en trayectos de A a B. No es un servicio de asistencia en el hogar ni de cuidados personales.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }

            if let error = submitError {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }

            Section {
                Button { submit() } label: {
                    Group {
                        if isSubmitting {
                            HStack(spacing: 8) { ProgressView(); Text("Enviando…") }
                        } else {
                            Text("Enviar solicitud").fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!isFormValid || isSubmitting)
                .foregroundStyle(isFormValid ? .white : .secondary)
                .listRowBackground(isFormValid ? Color.wheelpGreen : Color(.secondarySystemBackground))
            }
        }
        .navigationTitle("Solicitar ser ayudante")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
        }
    }

    // MARK: - Pantalla de éxito

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72)).foregroundStyle(Color.wheelpGreen)
            Text("Solicitud enviada").font(.title2.bold())
            Text("El equipo de Wheelp revisará tu solicitud en breve. Envía tu certificado de antecedentes penales a:")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Link(destination: URL(string: "mailto:verificacion@wheelp.com?subject=Antecedentes%20penales")!) {
                Label("verificacion@wheelp.com", systemImage: "envelope")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(Color.wheelpGreen)
            Spacer()
            Button("Cerrar") { onSubmit?(); dismiss() }
                .buttonStyle(.wheelpPrimary)
                .padding(.horizontal, 28).padding(.bottom, 28)
        }
        .navigationTitle("Solicitud enviada")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Instrucciones del certificado

    private var criminalCheckInfoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Certificado de Antecedentes Penales", systemImage: "doc.badge.checkmark")
                        .font(.headline)

                    Text("Para ser ayudante en Wheelp es obligatorio acreditar la ausencia de antecedentes penales, especialmente por delitos contra la integridad física o la libertad sexual.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        stepRow(number: "1", title: "Accede a la Sede Electrónica", body: "Entra en la sede electrónica del Ministerio de Justicia de España (sede.mjusticia.gob.es) y busca \"Certificado de Antecedentes Penales\".")
                        stepRow(number: "2", title: "Identifícate", body: "Puedes usar Cl@ve, DNI electrónico o certificado digital. También existe la opción presencial en cualquier Registro Civil o Gerencia Territorial de Justicia.")
                        stepRow(number: "3", title: "Solicita el certificado", body: "Elige la opción de certificado para uso privado. Es gratuito y se emite al instante en formato PDF con sello electrónico oficial.")
                        stepRow(number: "4", title: "Envíanoslo por correo", body: "Manda el PDF a verificacion@wheelp.com con el asunto \"Antecedentes penales – [tu nombre]\". Revisamos todos los certificados manualmente antes de aprobar el alta.")
                    }

                    Divider()

                    Link(destination: URL(string: "mailto:verificacion@wheelp.com?subject=Antecedentes%20penales")!) {
                        Label("Abrir correo a verificacion@wheelp.com", systemImage: "envelope.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.wheelpGreen)

                    Divider()

                    Label("El certificado no se almacena en los servidores de Wheelp. Solo lo revisa el equipo de forma manual (art. 25 RGPD).", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
            }
            .navigationTitle("¿Cómo obtenerlo?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Entendido") { showCriminalCheckInfo = false }
                        .foregroundStyle(Color.wheelpGreen)
                }
            }
        }
    }

    private func stepRow(number: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.wheelpGreen, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - KYC

    private func startKYC() {
        let config = DiditSdk.Configuration(
            languageLocale: .spanish,
            loggingEnabled: false,
            showCloseButton: true,
            showExitConfirmation: true
        )
        DiditSdk.shared.startVerification(
            workflowId: "d53ab3f8-7414-40c8-8fb2-5a811c059a7d",
            configuration: config
        )
    }

    // MARK: - Validación y envío

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        city.trimmingCharacters(in: .whitespaces).count >= 3 &&
        phone.trimmingCharacters(in: .whitespaces).count >= 9 &&
        kycSessionId != nil &&
        criminalCheckConfirmed
    }

    private func submit() {
        isSubmitting = true; submitError = nil
        let trimMotivation = motivation.trimmingCharacters(in: .whitespaces)
        guard let sessionId = kycSessionId else {
            submitError = "Completa la verificación de identidad antes de enviar."
            isSubmitting = false; return
        }
        Task {
            do {
                try await HelperService.submitApplication(
                    name: name.trimmingCharacters(in: .whitespaces),
                    city: city.trimmingCharacters(in: .whitespaces),
                    phone: phone.trimmingCharacters(in: .whitespaces),
                    motivation: trimMotivation.isEmpty ? nil : trimMotivation,
                    kycSessionId: sessionId
                )
                didSubmit = true
            } catch {
                submitError = "No se pudo enviar la solicitud. Comprueba tu conexión e inténtalo de nuevo."
            }
            isSubmitting = false
        }
    }
}
