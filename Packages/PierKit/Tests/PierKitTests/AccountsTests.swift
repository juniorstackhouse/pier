import Foundation
import Testing

@testable import PierKit

@Suite struct AccountsTests {
    @Test func decodes() throws {
        let a = try Fixture.decode("accounts.json", as: [AgentAccount].self)
        #expect(a.count == 3 && a[0].builtin && a[0].isDefault && a[0].limits?.windows.count == 2 && a[0].limits?.source == "statusline")
        #expect(a[2].name == "Trabalho" && !a[2].signedIn && !a[2].limitsReady && a[2].limits == nil)
        #expect(Accounts.tightest(a[0].limits)?.kind == "seven_day")
        #expect(Accounts.windowLabel(a[1].limits!.windows[0]) == "5h" && Accounts.windowLabel(a[1].limits!.windows[1]) == "7d")
        #expect(Accounts.windowLabel(LimitWindow(kind: "primary", minutes: 90, usedPercent: 1)) == "90m")
        let env = try Fixture.decode("box_env.json", as: BoxVariables.self)
        #expect(env.env.count == 2 && env.notes["STAGING_URL"] == "the staging API")
        let skills = try Fixture.decode("skills.json", as: [BoxSkill].self)
        #expect(skills[0].installed && skills[0].paths.count == 2 && !skills[1].installed)
        let links = try Fixture.decode("shares.json", as: [PublicLink].self)
        #expect(links[0].port == 41010 && links[0].url.hasPrefix("https://p-") && links[0].expires != nil)
        let loc = try JSONDecoder.pier.decode(Location.self, from: Data(#"{"name":"acme-api","accounts":{"claude":"claude-8533e81f"}}"#.utf8))
        #expect(Accounts.effective(agent: "claude", project: loc, accounts: a)?.name == "Trabalho")
        #expect(Accounts.effective(agent: "claude", project: Location(name: "shop"), accounts: a)?.id == "claude")
        #expect(Accounts.effective(agent: "codex", project: loc, accounts: a)?.id == "codex")
    }

    @Test func rules() {
        #expect(Accounts.level(74) == .ok && Accounts.level(75) == .high && Accounts.level(92) == .critical)
        for s in ["GITHUB_TOKEN", "STRIPE_SECRET_KEY", "DB_PASSWORD", "OPENAI_API_KEY", "SSH_PRIVATE"] { #expect(Accounts.isSecret(s), "\(s)") }
        for s in ["STAGING_URL", "REGION", "MONKEY"] { #expect(!Accounts.isSecret(s), "\(s)") }
        #expect(Accounts.isValidVariable("STAGING_URL") && !Accounts.isValidVariable("PIER_PORT") && !Accounts.isValidVariable("PATH") && !Accounts.isValidVariable("1A") && !Accounts.isValidVariable("A-B"))
    }

    @Test func routes() async throws {
        let t = MockTransport { method, path, _ in
            switch path {
            case "/v1/accounts": return (200, method == .get ? try Fixture.data("accounts.json") : Data(#"{"id":"codex-1","agent":"codex","name":"Pessoal"}"#.utf8))
            case let p where p.hasPrefix("/v1/accounts/") && p.hasSuffix("/login"): return (200, try Fixture.data("session_shell.json"))
            case let p where p.hasPrefix("/v1/accounts/"): return (200, Data(#"{"id":"claude-1","agent":"claude","name":"X"}"#.utf8))
            case let p where p.hasSuffix("/accounts"): return (200, Data(#"{"name":"shop"}"#.utf8))
            case "/v1/env": return (200, try Fixture.data("box_env.json"))
            case let p where p.hasPrefix("/v1/skills"): return (200, try Fixture.data("skills.json"))
            case "/v1/shares": return (200, method == .get ? try Fixture.data("shares.json") : Data(#"{"name":"n","url":"u","location":"shop","worktree":"w","port":1}"#.utf8))
            default: return (200, Data("{}".utf8))
            }
        }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        _ = try await a.accounts()
        _ = try await a.addAccount(agent: "codex", name: "Pessoal")
        _ = try await a.makeDefaultAccount(id: "claude-1")
        _ = try await a.loginAccount(id: "claude-1")
        try await a.removeAccount(id: "claude-1")
        try await a.enableLimits()
        _ = try await a.setProjectAccounts(location: "shop", ["claude": "claude-1"])
        _ = try await a.setBoxVariables(BoxVariables(env: ["A": "1"]))
        _ = try await a.setSkill(id: "pier-box", installed: false)
        _ = try await a.createPublicLink(location: "shop", worktree: "w", port: 41010)
        try await a.removePublicLink(name: "n")
        #expect(t.requests.map { "\($0.method) \($0.path)" } == [
            "GET /v1/accounts", "POST /v1/accounts", "PATCH /v1/accounts/claude-1", "POST /v1/accounts/claude-1/login", "DELETE /v1/accounts/claude-1",
            "POST /v1/limits/enable", "PUT /v1/locations/shop/accounts", "PUT /v1/env", "DELETE /v1/skills/pier-box", "POST /v1/shares", "DELETE /v1/shares/n",
        ])
        #expect(t.requests[2].body == #"{"default":true}"#)
        #expect(t.requests[9].body == #"{"location":"shop","port":41010,"worktree":"w"}"#)
    }
}
