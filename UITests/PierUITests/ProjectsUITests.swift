import XCTest

/// Projects coming and going, against the mock box (compact width, an iPhone simulator): the GitHub account's
/// repositories downloaded with a tap, a repository cloned by its link, a project removed from the disk (with its
/// unsaved work in the way first), and a worktree's details (its preview link and services). Skipped on regular width.
final class ProjectsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-startTab", "projects", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }

    private func launch() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Projetos"].waitForExistence(timeout: 15), "Projetos did not open")
        if element("sidebar-home").exists { throw XCTSkip("regular width: covered on the iPhone") }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(_ s: String) -> XCUIElement { app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    func testDownloadFromGitHubAndCloneByLink() throws {
        try launch()
        element("projects-add").tap()
        app.buttons["Repositórios do GitHub"].tap()
        let notes = element("github-repo-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "the account's repositories did not load")
        XCTAssertTrue(text("Na box").exists, "repositories already on the box are not marked")
        shot("github-repos")
        notes.tap()
        // The mock clones in about 3 s; then notes is on the box.
        let onBox = notes.staticTexts["Na box"]
        XCTAssertTrue(onBox.waitForExistence(timeout: 15), "the downloaded repository did not reach the box")
        shot("github-downloaded")

        element("clone-by-link").tap()
        let field = element("clone-link-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://github.com/octocat/hello-world")
        element("clone-start").tap()
        XCTAssertTrue(text("Pronto").waitForExistence(timeout: 15), "the clone by link did not finish")
        shot("clone-by-link-ready")
        element("clone-open").tap()
        XCTAssertTrue(app.navigationBars["hello-world"].waitForExistence(timeout: 10), "Abrir projeto did not open the clone")
    }

    func testRemoveProjectNeedsDiscardForUnsavedWork() throws {
        try launch()
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let remove = element("project-remove")
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "no Remover projeto do disco")
        remove.tap()
        XCTAssertTrue(text("Ocupa").waitForExistence(timeout: 10), "the project's size was not measured")
        XCTAssertTrue(text("commit(s) que nenhum remoto tem").exists, "unpushed commits are not listed")
        let run = element("purge-run")
        if !run.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(run.waitForExistence(timeout: 5), "no Remover do disco button")
        XCTAssertFalse(run.isEnabled, "removal is allowed with unsaved work and no Descartar")
        shot("remove-project-unsaved")
        element("purge-force").switches.firstMatch.tap()
        XCTAssertTrue(run.isEnabled)
        run.tap()
        XCTAssertTrue(app.navigationBars["Projetos"].waitForExistence(timeout: 10), "did not go back to Projetos")
        XCTAssertTrue(text("removido da box").waitForExistence(timeout: 5), "no confirmation")
        XCTAssertFalse(app.staticTexts["sandbox"].exists, "the removed project is still listed")
    }

    func testWorktreeDetailsShowPreviewAndServices() throws {
        try launch()
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let worktree = app.staticTexts["subtract"].firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 10))
        worktree.tap()
        let details = element("worktree-details")
        XCTAssertTrue(details.waitForExistence(timeout: 10), "no Detalhes on the worktree")
        details.tap()
        XCTAssertTrue(element("service-dev").waitForExistence(timeout: 10), "the worktree's services did not load")
        XCTAssertTrue(text("HOST=0.0.0.0 npm run dev").exists, "the service's command is not shown")
        XCTAssertTrue(text("rodando").exists)
        XCTAssertTrue(text("Portas").exists, "no ports in Ambiente")
        shot("worktree-details")
        app.buttons["Parar dev"].tap()
        XCTAssertTrue(text("parado").waitForExistence(timeout: 10), "stopping the service did not show")
    }
}
