import CloudKit
import Foundation
import UserNotifications

/// What needs the person, relayed by the Mac app through their own iCloud (`CloudAlerts`), as it reaches their iPhone or
/// iPad: a CloudKit query notification whose record fields (the subscription's desired keys) carry the alert. Compiled
/// into the app and the notification service extension, which turns it into the content a push from pierd makes: the
/// title and body, the session to open (`box`, `session`, `location` in the userInfo, docs/PUSH.md 4.1), the choices
/// as buttons (`options`, NotificationChoices) and one thread per session.
enum CloudAlertPayload {
    static let recordType = "PierAlert"
    static let subscriptionID = "pier-alerts-v1"
    /// The record's fields the notification carries.
    static let desiredKeys = ["title", "body", "box", "session", "location", "category", "options"]

    struct Alert: Equatable {
        var title: String
        var body: String
        var box: String
        var session: String
        var location: String?
        var category: String?
        var options: [String]?
    }

    /// The Mac's alert in a notification's userInfo; nil for anything else (pierd's pushes, local notifications).
    static func alert(in userInfo: [AnyHashable: Any]) -> Alert? {
        guard userInfo["ck"] != nil,
              let note = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              note.subscriptionID == subscriptionID, let f = note.recordFields else { return nil }
        return alert(fields: f)
    }

    static func alert(fields f: [String: Any]) -> Alert? {
        guard let box = f["box"] as? String, let session = f["session"] as? String else { return nil }
        return Alert(title: f["title"] as? String ?? "", body: f["body"] as? String ?? "", box: box, session: session,
                     location: f["location"] as? String, category: f["category"] as? String,
                     options: f["options"] as? [String])
    }

    /// The userInfo the app's handlers read (as a push from pierd carries it), filled from the Mac's alert when there is one.
    static func userInfo(merging info: [AnyHashable: Any]) -> [AnyHashable: Any] {
        guard info["box"] == nil, let a = alert(in: info) else { return info }
        var out = info
        out["box"] = a.box
        out["session"] = a.session
        if let l = a.location { out["location"] = l }
        if let o = a.options { out[NotificationChoices.optionsKey] = o }
        return out
    }

    /// Fills a notification's content from the alert. The category is the alert's; choices get theirs from the caller
    /// (NotificationChoices.register), which needs the system's notification center.
    static func apply(_ a: Alert, to c: UNMutableNotificationContent) {
        if !a.title.isEmpty { c.title = a.title }
        if !a.body.isEmpty { c.body = a.body }
        c.userInfo = userInfo(merging: c.userInfo)
        c.threadIdentifier = "\(a.box)/\(a.session)"
        if let cat = a.category, !cat.isEmpty { c.categoryIdentifier = cat }
    }
}
