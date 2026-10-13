import SwiftUI
import PierKit

/// Remove a project from the box's disk (`DELETE /v1/locations/{l}?purge=1`): its repository and worktrees go, its services
/// stop and its sessions end; it stays on GitHub, to download again from "Repositórios do GitHub". Says first how much it
/// frees and what would be lost (`GET …/disk`): uncommitted files, commits no remote has, stashes. Those need "Descartar".
struct RemoveProjectSheet: View {
    let box: String
    let location: String
    /// Called once it is gone (the app's toast says so, wherever the person ends up).
    var onRemoved: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var disk: ProjectDisk?
    @State private var loadError: String?
    @State private var force = false
    @State private var working = false
    @State private var error: String?

    private var conn: BoxConnection? { model.connection(for: box) }
    private var name: String { prefs.displayName(box: box, location: location) }
    private var size: String { ByteCountFormatter.string(fromByteCount: disk?.bytes ?? 0, countStyle: .file) }
    private var onGitHub: Bool { disk?.remote?.contains("github.com") == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ProjectGlyph(name: name, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.headline).foregroundStyle(Theme.text)
                            if let disk {
                                Text("Ocupa \(size) no disco da box").font(.subheadline).foregroundStyle(Theme.textDim)
                            } else if loadError == nil {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Medindo o projeto…") }.font(.subheadline).foregroundStyle(Theme.textDim)
                            }
                        }
                    }
                    if let disk {
                        ForEach(disk.paths, id: \.self) { MonoText($0, size: 11, color: Theme.textFaint).lineLimit(1) }
                    }
                } footer: {
                    if onGitHub {
                        Text("O repositório continua no GitHub: baixe de volta quando quiser em Projetos › Repositórios do GitHub.")
                    } else {
                        Text("A pasta do repositório e as das worktrees são apagadas da box.")
                    }
                }
                .listRowBackground(Theme.card)

                if let loadError { Section { Text(loadError).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }

                if let disk, !disk.removable {
                    Section {
                        Label(disk.reason ?? String(localized: "Este projeto não pode ser apagado do disco."), systemImage: "hand.raised.fill")
                            .foregroundStyle(Theme.orange).font(.subheadline)
                    }.listRowBackground(Theme.card)
                } else if let disk {
                    if disk.hasUnsavedWork || disk.sessions > 0 {
                        Section {
                            if disk.sessions > 0 {
                                Label(disk.sessions == 1 ? String(localized: "1 sessão em andamento será encerrada.")
                                                         : String(localized: "\(disk.sessions) sessões em andamento serão encerradas."),
                                      systemImage: "terminal").foregroundStyle(Theme.orange)
                            }
                            ForEach(Array(Projects.unsavedLines(disk).enumerated()), id: \.offset) { _, l in
                                switch l.kind {
                                case .uncommitted:
                                    Label("\(l.name): \(l.count) arquivo(s) não commitado(s)", systemImage: "pencil.line").foregroundStyle(Theme.orange)
                                case .unpushed:
                                    Label("\(l.name): \(l.count) commit(s) que nenhum remoto tem", systemImage: "arrow.up.circle").foregroundStyle(Theme.orange)
                                case .stash:
                                    Label("\(l.count) stash(es)", systemImage: "tray.full").foregroundStyle(Theme.orange)
                                }
                            }
                            if disk.hasUnsavedWork {
                                Toggle("Descartar este trabalho", isOn: $force).tint(Theme.red).accessibilityIdentifier("purge-force")
                            }
                        } header: { Text(disk.hasUnsavedWork ? "Trabalho que só existe aqui" : "Atenção") }
                        .font(.subheadline)
                        .listRowBackground(Theme.card)
                    } else {
                        Section {
                            Label("Tudo commitado e enviado: nada se perde.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.green).font(.subheadline)
                        }.listRowBackground(Theme.card)
                    }
                    if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
                    Section {
                        Button(role: .destructive) { Task { await remove() } } label: {
                            HStack {
                                Spacer()
                                if working { ProgressView() } else { Text("Remover do disco (libera \(size))").fontWeight(.semibold) }
                                Spacer()
                            }
                        }
                        .disabled(working || (disk.hasUnsavedWork && !force))
                        .accessibilityIdentifier("purge-run")
                    }.listRowBackground(Theme.card)
                }
            }
            .pierBackground()
            .navigationTitle("Remover projeto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction) } }
            .task { await load() }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(working)
    }

    private func load() async {
        guard let conn else { return }
        do { disk = try await BoxAPI(transport: conn.raw).projectDisk(location: location) }
        catch { loadError = ComposeErrorText.message(error) }
    }

    private func remove() async {
        guard let conn else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let worktrees = conn.location(named: location)?.worktrees ?? []
            let r = try await BoxAPI(transport: conn.raw).purgeProject(location: location, force: force)
            for wt in worktrees { WorkspaceRegistry.shared.forget(box: box, location: location, worktree: wt.name) }
            await conn.refreshLocations(); await conn.refreshSessions()
            let freed = ByteCountFormatter.string(fromByteCount: r.freed, countStyle: .file)
            model.toast = AppToast(text: String(localized: "“\(name)” removido da box (\(freed) liberados)."), symbol: "externaldrive.badge.checkmark")
            onRemoved()
            dismiss()
        } catch {
            if (error as? BoxError)?.code == "unsaved_work" {
                // Work appeared since the sheet measured it: show it and ask again.
                await load()
            }
            self.error = ComposeErrorText.message(error)
        }
    }
}
