import Foundation

// Projects coming onto and leaving the box (capability `projects`, docs/API.md §2.8).

extension BoxAPI {
    /// The repositories of the GitHub account gh is signed in to on the box, or of `owner` (one of its organisations).
    /// `BoxError.code` is `gh_missing` or `gh_auth` when the box cannot ask GitHub.
    public func gitHubRepos(owner: String? = nil) async throws -> GitHubRepos {
        try await get(Self.url("/v1/github/repos", [("owner", owner)]))
    }

    /// Clone a repository onto the box in the background; follow it with `clones()` (or the `clone.*` events).
    public func clone(_ req: CloneRequest) async throws -> ProjectClone {
        try decode(try await call(.post, "/v1/clones", body: req).data)
    }

    /// The clones of the last hour, newest first.
    public func clones() async throws -> [ProjectClone] { try await get("/v1/clones") }

    /// Forget a finished or failed clone.
    public func forgetClone(id: String) async throws {
        _ = try await call(.delete, "/v1/clones/\(Self.seg(id))")
    }

    /// What a project takes on the disk and what removing it would lose.
    public func projectDisk(location: String) async throws -> ProjectDisk {
        try await get("/v1/locations/\(Self.seg(location))/disk")
    }

    /// Delete a project's repository and worktrees from the disk and forget it. Without `force` the box refuses
    /// (409, `unsaved_work`) while it has uncommitted changes, commits no remote has, or stashes.
    public func purgeProject(location: String, force: Bool) async throws -> ProjectPurge {
        let path = Self.url("/v1/locations/\(Self.seg(location))", [("purge", "1"), ("force", force ? "1" : nil)])
        return try decode(try await call(.delete, path).data)
    }

    /// A worktree's services with their commands (`WorktreeServiceDetail`).
    public func worktreeServiceDetails(location: String, worktree: String) async throws -> [WorktreeServiceDetail] {
        try await get("/v1/locations/\(Self.seg(location))/worktrees/\(Self.seg(worktree))/services")
    }
}
