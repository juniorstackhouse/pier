import Foundation
import Testing

@testable import PierKit

@Suite struct EnvironmentsTests {
    @Test func decodesSettingsAndEnvironments() throws {
        let s = try Fixture.decode("settings.json", as: BoxSettings.self)
        #expect(s.projectsRoot == "/home/octocat/projects" && s.spaces.map(\.name) == ["acme", "side"] && s.spaces[0].projects == 2 && s.docker.available)
        let unset = try Fixture.decode("settings_unset.json", as: BoxSettings.self)
        #expect(unset.projectsRoot == nil && !unset.docker.available && unset.docker.error?.contains("daemon") == true)

        let e = try Fixture.decode("environment.json", as: EnvironmentView.self)
        #expect(e.environment.runtime?.preset == "php:8.4" && e.environment.containers.count == 2 && e.project.compose && !e.project.dockerfile)
        #expect(e.status.state == "ready" && e.status.containers[0].hostPort == 41030 && e.status.containers[0].isRunning && e.status.variables.contains("DB_HOST"))
        #expect(Environments.summary(e.environment) == "PHP 8.4 · MySQL 8.0 · Redis 7")
        let none = try Fixture.decode("environment_none.json", as: EnvironmentView.self)
        #expect(none.environment.isEmpty && none.project.dockerfile && Environments.summary(none.environment) == nil)
        #expect(try Fixture.decode("space_not_empty.json", as: BoxError.self).code == "space_not_empty")

        let loc = try JSONDecoder.pier.decode(Location.self, from: Data(#"{"name":"shop","space":"acme","isolated":true}"#.utf8))
        #expect(loc.space == "acme" && loc.isolated && !loc.outsideRoot)
    }

    @Test func encodesWhatPierdReads() throws {
        let env = ProjectEnvironment(runtime: EnvRuntime(preset: "node:22"), containers: [EnvContainer(name: "pg", image: "postgres:16")])
        let json = String(decoding: try BoxAPI.encode(env), as: UTF8.self)
        #expect(json == #"{"containers":[{"image":"postgres:16","name":"pg"}],"runtime":{"preset":"node:22"}}"#)
        let docker = String(decoding: try BoxAPI.encode(ProjectEnvironment(runtime: EnvRuntime(projectDockerfile: true, commands: ["php"]), compose: true)), as: UTF8.self)
        #expect(docker.contains(#""project_dockerfile":true"#) && docker.contains(#""compose":true"#) && docker.contains(#""commands":["php"]"#))
        #expect(String(decoding: try BoxAPI.encode(ProjectEnvironment()), as: UTF8.self) == #"{"containers":[]}"#)
    }

    @Test func presets() {
        #expect(Environments.parsePreset("php:8.5")?.language.title == "PHP")
        #expect(Environments.parsePreset("php:8.5")?.version == "8.5")
        #expect(Environments.parsePreset("cobol:1") == nil && Environments.parsePreset(nil) == nil && Environments.parsePreset("php:") == nil)
        #expect(Environments.service(ofImage: "library/mysql:5.7")?.service.id == "mysql")
        #expect(Environments.service(ofImage: "redis")?.version == "latest")
        #expect(Environments.service(ofImage: "nginx:1") == nil)
        let mysql = Environments.services[0]
        let first = Environments.container(mysql, version: "8.0", taken: [])
        #expect(first.name == "mysql" && first.image == "mysql:8.0")
        #expect(Environments.container(mysql, version: "5.7", taken: [first]).name == "mysql-2")
        #expect(Environments.isValidName("mysql-2") && !Environments.isValidName("MySQL") && !Environments.isValidName("-x"))
        #expect(Environments.isValidSpace("acme.io") && !Environments.isValidSpace("a b") && !Environments.isValidSpace(".hidden"))
    }

    @Test func routes() async throws {
        let t = MockTransport { method, path, _ in
            if path.hasPrefix("/v1/settings") { return (200, try Fixture.data("settings.json")) }
            if path.hasSuffix("/environment") { return (method == .put ? 202 : 200, try Fixture.data("environment.json")) }
            if path == "/v1/spaces" { return (200, Data(#"{"name":"acme","path":"/x","projects":0}"#.utf8)) }
            return (200, Data(#"{"removed":"acme","freed":0}"#.utf8))
        }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        _ = try await a.settings()
        _ = try await a.setProjectsRoot("~/projects")
        _ = try await a.addSpace(name: "acme")
        _ = try await a.removeSpace(name: "acme", purge: false, force: false)
        _ = try await a.removeSpace(name: "acme", purge: true, force: true)
        _ = try await a.environment(location: "my shop")
        _ = try await a.setEnvironment(location: "shop", ProjectEnvironment())
        #expect(t.requests.map { "\($0.method) \($0.path)" } == [
            "GET /v1/settings", "PUT /v1/settings", "POST /v1/spaces", "DELETE /v1/spaces/acme", "DELETE /v1/spaces/acme?purge=1&force=1",
            "GET /v1/locations/my%20shop/environment", "PUT /v1/locations/shop/environment",
        ])
        #expect(t.requests[1].body == #"{"projects_root":"~/projects"}"#)
    }
}
