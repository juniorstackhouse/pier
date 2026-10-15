#if os(iOS) && !targetEnvironment(macCatalyst)
import CarPlay
import PierKit

/// Pier on the car's screen (CarPlay, communication category): the agents that need the person, the turns that ended,
/// and the agents at work, from every paired box. Made for a glance and the voice:
/// - a waiting agent opens its answers as big rows (Permitir / Negar, or its question's choices, checked against the box
///   before they are sent, as from a notification), plus "Responder por voz";
/// - an ended turn is a conversation: picking it has Siri read the reply aloud and take a spoken answer
///   (`CPMessageListItem` → `MessageIntentHandler`), with no typing and no reading while driving;
/// - an agent at work only says so.
/// Runs without the app's window (the phone locked in a pocket): `CarFeed` reads the boxes headlessly, every few seconds
/// while the car shows it. Needs the CarPlay communication entitlement (`com.apple.developer.carplay-communication`):
/// simulator builds carry it; a device build gets it once Apple grants it (docs/CARPLAY.md).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        let c = CarPlayController(interface: interfaceController)
        controller = c
        c.start()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.stop()
        controller = nil
    }
}

@MainActor
final class CarPlayController {
    /// nil only for the Debug self-test, which builds the list without a car (`CarPlaySelfTest`).
    private let interface: CPInterfaceController?
    private let root: CPListTemplate
    private var loop: Task<Void, Never>?
    /// What the list shows now (kind, id, since): the list is redrawn only when it changes, so nothing flickers.
    private var shown: [String] = []
    /// How often the boxes are read while the car shows Pier.
    private static let interval: Duration = .seconds(5)

    init(interface: CPInterfaceController?) {
        self.interface = interface
        root = CPListTemplate(title: "Pier", sections: [])
        root.emptyViewTitleVariants = [String(localized: "Nada esperando por você")]
        root.emptyViewSubtitleVariants = [String(localized: "Os agentes que precisarem de você aparecem aqui.")]
        root.tabTitle = "Pier"
        root.tabImage = UIImage(systemName: "bubble.left.and.bubble.right.fill")
    }

