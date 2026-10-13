import Foundation
import PierKit

/// The mock box's projects coming and going (`-uiTestMock 1`): the GitHub account's repositories (`GET /v1/github/repos`),
/// clones that go through cloning and setting up in a few seconds (`POST`/`GET /v1/clones`), a project's disk use and its
/// removal (`GET …/disk`, `DELETE /v1/locations/{l}?purge=1`), and a worktree's services with a dev server on its port.
struct MockProjects {
    typealias JSON = [String: Any]

    private struct CloneJob {
        let id: String
        let repo: String
        let slug: String?
        let name: String
        let started: Date
        var forgotten = false
    }

    private var clones: [CloneJob] = []
    private var removed: Set<String> = []
    /// Services stopped from the app, by "location/worktree/service".
    private var stopped: Set<String> = []

    private static let cloning: TimeInterval = 1.2
    private static let settingUp: TimeInterval = 2.8

    private static let account: [(slug: String, description: String, language: String, privateRepo: Bool, days: Double)] = [
        ("octocat/acme-site", "Marketing site", "TypeScript", false, 0.2),
        ("octocat/notes", "Personal notes app", "Swift", true, 1),
        ("octocat/hello-world", "My first repository on GitHub!", "JavaScript", false, 9),
        ("octocat/atlas-ios", "Atlas for iPhone", "Swift", true, 14),
        ("octocat/dotfiles", "", "Shell", false, 40),
    ]

    // MARK: locations

    /// The fixture's locations without the removed ones, with the clones that finished.
    func locations(_ fixture: String) -> Data {
        var all = ((try? JSONSerialization.jsonObject(with: Data(fixture.utf8))) as? [JSON]) ?? []
        all.removeAll { removed.contains(($0["name"] as? String) ?? "") }
        for c in clones where state(c) == "ready" && !removed.contains(c.name) {
            let path = "/home/ubuntu/code/\(c.name)"
            all.append(["name": c.name, "path": path, "repo": true, "remote": "https://github.com/\(c.slug ?? "octocat/\(c.name)").git",
                        "slug": c.slug ?? "octocat/\(c.name)", "default_branch": "main", "repo_trust": "none", "scripts": ["setup": "npm ci", "from": "box"],
                        "worktrees": [["name": c.name, "path": path, "branch": "main", "head": "0a1b2c3d4e", "main": true, "port": 41200]]])
        }
        return Self.json(all)
    }

    /// Dev servers listening (`GET /v1/services`): each clone's and the sandbox's main checkout.
    func services() -> Data {
        var out: [JSON] = [["location": "sandbox", "worktree": "sandbox", "path": "/home/ubuntu/code/sandbox", "port": 41000, "process": "node .bin/vite", "main": true]]
        for c in clones where state(c) == "ready" && !removed.contains(c.name) && !stopped.contains("\(c.name)/\(c.name)/dev") {
            out.append(["location": c.name, "worktree": c.name, "path": "/home/ubuntu/code/\(c.name)", "port": 41200, "process": "node .bin/next dev", "main": true])
        }
        if stopped.contains("sandbox/sandbox/dev") { out.removeFirst() }
        return Self.json(out)
    }

    // MARK: routes

    mutating func route(_ method: BoxClient.Method, _ p: [String], _ query: [String: String], _ body: Data?, locations fixture: String) -> (Int, Data)? {
        switch (method, p.count, p[1]) {
        case (.get, 3, "github") where p[2] == "repos": return (200, repos(owner: query["owner"], fixture: fixture))
        case (.get, 2, "clones"): return (200, Self.json(clones.filter { !$0.forgotten }.reversed().map(cloneJSON)))
        case (.post, 2, "clones"): return clone(body, fixture: fixture)
        case (.delete, 3, "clones"):
            guard let i = clones.firstIndex(where: { $0.id == p[2] }) else { return Self.notFound }
            clones[i].forgotten = true
            return (200, Self.json(["forgotten": p[2]]))
        case (.get, 4, "locations") where p[3] == "disk": return disk(p[2])
        case (.delete, 3, "locations") where query["purge"] == "1": return purge(p[2], force: query["force"] == "1")
        case (.get, 6, "locations") where p[3] == "worktrees" && p[5] == "services": return (200, worktreeServices(p[2], p[4]))
        case (.post, 8, "locations") where p[3] == "worktrees" && p[5] == "services":
            let key = "\(p[2])/\(p[4])/\(p[6])"
            if p[7] == "stop" { stopped.insert(key) } else { stopped.remove(key) }
            return (200, Self.json(serviceJSON(p[2], p[4], name: p[6])))
        default: return nil
        }
    }

