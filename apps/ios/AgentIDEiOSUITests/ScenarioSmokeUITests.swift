import XCTest

@MainActor
final class ScenarioSmokeUITests: XCTestCase {
    func testComprehensiveScenarioOpensSessionAndRendersInteraction() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "interactions"]
        app.launch()

        let project = app.staticTexts["Scenario Workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()

        let session = app.staticTexts["Scenario approval"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        XCTAssertTrue(app.buttons["question-option-tests"].waitForExistence(timeout: 5))
        let approve = app.buttons["Approve Once"]
        XCTAssertTrue(makeHittable(approve, in: app, moving: .later))
        XCTAssertTrue(app.buttons["Reject"].waitForExistence(timeout: 5))
        approve.tap()
        XCTAssertTrue(app.staticTexts["Responded"].waitForExistence(timeout: 5))

        let answer = app.textFields["Your answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.tap()
        answer.typeText("Run tests")
        let submit = app.buttons["question-submit-question-demo"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        let submitEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: submit
        )
        XCTAssertEqual(XCTWaiter.wait(for: [submitEnabled], timeout: 5), .completed)
        submit.tap()
        let submitDisabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"),
            object: submit
        )
        XCTAssertEqual(XCTWaiter.wait(for: [submitDisabled], timeout: 5), .completed)
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)
    }

    func testComprehensiveScenarioCreatesSessionAndBrowsesFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "interactions"]
        app.launch()

        let project = app.staticTexts["Scenario Workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()

        app.buttons["Create session"].tap()
        let task = app.textViews["Initial task"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        task.typeText("Inspect the simulated workspace")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Scenario task"].waitForExistence(timeout: 5))

        let browseFiles = app.buttons["session-browse-files"]
        XCTAssertTrue(browseFiles.waitForExistence(timeout: 5))
        browseFiles.tap()
        let sessionReadme = app.staticTexts.matching(identifier: "README.md").firstMatch
        XCTAssertTrue(sessionReadme.waitForExistence(timeout: 5))
        sessionReadme.tap()
        let fileActions = app.buttons["file-actions"]
        XCTAssertTrue(fileActions.waitForExistence(timeout: 5))
        fileActions.tap()
        let sendReference = app.buttons["Send to Agent"]
        XCTAssertTrue(sendReference.waitForExistence(timeout: 5))
        sendReference.tap()

        let message = app.textFields["session-composer"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.value as? String, "@README.md")
        message.tap()
        message.typeText(" Summarize this file")
        app.buttons["Send message"].tap()
        let cancelTurn = app.buttons["Cancel current turn"]
        XCTAssertTrue(cancelTurn.waitForExistence(timeout: 5))
        cancelTurn.tap()
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Browse files"].tap()
        let readme = app.staticTexts.matching(identifier: "README.md").firstMatch
        XCTAssertTrue(readme.waitForExistence(timeout: 5))
        readme.tap()
        let scenarioText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Scenario workspace")
        ).firstMatch
        XCTAssertTrue(scenarioText.waitForExistence(timeout: 5))
        app.buttons["file-actions"].tap()
        XCTAssertFalse(app.buttons["Send to Agent"].exists)
    }

    func testComprehensiveScenarioOpensChangesDiffAndReturnsToSession() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "interactions"]
        app.launch()

        let project = app.staticTexts["Scenario Workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        let session = app.staticTexts["Scenario approval"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let changes = app.buttons["session-changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        changes.tap()
        let file = app.buttons["change-unstaged-Sources/App.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        XCTAssertTrue(app.staticTexts["diff-hunk"].waitForExistence(timeout: 5))
        let back = app.buttons["Return to previous workspace level"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["session-changes"].waitForExistence(timeout: 5))
    }

    func testComprehensiveScenarioFileChangedOpensMatchingDiff() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "interactions"]
        app.launch()

        let project = app.staticTexts["Scenario Workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        let session = app.staticTexts["Scenario approval"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let fileChanged = app.buttons["file-changed-Sources/App.swift"]
        XCTAssertTrue(makeHittable(fileChanged, in: app, moving: .earlier))
        fileChanged.tap()
        XCTAssertTrue(app.staticTexts["diff-hunk"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Sources/App.swift"].exists)
    }

    func testComprehensiveScenarioRendersReportsAndOpensDiagnosticFile() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "reports"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()

        let testReport = app.buttons["report-test_report"]
        XCTAssertTrue(testReport.waitForExistence(timeout: 5))
        assertMetric("report-test-total", contains: ["42", "Total"], in: app)
        assertMetric("report-test-passed", contains: ["40", "Passed"], in: app)
        assertMetric("report-test-failed", contains: ["1", "Failed"], in: app)
        assertMetric("report-test-skipped", contains: ["1", "Skipped"], in: app)
        guard makeHittable(testReport, in: app, moving: .earlier) else {
            XCTFail("Report frame: \(testReport.frame), navigation: \(app.navigationBars.firstMatch.frame), composer: \(app.textFields["session-composer"].frame), feed: \(app.scrollViews["session-feed"].frame)")
            return
        }
        testReport.tap()
        XCTAssertTrue(app.staticTexts["WorkspaceTests.testRestore"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Expected restored report state"].waitForExistence(timeout: 5))
        XCTAssertTrue(makeHittable(testReport, in: app, moving: .earlier))
        testReport.tap()

        let plan = app.buttons["report-plan"]
        XCTAssertTrue(makeHittable(plan, in: app, moving: .later))
        plan.tap()
        XCTAssertTrue(app.staticTexts["1. Define protocol"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 5))
        XCTAssertTrue(makeHittable(plan, in: app, moving: .earlier))
        plan.tap()

        let todo = app.buttons["report-todo"]
        XCTAssertTrue(makeHittable(todo, in: app, moving: .later))
        todo.tap()
        XCTAssertTrue(app.staticTexts["Task 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Blocked"].waitForExistence(timeout: 5))
        XCTAssertTrue(makeHittable(todo, in: app, moving: .earlier))
        todo.tap()

        let diagnostics = app.buttons["report-diagnostics"]
        XCTAssertTrue(makeHittable(diagnostics, in: app, moving: .later))
        diagnostics.tap()
        let diagnostic = app.buttons["diagnostic-file-Sources/App.swift"]
        XCTAssertTrue(makeHittable(diagnostic, in: app, moving: .later))
        XCTAssertTrue(app.staticTexts["Preview state is stale"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sources/App.swift:12:5"].waitForExistence(timeout: 5))
        diagnostic.tap()
        XCTAssertTrue(app.buttons["file-actions"].waitForExistence(timeout: 5))

        app.swipeLeft()
        XCTAssertTrue(app.buttons["session-changes"].waitForExistence(timeout: 5))
        XCTAssertTrue(makeHittable(diagnostics, in: app, moving: .earlier))
        diagnostics.tap()

        let future = app.buttons["report-coverage"]
        XCTAssertTrue(makeHittable(future, in: app, moving: .later))
        future.tap()
        let fallback = app.staticTexts["report-unknown-fallback"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        XCTAssertEqual(fallback.label, "This report type is not supported by this version of AgentIDE.")
    }

    func testReportHeaderRemainsAccessibleInLandscape() {
        let device = XCUIDevice.shared
        device.orientation = .landscapeLeft
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "report-layout"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()

        let report = app.buttons["report-test_report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(report.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        report.tap()
        XCTAssertTrue(app.staticTexts["WorkspaceTests.testRestore"].waitForExistence(timeout: 5))
    }

    func testComprehensiveScenarioSearchesFileAndSendsReferenceToSession() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()
        XCTAssertTrue(app.buttons["session-browse-files"].waitForExistence(timeout: 5))
        app.buttons["session-browse-files"].tap()

        let search = app.textFields["file-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Context")
        let result = app.staticTexts["Context Guide.md"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()

        XCTAssertTrue(app.buttons["file-actions"].waitForExistence(timeout: 5))
        app.buttons["file-actions"].tap()
        XCTAssertTrue(app.buttons["Send to Agent"].waitForExistence(timeout: 5))
        app.buttons["Send to Agent"].tap()
        let composer = app.textFields["session-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "@Sources/Context Guide.md")
    }

    func testComprehensiveScenarioSearchesAndLocatesDirectory() {
        let app = launchFileBrowser(scenario: "comprehensive")
        let search = app.textFields["file-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Sources")
        let result = app.staticTexts.matching(identifier: "Sources").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(app.staticTexts["App.swift"].waitForExistence(timeout: 5))
    }

    func testSearchDirectoryDisappearingShowsRecoverableError() {
        let app = launchFileBrowser(scenario: "search-missing-directory")
        let search = app.textFields["file-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Deleted")
        let result = app.staticTexts.matching(identifier: "Deleted").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "no longer available")
        ).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Dismiss"].exists)
    }

    private func launchFileBrowser(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", scenario]
        app.launch()
        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()
        XCTAssertTrue(app.buttons["session-browse-files"].waitForExistence(timeout: 5))
        app.buttons["session-browse-files"].tap()
        return app
    }

    private enum FeedDirection {
        case earlier
        case later
    }

    private func makeHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        moving direction: FeedDirection = .earlier,
        attempts: Int = 12
    ) -> Bool {
        _ = element.waitForExistence(timeout: 1)
        if isVisibleInFeed(element, app: app) { return true }
        let feed = app.scrollViews["session-feed"]
        guard feed.waitForExistence(timeout: 2) else { return false }
        for _ in 0..<attempts {
            drag(feed, moving: directionToReveal(element, in: app) ?? direction)
            if isVisibleInFeed(element, app: app) { return true }
        }
        return false
    }

    private func directionToReveal(_ element: XCUIElement, in app: XCUIApplication) -> FeedDirection? {
        guard element.exists else { return nil }
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.textFields["session-composer"].frame.minY
        if element.frame.maxY < top { return .earlier }
        if element.frame.minY > bottom { return .later }
        return nil
    }

    private func isVisibleInFeed(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.textFields["session-composer"].frame.minY
        return element.frame.midY >= top && element.frame.midY <= bottom
    }

    private func assertMetric(_ identifier: String, contains values: [String], in app: XCUIApplication) {
        let metric = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(metric.waitForExistence(timeout: 2), "Missing metric \(identifier)")
        for value in values {
            XCTAssertTrue(metric.label.contains(value), "Expected \(identifier) label '\(metric.label)' to contain '\(value)'")
        }
    }

    private func drag(_ feed: XCUIElement, moving direction: FeedDirection) {
        let startY = direction == .earlier ? 0.45 : 0.85
        let endY = direction == .earlier ? 0.85 : 0.45
        feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY)).press(
            forDuration: 0.05,
            thenDragTo: feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        )
    }
}
