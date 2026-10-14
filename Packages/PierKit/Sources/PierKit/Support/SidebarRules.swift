import Foundation

/// What the regular-width sidebar lists besides the projects tree: every live agent, a row each ("Agentes", pinned above
/// everything) and the sessions the person archived or that exited ("Arquivadas").
/// Pure over the sessions plus the phone's marks, with the same columns as the agents board.
public enum SidebarRules {
    /// Whether a session belongs in the projects tree (and the chats list): an agent, not archived and not exited.
    public static func isListed(_ s: Session, archived: Bool, background: Bool) -> Bool {
        guard let c = AgentBoard.column(s, archived: archived, background: background) else { return false }
        return c != .closed
    }

    /// One live agent at the top of the sidebar, a row of its own that opens its conversation.
    public struct LiveAgent: Sendable, Hashable, Identifiable {
        public let item: AgentBoard.Item
        /// needsYou, working (a finished turn with work in the background too), yourTurn or ready.
        public let column: AgentBoard.Column
        public var id: String { item.id }
    }

    /// Every live agent (an agent, not archived, not exited), one per row: those that need the person first (the longest
    /// wait on top), then those at work, then those whose turn ended (the person's turn), then the idle ones; within
    /// each, the most recent first. Hidden projects are the caller's to leave out.
    public static func agents(_ items: [AgentBoard.Item], archived: (AgentBoard.Item) -> Bool,
                              background: Set<String>) -> [LiveAgent] {
        let rank: [AgentBoard.Column: Int] = [.needsYou: 0, .working: 1, .yourTurn: 2, .ready: 3]
        let live = items.compactMap { it -> LiveAgent? in
            guard let c = AgentBoard.column(it.session, archived: archived(it), background: background.contains(it.id)),
                  rank[c] != nil else { return nil }
            return LiveAgent(item: it, column: c)
        }
        return live.sorted { a, b in
            let ra = rank[a.column]!, rb = rank[b.column]!
            if ra != rb { return ra < rb }
            if a.item.since != b.item.since { return a.column == .needsYou ? a.item.since < b.item.since : a.item.since > b.item.since }
            return a.id < b.id
        }
    }

    /// Archived (on the phone) or exited (on the box) agent sessions, most recent first.
    public static func archived(_ items: [AgentBoard.Item], archived: (AgentBoard.Item) -> Bool) -> [AgentBoard.Item] {
        items.filter { AgentBoard.column($0.session, archived: archived($0), background: false) == .closed }
            .sorted { a, b in a.since != b.since ? a.since > b.since : a.id < b.id }
    }
}
