import Foundation

/// The agents a project's Agentes tab lists under its box: from the main checkout, every agent of the project (its
/// worktrees' too); from a worktree, that worktree's. Those that need the person first, then those at work, then those
/// whose turn ended, then the idle ones, the exited last; within each, the latest change first.
public enum ProjectAgents {
    /// `worktree` is the worktree's location ref (`"shop/login"`), nil for the main checkout.
    public static func list(_ sessions: [Session], project: String, worktree: String?) -> [Session] {
        let mine = sessions.filter { s in
            guard s.isAgent, let l = s.location else { return false }
            if let worktree { return l == worktree }
            return l == project || l.hasPrefix(project + "/")
        }
        return mine.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            let ta = a.stateSince ?? a.created, tb = b.stateSince ?? b.created
            return ta != tb ? ta > tb : a.name < b.name
        }
    }

    private static func rank(_ s: Session) -> Int {
        if s.exited { return 4 }
        switch s.agentState {
        case .waiting: return 0
        case .running: return 1
        case .finished: return 2
        default: return 3
        }
    }
}
