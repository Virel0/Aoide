import Foundation
import Network
import Observation

/// Whether the phone has a usable network path.
///
/// This answers "is there any connection at all", not "can we reach the Jellyfin
/// server" — a captive hotel wifi satisfies it and the server still won't answer.
/// That's the right question for choosing a launch screen: being on a network that
/// happens to be useless is rare, whereas being on a plane is exactly the case this
/// exists for, and a wrong guess costs one tab.
@MainActor
@Observable
final class Reachability {
    static let shared = Reachability()

    /// `nil` until the first path update lands. Distinguishing "not yet known" from
    /// "online" matters at launch: `NWPathMonitor` reports asynchronously, so an
    /// optimistic default would route an offline launch to Home every time, the
    /// monitor arriving a beat too late to matter.
    private(set) var isOnline: Bool?

    private let monitor = NWPathMonitor()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.apply(online) }
        }
        monitor.start(queue: DispatchQueue(label: AppIdentity.named("reachability")))
    }

    private func apply(_ online: Bool) {
        isOnline = online
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// Waits for the first real answer, giving up after a moment.
    ///
    /// The timeout is the point: a launch must not stall behind the network stack.
    /// If nothing has arrived by then the app opens normally, which is the same
    /// thing it did before any of this existed.
    func settled(timeout: Duration = .milliseconds(300)) async {
        guard isOnline == nil else { return }

        // A task group would be the obvious shape, but it awaits every child before
        // returning — the timeout would be forced to wait for the very thing it is
        // meant to bound. Whichever of these two arrives first drains `waiters`, and
        // draining is what makes the second a no-op.
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        await withCheckedContinuation { waiters.append($0) }
        deadline.cancel()
    }
}
