import Foundation

/// What the car shows and what Siri reads (pure, tested): the agents that need the person, the turns that ended and the
/// agents at work, each a conversation Siri can read and answer by its id; and an agent's reply made fit to be spoken.
/// CarPlay (App/CarPlay), the message intents (App/Intents/MessageIntents.swift) and the communication notifications
/// (App/Shared/CommunicationNotification.swift) all go by these ids, so a reply said to Siri lands in the right session.
public enum CarDigest {
    public enum Kind: Int, Sendable, Hashable {
        case needsYou = 0, yourTurn = 1, working = 2
    }

    public struct Row: Sendable, Hashable, Identifiable {
        /// The conversation's id (`conversationID(box:session:)`).
        public let id: String
        public let box: String
        public let session: Session
        public let kind: Kind
        public let since: Date

        public init(box: String, session: Session, kind: Kind) {
            self.id = CarDigest.conversationID(box: box, session: session.name)
            self.box = box
            self.session = session
            self.kind = kind
            self.since = session.stateSince ?? session.created
        }
    }

    // MARK: conversation ids

    private static let scheme = "pier-session:"
    /// Unreserved characters only: a box or a session name can hold a "/" (or anything else) and still come back whole.
    private static let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// "pier-session:<box>/<session>", both percent-encoded: the conversation a notification, a CarPlay row and Siri share.
    public static func conversationID(box: String, session: String) -> String {
        let b = box.addingPercentEncoding(withAllowedCharacters: safe) ?? box
        let s = session.addingPercentEncoding(withAllowedCharacters: safe) ?? session
        return scheme + b + "/" + s
    }

    /// The box and session a conversation id names; nil for anything else (an id of another app, a contact's handle).
    public static func parse(_ id: String?) -> (box: String, session: String)? {
        guard let id, id.hasPrefix(scheme) else { return nil }
        let rest = id.dropFirst(scheme.count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let b = parts[0].removingPercentEncoding, let s = parts[1].removingPercentEncoding,
              !b.isEmpty, !s.isEmpty else { return nil }
        return (b, s)
    }

    // MARK: sections

    /// The rows the car lists: agents waiting (oldest first: the one waiting longest is the most urgent), then turns that
    /// ended and were not archived (newest first), then agents at work (newest first). Each list capped at `limit`: a
    /// driver gets a short list. `archived` says which finished turns the person closed; ties keep their order by id.
    public static func rows(_ items: [(box: String, session: Session)], archived: (String, Session) -> Bool = { _, _ in false },
                            limit: Int = 8) -> [Row] {
        var out: [Row] = []
        for (box, s) in items where s.isAgent && !s.exited {
            switch s.agentState {
            case .waiting: out.append(Row(box: box, session: s, kind: .needsYou))
            case .finished where !archived(box, s): out.append(Row(box: box, session: s, kind: .yourTurn))
            case .running: out.append(Row(box: box, session: s, kind: .working))
            default: break
            }
        }
        out.sort { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.since != b.since { return a.kind == .needsYou ? a.since < b.since : a.since > b.since }
            return a.id < b.id
        }
        var counts: [Kind: Int] = [:]
        return out.filter { r in
            counts[r.kind, default: 0] += 1
            return counts[r.kind]! <= limit
        }
    }

    /// The name Siri says for an agent's conversation: its title, else the project (worktree) it works in, else the name.
    public static func title(_ s: Session) -> String {
        if let t = s.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let l = s.location, !l.isEmpty { return l.replacingOccurrences(of: "/", with: " / ") }
        return s.name
    }

    /// "Claude Code", "Codex": who speaks in the conversation.
    public static func agentName(_ s: Session) -> String {
        switch s.agent?.lowercased() {
        case "claude", "claude-code", "claudecode": return "Claude Code"
        case "codex": return "Codex"
        case let a?: return a.prefix(1).uppercased() + a.dropFirst()
        case nil: return "Agent"
        }
    }

    // MARK: speech

    /// An agent's reply (Markdown) made fit for Siri to read aloud in the car: code blocks and tables become a short
    /// placeholder, links keep their words, marks go, whitespace folds, and it ends on a sentence within `limit`
    /// characters (a reply can be pages long; the rest stays for the phone).
    public static func spoken(_ markdown: String, limit: Int = 600, codePlaceholder: String = "(code)") -> String {
        var lines: [String] = []
        var inFence = false
        var placeholderDue = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if !inFence { placeholderDue = true }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if placeholderDue { lines.append(codePlaceholder); placeholderDue = false }
            // Tables: their rows are read as nothing useful; a separator row or a piped row goes.
            if line.hasPrefix("|") { continue }
            var l = line
            // Headings, quotes, list marks and rules.
            while let f = l.first, f == "#" || f == ">" { l.removeFirst(); l = l.trimmingCharacters(in: .whitespaces) }
            if l == "---" || l == "***" || l == "___" { continue }
            if l.hasPrefix("- [ ] ") || l.hasPrefix("- [x] ") || l.hasPrefix("- [X] ") { l = String(l.dropFirst(6)) }
            else if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") { l = String(l.dropFirst(2)) }
            lines.append(l)
        }
        if placeholderDue { lines.append(codePlaceholder) }
        var text = lines.filter { !$0.isEmpty }.map { l -> String in
            // A line without its own end mark reads as a sentence of its own.
            guard let last = l.last, !".!?:;…".contains(last), l != codePlaceholder else { return l }
            return l + "."
        }.joined(separator: " ")
        text = inline(text)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return clip(text, limit: limit)
    }

    /// Inline Markdown out: links and images keep their words, code spans their text, emphasis marks go.
    private static func inline(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "~~", with: "")
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        return t
    }

    /// Up to `limit` characters, ended at the last sentence that fits (else the last word, with an ellipsis).
    static func clip(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit))
        if let end = head.lastIndex(where: { ".!?…".contains($0) }), head.distance(from: head.startIndex, to: end) > limit / 3 {
            return String(head[...end])
        }
        if let space = head.lastIndex(of: " ") { return String(head[..<space]) + "…" }
        return head + "…"
    }
}
