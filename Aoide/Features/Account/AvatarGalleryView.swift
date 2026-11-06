import MeleteKit
import SwiftUI

/// The server's profile picture gallery, by category: Melete's own pictures,
/// then any the server's admin added. Tapping one makes it yours (a copy, so it
/// stays if the gallery changes) and goes back.
struct AvatarGalleryView: View {
    @Environment(AppSession.self) private var session
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var shelves: [Shelf]?
    @State private var choosing: String?
    @State private var errorMessage: String?

    private static let pageSize = 60

    struct Shelf: Identifiable {
        let category: AvatarCategory
        var pictures: [AvatarPicture]
        var id: String { category.id }
        var hasMore: Bool { pictures.count < category.count }
    }

    var body: some View {
        ScrollView {
            if let errorMessage {
                ErrorLabel(errorMessage)
                    .padding()
            }
            if let shelves {
                if shelves.isEmpty {
                    ContentUnavailableView(
                        "No Pictures",
                        systemImage: "person.crop.circle",
                        description: Text("This server's gallery is empty. Choose a photo instead.")
                    )
                }
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(shelves) { shelf in
                        shelfView(shelf)
                    }
                }
                .padding()
            } else if errorMessage == nil {
                ProgressView("Loading the gallery…")
                    .padding(.top, 40)
            }
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .task { if shelves == nil { await load() } }
    }

    private func shelfView(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.category.name)
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 14)], spacing: 14) {
                ForEach(shelf.pictures) { picture in
                    pictureButton(picture)
                }
            }
            if shelf.hasMore {
                Button("Show More") { Task { await loadMore(of: shelf.id) } }
            }
        }
    }

    private func pictureButton(_ picture: AvatarPicture) -> some View {
        Button {
            choose(picture)
        } label: {
            AvatarView(name: "", url: session.client?.avatarURL(picture.url), size: 76)
                .overlay {
                    if choosing == picture.id { ProgressView() }
                }
        }
        .buttonStyle(.plain)
        .disabled(choosing != nil)
        .accessibilityLabel(Self.spokenName(picture.id))
        .accessibilityHint("Makes it your profile picture")
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            var loaded: [Shelf] = []
            for category in try await client.avatarCategories() {
                let page = try await client.avatarPictures(in: category.id, limit: Self.pageSize)
                loaded.append(Shelf(category: category, pictures: page.pictures))
            }
            shelves = loaded
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = AccountMessage.words(for: error, while: .loadingGallery)
        }
    }

    private func loadMore(of id: String) async {
        guard let client = session.client, let index = shelves?.firstIndex(where: { $0.id == id }),
              let shelf = shelves?[index]
        else { return }
        do {
            let page = try await client.avatarPictures(in: id, offset: shelf.pictures.count, limit: Self.pageSize)
            shelves?[index].pictures.append(contentsOf: page.pictures)
        } catch {
            errorMessage = AccountMessage.words(for: error, while: .loadingGallery)
        }
    }

    private func choose(_ picture: AvatarPicture) {
        guard let client = session.client else { return }
        choosing = picture.id
        errorMessage = nil
        Task {
            defer { choosing = nil }
            do {
                account.pictureChanged(to: try await client.setAvatar(galleryPicture: picture.id))
                dismiss()
            } catch {
                errorMessage = AccountMessage.words(for: error, while: .choosingGalleryPicture)
            }
        }
    }

    /// `official/01-flame.webp` read out as "flame".
    static func spokenName(_ id: String) -> String {
        let file = id.split(separator: "/").last.map(String.init) ?? id
        let stem = file.split(separator: ".").first.map(String.init) ?? file
        let words = stem.drop { $0.isNumber || $0 == "-" || $0 == "_" }
        let name = words.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return name.isEmpty ? "Picture" : name
    }
}
