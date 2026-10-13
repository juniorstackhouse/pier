import Foundation

/// What the environment screen offers: the runtimes and the service containers by version, and how a saved
/// environment reads back as those choices. Pure, so the screen and its tests agree with pierd's presets
/// (Server/pierd/internal/box/environment.go `runtimePreset`, `kindOf`).
public enum Environments {
    public struct Language: Sendable, Hashable, Identifiable {
        public let id: String          // "php"
        public let title: String       // "PHP"
        public let versions: [String]  // newest first
        public let commands: [String]
    }

    public static let languages: [Language] = [
        Language(id: "php", title: "PHP", versions: ["8.5", "8.4", "8.3", "8.2", "8.1", "7.4"], commands: ["php", "composer"]),
        Language(id: "node", title: "Node.js", versions: ["24", "22", "20", "18"], commands: ["node", "npm", "npx", "corepack", "yarn", "pnpm"]),
        Language(id: "python", title: "Python", versions: ["3.13", "3.12", "3.11", "3.10"], commands: ["python", "python3", "pip", "pip3"]),
        Language(id: "ruby", title: "Ruby", versions: ["3.4", "3.3", "3.2"], commands: ["ruby", "gem", "bundle", "bundler", "irb"]),
        Language(id: "go", title: "Go", versions: ["1.24", "1.23", "1.22"], commands: ["go", "gofmt"]),
    ]

    public struct Service: Sendable, Hashable, Identifiable {
        public let id: String          // "mysql": also the container's default name
        public let title: String
        public let image: String       // repository: "mysql"
        public let versions: [String]
        public let port: Int
    }

    public static let services: [Service] = [
        Service(id: "mysql", title: "MySQL", image: "mysql", versions: ["9.1", "8.4", "8.0", "5.7"], port: 3306),
        Service(id: "mariadb", title: "MariaDB", image: "mariadb", versions: ["11.4", "10.11", "10.6"], port: 3306),
        Service(id: "postgres", title: "PostgreSQL", image: "postgres", versions: ["17", "16", "15", "14"], port: 5432),
        Service(id: "redis", title: "Redis", image: "redis", versions: ["7", "6"], port: 6379),
        Service(id: "mongo", title: "MongoDB", image: "mongo", versions: ["8", "7", "6"], port: 27017),
    ]

    /// "php:8.4" -> (PHP, "8.4"); nil for anything else.
    public static func parsePreset(_ preset: String?) -> (language: Language, version: String)? {
        guard let preset, let i = preset.firstIndex(of: ":") else { return nil }
        let id = String(preset[..<i]), v = String(preset[preset.index(after: i)...])
        guard let l = languages.first(where: { $0.id == id }), !v.isEmpty else { return nil }
        return (l, v)
    }

    /// The service and version an image is ("mysql:8.0" -> MySQL 8.0), when it is one of ours.
    public static func service(ofImage image: String) -> (service: Service, version: String)? {
        let name = image.split(separator: "/").last.map(String.init) ?? image
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard let s = services.first(where: { $0.image == parts[0] }) else { return nil }
        return (s, parts.count > 1 ? parts[1] : "latest")
    }

    /// A container for a service at a version, named after the service unless that name is taken (mysql-2…).
    public static func container(_ s: Service, version: String, taken: [EnvContainer]) -> EnvContainer {
        var name = s.id, i = 2
        while taken.contains(where: { $0.name == name }) { name = "\(s.id)-\(i)"; i += 1 }
        return EnvContainer(name: name, image: "\(s.image):\(version)")
    }

    /// One line for a project's environment ("PHP 8.4 · MySQL 8.0 · Redis 7"), nil when it has none.
    public static func summary(_ e: ProjectEnvironment) -> String? {
        var parts: [String] = []
        if let r = e.runtime {
            if let p = parsePreset(r.preset) { parts.append("\(p.language.title) \(p.version)") }
            else if r.projectDockerfile { parts.append("Dockerfile") }
            else if let img = r.image { parts.append(img) }
        }
        for c in e.containers {
            if let s = service(ofImage: c.image) { parts.append("\(s.service.title) \(s.version)") } else { parts.append(c.image) }
        }
        if e.compose { parts.append("compose") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A container name pierd takes: lowercase letters, digits and dashes, starting with a letter or digit.
    public static func isValidName(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
    }

    /// A space's name as pierd takes it.
    public static func isValidSpace(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$"#, options: .regularExpression) != nil
    }
}
