import SwiftUI
import PierKit

/// The widest a conversation's column grows (iPad, Mac): about 90 characters of body text a line, like a book or any
/// chat on a desktop, instead of lines that run across the whole window.
let readableColumn: CGFloat = 780

struct ConversationView: View {
    let vm: SessionViewModel
    @Environment(Router.self) private var router
    @State private var bottomVisible = true
    @State private var scrollState = ConversationScrollState()
    @State private var scrollEvents = ConversationScrollEvents()
    @State private var followTask: Task<Void, Never>?

    private var detached: Bool { !scrollState.followsBottom }
    @State private var scrolledUp = false

    private var blocks: [ConversationBlock] { ConversationFold.blocks(vm.store.displayItems, live: vm.isRunning || vm.isWaiting) }

    /// What the lazy stack iterates: an id and where the block is. SwiftUI walks a ForEach's data again and again while
    /// it scrolls, and copying the blocks themselves (each holding whole transcript items) was a tenth of the main thread.
    private struct Row: Identifiable {
        let id: String
        let index: Int
    }

    var body: some View {
        let blocks = self.blocks
        let rows = blocks.indices.map { Row(id: blocks[$0].id, index: $0) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    top(proxy)
                    // A task just started here: the person's words first, while the agent writes its record.
                    if vm.showsStartingPrompt, let p = vm.startingPrompt {
                        UserBubble(item: TranscriptItem(kind: "user", id: "starting-prompt", text: p), agent: vm.session.agentShortName)
                            .id("starting-prompt")
                    }
                    ForEach(rows) { row in
                        switch blocks[row.index] {
                        case .item(let it):
                            TranscriptRow(vm: vm, item: it).id(it.id)
                        case .fold(let id, let steps, let live):
                            WorkFoldRow(vm: vm, id: id, steps: steps, live: live).id(id)
                        }
                    }
                    ForEach(vm.outgoing) { o in OutgoingBubble(message: o).id(o.id) }
                    if vm.isRunning || vm.starting { LiveDraftRow(vm: vm).id("draft") }
                    if let card = vm.reviewCard, let (loc, wt) = vm.reviewTarget {
                        ReviewCard(changes: card.changes, uncommittedOnly: card.uncommittedOnly) {
                            router.push(ReviewRoute(box: vm.box, location: loc, worktree: wt, session: vm.name))
                        }
                        .id("review-card")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    // Suggested replies for a finished turn (Inbox feature): only sent when the person taps one.
                    SessionNextSteps(vm: vm).id("next-steps")
                    if vm.store.displayItems.isEmpty, vm.outgoing.isEmpty, vm.loaded, !vm.isRunning, !vm.starting, !vm.showsStartingPrompt { emptyNote }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear {
                            if #available(iOS 18, *) { return }
                            bottomVisible = true
                            scrollState.requestFollow()
                        }
                        .onDisappear {
                            if #available(iOS 18, *) { return }
                            bottomVisible = false
                        }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                .frame(maxWidth: readableColumn)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("conversation-scroll")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size.width > 0, size.height > 0 else { return }
                // Window/inspector resizing reflows text. Follow the viewport, never estimated content height.
                scrollEvents.submitViewportChange(size) { follow(proxy) }
            }
            .modifier(InitialConversationAnchor())
            .modifier(FollowScrollPosition(state: $scrollState, events: scrollEvents, resumeFollowing: { follow(proxy) }) {
                Task { await loadOlder(proxy) }
            })
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onEnded { _ in
                // iOS 17 (no scroll geometry): a drag that left the bottom out of view detaches.
                if #available(iOS 18, *) { return }
                scrolledUp = true
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    _ = scrollState.update(fromTop: 300, fromBottom: bottomVisible ? 0 : 200,
                                           scrollable: true, userInteracting: true)
                }
            })
            // A task just started here already has its first message to show: no spinner over it.
            .overlay { if !vm.loaded && !vm.showsStartingPrompt { loading } }
            .overlay(alignment: .bottomTrailing) {
                if detached {
                    Button {
                        requestFollow(proxy)
                    } label: {
                        Image(systemName: "arrow.down").font(.footnote.weight(.bold)).foregroundStyle(Theme.text)
                            .padding(11).background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.stroke))
                    }
                    .padding(12).transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Ir para o fim")
                }
            }
            // Observe streaming in a child, so each draft update does not fold/diff the entire history.
            // Follow content changes explicitly, outside the layout transaction. Size-change anchoring on a
            // lazy stack can feed its estimated heights back into scroll layout indefinitely on Mac Catalyst.
            .background { DraftFollow(vm: vm) { follow(proxy) } }
            .background {
                #if DEBUG
                ChatHistoryProbe()
                #endif
            }
            .onChange(of: vm.store.next) { _, _ in follow(proxy) }
            .onChange(of: vm.loaded) { _, loaded in if loaded { follow(proxy) } }
            .onChange(of: vm.outgoing.count) { _, _ in follow(proxy) }
            .onChange(of: vm.session.agentState) { _, _ in follow(proxy) }
            .onChange(of: vm.reviewCard?.changes) { _, _ in follow(proxy) }
            .onChange(of: vm.sendTick) { _, _ in requestFollow(proxy) }
            .onDisappear {
                followTask?.cancel()
                scrollEvents.cancelGeometry()
                scrollEvents.cancelViewportChange()
            }
        }
    }

    private func requestFollow(_ proxy: ScrollViewProxy) {
        scrollEvents.cancelGeometry()
        scrollState.requestFollow()
        follow(proxy)
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard scrollState.followsBottom, !vm.loadingOlder else { return }
        if scrollEvents.isUserInteracting || scrollEvents.isViewportChanging {
            scrollEvents.pendingContentFollow = true
            return
        }
        scrollEvents.pendingContentFollow = false
        followTask?.cancel()
        followTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, scrollState.followsBottom, !vm.loadingOlder else { return }
            if scrollEvents.isUserInteracting || scrollEvents.isViewportChanging {
                scrollEvents.pendingContentFollow = true
                return
            }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    @ViewBuilder private func top(_ proxy: ScrollViewProxy) -> some View {
        if vm.store.hasMoreBefore {
            Button {
                Task { await loadOlder(proxy) }
            } label: {
                HStack(spacing: 6) {
                    if vm.loadingOlder { ProgressView().controlSize(.small) } else { Image(systemName: "clock.arrow.circlepath").font(.caption) }
                    Text("Mensagens anteriores").font(.footnote)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .foregroundStyle(Theme.textDim)
            .disabled(vm.loadingOlder)
            .onAppear {
                if #available(iOS 18, *) { return }
                if scrolledUp { Task { await loadOlder(proxy) } }
            }
            .onChange(of: scrolledUp) { _, up in if up { Task { await loadOlder(proxy) } } }
        } else if vm.loaded, vm.store.displayItems.count > 6 {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                Text("Início da conversa").font(.caption2).foregroundStyle(Theme.textFaint).fixedSize()
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
            .padding(.vertical, 6)
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) async {
        guard !vm.loadingOlder, vm.store.hasMoreBefore, let offset = vm.store.oldestOffset else { return }
        scrollState.requestHistory()
        scrollEvents.pendingContentFollow = false
        followTask?.cancel()
        let first = blocks.first?.id
        await vm.loadOlder()
        // Failed requests and concurrent/no-op loads must not move the scroll position.
        guard let newOffset = vm.store.oldestOffset, newOffset < offset, let first else { return }
        proxy.scrollTo(first, anchor: .top)
    }

    private var emptyNote: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.title2).foregroundStyle(Theme.textFaint)
            Text("Nada por aqui ainda").font(.subheadline).foregroundStyle(Theme.textDim)
            Text("As mensagens aparecem assim que o agente começar a trabalhar.").font(.caption).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    @ViewBuilder private var loading: some View {
        if let err = vm.loadError {
            VStack(spacing: 12) {
                EmptyState(symbol: "exclamationmark.triangle", title: "Sem conversa", message: LocalizedStringKey(err))
                Button("Ver terminal") { vm.setMode(.terminal) }.buttonStyle(SecondaryButtonStyle()).frame(width: 180)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text("Abrindo a conversa…").font(.footnote).foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// The reply being written right now and an alive "working" line: the agent's own status word (Brewing…), its current
/// step read from the screen, and the time on this turn.
struct LiveDraftRow: View {
    let vm: SessionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Words still being written: nothing to select yet, and no cost to pay on every update for it.
            if let t = vm.visibleDraft { MarkdownView(text: t, draft: true, touchSelection: false) }
            HStack(spacing: 8) {
                PulsingDot()
                ShimmerText(text: vm.liveWord)
                if let step = vm.step, !step.isEmpty, step != StepText.thinking || vm.draft?.status == nil {
                    Text("· \(step)").font(.footnote).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { c in
                    Text(Fmt.elapsed(since: vm.session.stateSince, now: c.date)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// The working dot: fades and shrinks a little, back and forth. Core Animation runs it (a `phaseAnimator` updated the
/// view graph every frame on the main thread).
struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion || !Motion.endless {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
        } else {
            PulseLayer(color: UIColor(Theme.accent)).frame(width: 8, height: 8)
        }
    }
}

private struct PulseLayer: UIViewRepresentable {
    let color: UIColor
    func makeUIView(context: Context) -> PulseView { PulseView() }
    func updateUIView(_ view: PulseView, context: Context) { view.backgroundColor = color }

    final class PulseView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, layer.animation(forKey: "pulse") == nil else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0.35
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.8
            let pulse = CAAnimationGroup()
            pulse.animations = [fade, shrink]
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        }
    }
}

/// Conversation-style view of an agent with no record the box can read (or a plain terminal program): the last thing on
/// its screen, rendered calmly, with a way into the terminal.
struct ConversationFallback: View {
    let vm: SessionViewModel

    private var lastMessage: String {
        MenuParser.lastMessage(TerminalText.clean(vm.screen)).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.textDim)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(vm.session.isAgent ? "Sem registro de conversa" : "Sessão de terminal").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(reason).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                if let p = vm.session.title, !p.isEmpty, vm.session.isAgent {
                    UserBubble(item: TranscriptItem(kind: "user", id: "prompt", text: p), agent: vm.session.agentShortName)
                }
                if !lastMessage.isEmpty {
                    MarkdownView(text: lastMessage).contextMenu { CopyButton(text: lastMessage) }
                } else if vm.screenLoaded {
                    Text("A tela do agente está vazia por enquanto.").font(.footnote).foregroundStyle(Theme.textDim)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if vm.isRunning { LiveDraftRow(vm: vm) }
                Button { vm.setMode(.terminal) } label: { Label("Ver terminal completo", systemImage: "terminal") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var reason: String {
        if !vm.session.isAgent { return S("Esta sessão roda um programa comum; abaixo está o que a tela mostra.") }
        if let r = vm.store.reason, !r.isEmpty { return S("A box não encontrou o registro deste agente (\(r)). Abaixo, a última mensagem lida da tela.") }
        return S("A box não encontrou o registro deste agente. Abaixo, a última mensagem lida da tela.")
    }
}

/// End of a finished turn that changed files: what changed, and the way into the review.
struct ReviewCard: View {
    let changes: TurnChanges
    let uncommittedOnly: Bool
    let action: () -> Void

    private var title: String {
        let n = changes.files
        if uncommittedOnly { return n == 1 ? S("\(n) arquivo com mudanças não commitadas") : S("\(n) arquivos com mudanças não commitadas") }
        return n == 1 ? S("Alterou \(n) arquivo") : S("Alterou \(n) arquivos")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass").font(.subheadline).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                PlusMinus(added: changes.added, removed: changes.removed, size: 12)
            }
            Spacer(minLength: 6)
            Button(action: action) {
                Text("Revisar").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("review-card-button")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// Set the initial position only. Continuously anchoring size changes fights a LazyVStack's height estimates.
private struct InitialConversationAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// Holds transient events without invalidating the view graph from inside a geometry callback.
@MainActor
private final class ConversationScrollEvents {
    var isUserInteracting = false
    private(set) var isViewportChanging = false
    /// Retry content following after a gesture or a viewport resize ends, if the reader is still following.
    var pendingContentFollow = false
    private var pendingGeometry: (@MainActor () -> Void)?
    private var scheduled = false
    private var viewportSize: CGSize?
    private var pendingViewportChange: (@MainActor () -> Void)?
    private var viewportTask: Task<Void, Never>?

    func submitGeometry(_ action: @escaping @MainActor () -> Void) {
        pendingGeometry = action
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let action = self.pendingGeometry
            self.pendingGeometry = nil
            action?()
        }
    }

    func cancelGeometry() { pendingGeometry = nil }

    /// A next-queue-turn scrollTo can still race the window's repeated layout passes. Wait for a stable viewport;
    /// the initial anchor and the loaded-content event already handle the first measurement.
    func submitViewportChange(_ size: CGSize, _ action: @escaping @MainActor () -> Void) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        guard let previous = viewportSize else { viewportSize = size; return }
        guard size != previous else { return }
        viewportSize = size
        isViewportChanging = true
        pendingViewportChange = action
        viewportTask?.cancel()
        viewportTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.viewportTask = nil
            self.isViewportChanging = false
            let action = self.pendingViewportChange
            self.pendingViewportChange = nil
            action?()
        }
    }

    func cancelViewportChange() {
        viewportTask?.cancel()
        viewportTask = nil
        pendingViewportChange = nil
        viewportSize = nil
        isViewportChanging = false
    }
}

/// Only real scroll interaction can detach following or request a history page. Initial placement, lazy height
/// estimates, a prepend and an explicit scrollTo all produce geometry too; none is a reader asking for more history.
private struct FollowScrollPosition: ViewModifier {
    @Binding var state: ConversationScrollState
    let events: ConversationScrollEvents
    let resumeFollowing: () -> Void
    let loadOlder: () -> Void

    struct Spot: Equatable {
        var fromBottom: Double
        var fromTop: Double
        var scrollable: Bool
    }

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Spot.self) { g in
                Spot(fromBottom: Double(((g.contentSize.height - g.visibleRect.maxY) / 20).rounded() * 20),
                     fromTop: Double((g.visibleRect.minY / 20).rounded() * 20),
                     scrollable: g.contentSize.height > g.containerSize.height + 1)
            } action: { _, spot in
                guard events.isUserInteracting else { return }
                events.submitGeometry {
                    if state.update(fromTop: spot.fromTop, fromBottom: spot.fromBottom,
                                    scrollable: spot.scrollable, userInteracting: true) {
                        loadOlder()
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                events.isUserInteracting = phase == .tracking || phase == .interacting || phase == .decelerating
                if phase == .idle {
                    // Deliver the final gesture position before rearming pagination for the next gesture.
                    DispatchQueue.main.async {
                        if !events.isUserInteracting {
                            state.endInteraction()
                            if events.pendingContentFollow {
                                events.pendingContentFollow = false
                                resumeFollowing()
                            }
                        }
                    }
                }
            }
        } else {
            content
        }
    }
}

/// Isolates high-frequency draft observation from the conversation's folding and diffing.
private struct DraftFollow: View {
    let vm: SessionViewModel
    let follow: () -> Void

    var body: some View {
        Color.clear.onChange(of: vm.draft?.text) { _, _ in follow() }
    }
}

/// A message the person just sent: drawn at once, in their bubble, until the box's copy takes its place.
struct OutgoingBubble: View {
    let message: SessionViewModel.Outgoing

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 4) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body).lineSpacing(2).foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    if message.photos > 0 {
                        Image(systemName: "photo").font(.caption2)
                        Text(message.photos == 1 ? S("1 foto") : S("\(message.photos) fotos"))
                        Text("·")
                    }
                    Text("Enviando…")
                }
                .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .opacity(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Você, enviando: \(message.text)")
        .accessibilityIdentifier("outgoing-message")
    }
}
