import Foundation
import MeleteKit

/// Who is signed in, as `/me` says: their name, picture and whether they're an
/// admin. Held by Settings and shared with the Account screens, so a new
/// picture shows beside "Signed in as" the moment it's set, not the next time
/// Settings opens.
@MainActor
@Observable
final class AccountStore {
    private(set) var me: MeleteUser?

    /// Asks `/me` again. A failure keeps what was shown: until it answers, or
    /// on a server without pictures, the name's initial stands in.
    func refresh(_ client: MeleteClient?) async {
        guard let client, let found = try? await client.me() else { return }
        me = found
    }

    /// The picture's path after a change, as the server answered it. Its
    /// address carries the picture's hash, so the new one is fetched at once.
    func pictureChanged(to path: String?) {
        me = me?.with(avatarUrl: path)
    }
}

/// Two-factor sign-in's state, shared by its screens so turning it on or off
/// on one shows on the others when they come back.
@MainActor
@Observable
final class TwoFactorStore {
    private(set) var status: TwoFactorStatus?
    private(set) var errorMessage: String?

    func reload(_ client: MeleteClient?) async {
        guard let client else { return }
        do {
            status = try await client.twoFactorStatus()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = AccountMessage.words(for: error, while: .loadingTwoFactor)
        }
    }
}
