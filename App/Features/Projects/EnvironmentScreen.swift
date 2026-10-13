import SwiftUI
import PierKit

/// A project's isolated environment (`GET`/`PUT /v1/locations/{l}/environment`): the version of its language (PHP 8.4
/// here, 8.5 in another project) and its databases (MySQL 5.7 here, 8.4 there), each in Docker on the box and none of it
/// in the project. Its programs (php, composer…) run in the container for everything in the project's worktrees:
/// agents, terminals, services, setup. A project with its own Dockerfile or compose file can use that instead.
struct ProjectEnvironmentRoute: Hashable {
    let box: String
    let location: String
}

struct ProjectEnvironmentScreen: View {
    let route: ProjectEnvironmentRoute

    @Environment(AppModel.self) private var model
    @State private var view: EnvironmentView?
    @State private var draft = ProjectEnvironment()
    @State private var mode: RuntimeMode = .none
    @State private var language = Environments.languages[0].id
    @State private var version = Environments.languages[0].versions[1]
    @State private var image = ""
    @State private var commands = ""
    @State private var saving = false
    @State private var error: String?

    enum RuntimeMode: Hashable { case none, preset, dockerfile, image }

    private var conn: BoxConnection? { model.connection(for: route.box) }
    private var api: BoxAPI? { conn.map { BoxAPI(transport: $0.raw) } }
    private var docker: DockerState? { view?.docker }
    private var edited: ProjectEnvironment {
        var e = draft
        let cmds = commands.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        switch mode {
        case .none: e.runtime = nil
        case .preset: e.runtime = EnvRuntime(preset: "\(language):\(version)")
        case .dockerfile: e.runtime = EnvRuntime(projectDockerfile: true, commands: cmds)
        case .image: e.runtime = EnvRuntime(image: image.trimmingCharacters(in: .whitespaces), commands: cmds)
        }
        return e
    }
    private var changed: Bool { view.map { edited != $0.environment } ?? false }
    private var valid: Bool {
        switch mode {
        case .none, .preset: true
        case .dockerfile: !commands.trimmingCharacters(in: .whitespaces).isEmpty
        case .image: !image.trimmingCharacters(in: .whitespaces).isEmpty && !commands.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        Form {
            if let view {
                statusSection(view)
                runtimeSection(view)
                containersSection(view)
                if view.project.compose || draft.compose {
                    Section {
                        Toggle("Rodar o compose do projeto", isOn: $draft.compose).accessibilityIdentifier("env-compose")
                    } footer: {
                        Text("Cada worktree sobe o docker compose do próprio projeto como o serviço “compose”, com um nome só dela (pier-<worktree>), para as worktrees não dividirem containers.")
                    }
                    .listRowBackground(Theme.card)
                }
                if !view.status.variables.isEmpty {
                    Section {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(view.status.variables, id: \.self) { v in
                                Text(v).font(.mono(11)).foregroundStyle(Theme.textDim)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.cardRaised, in: Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    } header: { Text("Variáveis nas worktrees") } footer: {
                        Text("Agentes, terminais e serviços do projeto recebem estas variáveis (o .env do projeto pode ler DB_HOST, DB_PORT, DATABASE_URL…). O env do próprio projeto tem prioridade.")
                    }
                    .listRowBackground(Theme.card)
                }
                if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline).textSelection(.enabled) }.listRowBackground(Theme.card) }
            } else if let error {
                Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card)
            } else {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .pierBackground()
        .navigationTitle("Ambiente")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Aplicar") { Task { await save() } }
                        .disabled(!changed || !valid || docker?.available != true && !edited.isEmpty)
                        .accessibilityIdentifier("env-apply")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .task(id: view?.isBuilding) {
            // While the box builds, read it again until it is done.
            while view?.isBuilding == true, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let v = try? await api?.environment(location: route.location) { view = v }
            }
        }
    }

    // MARK: sections

    @ViewBuilder private func statusSection(_ v: EnvironmentView) -> some View {
        Section {
            if v.docker.available != true {
                Label("Docker indisponível na box", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                if let e = v.docker.error { Text(e).font(.caption).foregroundStyle(Theme.textDim).textSelection(.enabled) }
                Text("Instale o Docker na box e coloque o usuário do pierd no grupo docker para isolar os ambientes.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            } else {
                HStack(spacing: 10) {
                    switch v.status.state {
                    case "building": ProgressView().controlSize(.small); Text("Preparando o ambiente…")
                    case "ready": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green); Text("Ambiente pronto")
                    case "failed": Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red); Text("Falhou")
                    default: Image(systemName: "circle.dashed").foregroundStyle(Theme.textFaint); Text("Usa os programas da própria box")
                    }
                    Spacer()
                    if let s = Environments.summary(v.environment) { Text(s).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
                }
                .font(.subheadline)
                .accessibilityIdentifier("env-state-\(v.status.state)")
                if v.status.state == "failed", let e = v.status.error {
                    Text(e).font(.mono(11)).foregroundStyle(Theme.red).textSelection(.enabled).lineLimit(12)
                }
                if let img = v.status.image, !v.status.commands.isEmpty {
                    Text("\(v.status.commands.joined(separator: ", ")) rodam em \(img)").font(.caption).foregroundStyle(Theme.textDim)
                }
            }
        } footer: {
            Text("Tudo roda em containers do Docker na box; nada é escrito no projeto. Os dados dos bancos ficam em volumes do Docker até o projeto ser removido do disco.")
        }
        .listRowBackground(Theme.card)
    }

    @ViewBuilder private func runtimeSection(_ v: EnvironmentView) -> some View {
        Section {
            Picker("Rodar com", selection: $mode) {
                Text("Programas da box").tag(RuntimeMode.none)
                Text("Versão escolhida").tag(RuntimeMode.preset)
                if v.project.dockerfile || mode == .dockerfile { Text("Dockerfile do projeto").tag(RuntimeMode.dockerfile) }
                Text("Imagem própria").tag(RuntimeMode.image)
            }
            .accessibilityIdentifier("env-runtime-mode")
            switch mode {
            case .none: EmptyView()
            case .preset:
                Picker("Linguagem", selection: $language) {
                    ForEach(Environments.languages) { Text($0.title).tag($0.id) }
                }
                .onChange(of: language) { _, l in
                    let vs = Environments.languages.first { $0.id == l }?.versions ?? []
                    if !vs.contains(version) { version = vs.count > 1 ? vs[1] : vs.first ?? "" }
                }
                Picker("Versão", selection: $version) {
                    ForEach(Environments.languages.first { $0.id == language }?.versions ?? [], id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("env-version")
                if let l = Environments.languages.first(where: { $0.id == language }) {
                    Text("No projeto, \(l.commands.joined(separator: ", ")) passam a rodar nesta versão.").font(.caption).foregroundStyle(Theme.textDim)
                }
            case .dockerfile:
                TextField("programas (ex.: php composer)", text: $commands).font(.mono(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
            case .image:
                TextField("imagem (ex.: php:8.4-cli)", text: $image).font(.mono(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("programas (ex.: php composer)", text: $commands).font(.mono(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } header: { Text("Linguagem") } footer: {
            Text("Cada projeto com a sua versão, sem instalar nada na box nem mexer nos outros projetos.")
        }
        .listRowBackground(Theme.card)
        .disabled(v.docker.available != true)
    }

    @ViewBuilder private func containersSection(_ v: EnvironmentView) -> some View {
        Section {
            if draft.containers.isEmpty {
                Text("Nenhum banco ou serviço.").font(.subheadline).foregroundStyle(Theme.textDim)
            }
            ForEach(draft.containers) { c in
                let st = v.status.containers.first { $0.name == c.name && $0.image == c.image }
                HStack(spacing: 10) {
                    Circle().fill(st?.isRunning == true ? Theme.green : Theme.textFaint).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Environments.service(ofImage: c.image).map { "\($0.service.title) \($0.version)" } ?? c.image)
                            .foregroundStyle(Theme.text)
                        HStack(spacing: 6) {
                            Text(c.name).font(.mono(11))
                            if let p = st?.hostPort { Text("·"); Text("127.0.0.1:\(String(p))").font(.mono(11)) }
                            if st == nil { Text("·"); Text("a aplicar") }
                        }
                        .font(.caption).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Button(role: .destructive) { draft.containers.removeAll { $0.name == c.name } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).tint(Theme.red).accessibilityLabel("Remover \(c.name)")
                }
                .accessibilityIdentifier("env-container-\(c.name)")
            }
            Menu {
                ForEach(Environments.services) { s in
                    Menu(s.title) {
                        ForEach(s.versions, id: \.self) { ver in
                            Button("\(s.title) \(ver)") { draft.containers.append(Environments.container(s, version: ver, taken: draft.containers)) }
                        }
                    }
                }
            } label: { Label("Adicionar banco ou serviço", systemImage: "plus.circle") }
            .accessibilityIdentifier("env-add-container")
        } header: { Text("Bancos e serviços") } footer: {
            Text("Cada um roda num container só deste projeto, numa porta própria da box, com os dados num volume do Docker. Usuário root (Postgres: postgres), senha “pier”, banco “app”.")
        }
        .listRowBackground(Theme.card)
        .disabled(v.docker.available != true)
    }

    // MARK: loading

    private func load() async {
        guard let api else { return }
        do {
            let v = try await api.environment(location: route.location)
            apply(v)
            error = nil
        } catch { self.error = ComposeErrorText.message(error) }
    }

    /// Takes what the box has as the screen's choices.
    private func apply(_ v: EnvironmentView) {
        view = v
        draft = v.environment
        commands = v.environment.runtime?.commands.joined(separator: " ") ?? ""
        image = v.environment.runtime?.image ?? ""
        if let p = Environments.parsePreset(v.environment.runtime?.preset) {
            mode = .preset; language = p.language.id; version = p.version
        } else if v.environment.runtime?.projectDockerfile == true {
            mode = .dockerfile
        } else if v.environment.runtime?.image != nil {
            mode = .image
        } else {
            mode = .none
        }
    }

    private func save() async {
        guard let api else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            apply(try await api.setEnvironment(location: route.location, edited))
            await conn?.refreshLocations()
        } catch { self.error = ComposeErrorText.message(error) }
    }
}
