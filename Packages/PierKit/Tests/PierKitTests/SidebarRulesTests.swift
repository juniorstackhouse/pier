import Foundation
import Testing

@testable import PierKit

@Suite struct SidebarRulesTests {
    private func s(_ name: String, _ state: AgentState?, location: String = "sandbox", exited: Bool = false, agent: String? = "claude",
                   ago: TimeInterval = 60) -> Session {
        Session(name: name, location: location, created: Date(timeIntervalSince1970: 1_000), exited: exited, agent: agent,
                agentState: state, stateSince: Date(timeIntervalSince1970: 100_000 - ago))
    }
    private func item(_ s: Session, box: String = "devbox") -> AgentBoard.Item { AgentBoard.Item(box: box, session: s) }

    @Test func listedLeavesOutArchivedExitedAndTerminals() {
        #expect(SidebarRules.isListed(s("a", .finished), archived: false, background: false))
        #expect(SidebarRules.isListed(s("a", .idle), archived: false, background: false))
        #expect(!SidebarRules.isListed(s("a", .finished), archived: true, background: false))
        #expect(!SidebarRules.isListed(s("a", .running, exited: true), archived: false, background: false))
        #expect(!SidebarRules.isListed(s("a", nil, agent: nil), archived: false, background: false))
        // A new turn of an archived session is back: the mark predates it (the caller's `archived` is false then).
        #expect(SidebarRules.isListed(s("a", .waiting), archived: false, background: false))
    }

    /// The sidebar's top lists every live agent, one each, the one that needs the person first and an agent whose turn
    /// ended too (it still runs, waiting for the next message): that is the one the person goes back to most.
    @Test func agentsListsEveryLiveOneUrgentFirst() {
        let items = [
            item(s("run-new", .running, location: "web", ago: 10)),
            item(s("run-old", .running, location: "web/login", ago: 50)),
            item(s("wait-new", .waiting, location: "web/login", ago: 20)),
            item(s("wait-old", .waiting, location: "docs", ago: 400)),
            item(s("done-old", .finished, location: "api", ago: 300)),
            item(s("done-new", .finished, location: "api/jobs", ago: 30)),
            item(s("bg", .finished, location: "api/jobs", ago: 5)),
            item(s("idle", .idle, location: "ops", ago: 1)),
            item(s("archived", .finished, location: "ops")),
            item(s("gone", .running, location: "ops", exited: true)),
            item(s("shell", nil, location: "ops", agent: nil)),
            item(s("chat", .finished, location: "", ago: 100)),
        ]
        let a = SidebarRules.agents(items, archived: { $0.session.name == "archived" }, background: ["devbox/bg"])
        #expect(a.map(\.item.session.name) == ["wait-old", "wait-new", "bg", "run-new", "run-old", "done-new", "chat", "done-old", "idle"])
        #expect(a.first?.column == .needsYou)
        #expect(a.first { $0.item.session.name == "bg" }?.column == .working)
        #expect(a.first { $0.item.session.name == "chat" }?.column == .yourTurn)
        #expect(a.last?.column == .ready)
        #expect(SidebarRules.agents([], archived: { _ in false }, background: []).isEmpty)
    }

    @Test func archivedIsClosedNewestFirst() {
        let items = [
            item(s("old", .finished, ago: 500)),
            item(s("exited", .running, exited: true, ago: 100)),
            item(s("open", .finished, ago: 1)),
            item(s("arch", .idle, ago: 300)),
            item(s("term", nil, exited: true, agent: nil)),
        ]
        let a = SidebarRules.archived(items, archived: { ["old", "arch"].contains($0.session.name) })
        #expect(a.map(\.session.name) == ["exited", "arch", "old"])
    }
}