    private func repos(owner: String?, fixture: String) -> Data {
        let have = Dictionary(((try? JSONDecoder.pier.decode([Location].self, from: locations(fixture))) ?? []).compactMap { l in l.slug.map { ($0.lowercased(), l.name) } },
                              uniquingKeysWith: { a, _ in a })
        let org = owner == "octo-org"
        let list: [JSON] = (org ? [("octo-org/platform", "Shared platform services", "Go", true, 3.0)] : Self.account).map { r in
            var j: JSON = ["slug": r.slug, "name": String(r.slug.split(separator: "/")[1]), "url": "https://github.com/\(r.slug)",
                           "private": r.privateRepo, "language": r.language,
                           "updated_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-r.days * 86400))]
            if !r.description.isEmpty { j["description"] = r.description }
            if let l = have[r.slug.lowercased()] { j["location"] = l }
            return j
        }
        return Self.json(["login": "octocat", "owner": owner ?? "octocat", "owners": ["octocat", "octo-org"], "repos": list])
    }

    private mutating func clone(_ body: Data?, fixture: String) -> (Int, Data) {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        let repo = ((req["repo"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard Projects.isRepoLink(repo) else {
            return (400, Self.json(["error": "\"\(repo)\" is not a repository link: use owner/repo or its https or ssh URL", "code": "bad_request"]))
        }
        var name = (req["name"] as? String) ?? ""
        let slug = PRCommands.slug(fromRemote: repo.contains("://") || repo.contains("@") ? repo : "github.com/\(repo)")
        if name.isEmpty { name = String((slug ?? repo).split(separator: "/").last ?? "project").replacingOccurrences(of: ".git", with: "") }
        let existing = ((try? JSONDecoder.pier.decode([Location].self, from: locations(fixture))) ?? [])
        if let l = existing.first(where: { $0.slug?.lowercased() == slug?.lowercased() && slug != nil }) {
            return (409, Self.json(["error": "\(repo) is already on this box as \(l.name)", "code": "bad_request"]))
        }
        let job = CloneJob(id: String(UUID().uuidString.prefix(12)).lowercased(), repo: repo, slug: slug, name: name, started: Date())
        removed.remove(name)
        clones.append(job)
        return (202, Self.json(cloneJSON(job)))
    }

    private func state(_ c: CloneJob) -> String {
        let t = Date().timeIntervalSince(c.started)
        if c.repo.contains("broken") { return t < Self.cloning ? "cloning" : "failed" }
        return t < Self.cloning ? "cloning" : t < Self.settingUp ? "setting_up" : "ready"
    }

    private func cloneJSON(_ c: CloneJob) -> JSON {
        let st = state(c)
        var j: JSON = ["id": c.id, "repo": c.repo, "location": c.name, "path": "/home/ubuntu/code/\(c.name)", "state": st,
                       "started": ISO8601DateFormatter().string(from: c.started)]
        if let s = c.slug { j["slug"] = s }
        if st == "ready" { j["setup"] = "detected"; j["services"] = ["dev"] }
        if st == "failed" { j["error"] = "clone failed: fatal: repository '\(c.repo)' not found" }
        return j
    }

    private func disk(_ location: String) -> (Int, Data) {
        guard !removed.contains(location) else { return Self.notFound }
        let unsaved = location == "sandbox"
        var j: JSON = ["bytes": unsaved ? 734_003_200 : 182_452_224, "paths": ["/home/ubuntu/code/\(location)"], "uncommitted": [], "unpushed": [],
                       "stashes": 0, "sessions": 0, "removable": true, "remote": "https://github.com/octocat/\(location).git"]
        if unsaved {
            j["uncommitted"] = [["worktree": "sandbox", "files": 3]]
            j["unpushed"] = [["branch": "feat/subtract", "commits": 2]]
        }
        return (200, Self.json(j))
    }

    private mutating func purge(_ location: String, force: Bool) -> (Int, Data) {
        guard !removed.contains(location) else { return Self.notFound }
        if location == "sandbox" && !force {
            return (409, Self.json(["error": "the project has work that is not on any remote: sandbox has 3 uncommitted files; feat/subtract has 2 commits no remote has (remove with force=1 to lose them)",
                                    "code": "unsaved_work"]))
        }
        removed.insert(location)
        return (200, Self.json(["removed": location, "freed": location == "sandbox" ? 734_003_200 : 182_452_224]))
    }

    private func worktreeServices(_ location: String, _ worktree: String) -> Data {
        Self.json([serviceJSON(location, worktree, name: "dev"), serviceJSON(location, worktree, name: "worker")])
    }

    private func serviceJSON(_ location: String, _ worktree: String, name: String) -> JSON {
        let running = name == "dev" && !stopped.contains("\(location)/\(worktree)/\(name)")
        return ["name": name, "run": name == "dev" ? "HOST=0.0.0.0 npm run dev" : "npm run worker", "autostart": name == "dev",
                "state": running ? "running" : "stopped", "unit": "svc-\(location)-\(worktree)-\(name)", "port": 41000]
    }

    private static var notFound: (Int, Data) { (404, json(["error": "not found", "code": "not_found"])) }
    private static func json(_ any: Any) -> Data { (try? JSONSerialization.data(withJSONObject: any)) ?? Data("{}".utf8) }
}
