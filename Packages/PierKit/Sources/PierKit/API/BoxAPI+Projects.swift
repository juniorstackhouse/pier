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

// The box's projects folder, its spaces and the projects' environments (capability `environments`, docs/API.md §2.9).

extension BoxAPI {
    public func settings() async throws -> BoxSettings { try await get("/v1/settings") }

    /// Set the folder every project lives under ("" clears it: anywhere again).
    public func setProjectsRoot(_ path: String) async throws -> BoxSettings {
        struct Body: Encodable { let projects_root: String }
        return try decode(try await call(.put, "/v1/settings", body: Body(projects_root: path)).data)
    }

    public func addSpace(name: String) async throws -> ProjectSpace {
        struct Body: Encodable { let name: String }
        return try decode(try await call(.post, "/v1/spaces", body: Body(name: name)).data)
    }

    /// Delete a space. With projects in it the box refuses (409 `space_not_empty`) unless `purge`, which removes them from
    /// the disk with it (409 `unsaved_work` for work no remote has, unless `force`). Its projects never move out of it.
    public func removeSpace(name: String, purge: Bool, force: Bool) async throws -> ProjectPurge {
        let path = Self.url("/v1/spaces/\(Self.seg(name))", [("purge", purge ? "1" : nil), ("force", force ? "1" : nil)])
        return try decode(try await call(.delete, path).data)
    }

    public func environment(location: String) async throws -> EnvironmentView {
        try await get("/v1/locations/\(Self.seg(location))/environment")
    }

    /// Save a project's environment; the box builds and starts it in the background (`status.state` "building").
    public func setEnvironment(location: String, _ env: ProjectEnvironment) async throws -> EnvironmentView {
        try decode(try await call(.put, "/v1/locations/\(Self.seg(location))/environment", body: env).data)
    }
}
