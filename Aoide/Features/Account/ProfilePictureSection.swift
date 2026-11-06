import MeleteKit
import PhotosUI
import SwiftUI

/// The profile picture on the Account screen: a photo from the library, one
/// from the server's gallery, or none. Everyone signed in to the server sees
/// it beside your name.
struct ProfilePictureSection: View {
    @Environment(AppSession.self) private var session
    @Environment(AccountStore.self) private var account

    @State private var chosen: PhotosPickerItem?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var username: String { account.me?.name ?? session.client?.credentials?.username ?? "" }
    private var hasPicture: Bool { account.me?.avatarUrl != nil }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                AvatarView(name: username, url: session.client?.avatarURL(account.me?.avatarUrl), size: 64)
                Text(username)
                    .font(.headline)
                Spacer()
                if isWorking { ProgressView() }
            }
            .padding(.vertical, 4)

            PhotosPicker(selection: $chosen, matching: .images, photoLibrary: .shared()) {
                Label("Choose a Photo", systemImage: "photo.on.rectangle")
            }
            NavigationLink {
                AvatarGalleryView().environment(account)
            } label: {
                Label("Choose from the Gallery", systemImage: "square.grid.3x3")
            }
            if hasPicture {
                Button("Remove Picture", systemImage: "trash", role: .destructive, action: remove)
            }
            if let errorMessage {
                ErrorLabel(errorMessage)
            }
        } header: {
            Text("Profile Picture")
        } footer: {
            Text("""
                Everyone signed in to your server sees it beside your name. A photo is cropped to a square and \
                made smaller on this iPhone first.
                """)
        }
        .disabled(isWorking)
        .onChange(of: chosen) {
            guard let item = chosen else { return }
            chosen = nil
            upload(item)
        }
    }

    private func upload(_ item: PhotosPickerItem) {
        change(.uploadingPicture) { client in
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PictureProblem.unreadable
            }
            let jpeg = try await Task.detached { () throws -> Data in
                guard let jpeg = AvatarImage.jpeg(from: data) else { throw PictureProblem.unreadable }
                return jpeg
            }.value
            return try await client.setAvatar(jpeg, type: AvatarImage.contentType)
        }
    }

    private func remove() {
        change(.removingPicture) { client in try await client.removeAvatar() }
    }

    private func change(_ action: AccountMessage.Action, _ body: @escaping (MeleteClient) async throws -> String?) {
        guard let client = session.client else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                account.pictureChanged(to: try await body(client))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = AccountMessage.words(for: error, while: action)
            }
        }
    }
}

/// A photo the library handed over that isn't an image this iPhone can read.
private enum PictureProblem: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "That photo couldn't be read on this iPhone. Try another one."
    }
}
