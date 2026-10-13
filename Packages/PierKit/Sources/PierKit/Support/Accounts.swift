import Foundation

/// The rules behind the accounts, limits and variables screens.
public enum Accounts {
    /// "5h", "7d", or Codex's window length ("5h" for 300 minutes, "7d" for 10080, "90m"…).
    public static func windowLabel(_ w: LimitWindow) -> String {
        switch w.kind {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        default:
            guard let m = w.minutes, m > 0 else { return w.kind }
            if m % 1440 == 0 { return "\(m / 1440)d" }
            if m % 60 == 0 { return "\(m / 60)h" }
            return "\(m)m"
        }
    }

    /// The window that runs out first: the highest use (ties: the one resetting sooner).
    public static func tightest(_ l: AccountLimits?) -> LimitWindow? {
        l?.windows.max { a, b in a.usedPercent != b.usedPercent ? a.usedPercent < b.usedPercent : (a.resetsAt ?? .distantFuture) > (b.resetsAt ?? .distantFuture) }
    }

    public enum Level: Sendable { case ok, high, critical }

    /// How worrying a use is: high from 75%, critical from 90%.
    public static func level(_ percent: Double) -> Level { percent >= 90 ? .critical : percent >= 75 ? .high : .ok }

    /// The account a project's agents use for `agent`: the project's choice, else the box's default, else the built-in.
    public static func effective(agent: String, project: Location?, accounts: [AgentAccount]) -> AgentAccount? {
        let mine = accounts.filter { $0.agent == agent }
        if let id = project?.accounts?[agent], let a = mine.first(where: { $0.id == id }) { return a }
        return mine.first(where: \.isDefault) ?? mine.first(where: \.builtin)
    }

    /// Whether a variable's value is a secret to hide by default (tokens, keys, passwords).
    public static func isSecret(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "PRIVATE", "CREDENTIAL", "API_KEY", "APIKEY", "_KEY", "AUTH"].contains { n.contains($0) }
    }

    /// A variable name pierd takes for the box (letters, digits, underscore; not PIER_*, PATH, HOME, SHELL, USER).
    public static func isValidVariable(_ name: String) -> Bool {
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil else { return false }
        return !name.hasPrefix("PIER_") && !["PATH", "HOME", "SHELL", "USER"].contains(name)
    }
}
