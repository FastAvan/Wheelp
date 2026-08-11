import SwiftUI

/// Vista de recorte circular para la foto de perfil del ayudante.
/// El usuario puede hacer pinch para ampliar y arrastrar para reencuadrar.
/// Al confirmar se entrega un UIImage cuadrado de 512×512 px ya recortado.
struct AvatarCropView: View {
    let image: UIImage
    let onConfirm: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var containerSize: CGSize = .zero

    private let cropFraction: CGFloat = 0.82

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let cropSize = proxy.size.width * cropFraction
                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .clipped()
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = max(1.0, min(8.0, lastScale * value))
                                    }
                                    .onEnded { _ in lastScale = scale },
                                DragGesture()
                                    .onChanged { value in
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in lastOffset = offset }
                            )
                        )
                        .accessibilityLabel("Foto de perfil")
                        .accessibilityHint("Pellizca para ampliar y arrastra para centrar. Activa 'Usar foto' en la barra superior para confirmar.")
                        .accessibilityAction(named: "Usar foto sin ajustar") {
                            onConfirm(cropResult())
                        }

                    CropMaskView(cropSize: cropSize)
                        .allowsHitTesting(false)

                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        .frame(width: cropSize, height: cropSize)
                        .allowsHitTesting(false)

                    VStack {
                        Spacer()
                        Text("Pellizca para ampliar · Arrastra para reencuadrar")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.bottom, 20)
                    }
                    .allowsHitTesting(false)
                }
                .onAppear { containerSize = proxy.size }
                .onChange(of: proxy.size) { _, size in containerSize = size }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Ajustar foto")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Usar foto") {
                        onConfirm(cropResult())
                    }
                    .fontWeight(.semibold)
                    .tint(Color.wheelpGreen)
                }
            }
        }
    }

    // MARK: - Recorte

    private func cropResult() -> UIImage {
        let img = normalized(image)
        let imgPoints = img.size
        let container = containerSize.width > 0 ? containerSize : UIScreen.main.bounds.size
        let cropSizePoints = container.width * cropFraction

        let fillScale = max(container.width / imgPoints.width, container.height / imgPoints.height)
        let totalScale = fillScale * scale
        let imgPtsPerScreenPt = 1.0 / totalScale

        let cropCenter = CGPoint(
            x: imgPoints.width / 2.0 - offset.width * imgPtsPerScreenPt,
            y: imgPoints.height / 2.0 - offset.height * imgPtsPerScreenPt
        )
        let halfCropInImg = (cropSizePoints / 2.0) * imgPtsPerScreenPt

        let pixelScale = img.scale
        let cropPixels = CGRect(
            x: (cropCenter.x - halfCropInImg) * pixelScale,
            y: (cropCenter.y - halfCropInImg) * pixelScale,
            width: halfCropInImg * 2 * pixelScale,
            height: halfCropInImg * 2 * pixelScale
        ).integral

        let imageBoundsPixels = CGRect(
            x: 0, y: 0,
            width: imgPoints.width * pixelScale,
            height: imgPoints.height * pixelScale
        )
        let safeRect = cropPixels.intersection(imageBoundsPixels)

        guard !safeRect.isNull, !safeRect.isEmpty,
              let croppedCG = img.cgImage?.cropping(to: safeRect) else { return img }

        let outputSize = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { _ in
            UIImage(cgImage: croppedCG).draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }

    private func normalized(_ src: UIImage) -> UIImage {
        guard src.imageOrientation != .up else { return src }
        let renderer = UIGraphicsImageRenderer(size: src.size)
        return renderer.image { _ in src.draw(at: .zero) }
    }
}

// MARK: - Máscara con agujero circular

private struct CropMaskView: View {
    let cropSize: CGFloat

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            ctx.blendMode = .destinationOut
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: (size.width - cropSize) / 2,
                    y: (size.height - cropSize) / 2,
                    width: cropSize,
                    height: cropSize
                )),
                with: .color(.white)
            )
        }
        .compositingGroup()
    }
}
