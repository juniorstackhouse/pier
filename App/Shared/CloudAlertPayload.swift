import CloudKit
import Foundation
import UserNotifications

/// What needs the person, relayed by the Mac app through their own iCloud (`CloudAlerts`), as it reaches their iPhone or
/// iPad: a CloudKit query notification. Its title and body are the record's `title` and `body` (the subscription's
/// localization arguments); everything else rides in one field, `info` (JSON), because CloudKit refuses a subscription
/// that asks for more than a few additional fields. Compiled into the app and the notification service extension, which
/// turns it into the content a push from pierd makes: the session to open (`box`, `session`, `location` in the
/// userInfo, docs/PUSH.md 4.1), the choices as buttons (`options`, NotificationChoices) and one thread per session.
enum CloudAlertPayload {
    static let recordType = "PierAlert"
    static let subscriptionID = "pier-alerts-v1"
    /// The record's field the notification carries besides its title and body.
    static let infoKey = "info"

    /// Where the alert leads and what it offers: the `info` field.
    struct Info: Codable, Equatable {
        var box: String
        var session: String
        var location: String?
        var category: String?
        var options: [String]?
    }

    static func encode(_ info: Info) -> String {
        (try? JSONEncoder().encode(info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode(_ text: String) -> Info? {
        try? JSONDecoder().decode(Info.self, from: Data(text.utf8))
    }

    /// The Mac's alert in a notification's userInfo; nil for anything else (pierd's pushes, local notifications).
    static func info(in userInfo: [AnyHashable: Any]) -> Info? {
        guard userInfo["ck"] != nil,
              let note = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              note.subscriptionID == subscriptionID, let text = note.recordFields?[infoKey] as? String else { return nil }
        return decode(text)
    }

    /// The userInfo the app's handlers read (as a push from pierd carries it), filled from the Mac's alert when there is one.
    static func userInfo(merging info: [AnyHashable: Any]) -> [AnyHashable: Any] {
        guard info["box"] == nil, let a = Self.info(in: info) else { return info }
        var out = info
        out["box"] = a.box
        out["session"] = a.session
        if let l = a.location { out["location"] = l }
        if let o = a.options { out[NotificationChoices.optionsKey] = o }
        return out
    }

    /// Fills a notification's content from the alert (its title and body are already the record's). The category is the
    /// alert's; choices get theirs from the caller (NotificationChoices.register), which needs the notification center.
    static func apply(_ a: Info, to c: UNMutableNotificationContent) {
        c.userInfo = userInfo(merging: c.userInfo)
        c.threadIdentifier = "\(a.box)/\(a.session)"
        if let cat = a.category, !cat.isEmpty { c.categoryIdentifier = cat }
    }
}
