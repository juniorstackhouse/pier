import Foundation
import Testing

@testable import PierKit

@Suite struct ProjectAgentsTests {
    private func s(_ name: String, _ state: AgentState?, location: String?, exited: Bool = false, agent: String? = "claude",
                   ago: TimeInterval = 60) -> Session {
        Session(name: name, location: location, created: Date(timeIntervalSince1970: 1_000), exited: exited, agent: agent,
                agentState: state, stateSince: Date(timeIntervalSince1970: 100_000 - ago))
    }

    private var sessions: [Session] {
        [
            s("main-done", .finished, location: "shop", ago: 30),
            s("login-run", .running, location: "shop/login", ago: 50),
            s("login-wait", .waiting, location: "shop/login", ago: 400),
            s("cart-idle", .idle, location: "shop/cart", ago: 5),
            s("cart-gone", .running, location: "shop/cart", exited: true, ago: 1),
            s("login-done-old", .finished, location: "shop/login", ago: 900),
            s("login-done-new", .finished, location: "shop/login", ago: 90),
            s("shell", nil, location: "shop/login", agent: nil),
            s("other", .waiting, location: "shopping", ago: 10),
            s("chat", .waiting, location: nil, ago: 10),
        ]
    }

    /// From the main checkout: the whole project's agents (not a project whose name starts the same, not shells or
    /// chats), urgent first, the exited last.
    @Test func theMainCheckoutListsTheWholeProject() {
        let names = ProjectAgents.list(sessions, project: "shop", worktree: nil).map(\.name)
        #expect(names == ["login-wait", "login-run", "main-done", "login-done-new", "login-done-old", "cart-idle", "cart-gone"])
    }

    /// From a worktree: that worktree's agents only.
    @Test func aWorktreeListsItsOwn() {
        let names = ProjectAgents.list(sessions, project: "shop", worktree: "shop/login").map(\.name)
        #expect(names == ["login-wait", "login-run", "login-done-new", "login-done-old"])
        #expect(ProjectAgents.list(sessions, project: "shop", worktree: "shop/none").isEmpty)
    }
}
