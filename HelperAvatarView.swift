import SwiftUI

/// Foto de perfil circular del ayudante, con fallback al icono de persona.
/// Prioridad: localImage (inmediato) > data URI en `url` (decodifica en background)
/// > URL HTTP con AsyncImage. Cachea el resultado para no decodificar en cada render.
struct HelperAvatarView: View {
    let url: String?
    let size: CGFloat
    var localImage: UIImage? = nil

    @State private var decodedDataImage: UIImage? = nil

    private static let dataPrefix = "data:image/jpeg;base64,"

    var body: some View {
        Group {
            if let img = localImage ?? decodedDataImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if let urlString = url,
                      !urlString.hasPrefix(Self.dataPrefix),
                      let imageURL = URL(string: urlString) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.wheelpGreen.opacity(0.4), lineWidth: 1.5))
        .accessibilityLabel("Foto del ayudante")
        .accessibilityHidden(true)
        .task(id: url) {
            // Decodifica el data URI en background y cachea el UIImage resultante.
            guard let urlString = url,
                  urlString.hasPrefix(Self.dataPrefix),
                  localImage == nil else { return }
            let base64 = String(urlString.dropFirst(Self.dataPrefix.count))
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: base64) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            decodedDataImage = decoded
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: size * 0.45))
            )
    }
}
