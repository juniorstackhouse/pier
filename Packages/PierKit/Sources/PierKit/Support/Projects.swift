import Foundation

/// Pure helpers behind the project screens: the GitHub list, the clone sheet, removal and a worktree's details.
public enum Projects {
    /// Whether text is worth sending as a repository to clone: `owner/repo`, an https / http / ssh URL, or `user@host:path`.
    /// The box checks it properly (`parseRepoSource`); this only keeps the button off for what cannot be one.
    public static func isRepoLink(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("-"), s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        if s.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._~/-]+$"#, options: .regularExpression) != nil { return true }
        guard let u = URLComponents(string: s), let scheme = u.scheme?.lowercased(), ["https", "http", "ssh"].contains(scheme),
              let host = u.host, !host.isEmpty else { return false }
        return u.path.split(separator: "/").count >= 1
    }

    /// The repositories matching a search (name, owner/name, description, language), archived ones only when asked for.
    /// Order is kept (the box sends the most recently updated first).
    public static func filter(_ repos: [GitHubRepo], query: String, showArchived: Bool = false) -> [GitHubRepo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return repos.filter { r in
            if r.archived && !showArchived { return false }
            guard !q.isEmpty else { return true }
            return [r.slug, r.name, r.description ?? "", r.language ?? ""].contains { $0.lowercased().contains(q) }
        }
    }

    /// The repository a location is a checkout of, by owner/name (case-insensitive), so the list can say "on the box".
    public static func location(for repo: GitHubRepo, in locations: [Location]) -> Location? {
        if let name = repo.location, let l = locations.first(where: { $0.name == name }) { return l }
        return locations.first { $0.slug?.lowercased() == repo.slug.lowercased() }
    }

    /// The dev servers listening in one worktree (`GET /v1/services`), by its folder, lowest port first.
    public static func devServers(_ all: [BoxService], location: String, worktree: Worktree) -> [BoxService] {
        all.filter { s in
            guard s.location == location, s.port > 0 else { return false }
            if let p = s.path, !p.isEmpty { return p == worktree.path }
            return s.worktree == worktree.name
        }
        .sorted { $0.port < $1.port }
    }

    /// The page a port serves, at the address this device reaches the box by (an IPv6 address in brackets).
    /// Nil for a box reached only through a relay, whose address is not the box's own.
    public static func previewURL(host: String, port: Int) -> URL? {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !h.isEmpty, port > 0, port < 65536 else { return nil }
        return URL(string: "http://\(h.contains(":") ? "[\(h)]" : h):\(port)")
    }

    /// The worktree's block of ports ($PIER_PORT and the ones after it) as "41010–41019".
    public static func portBlock(_ first: Int?, size: Int = 10) -> String? {
        guard let first, first > 0 else { return nil }
        return "\(first)–\(first + max(size, 1) - 1)"
    }

    /// Lines saying what removing a project would lose, for the confirmation (worktree / branch names stay as they are).
    public static func unsavedLines(_ d: ProjectDisk) -> [(kind: UnsavedKind, name: String, count: Int)] {
        d.uncommitted.map { (UnsavedKind.uncommitted, $0.worktree, $0.files) }
            + d.unpushed.map { (UnsavedKind.unpushed, $0.branch, $0.commits) }
            + (d.stashes > 0 ? [(UnsavedKind.stash, "", d.stashes)] : [])
    }

    public enum UnsavedKind: Sendable { case uncommitted, unpushed, stash }
}
