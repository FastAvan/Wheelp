import SwiftUI

/// Hoja modal que aparece al terminar una ruta con ayudante.
/// El usuario puntúa de 1 a 5 estrellas o puede saltar.
struct HelperRatingView: View {
    let target: HelperRatingTarget
    var onDismiss: () -> Void

    @State private var selected = 0
    @State private var submitting = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "figure.2")
                .font(.system(size: 48))
                .foregroundStyle(Color.wheelpGreen)
                .padding(.top, 32)

            VStack(spacing: 6) {
                Text("¿Cómo te fue con \(target.name)?")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Tu valoración ayuda a otros usuarios a elegir ayudante.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= selected ? "star.fill" : "star")
                        .font(.system(size: 36))
                        .foregroundStyle(star <= selected ? Color.yellow : Color.secondary.opacity(0.4))
                        .onTapGesture { selected = star }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Valoración: \(selected) de 5 estrellas")

            VStack(spacing: 12) {
                Button {
                    guard selected > 0, !submitting else { return }
                    submitting = true
                    Task {
                        await HelperService.submitRating(helperId: target.id, rating: selected)
                        onDismiss()
                    }
                } label: {
                    Group {
                        if submitting {
                            ProgressView()
                        } else {
                            Text("Enviar valoración")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(selected > 0 ? Color.wheelpGreen : Color.secondary.opacity(0.2))
                    .foregroundStyle(selected > 0 ? .white : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(selected == 0 || submitting)

                Button("Ahora no") { onDismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
