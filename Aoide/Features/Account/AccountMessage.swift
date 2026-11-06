import Foundation
import MeleteKit

/// What went wrong on the Account screens, in the app's words: the same
/// status means something different from one request to the next (a 409 is
/// "on already" for setup and "nothing waiting" for a code).
enum AccountMessage {
    enum Action {
        case uploadingPicture, choosingGalleryPicture, removingPicture, loadingGallery
        case changingPassword
        case loadingTwoFactor, startingTwoFactor, confirmingTwoFactor, turningOffTwoFactor
        case loadingUsers, givingPassword
    }

    static let locked = "Too many wrong passwords or codes. Wait 15 minutes, then try again."

    static func words(for error: any Error, while action: Action) -> String {
        if let specific = specific(error, action) { return specific }
        if case MeleteError.http(status: 429, _, _) = error { return locked }
        return (error as? MeleteError)?.errorDescription ?? error.localizedDescription
    }

    private static func specific(_ error: any Error, _ action: Action) -> String? {
        switch (action, error as? MeleteError) {
        case (.uploadingPicture, .http(status: 400, _, _)?):
            "The server couldn't read that photo as a JPEG, PNG or WebP image. Try another one."
        case (.uploadingPicture, .http(status: 413, _, _)?):
            "That photo is over the server's 5 MB limit. Try a smaller one."
        case (.choosingGalleryPicture, .notFound?):
            "That picture isn't in the server's gallery any more. Choose another."
        case (.choosingGalleryPicture, .http(status: 422, _, _)?):
            "The server can't use that gallery picture. Choose another."
        case (.changingPassword, .wrong(.password)?):
            "Your current password isn't right."
        case (.changingPassword, .http(status: 400, _, _)?):
            "The new password needs 8 to 1,024 characters."
        case (.changingPassword, .http(status: 429, _, _)?):
            "Too many wrong passwords. Wait 15 minutes, then try again."
        case (.startingTwoFactor, .http(status: 409, _, _)?):
            "Two-factor sign-in is on already. Turn it off first to set it up again."
        case (.confirmingTwoFactor, .http(status: 409, _, _)?):
            "This setup isn't waiting for a code any more. Start again for a new secret."
        case (.turningOffTwoFactor, .http(status: 409, _, _)?):
            "Two-factor sign-in is off already."
        case (.loadingUsers, .forbidden?), (.givingPassword, .forbidden?):
            "Only an admin of this server can do that."
        case (.givingPassword, .notFound?):
            "That user isn't on the server any more."
        case (.givingPassword, .http(status: 409, _, _)?):
            "That's your own account. Change your own password under Change Password."
        default:
            nil
        }
    }
}
