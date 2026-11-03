import SwiftUI

/// Someone's profile picture, small and round. Without one, or until it has
/// loaded, the first letter of their name in a round tile.
///
/// Fetched through ``ArtworkCache``, which sends the token Melete asks for. The
/// address carries the picture's hash, so a new picture is a new address.
struct AvatarView: View {
    let name: String
    let url: URL?
    var size: CGFloat = 28

    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(.fill.tertiary)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(initial)
                        .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                image = await ArtworkCache.shared.image(for: url)
            }
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
    }
}
