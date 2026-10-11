import UserNotifications

/// Every alert push passes through here before it is shown (`mutable-content: 1`, docs/PUSH.md 4.2), pierd's and the
/// alerts a Mac relays through the person's iCloud (CloudAlertPayload, made into the same content first). A waiting agent's
/// choices (`options` in the payload) become the notification's buttons: a category for them is registered
/// (`NotificationChoices`, shared with the app) and named on the content, so the person answers the question from the
/// Lock Screen. Everything else goes through untouched. No network, no keychain: the payload has all it needs.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let c = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        // An alert a Mac relayed through the person's iCloud (CloudAlertPayload): the same content a push from pierd has.
        if let alert = CloudAlertPayload.info(in: request.content.userInfo) { CloudAlertPayload.apply(alert, to: c) }
        lock.withLock { handler = contentHandler; content = c }
        guard let options = NotificationChoices.options(in: c.userInfo) else { finish(); return }
        Task {
            let id = await NotificationChoices.register(options: options)
            // The registration lands in the system daemon a moment later: let it, so the banner is drawn with its buttons.
            try? await Task.sleep(for: .milliseconds(200))
            self.lock.withLock { self.content?.categoryIdentifier = id }
            self.finish()
        }
    }

    /// Out of time: show what we have (with its buttons when the registration made it, without them otherwise).
    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        let (h, c): (((UNNotificationContent) -> Void)?, UNMutableNotificationContent?) = lock.withLock {
            defer { handler = nil }
            return (handler, content)
        }
        if let h, let c { h(c) }
    }
}
