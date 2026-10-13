import Foundation
import Testing

@testable import PierKit

@Suite struct ProjectsTests {
    @Test func decodesTheProjectRoutes() throws {
        let gh = try Fixture.decode("github_repos.json", as: GitHubRepos.self)
        #expect(gh.login == "octocat" && gh.owners == ["octocat", "octo-org"] && gh.repos.count == 3)
        #expect(gh.repos[0].isPrivate && gh.repos[0].location == "shop" && gh.repos[0].language == "TypeScript" && gh.repos[0].updatedAt != nil)
        #expect(gh.repos[1].fork && gh.repos[2].archived)

        let started = try Fixture.decode("clone_started.json", as: ProjectClone.self)
        #expect(started.state == .cloning && started.isRunning && started.started != nil)
        let clones = try Fixture.decode("clones.json", as: [ProjectClone].self)
        #expect(clones[0].state == .ready && clones[0].setup == "detected" && clones[0].services == ["dev"] && !clones[0].isRunning)
        #expect(clones[1].state == .failed && clones[1].error?.contains("terminal prompts disabled") == true)

        let disk = try Fixture.decode("location_disk.json", as: ProjectDisk.self)
        #expect(disk.bytes == 734_003_200 && disk.removable && disk.hasUnsavedWork && disk.paths.count == 2)
        let lines = Projects.unsavedLines(disk)
        #expect(lines.count == 3 && lines[0].kind == .uncommitted && lines[1].count == 2 && lines[2].kind == .stash)
        #expect(!ProjectDisk(bytes: 1).hasUnsavedWork)

        let unsaved = try Fixture.decode("location_unsaved.json", as: BoxError.self)
        #expect(unsaved.code == "unsaved_work")
        let services = try Fixture.decode("services_detail.json", as: [WorktreeServiceDetail].self)
        #expect(services[0].isRunning && services[0].autostart && !services[1].isRunning && services[1].run == "pnpm run worker")
    }

    @Test func routes() async throws {
        let t = MockTransport { method, path, _ in
            switch (method, path) {
            case (.get, let p) where p.hasPrefix("/v1/github/repos"): return (200, try Fixture.data("github_repos.json"))
            case (.post, "/v1/clones"): return (202, try Fixture.data("clone_started.json"))
            case (.get, "/v1/clones"): return (200, try Fixture.data("clones.json"))
            case (.get, let p) where p.hasSuffix("/disk"): return (200, try Fixture.data("location_disk.json"))
            case (.delete, let p) where p.contains("purge=1"): return (200, try Fixture.data("location_purged.json"))
            default: return (200, Data("{}".utf8))
            }
        }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        _ = try await a.gitHubRepos()
        _ = try await a.gitHubRepos(owner: "octo-org")
        let c = try await a.clone(CloneRequest(repo: "octocat/notes"))
        #expect(c.location == "notes")
        _ = try await a.clones()
        try await a.forgetClone(id: "a1b2c3d4e5f6")
        _ = try await a.projectDisk(location: "my shop")
        let purged = try await a.purgeProject(location: "shop", force: false)
        #expect(purged.freed == 734_003_200)
        _ = try await a.purgeProject(location: "shop", force: true)
        #expect(t.requests.map(\.path) == [
            "/v1/github/repos", "/v1/github/repos?owner=octo-org", "/v1/clones", "/v1/clones", "/v1/clones/a1b2c3d4e5f6",
            "/v1/locations/my%20shop/disk", "/v1/locations/shop?purge=1", "/v1/locations/shop?purge=1&force=1",
        ])
        let body = try #require(t.requests[2].body)
        let sent = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(sent?["repo"] as? String == "octocat/notes" && sent?["setup"] as? Bool == true)
    }

    @Test func repoLinks() {
        for ok in ["octocat/shop", "https://github.com/octocat/shop", "git@github.com:octocat/shop.git", "ssh://git@host/a/b.git",
                   " https://gitlab.com/group/app.git "] {
            #expect(Projects.isRepoLink(ok), "\(ok)")
        }
        for bad in ["", "shop", "-x/y", "file:///etc", "ftp://host/a", "https://", "octo cat/shop", "ext::sh -c id"] {
            #expect(!Projects.isRepoLink(bad), "\(bad)")
        }
    }

    @Test func filterAndMatch() throws {
        let gh = try Fixture.decode("github_repos.json", as: GitHubRepos.self)
        #expect(Projects.filter(gh.repos, query: "").map(\.name) == ["shop", "notes"])
        #expect(Projects.filter(gh.repos, query: "", showArchived: true).count == 3)
        #expect(Projects.filter(gh.repos, query: "typescript").map(\.name) == ["shop"])
        #expect(Projects.filter(gh.repos, query: "OCTOCAT/NO").map(\.name) == ["notes"])
        let locs = [Location(name: "notes-box", slug: "Octocat/Notes")]
        #expect(Projects.location(for: gh.repos[1], in: locs)?.name == "notes-box")
        #expect(Projects.location(for: gh.repos[0], in: locs) == nil)
    }

    @Test func devServersAndPreview() {
        let wt = Worktree(name: "checkout-fix", path: "/home/octocat/code/shop-checkout-fix", port: 41010)
        let all = [
            BoxService(location: "shop", worktree: "checkout-fix", path: "/home/octocat/code/shop-checkout-fix", port: 41011),
            BoxService(location: "shop", worktree: "checkout-fix", path: "/home/octocat/code/shop-checkout-fix", port: 41010),
            BoxService(location: "shop", worktree: "shop", path: "/home/octocat/code/shop", port: 41000, main: true),
            BoxService(location: "other", worktree: "checkout-fix", path: "/x", port: 3000),
        ]
        #expect(Projects.devServers(all, location: "shop", worktree: wt).map(\.port) == [41010, 41011])
        #expect(Projects.previewURL(host: "devbox.local", port: 41010)?.absoluteString == "http://devbox.local:41010")
        #expect(Projects.previewURL(host: "fd00::1", port: 41010)?.absoluteString == "http://[fd00::1]:41010")
        #expect(Projects.previewURL(host: "", port: 1) == nil)
        #expect(Projects.portBlock(41010) == "41010–41019")
        #expect(Projects.portBlock(nil) == nil)
    }
}
