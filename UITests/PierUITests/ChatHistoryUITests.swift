import XCTest

/// Synthetic reproduction of the Mac chat's layout loop: a bottom-anchored, paginated conversation with uneven
/// rows, including one much taller than the viewport. Run this suite on Mac Catalyst (or an iPad simulator).
/// The mock's initial page has only turns 234–240; turn 233 can appear only after an older-page request.
final class ChatHistoryUITests: XCTestCase {
    private var app: XCUIApplication!
    private let lab = "chatlab-claude-z9"
    private let other = "sandbox-subtract-claude-6s1"
    private var latestTurn = 240

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMock", "1", "-uiTestChatLab", "1", "-uiTestChatLabTurns", "240", "-uiTestChatLabPageSize", "24",
            "-uiTestChatLabProbe", "1",
            "-openSession", lab, "-undoSeconds", "0", "-session.inspector", "0", "-macWindowSize", "1280x800",
            "-session.view.devbox/\(lab)", "conversation", "-session.view.devbox/\(other)", "conversation",
            "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR",
        ]
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func marker(_ turn: Int) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "history-turn-\(turn)")).firstMatch
    }

    private var conversation: XCUIElement { element("conversation-scroll") }
    private var historyRequests: Int? { (element("chat-history-before-count").value as? String).flatMap(Int.init) }

    private func assertLatestVisible() {
        let latest = marker(latestTurn)
        XCTAssertTrue(latest.waitForExistence(timeout: 15), "the newest reply never appeared; the layout may be spinning")
        let visible = NSPredicate { _, _ in latest.exists && latest.frame.intersects(self.conversation.frame) }
        let expectation = XCTNSPredicateExpectation(predicate: visible, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "the chat did not settle at the latest reply")
    }

    private func openLab() {
        app.launch()
        XCTAssertTrue(element("session-open-\(lab)").waitForExistence(timeout: 15), "the lab session did not open")
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), "the conversation was replaced by a terminal or fallback")
        assertLatestVisible()
        XCTAssertTrue(element("chat-history-before-count").waitForExistence(timeout: 5), "the DEBUG history probe is missing")
        XCTAssertEqual(historyRequests, 0, "opening at the bottom fetched history without a user scroll")
    }

    /// Typing and reading the unsent draft exercises the main thread, not just the presence of stale view objects.
    private func assertComposerResponds(_ draft: String) {
        let field = element("composer-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(draft)
        XCTAssertTrue((field.value as? String)?.contains(draft) == true, "the composer stopped responding after layout")
    }

    func testTallTailOpensAtTheBottomAndRemainsResponsive() {
        app.launchArguments += ["-uiTestChatLabTallTail", "1"]
        openLab()
        assertComposerResponds("synthetic-layout-check")
        XCTAssertTrue(conversation.exists, "the app left conversation mode")
        // Changing the available width must settle too (when the regular-width inspector is available).
        let inspector = element("session-inspector-toggle")
        if inspector.exists {
            inspector.tap()
            assertLatestVisible()
            inspector.tap()
            assertComposerResponds("-after-resize")
        }
        XCTAssertEqual(historyRequests, 0, "typing or resizing at the bottom fetched older history")
    }

    func testScrollingLoadsEarlierPagesAndReturnsToLatestReply() {
        openLab()
        let older = marker(233)
        // The lab has 240 turns, but the initial response contains only its last 24 items.
        XCTAssertFalse(older.exists, "an older page is already visible before any scroll")
        for _ in 0..<24 {
            if older.exists { break }
            conversation.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(older.waitForExistence(timeout: 5), "scrolling to the top never loaded the next history page")
        XCTAssertGreaterThan(historyRequests ?? -1, 0, "the older row did not come from a history request")
        let end = app.buttons["Ir para o fim"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5), "scrolling away from the bottom did not offer a return")
        end.tap()
        assertLatestVisible()
        assertComposerResponds("Synthetic reply after loading history")
        element("composer-send").tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "streamcheck-7f3a")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the chat could not render a streamed reply after pagination")
    }

    func testSwitchingSessionsKeepsTheLongConversationResponsive() throws {
        app.launchArguments += ["-uiTestChatLabTallTail", "1"]
        openLab()
        let labRow = element("sidebar-chat-\(lab)")
        let otherRow = element("sidebar-agent-devbox/\(other)")
        guard labRow.exists, otherRow.exists else {
            throw XCTSkip("session switching uses the regular-width Mac/iPad sidebar")
        }
        for _ in 0..<3 {
            otherRow.tap()
            XCTAssertTrue(element("session-open-\(other)").waitForExistence(timeout: 5), "the other session did not open")
            labRow.tap()
            XCTAssertTrue(element("session-open-\(lab)").waitForExistence(timeout: 5), "the long conversation did not reopen")
            assertLatestVisible()
        }
        assertComposerResponds("synthetic-after-session-switch")
        XCTAssertEqual(historyRequests, 0, "switching sessions fetched history without a user scroll")
    }

    /// The reported freeze also occurs in short records. Long history is a stress case, not a precondition.
    func testSmallUnpagedConversationRemainsResponsiveAcrossSessionSwitches() throws {
        latestTurn = 5
        for (flag, value) in [("-uiTestChatLabTurns", "5"), ("-uiTestChatLabPageSize", "0")] {
            let index = app.launchArguments.firstIndex(of: flag)!
            app.launchArguments[index + 1] = value
        }
        // Five invented turns (20 items), ordinary mixed Markdown, no oversized final reply or earlier pages.
        openLab()
        assertComposerResponds("synthetic-small-open")
        let labRow = element("sidebar-chat-\(lab)")
        let otherRow = element("sidebar-agent-devbox/\(other)")
        guard labRow.exists, otherRow.exists else {
            throw XCTSkip("session switching uses the regular-width Mac/iPad sidebar")
        }
        for round in 1...3 {
            otherRow.tap()
            XCTAssertTrue(element("session-open-\(other)").waitForExistence(timeout: 5))
            labRow.tap()
            XCTAssertTrue(element("session-open-\(lab)").waitForExistence(timeout: 5))
            assertLatestVisible()
            assertComposerResponds("-small-switch-\(round)")
        }
        XCTAssertEqual(historyRequests, 0, "an unpaged conversation requested older history")
    }
}