    func start() {
        interface?.setRootTemplate(root, animated: false, completion: nil)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: the list

    func refresh() async {
        let rows = await CarFeed.rows(limit: max(1, min(8, CPListTemplate.maximumItemCount / 3)))
        let signature = rows.map { "\($0.kind.rawValue)|\($0.id)|\($0.since.timeIntervalSince1970)|\(CarDigest.title($0.session))" }
        guard signature != shown else { return }
        shown = signature
        root.updateSections(sections(rows))
    }

    func sections(_ rows: [CarDigest.Row]) -> [CPListSection] {
        var out: [CPListSection] = []
        let waiting = rows.filter { $0.kind == .needsYou }
        if !waiting.isEmpty {
            out.append(CPListSection(items: waiting.map(waitingItem), header: String(localized: "Precisa de você"), sectionIndexTitle: nil))
        }
        let ended = rows.filter { $0.kind == .yourTurn }
        if !ended.isEmpty {
            out.append(CPListSection(items: ended.map(endedItem), header: String(localized: "Sua vez"), sectionIndexTitle: nil))
        }
        let working = rows.filter { $0.kind == .working }
        if !working.isEmpty {
            out.append(CPListSection(items: working.map(workingItem), header: String(localized: "Trabalhando"), sectionIndexTitle: nil))
        }
        return out
    }

    private func waitingItem(_ row: CarDigest.Row) -> CPListItem {
        let item = CPListItem(text: CarDigest.title(row.session), detailText: CarFeed.ask(row.session),
                              image: Self.symbol("hand.raised.fill", .systemOrange))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                await self?.openAnswers(row)
                done()
            }
        }
        return item
    }

    /// A conversation Siri reads and answers: unread until the person looked at it on a screen.
    private func endedItem(_ row: CarDigest.Row) -> CPMessageListItem {
        let lead = CPMessageListItemLeadingConfiguration(leadingItem: .none, leadingImage: Self.avatar(row), unread: true)
        let trail = CPMessageListItemTrailingConfiguration(trailingItem: .none, trailingImage: nil)
        return CPMessageListItem(conversationIdentifier: row.id, text: CarDigest.title(row.session), leadingConfiguration: lead,
                                 trailingConfiguration: trail,
                                 detailText: String(localized: "\(CarDigest.agentName(row.session)) terminou · toque para ouvir"),
                                 trailingText: Self.age(row.since))
    }

    private func workingItem(_ row: CarDigest.Row) -> CPListItem {
        let item = CPListItem(text: CarDigest.title(row.session),
                              detailText: String(localized: "\(CarDigest.agentName(row.session)) trabalhando · \(Self.age(row.since))"),
                              image: Self.symbol("ellipsis.circle.fill", .systemBlue))
        item.handler = { _, done in done() }
        return item
    }

    // MARK: answering

    /// A waiting agent's answers, read from its box now: Permitir / Negar for a permission menu, else its question's
    /// choices; and "Responder por voz" (Siri takes the words).
    private func openAnswers(_ row: CarDigest.Row) async {
        let s = row.session
        var items: [CPListTemplateItem] = []
        if Ask.classify(s.ask) == .permission {
            items.append(answerItem(String(localized: "Permitir"), "checkmark.circle.fill", .systemGreen) {
                await SessionActions.answerPermission(box: row.box, session: s.name, .allow)
            })
            items.append(answerItem(String(localized: "Negar"), "xmark.circle.fill", .systemRed) {
                await SessionActions.answerPermission(box: row.box, session: s.name, .deny)
            })
        } else if let client = try? HeadlessBoxes.box(row.box).client,
                  let options = await ChoiceOptions.fetch(client: client, session: s) {
            for (i, label) in options.enumerated() {
                items.append(answerItem("\(i + 1). \(label)", "\(i + 1).circle.fill", .systemBlue) {
                    await SessionActions.answerChoice(box: row.box, session: s.name, label: label)
                })
            }
        }
        let voice = CPMessageListItem(conversationIdentifier: row.id, text: String(localized: "Responder por voz"),
                                      leadingConfiguration: CPMessageListItemLeadingConfiguration(
                                        leadingItem: .none, leadingImage: Self.symbol("mic.fill", .systemBlue), unread: false),
                                      trailingConfiguration: CPMessageListItemTrailingConfiguration(trailingItem: .none, trailingImage: nil),
                                      detailText: String(localized: "Diga a resposta para o Siri"), trailingText: nil)
        items.append(voice)
        let section = CPListSection(items: items, header: CarFeed.ask(s), sectionIndexTitle: nil)
        let template = CPListTemplate(title: CarDigest.title(s), sections: [section])
        interface?.pushTemplate(template, animated: true, completion: nil)
    }

    /// A row that answers the agent, then goes back to the list (or says why it could not).
    private func answerItem(_ title: String, _ symbol: String, _ color: UIColor,
                            _ act: @escaping @MainActor () async -> Result<Void, SessionActions.Failure>) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: Self.symbol(symbol, color))
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                let result = await act()
                done()
                guard let self else { return }
                switch result {
                case .success:
                    self.interface?.popToRootTemplate(animated: true, completion: nil)
                    self.shown = []
                    await self.refresh()
                case .failure(let f):
                    self.alert(f.message)
                }
            }
        }
        return item
    }

    private func alert(_ message: String) {
        let ok = CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak self] _ in
            self?.interface?.dismissTemplate(animated: true, completion: nil)
        }
        interface?.presentTemplate(CPAlertTemplate(titleVariants: [message], actions: [ok]), animated: true, completion: nil)
    }

    // MARK: drawing

    private static func symbol(_ name: String, _ color: UIColor) -> UIImage? {
        UIImage(systemName: name)?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    private static func avatar(_ row: CarDigest.Row) -> UIImage? {
        CommunicationNotification.avatarImage(for: CarDigest.agentName(row.session))
    }

    /// "agora", "5 min", "2 h": how long ago, short enough for the car's trailing text.
    private static func age(_ since: Date) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = [.day, .hour, .minute]
        let interval = Date().timeIntervalSince(since)
        return interval < 60 ? String(localized: "agora") : (f.string(from: interval) ?? "")
    }
}

#endif
