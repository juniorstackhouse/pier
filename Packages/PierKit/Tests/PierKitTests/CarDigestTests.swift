import Foundation
import Testing

@testable import PierKit

@Suite struct CarDigestTests {
    private func s(_ name: String, _ state: AgentState?, at t: TimeInterval, title: String? = nil, agent: String? = "claude",
                   exited: Bool = false, service: String? = nil, location: String? = "shop/checkout") -> Session {
        Session(name: name, location: location, created: Date(timeIntervalSince1970: 0), exited: exited, agent: agent,
                agentState: state, stateSince: Date(timeIntervalSince1970: t), title: title, service: service)
    }

    // MARK: ids

    @Test func conversationIDsRoundTrip() {
        let id = CarDigest.conversationID(box: "devbox", session: "shop-claude-1x2")
        #expect(id == "pier-session:devbox/shop-claude-1x2")
        #expect(CarDigest.parse(id)! == ("devbox", "shop-claude-1x2"))
    }

    @Test func oddNamesComeBackWhole() {
        for (box, session) in [("home/lab", "a b/c"), ("ção", "x%2Fy"), ("a:b", "?&=#")] {
            let id = CarDigest.conversationID(box: box, session: session)
            #expect(id.dropFirst("pier-session:".count).filter { $0 == "/" }.count == 1)
            let back = CarDigest.parse(id)
            #expect(back?.box == box && back?.session == session)
        }
    }

    @Test func foreignIDsAreNotOurs() {
        #expect(CarDigest.parse(nil) == nil)
        #expect(CarDigest.parse("") == nil)
        #expect(CarDigest.parse("+5511999990000") == nil)
        #expect(CarDigest.parse("pier-session:onlybox") == nil)
        #expect(CarDigest.parse("pier-session:/x") == nil)
        #expect(CarDigest.parse("pier-session:a/b/c") == nil)
    }

    // MARK: rows

    @Test func needsYouOldestFirstThenFinishedThenWorkingNewestFirst() {
        let items: [(box: String, session: Session)] = [
            ("b", s("w-new", .waiting, at: 50)), ("b", s("w-old", .waiting, at: 10)),
            ("b", s("f-old", .finished, at: 5)), ("b", s("f-new", .finished, at: 60)),
            ("b", s("r-old", .running, at: 1)), ("b", s("r-new", .running, at: 70)),
            ("b", s("idle", .idle, at: 80)),
        ]
        let rows = CarDigest.rows(items)
        #expect(rows.map(\.session.name) == ["w-old", "w-new", "f-new", "f-old", "r-new", "r-old"])
        #expect(rows.map(\.kind) == [.needsYou, .needsYou, .yourTurn, .yourTurn, .working, .working])
    }

    @Test func leavesOutExitedServicesShellsAndArchived() {
        let items: [(box: String, session: Session)] = [
            ("b", s("gone", .waiting, at: 1, exited: true)),
            ("b", s("svc", .running, at: 1, service: "web")),
            ("b", s("shell", nil, at: 1, agent: nil)),
            ("b", s("closed", .finished, at: 1)),
            ("b", s("open", .finished, at: 2)),
        ]
        let rows = CarDigest.rows(items, archived: { _, s in s.name == "closed" })
        #expect(rows.map(\.session.name) == ["open"])
    }

    @Test func eachListIsCapped() {
        let items: [(box: String, session: Session)] = (0..<20).map { ("b", s("w\($0)", .waiting, at: Double($0))) }
            + (0..<20).map { ("b", s("f\($0)", .finished, at: Double($0))) }
        let rows = CarDigest.rows(items, limit: 5)
        #expect(rows.filter { $0.kind == .needsYou }.count == 5)
        #expect(rows.filter { $0.kind == .yourTurn }.count == 5)
        #expect(rows.first?.session.name == "w0")
    }

    @Test func equalTimesKeepAStableOrder() {
        let items: [(box: String, session: Session)] = [("b", s("z", .waiting, at: 5)), ("a", s("y", .waiting, at: 5))]
        #expect(CarDigest.rows(items).map(\.box) == CarDigest.rows(items.reversed()).map(\.box))
    }

    @Test func titlesAndAgents() {
        #expect(CarDigest.title(s("n", .finished, at: 0, title: "  Fix login  ")) == "Fix login")
        #expect(CarDigest.title(s("n", .finished, at: 0, title: "")) == "shop / checkout")
        #expect(CarDigest.title(s("n", .finished, at: 0, location: nil)) == "n")
        #expect(CarDigest.agentName(s("n", .finished, at: 0)) == "Claude Code")
        #expect(CarDigest.agentName(s("n", .finished, at: 0, agent: "codex")) == "Codex")
        #expect(CarDigest.agentName(s("n", .finished, at: 0, agent: "gemini")) == "Gemini")
    }

    // MARK: speech

    @Test func spokenDropsMarksAndCode() {
        let md = """
        ## Done

        I fixed the **login** bug in `auth.ts` and added a [test](https://x.dev/t).

        ```ts
        const a = 1
        ```

        - Run `npm test`
        - Deploy
        """
        #expect(CarDigest.spoken(md, codePlaceholder: "(código)")
                == "Done. I fixed the login bug in auth.ts and added a test. (código) Run npm test. Deploy.")
    }

    @Test func spokenSkipsTablesAndRules() {
        let md = "Summary:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\nAll green"
        #expect(CarDigest.spoken(md) == "Summary: All green.")
    }

    @Test func spokenKeepsSnakeCaseAndMultiplication() {
        #expect(CarDigest.spoken("Use my_var_name and 2 * 3 * 4") == "Use my_var_name and 2 * 3 * 4.")
        #expect(CarDigest.spoken("It is *really* _very_ good") == "It is really very good.")
    }

    @Test func spokenEndsOnASentenceWithinTheLimit() {
        let md = String(repeating: "This is one sentence. ", count: 60)
        let out = CarDigest.spoken(md, limit: 100)
        #expect(out.count <= 100)
        #expect(out.hasSuffix("."))
        let words = CarDigest.spoken(String(repeating: "word ", count: 100), limit: 50)
        #expect(words.hasSuffix("…"))
        #expect(words.count <= 51)
    }

    @Test func unclosedFenceStillReadsAPlaceholder() {
        #expect(CarDigest.spoken("Here:\n```\nlet x = 1") == "Here: (code)")
    }
}
