import Foundation
import UserNotifications
#if os(iOS) && !targetEnvironment(macCatalyst)
import Intents
import UIKit
#endif

/// An agent's notification as a message from that agent (a communication notification): the agent is the sender, with
/// its avatar, and each session is a conversation (`CarDigest.conversationID`). That is what lets Siri read it aloud in
/// the car (and on AirPods) and answer it: "Responder" dictates a reply that comes back to the app as an
/// `INSendMessageIntent` for that conversation (App/Intents/MessageIntents.swift), which sends it to the session.
/// Compiled into the app (local notifications) and the notification service extension (pierd's pushes). iPhone and iPad
/// only: the Mac app has no Siri messaging and posts plain notifications.
enum CommunicationNotification {
    /// The categories Siri may answer through a message intent, and that CarPlay shows.
    static var categoryOptions: UNNotificationCategoryOptions {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return [.allowInCarPlay]
        #else
        return []
        #endif
    }

    static var intentIdentifiers: [String] {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return [INSendMessageIntentIdentifier]
        #else
        return []
        #endif
    }

    /// `CarDigest.conversationID` (PierKit, tested there): the extension does not link PierKit, so the same rule is
    /// written here too; `selfCheck()` compares the two in Debug builds.
    static func conversationID(box: String, session: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "pier-session:" + (box.addingPercentEncoding(withAllowedCharacters: safe) ?? box) + "/"
            + (session.addingPercentEncoding(withAllowedCharacters: safe) ?? session)
    }

    /// What a pierd alert says, read back from its parts (docs/PUSH.md 4.2): title "✋ Needs you · Fix login", subtitle
    /// "shop / checkout-fix · Claude Code". nil pieces when the alert is laid out another way.
    static func parts(title: String, subtitle: String) -> (state: String?, conversation: String?, agent: String?) {
        let t = title.components(separatedBy: " · ")
        let s = subtitle.components(separatedBy: " · ")
        return (t.count >= 2 ? t[0] : nil, t.count >= 2 ? t.dropFirst().joined(separator: " · ") : nil,
                s.count >= 2 ? s[1] : nil)
    }

    /// The content as a message from `agent` in the conversation `conversation` (the session's title), its words led by
    /// `state` ("Precisa de você", "Terminou"). The content as it was when the system refuses (no Siri, no entitlement).
    static func apply(to content: UNMutableNotificationContent, box: String, session: String, agent: String,
                      conversation: String, state: String?) async -> UNNotificationContent {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let id = conversationID(box: box, session: session)
        let sender = INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: nil,
                              displayName: "\(agent) · \(conversation)", image: avatar(for: agent), contactIdentifier: nil,
                              customIdentifier: id)
        let words = [state, content.body.isEmpty ? nil : content.body].compactMap { $0 }.joined(separator: " — ")
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: words,
                                         speakableGroupName: INSpeakableString(spokenPhrase: conversation),
                                         conversationIdentifier: id, serviceName: nil, sender: sender, attachments: nil)
        intent.setImage(avatar(for: agent), forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.groupIdentifier = id
        try? await interaction.donate()
        content.body = words
        return (try? content.updating(from: intent)) ?? content
        #else
        return content
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// The agent's mark: its initial on its color, as the app draws agents (Claude orange, Codex graphite).
    static func avatar(for agent: String) -> INImage? {
        avatarImage(for: agent).pngData().map { INImage(imageData: $0) }
    }

    static func avatarImage(for agent: String) -> UIImage {
        let lower = agent.lowercased()
        let color: UIColor = lower.contains("claude") ? UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
            : lower.contains("codex") ? UIColor(white: 0.22, alpha: 1) : UIColor(red: 0.33, green: 0.52, blue: 0.95, alpha: 1)
        let size = CGSize(width: 120, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let letter = String(agent.first ?? "A").uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 60, weight: .bold), .foregroundColor: UIColor.white]
            let s = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2), withAttributes: attrs)
        }
    }
    #endif
}
