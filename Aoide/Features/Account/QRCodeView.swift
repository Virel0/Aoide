import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A link drawn as a QR code on the phone, black on white with its quiet
/// margin, for another device's camera. Drawn here rather than from the
/// server's SVG: nothing to parse, and the drawing lives no longer than the
/// view.
struct QRCodeView: View {
    private let image: UIImage?
    private let side: CGFloat

    init(text: String, side: CGFloat = 200) {
        image = Self.image(for: text)
        self.side = side
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .padding(12)
        .background(.white, in: .rect(cornerRadius: 8))
    }

    /// The code at one pixel per module; SwiftUI scales it up without blur.
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
