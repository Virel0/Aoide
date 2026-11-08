import MeleteKit
import SwiftUI

/// A request search result's cover, or an artist's portrait in a circle, as the
/// server gives it (`poster`); the placeholder when it has none.
struct RequestPicture: View {
    let candidate: RequestCandidate
    var size: CGFloat = 44

    var body: some View {
        let url = candidate.poster.flatMap {
            AppSession.shared.client?.posterURL($0, maxWidth: Int(size * 3))
        }
        ArtworkView(url: url, cornerRadius: candidate.kind == .artist ? size / 2 : 4)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A portrait's author and licence, which its licence asks to be shown with it,
/// opening its page on Commons when there's one.
struct PosterCreditLine: View {
    let credit: PosterCredit

    var body: some View {
        if let line = credit.line {
            Group {
                if let link = credit.link {
                    Link(destination: link) { Text(line).underline() }
                        .buttonStyle(.borderless)
                } else {
                    Text(line)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}
