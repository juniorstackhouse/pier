import XCTest

/// A worktree's terminal is a real one (LiveTerminal.swift, libghostty fed by the box's terminal stream): what is typed
/// goes straight to the shell, ⌃C (the keys bar's, or the hardware keyboard's) stops what runs, and the tab is named
/// after it. Against the mock box's shells (UITestMockTerminals.swift), whose stream echoes and runs lines as a shell
/// would. The terminal's text is its accessibility value (what VoiceOver reads), refreshed after each key.
final class LiveTerminalUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR",
                               "-openSession", "sandbox-subtract-claude-6s1", "-sessionNewTerminal", "1"] + extra
        app.launch()
        return app
    }

    private func screen(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "live-terminal").firstMatch
    }

    private func waitFor(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let term = screen(app)
        let found = NSPredicate { _, _ in (term.value as? String)?.contains(text) == true }
        let ok = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: found, object: nil)], timeout: timeout) == .completed
        XCTAssertTrue(ok, "the terminal never showed “\(text)”; it shows: \(term.value as? String ?? "nothing")", file: file, line: line)
    }

    /// A terminal just opened takes the keyboard by itself, and a tap on the terminal toggles it (Ghostty's way): it is
    /// tapped only while the keyboard is down.
    private func keyboardUp(_ app: XCUIApplication, _ term: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { tap(term) }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "the keyboard did not come up for the terminal",
                      file: file, line: line)
    }

    /// A tap where the terminal's text is, by position: the chat kept under the terminal (for going back to it at once)
    /// stays in the accessibility tree, so XCUITest takes the terminal's middle for covered and taps elsewhere (the keys
    /// bar's Esc).
    private func tap(_ term: XCUIElement) {
        term.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    }

    func testTypingRunsInTheShellAndControlCStopsIt() {
        let app = launch()
        let term = screen(app)
        XCTAssertTrue(term.waitForExistence(timeout: 25), "the terminal tab did not open")
        waitFor(app, "ubuntu@devbox:~/code/sandbox-subtract$")
        keyboardUp(app, term)
        app.typeText("ls\n")
        waitFor(app, "test_calc.py")
        app.typeText("npm run dev\n")
        waitFor(app, "VITE v5.4.2")
        // The tab says what runs; while a line is being typed it does not.
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'terminal-tab-'")).firstMatch
        let named = NSPredicate(format: "label == 'npm run dev'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: named, object: tab)], timeout: 8), .completed,
                       "the tab is not named after what runs: \(tab.label)")
        // A tap puts the keyboard away, and the keys bar under the terminal shows with ⌃C.
        tap(term)
        let interrupt = app.buttons["Control C, interromper"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 5), "the keys bar did not show with the keyboard down")
        interrupt.tap()
        waitFor(app, "^C")
        keyboardUp(app, term)
        app.typeText("pwd\n")
        waitFor(app, "/home/ubuntu/code/sandbox-subtract")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live-terminal"; shot.lifetime = .keepAlways
        add(shot)
    }

    /// The hardware keyboard's ⌃C reaches the shell: the text system takes Ctrl+letter for itself unless the terminal
    /// claims it (on the Mac, ⌃C never left the old command line).
    func testHardwareControlCReachesTheShell() {
        let app = launch()
        let term = screen(app)
        XCTAssertTrue(term.waitForExistence(timeout: 25), "the terminal tab did not open")
        waitFor(app, "ubuntu@devbox:~/code/sandbox-subtract$")
        keyboardUp(app, term)
        app.typeText("sleep 30\n")
        waitFor(app, "sleep 30")
        app.typeKey("c", modifierFlags: .control)
        waitFor(app, "^C")
        app.typeText("echo after\n")
        waitFor(app, "after\nubuntu@devbox")
    }

    /// A box before terminal streams (`-mockTTY 0`) keeps the screen read every second and the command line.
    func testABoxWithoutStreamsKeepsTheCommandLine() {
        let app = launch(["-mockTTY", "0"])
        let field = app.descendants(matching: .any).matching(identifier: "terminal-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 25), "the command line did not show")
        XCTAssertFalse(screen(app).exists, "a box without streams got a live terminal")
    }
}
