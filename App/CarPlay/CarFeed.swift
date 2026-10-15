import Foundation
import PierKit

/// What the car and Siri read from the boxes, without the app's window (the phone can be locked in a pocket while
/// CarPlay or Siri runs the app in the background): the conversations `CarDigest` lists, from every paired box, and the
/// words of each, made to be heard.
enum CarFeed {
    /// The car's rows: waiting agents, ended turns not archived, agents at work (`CarDigest.rows`).
    static func rows(limit: Int = 8) async -> [CarDigest.Row] {
        guard let items = try? await HeadlessBoxes.sessions() else { return [] }
        let marks = await LocalPrefs.savedClosedMarks()
        return CarDigest.rows(items, archived: { LocalPrefs.isClosed(marks, box: $0, session: $1) }, limit: limit)
    }

    /// The row for a conversation id, read fresh from its box.
    static func row(for id: String) async -> CarDigest.Row? {
        guard let (box, name) = CarDigest.parse(id), let client = try? HeadlessBoxes.box(box).client,
              let s = try? await client.sessions().first(where: { $0.name == name }) else { return nil }
        let kind: CarDigest.Kind = s.needsYou ? .needsYou : s.agentState == .running ? .working : .yourTurn
        return CarDigest.Row(box: box, session: s, kind: kind)
    }

    /// What Siri reads for a conversation: a waiting agent's request or question, the reply that ended a turn (its words
    /// only, `CarDigest.spoken`), or that it is still at work.
    static func words(for row: CarDigest.Row) async -> String {
        switch row.kind {
        case .needsYou:
            return ask(row.session)
        case .working:
            return String(localized: "Ainda está trabalhando.")
        case .yourTurn:
            guard let client = try? HeadlessBoxes.box(row.box).client else { return String(localized: "Terminou.") }
            let name = row.session.name
            let reply: String? = await BoxAccess.withTimeout(.seconds(4)) {
                SessionSignals.lastReplyMarkdown(try await client.transcriptBefore(session: name, before: 0, limit: 40))
            } ?? nil
            guard let reply, !reply.isEmpty else { return String(localized: "Terminou.") }
            return CarDigest.spoken(reply, codePlaceholder: String(localized: "(código)"))
        }
    }

    /// "Quer permissão para Bash: rm -rf build", or the agent's question.
    static func ask(_ s: Session) -> String {
        guard let a = s.ask else { return String(localized: "Precisa de você.") }
        if Ask.classify(a) == .permission {
            let what = [a.tool, a.input].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            return what.isEmpty ? String(localized: "Pede uma permissão.") : String(localized: "Quer permissão para \(what)")
        }
        if let m = a.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return CarDigest.spoken(m, limit: 300) }
        return String(localized: "Tem uma pergunta para você.")
    }
}
