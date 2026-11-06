import Foundation
import Testing
@testable import MeleteKit

@Suite("Turning two-factor sign-in on and off")
struct TwoFactorTests {
    @Test("the status reads when it came on and what changed, newest first")
    func status() async throws {
        let client = StubServer.client(host: "tf-status.test") { _, _ in
            (200, Fixture.json([
                "on": true, "on_since": 1_700_000_000,
                "changes": [
                    ["change": "wrong_sign_in_code", "made_from": "sign_in", "at": 1_700_000_900, "count": 3],
                    ["change": "two_factor_on", "made_from": "account", "at": 1_700_000_000, "count": 1],
                    ["change": "two_factor_off", "made_from": "server", "at": 1_600_000_000, "count": 1],
                ],
            ]))
        }
        let status = try await client.twoFactorStatus()
        #expect(status.on && status.onSince == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(status.changes.map(\.change) == [.wrongSignInCode, .turnedOn, .turnedOff])
        #expect(status.changes.map(\.madeFrom) == [.signIn, .account, .server])
        #expect(status.changes.first?.count == 3)
    }

    @Test("off, it has no start date and no changes")
    func off() async throws {
        let client = StubServer.client(host: "tf-off.test") { _, _ in
            (200, Fixture.json(["on": false, "on_since": NSNull(), "changes": []]))
        }
        let status = try await client.twoFactorStatus()
        #expect(!status.on && status.onSince == nil && status.changes.isEmpty)
    }

    @Test("setup needs the password and answers the secret; the code confirms it; a wrong one is named")
    func setUp() async throws {
        let client = StubServer.client(host: "tf-setup.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            switch request.url?.path() {
            case "/api/v1/me/two-factor/setup":
                guard sent?["password"] == "right" else {
                    return (403, Fixture.json(["error": "password is wrong", "reason": "wrong_password"]))
                }
                return (200, Fixture.json([
                    "secret": "JBSWY3DPEHPK3PXP",
                    "uri": "otpauth://totp/Melete:alex?secret=JBSWY3DPEHPK3PXP&issuer=Melete",
                    "qr": "<svg/>",
                ]))
            case "/api/v1/me/two-factor/confirm":
                return sent?["code"] == "123456"
                    ? (204, Data())
                    : (403, Fixture.json(["error": "wrong code", "reason": "wrong_code"]))
            default:
                return (404, Data())
            }
        }
        await #expect(throws: MeleteError.wrong(.password)) { try await client.startTwoFactor(password: "guess") }
        let setup = try await client.startTwoFactor(password: "right")
        #expect(setup.secret == "JBSWY3DPEHPK3PXP" && setup.uri.hasPrefix("otpauth://totp/"))
        await #expect(throws: MeleteError.wrong(.code)) { try await client.confirmTwoFactor(code: "000000") }
        try await client.confirmTwoFactor(code: " 123 456 ")
    }

    @Test("turning off says which secret was wrong, and when it's off already")
    func turnOff() async throws {
        let client = StubServer.client(host: "tf-turnoff.test") { _, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            switch (sent?["password"], sent?["code"]) {
            case ("right", "123456"): return (204, Data())
            case ("right", _): return (403, Fixture.json(["error": "wrong code", "reason": "wrong_code"]))
            case ("again", _): return (409, Fixture.json(["error": "two-factor sign-in is off already"]))
            default: return (403, Fixture.json(["error": "password is wrong", "reason": "wrong_password"]))
            }
        }
        await #expect(throws: MeleteError.wrong(.password)) { try await client.turnOffTwoFactor(password: "guess", code: "123456") }
        await #expect(throws: MeleteError.wrong(.code)) { try await client.turnOffTwoFactor(password: "right", code: "999999") }
        try await client.turnOffTwoFactor(password: "right", code: "123456")
        do {
            try await client.turnOffTwoFactor(password: "again", code: "123456")
            Issue.record("off twice")
        } catch MeleteError.http(status: 409, _, _) {}
    }

    @Test("too many wrong tries is the server's 429, words and all")
    func locked() async throws {
        let client = StubServer.client(host: "tf-locked.test") { _, _ in
            (429, Fixture.json(["error": "too many wrong passwords or codes; try again in 15 minutes"]))
        }
        do {
            _ = try await client.startTwoFactor(password: "right")
            Issue.record("not locked")
        } catch MeleteError.http(status: 429, _, let detail) {
            #expect(detail?.contains("15 minutes") == true)
        }
    }
}
