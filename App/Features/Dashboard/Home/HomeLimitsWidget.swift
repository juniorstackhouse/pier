import SwiftUI
import PierKit

/// "Limites de uso": each Claude Code and Codex account of each box with how much of its subscription's windows is used
/// (5 hours, 7 days) and when each resets. Claude Code's come from pierd's status line (an account whose status line is
/// not pierd's yet offers to turn it on), Codex's from its newest session log. A tap makes an account the box's default,
/// the quick way to move new agents to another subscription; the accounts themselves are managed in Ajustes.
struct LimitsWidget: View {
    let home: HomeStore
    @Environment(AppModel.self) private var model
    @State private var busy: String?

    private var multiBox: Bool { Set(home.limits.map(\.box)).count > 1 }

    var body: some View {
        let list = home.limits
        let urgent = list.contains { Accounts.tightest($0.account.limits).map { Accounts.level($0.usedPercent) == .critical } ?? false }
        HomeCard(kind: .limits, count: nil, urgent: urgent, updatedAt: home.limitsAt, loading: home.limitsAt == nil && home.loading.contains(.limits)) {
            if home.limitsAt == nil {
                if let e = home.limitsError { HomeEmpty(symbol: "exclamationmark.triangle", title: "Não foi possível ler os limites", hint: e, color: Theme.orange) }
                else if model.boxes.allSatisfy({ $0.info?.has("accounts") != true }) {
                    HomeEmpty(symbol: "gauge.with.dots.needle.0percent", title: "Atualize o pierd", hint: HL("As boxes mostram os limites a partir desta versão do pierd."))
                } else { HomeSkeleton(rows: 2) }
            } else if list.isEmpty {
                HomeEmpty(symbol: "gauge.with.dots.needle.0percent", title: "Nenhuma conta", hint: HL("Instale o Claude Code ou o Codex na box."))
            } else {
                VStack(spacing: 14) { ForEach(list) { row($0) } }
            }
        }
    }

    @ViewBuilder private func row(_ e: HomeStore.LimitsEntry) -> some View {
        let a = e.account
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AgentGlyph(agent: a.agent, size: 22)
                Text(a.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if multiBox { Text(verbatim: e.box).font(.caption).foregroundStyle(Theme.textFaint) }
                if a.isDefault {
                    HText("padrão").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.accent.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 4)
                if busy == e.id { ProgressView().controlSize(.mini) }
                Menu {
                    if !a.isDefault {
                        Button { Task { await makeDefault(e) } } label: { Label { HText("Usar como padrão na box") } icon: { Image(systemName: "checkmark.circle") } }
                    }
                    if !a.projects.isEmpty {
                        Section(HL("Projetos nesta conta")) { ForEach(a.projects, id: \.self) { Text(verbatim: $0) } }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textDim).frame(width: 28, height: 22)
                }
                .accessibilityIdentifier("limits-menu-\(a.id)")
            }
            if !a.signedIn && a.signedInKnown {
                HText("Não conectada: entre em Ajustes › Contas.").font(.caption).foregroundStyle(Theme.orange)
            } else if let windows = a.limits?.windows, !windows.isEmpty {
                ForEach(windows) { w in bar(w) }
            } else if !a.limitsReady {
                Button { Task { await enable(e) } } label: {
                    Label { HText("Ativar a leitura dos limites") } icon: { Image(systemName: "gauge.with.dots.needle.33percent") }
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("limits-enable")
            } else {
                HText(a.agent == "codex" ? "Aparecem depois da próxima sessão do Codex." : "Aparecem depois da próxima resposta do Claude Code.")
                    .font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("limits-\(a.id)")
    }

    private func bar(_ w: LimitWindow) -> some View {
        let level = Accounts.level(w.usedPercent)
        let color = level == .critical ? Theme.red : level == .high ? Theme.orange : Theme.accent
        return HStack(spacing: 8) {
            Text(verbatim: Accounts.windowLabel(w)).font(.mono(11, weight: .semibold)).foregroundStyle(Theme.textDim).frame(width: 24, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardRaised)
                    Capsule().fill(color).frame(width: max(4, g.size.width * min(w.usedPercent, 100) / 100))
                }
            }
            .frame(height: 6)
            Text(verbatim: "\(Int(w.usedPercent.rounded()))%").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(level == .ok ? Theme.text : color)
                .frame(width: 38, alignment: .trailing)
            if let r = w.resetsAt, r > Date() {
                Text(r, format: .relative(presentation: .numeric, unitsStyle: .narrow)).font(.caption2).foregroundStyle(Theme.textFaint)
                    .frame(width: 64, alignment: .trailing).lineLimit(1)
            }
        }
    }

    private func makeDefault(_ e: HomeStore.LimitsEntry) async {
        guard let conn = model.connection(for: e.box) else { return }
        busy = e.id
        defer { busy = nil }
        _ = try? await BoxAPI(transport: conn.raw).makeDefaultAccount(id: e.account.id)
        model.toast = AppToast(text: String(localized: "Novos agentes em \(e.box) usam “\(e.account.name)”."), symbol: "person.crop.circle.badge.checkmark")
        await home.reloadLimits()
    }

    private func enable(_ e: HomeStore.LimitsEntry) async {
        guard let conn = model.connection(for: e.box) else { return }
        busy = e.id
        defer { busy = nil }
        try? await BoxAPI(transport: conn.raw).enableLimits()
        await home.reloadLimits()
    }
}
