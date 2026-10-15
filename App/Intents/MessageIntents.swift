#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import Intents
import PierKit

/// Siri's side of the agents' conversations, in the car and anywhere else (iPhone and iPad):
/// - **send** (`INSendMessageIntent`): "Responder" to an agent's notification, a CarPlay conversation, or "manda uma
///   mensagem pro Claude no Fix login" — the words go to that session (`SessionActions.send`, queued until it is idle);
/// - **read** (`INSearchForMessagesIntent`): what a CarPlay row or "lê minhas mensagens do Pier" reads aloud, the waiting
///   agents' requests and the replies that ended their turns (`CarFeed.words`);
/// - **mark read** (`INSetMessageAttributeIntent`): nothing to keep, said done.
/// The conversation is the session (`CarDigest.conversationID`), the person speaking is its agent. Handled in the app
/// (`AppDelegate.application(_:handlerFor:)`), which Siri starts in the background, the phone locked or not.
final class MessageIntentHandler: NSObject, INSendMessageIntentHandling, INSearchForMessagesIntentHandling,
                                  INSetMessageAttributeIntentHandling, @unchecked Sendable {
    static func handles(_ intent: INIntent) -> Bool {
        intent is INSendMessageIntent || intent is INSearchForMessagesIntent || intent is INSetMessageAttributeIntent
    }

    /// The agent of a conversation as Siri names it: "Claude Code · Fix login".
    static func person(_ row: CarDigest.Row) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: row.id, type: .unknown), nameComponents: nil,
                 displayName: "\(CarDigest.agentName(row.session)) · \(CarDigest.title(row.session))",
                 image: CommunicationNotification.avatar(for: CarDigest.agentName(row.session)), contactIdentifier: nil,
                 customIdentifier: row.id)
    }

    // MARK: send

    func resolveRecipients(for intent: INSendMessageIntent, with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void) {
        let done = Once(completion)
        let conversation = intent.conversationIdentifier
        let asked = (intent.recipients ?? []).map { Asked(person: $0) }
        Task {
            // A reply in a conversation Siri already knows (a notification, a CarPlay row): its agent.
            if let conversation, CarDigest.parse(conversation) != nil {
                if let row = await CarFeed.row(for: conversation) { done.run([.success(with: Self.person(row))]); return }
                done.run([.unsupported(forReason: .noValidHandle)]); return
            }
            guard !asked.isEmpty else { done.run([.needsValue()]); return }
            let rows = await CarFeed.rows(limit: 30)
            var results: [INSendMessageRecipientResolutionResult] = []
            for a in asked {
                if let id = a.id {
                    var row = rows.first(where: { $0.id == id })
                    if row == nil { row = await CarFeed.row(for: id) }
                    if let row { results.append(.success(with: Self.person(row))); continue }
                }
                let found = Self.match(a.name, in: rows)
                switch found.rows.count {
                case 0: results.append(.unsupported(forReason: .noValidHandle))
                // Only part of what was heard matched: Siri asks before the words go to that session.
                case 1: results.append(found.exact ? .success(with: Self.person(found.rows[0])) : .confirmationRequired(with: Self.person(found.rows[0])))
                default: results.append(.disambiguation(with: found.rows.prefix(5).map(Self.person)))
                }
            }
            done.run(results)
        }
    }

    func resolveContent(for intent: INSendMessageIntent, with completion: @escaping (INStringResolutionResult) -> Void) {
        let text = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        completion(text.isEmpty ? .needsValue() : .success(with: text))
    }

    func handle(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        let done = Once(completion)
        let target = intent.conversationIdentifier.flatMap(CarDigest.parse)
            ?? intent.recipients?.lazy.compactMap { Asked(person: $0).id.flatMap(CarDigest.parse) }.first
        let text = intent.content ?? ""
        guard let target else { done.run(INSendMessageIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)); return }
        Task {
            switch await SessionActions.reply(box: target.box, session: target.session, text: text) {
            case .success: done.run(INSendMessageIntentResponse(code: .success, userActivity: nil))
            case .failure: done.run(INSendMessageIntentResponse(code: .failure, userActivity: nil))
            }
        }
    }

    // MARK: read

    func handle(intent: INSearchForMessagesIntent, completion: @escaping (INSearchForMessagesIntentResponse) -> Void) {
        let done = Once(completion)
        let wanted = Set(intent.conversationIdentifiers ?? [])
        let senders = (intent.senders ?? []).map { Asked(person: $0) }
        Task {
            var rows = await CarFeed.rows(limit: 6).filter { $0.kind != .working }
            if !wanted.isEmpty {
                rows = rows.filter { wanted.contains($0.id) }
                // A conversation that left the lists (archived meanwhile): read straight from its box.
                for id in wanted where !rows.contains(where: { $0.id == id }) { if let r = await CarFeed.row(for: id) { rows.append(r) } }
            } else if !senders.isEmpty {
                rows = rows.filter { r in senders.contains { s in s.id == r.id || !Self.match(s.name, in: [r]).rows.isEmpty } }
            }
            // The words of each, read in parallel; the messages made from them afterwards (INMessage is not Sendable).
            let words = await withTaskGroup(of: (Int, String).self) { g in
                for (i, row) in rows.enumerated() { g.addTask { (i, await CarFeed.words(for: row)) } }
                var out: [Int: String] = [:]
                for await (i, w) in g { out[i] = w }
                return out
            }
            let messages = rows.enumerated().map { i, row in
                INMessage(identifier: "\(row.id)#\(Int(row.since.timeIntervalSince1970))", conversationIdentifier: row.id,
                          content: words[i] ?? "", dateSent: row.since, sender: Self.person(row), recipients: nil,
                          groupName: INSpeakableString(spokenPhrase: CarDigest.title(row.session)), messageType: .text,
                          serviceName: nil)
            }
            let r = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
            r.messages = messages
            done.run(r)
        }
    }

    // MARK: mark read

    func handle(intent: INSetMessageAttributeIntent, completion: @escaping (INSetMessageAttributeIntentResponse) -> Void) {
        completion(INSetMessageAttributeIntentResponse(code: .success, userActivity: nil))
    }

    // MARK: matching

    /// Rows whose title or agent is the name Siri heard ("Fix login", "Claude", "Claude no Fix login"), by whole words of
    /// three letters or more: `exact` when the whole title or agent name was said, else only some of its words were (the
    /// caller asks before sending). A title "api" never matches "rapid fix".
    static func match(_ heard: String?, in rows: [CarDigest.Row]) -> (rows: [CarDigest.Row], exact: Bool) {
        func words(_ s: String) -> [String] {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        }
        let said = words(heard ?? "")
        guard !said.isEmpty else { return ([], false) }
        let saidSet = Set(said)
        func contained(_ w: [String]) -> Bool { !w.isEmpty && w.allSatisfy(saidSet.contains) }
        // The whole title said (in what was heard), then the whole agent name, then titles sharing words.
        let byTitle = rows.filter { contained(words(CarDigest.title($0.session))) }
        if !byTitle.isEmpty { return (byTitle, true) }
        let byAgent = rows.filter { r in contained(words(CarDigest.agentName(r.session))) || saidSet.contains(words(CarDigest.agentName(r.session)).first ?? "") }
        if !byAgent.isEmpty { return (byAgent, byAgent.count == 1) }
        let scored = rows.map { r in (r, Set(words(CarDigest.title(r.session))).intersection(saidSet).count) }.filter { $0.1 > 0 }
        guard let best = scored.map(\.1).max() else { return ([], false) }
        return (scored.filter { $0.1 == best }.map(\.0), false)
    }

    /// What Siri passed of a person, read once on the calling thread (INPerson is not Sendable).
    private struct Asked: Sendable {
        let id: String?
        let name: String?
        init(person: INPerson) {
            id = [person.customIdentifier, person.personHandle?.value].compactMap { $0 }.first { CarDigest.parse($0) != nil }
            name = person.displayName.isEmpty ? person.nameComponents?.givenName : person.displayName
        }
    }

    /// A completion handler carried into a task and called once (the system's handlers are not marked Sendable).
    private final class Once<T>: @unchecked Sendable {
        private var run_: ((T) -> Void)?
        private let lock = NSLock()
        init(_ run: @escaping (T) -> Void) { run_ = run }
        func run(_ value: T) {
            let f = lock.withLock { () -> ((T) -> Void)? in defer { run_ = nil }; return run_ }
            f?(value)
        }
    }
}
#endif
