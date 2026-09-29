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

        let pendingQuestion = app.buttons["pending-question"]
        XCTAssertTrue(pendingQuestion.waitForExistence(timeout: 5))
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        XCTAssertGreaterThanOrEqual(pendingQuestion.frame.minY, navigationBottom - 1)
        XCTAssertLessThan(pendingQuestion.frame.minY - navigationBottom, 20)
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
        let sendReference = app.buttons["Add Reference to Draft"]
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
        XCTAssertFalse(((message.value as? String) ?? "").contains("Summarize"), "composer \(String(describing: message.value))")
        cancelTurn.tap()
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 5))
        XCTAssertFalse(((message.value as? String) ?? "").contains("Summarize"), "composer after cancel \(String(describing: message.value))")

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
        XCTAssertFalse(app.buttons["Add Reference to Draft"].exists)
    }

    func testSpatialChangesAndDiffStayReadable() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()

        app.buttons["session-changes"].tap()
        XCTAssertTrue(app.staticTexts["Staged"].waitForExistence(timeout: 5))
        let pathFont = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let statusFont = UIFont.preferredFont(forTextStyle: .caption1)
        assertLaidOutInFull("README.md", font: pathFont, in: app)
        assertLaidOutInFull("Sources/App.swift", font: pathFont, in: app)
        assertLaidOutInFull("assets/logo.png", font: pathFont, in: app)
        assertLaidOutInFull("Staged · Added", font: statusFont, in: app)
        assertLaidOutInFull("Unstaged · Modified", font: statusFont, in: app)
        assertLaidOutInFull("Unstaged · Modified · Binary", font: statusFont, in: app)

        app.buttons["change-unstaged-Sources/App.swift"].tap()
        let hunk = app.staticTexts["diff-hunk"]
        XCTAssertTrue(hunk.waitForExistence(timeout: 5))
        XCTAssertLessThan(hunk.frame.minY, 360)
        let gitLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "diff --git")).firstMatch
        XCTAssertTrue(gitLine.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(gitLine.frame.minX, window.minX - 1)
        XCTAssertLessThanOrEqual(gitLine.frame.maxX, window.maxX + 1, "git header frame \(gitLine.frame) outside \(window)")

        app.buttons["Back"].tap()
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["session-changes"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["session-list-changes"].tap()
        XCTAssertTrue(app.buttons["changes-refresh"].waitForExistence(timeout: 5))
        assertLaidOutInFull("Sources/App.swift", font: pathFont, in: app)
        XCTAssertTrue(app.staticTexts["24 B → 30 B"].exists)
        XCTAssertTrue(app.staticTexts["8 B → 12 B"].exists)
    }

    func testSourceStaysUnderThePathAndScrollsPastLineNumbers() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()
        let browseFiles = app.buttons["session-browse-files"]
        XCTAssertTrue(browseFiles.waitForExistence(timeout: 5))
        browseFiles.tap()
        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 5))
        app.staticTexts["Sources"].tap()
        let sourceFile = app.staticTexts["App.swift"]
        XCTAssertTrue(sourceFile.waitForExistence(timeout: 5))
        sourceFile.tap()

        // The whole file is one text element; a single source line is not its own accessibility element.
        let body = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "# Scenario workspace")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(body.label.contains("This file is served by the deterministic simulator scenario."))
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        XCTAssertGreaterThan(body.frame.minY, navigationBottom)
        XCTAssertLessThan(body.frame.minY, navigationBottom + 120)
        let lineNumbers = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "1\n")
        ).firstMatch
        XCTAssertTrue(lineNumbers.exists)
        let lineNumberX = lineNumbers.frame.minX
        let bodyX = body.frame.minX
        body.swipeLeft()
        XCTAssertEqual(lineNumbers.frame.minX, lineNumberX, accuracy: 1)
        XCTAssertLessThan(body.frame.minX, bodyX - 8)
    }

    func testSessionActivitySitsUnderTheNavigationBarInDarkMode() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "interactions"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()
        let pendingQuestion = app.buttons["pending-question"]
        XCTAssertTrue(pendingQuestion.waitForExistence(timeout: 5))
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        XCTAssertGreaterThanOrEqual(pendingQuestion.frame.minY, navigationBottom - 1)
        XCTAssertLessThan(pendingQuestion.frame.minY - navigationBottom, 20)
        XCTAssertTrue(app.staticTexts["Waiting for you"].exists)
        XCTAssertTrue(app.staticTexts["Answer the question or approval first."].exists)
    }

    func testProjectHomeAndPairingScanner() {
        let offline = XCUIApplication()
        offline.launchArguments = ["-mobileScenario", "offline"]
        offline.launch()
        XCTAssertTrue(offline.staticTexts["Mac Offline"].waitForExistence(timeout: 5))
        XCTAssertEqual(offline.staticTexts.matching(NSPredicate(format: "label == %@", "Mac Offline")).count, 1)
        XCTAssertEqual(offline.buttons.matching(NSPredicate(format: "label == %@", "Unpair this iPhone")).count, 1)
        XCTAssertTrue(offline.staticTexts["scenario-ios"].exists)

        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Mac Online")).count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Unpair this iPhone")).count, 1)
        XCTAssertTrue(app.staticTexts["This identifier is for this iPhone."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["scenario-ios"].exists)
        app.buttons["Unpair this iPhone"].tap()
        let unpairAlert = app.alerts["Unpair this iPhone?"]
        XCTAssertTrue(unpairAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(unpairAlert.buttons["Cancel"].isHittable)
        unpairAlert.buttons["Unpair"].tap()
        XCTAssertTrue(app.staticTexts["No Mac paired"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["AgentIDE"].exists)
        let navigationBottom = app.navigationBars["AgentIDE"].frame.maxY
        let titlesBelowNavigation = app.staticTexts.matching(NSPredicate(format: "label == %@", "AgentIDE")).allElementsBoundByIndex.filter { title in
            title.frame.minY >= navigationBottom - 1
        }
        XCTAssertEqual(titlesBelowNavigation.count, 0)
        app.buttons["Scan Pairing QR"].tap()
        XCTAssertTrue(app.staticTexts["No Camera Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Scan Pairing QR"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.descendants(matching: .any)["report-icon-failed"].exists)
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
        XCTAssertTrue(app.buttons["Add Reference to Draft"].waitForExistence(timeout: 5))
        app.buttons["Add Reference to Draft"].tap()
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

    func testMobileExperienceWalkMatchesPlan() {
        let failed = launch(scenario: "request-failure")
        XCTAssertTrue(failed.navigationBars["Projects"].waitForExistence(timeout: 5))
        XCTAssertTrue(failed.staticTexts["Scenario request failure"].waitForExistence(timeout: 5))
        XCTAssertTrue(failed.buttons["Retry"].exists)
        XCTAssertTrue(failed.buttons["Unpair this iPhone"].exists)
        XCTAssertTrue(failed.staticTexts["This identifier is for this iPhone."].exists)
        XCTAssertFalse(failed.staticTexts["No Projects"].exists)
        XCTAssertFalse(failed.staticTexts["Mac Online"].exists)

        let timedOut = launch(scenario: "timeout")
        XCTAssertTrue(timedOut.staticTexts["Request timed out. You can try again."].waitForExistence(timeout: 20))
        XCTAssertTrue(timedOut.buttons["Unpair this iPhone"].exists)
        XCTAssertTrue(timedOut.staticTexts["This identifier is for this iPhone."].exists)
        XCTAssertFalse(timedOut.staticTexts["No Projects"].exists)
        XCTAssertFalse(timedOut.staticTexts["Mac Online"].exists)

        let offline = launch(scenario: "offline")
        XCTAssertTrue(offline.staticTexts["Mac Offline"].waitForExistence(timeout: 5))
        XCTAssertEqual(offline.staticTexts.matching(NSPredicate(format: "label == %@", "Mac Offline")).count, 1)
        XCTAssertEqual(offline.buttons.matching(NSPredicate(format: "label == %@", "Unpair this iPhone")).count, 1)
        XCTAssertTrue(offline.staticTexts["Projects appear when your Mac is online."].exists)
        XCTAssertTrue(offline.staticTexts["scenario-ios"].exists)

        let app = launch(scenario: "comprehensive")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Mac Online")).count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Unpair this iPhone")).count, 1)
        XCTAssertTrue(app.staticTexts["This identifier is for this iPhone."].exists)
        XCTAssertTrue(app.staticTexts["scenario-ios"].exists)
        XCTAssertTrue(app.staticTexts["Codex · Claude"].waitForExistence(timeout: 5))
        let online = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Online")).firstMatch
        XCTAssertTrue(online.waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.navigationBars["Scenario Workspace"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Scenario Works..."].exists)

        app.buttons["Create session"].tap()
        XCTAssertTrue(app.staticTexts["For example, fix the failing test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Enter a task to create the session."].exists)
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        app.buttons["Cancel"].tap()

        app.staticTexts["Scenario approval"].tap()
        XCTAssertTrue(app.navigationBars["Scenario approval"].waitForExistence(timeout: 5))
        let pendingQuestion = app.buttons["pending-question"]
        XCTAssertTrue(pendingQuestion.waitForExistence(timeout: 5))
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        XCTAssertGreaterThanOrEqual(pendingQuestion.frame.minY, navigationBottom - 1)
        XCTAssertLessThan(pendingQuestion.frame.minY - navigationBottom, 20)
        XCTAssertTrue(app.staticTexts["Waiting for you"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Waiting User"].exists)
        XCTAssertTrue(app.buttons["pending-question"].exists)
        XCTAssertTrue(app.buttons["pending-approval"].exists)
        XCTAssertTrue(app.staticTexts["Answer the question or approval first."].exists)

        app.buttons["session-browse-files"].tap()
        let readme = app.staticTexts["README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "README.md")).count, 1)
        let search = app.textFields["file-search-field"]
        XCTAssertEqual(search.placeholderValue, "Search files")
        search.tap()
        search.typeText("Ap")
        XCTAssertTrue(app.staticTexts["App.swift"].waitForExistence(timeout: 5))
        let spinnerGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.activityIndicators.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [spinnerGone], timeout: 3), .completed)
        app.buttons["Clear search"].tap()
        app.staticTexts["Sources"].tap()
        app.staticTexts["说明.md"].tap()
        let markdown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Scenario workspace")).firstMatch
        XCTAssertTrue(markdown.waitForExistence(timeout: 5))
        XCTAssertTrue(markdown.label.contains("This file"))
        XCTAssertFalse(markdown.label.contains("workspaceThis"))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["说明.md"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["session-browse-files"].exists)
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["session-browse-files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Scenario approval"].exists)

        app.buttons["session-changes"].tap()
        XCTAssertTrue(app.staticTexts["Staged"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unstaged"].exists)
        let pathFont = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let statusFont = UIFont.preferredFont(forTextStyle: .caption1)
        assertLaidOutInFull("README.md", font: pathFont, in: app)
        assertLaidOutInFull("Sources/App.swift", font: pathFont, in: app)
        assertLaidOutInFull("assets/logo.png", font: pathFont, in: app)
        assertLaidOutInFull("Staged · Added", font: statusFont, in: app)
        assertLaidOutInFull("Unstaged · Modified", font: statusFont, in: app)
        assertLaidOutInFull("Unstaged · Modified · Binary", font: statusFont, in: app)
        let change = app.buttons["change-unstaged-Sources/App.swift"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.tap()
        let hunk = app.staticTexts["diff-hunk"]
        XCTAssertTrue(hunk.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(hunk.frame.minX, 0)
        XCTAssertLessThan(hunk.frame.minY, 360)
        let gitLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "diff --git")).firstMatch
        XCTAssertTrue(gitLine.exists)
        XCTAssertTrue(gitLine.label.contains("a/Sources/App.swift"))
        XCTAssertTrue(gitLine.label.contains("b/Sources/App.swift"))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(gitLine.frame.minX, window.minX - 1)
        XCTAssertLessThanOrEqual(gitLine.frame.maxX, window.maxX + 1)
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["change-unstaged-Sources/App.swift"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["session-changes"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Create session"].waitForExistence(timeout: 5))
        app.buttons["session-list-changes"].tap()
        XCTAssertTrue(app.buttons["changes-refresh"].waitForExistence(timeout: 5))
        assertLaidOutInFull("Sources/App.swift", font: pathFont, in: app)
        XCTAssertTrue(app.staticTexts["24 B → 30 B"].exists)
        XCTAssertTrue(app.staticTexts["8 B → 12 B"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Create session"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
        app.buttons["Unpair this iPhone"].firstMatch.tap()
        let unpairAlert = app.alerts["Unpair this iPhone?"]
        XCTAssertTrue(unpairAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(unpairAlert.buttons["Cancel"].isHittable)
        unpairAlert.buttons["Unpair"].tap()
        XCTAssertTrue(app.staticTexts["No Mac paired"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["AgentIDE"].exists)
        let pairingNavigationBottom = app.navigationBars["AgentIDE"].frame.maxY
        let titlesBelowNavigation = app.staticTexts.matching(NSPredicate(format: "label == %@", "AgentIDE")).allElementsBoundByIndex.filter { title in
            title.frame.minY >= pairingNavigationBottom - 1
        }
        XCTAssertEqual(titlesBelowNavigation.count, 0)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "choose Pairing")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Scan Pairing QR"].exists)
        app.buttons["Scan Pairing QR"].tap()
        XCTAssertTrue(app.staticTexts["No Camera Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Scan Pairing QR"].waitForExistence(timeout: 5))

        let notGit = openChanges(scenario: "not-git")
        XCTAssertTrue(notGit.staticTexts["Not a Git Repository"].waitForExistence(timeout: 5))
        XCTAssertFalse(notGit.staticTexts["No Changes"].exists)

        let clean = openChanges(scenario: "clean")
        XCTAssertTrue(clean.staticTexts["No Changes"].waitForExistence(timeout: 5))

        let tooLarge = openChanges(scenario: "too-large")
        tooLarge.buttons["change-unstaged-Sources/App.swift"].tap()
        let retry = tooLarge.buttons["Request this diff again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let unavailable = tooLarge.staticTexts["Diff Unavailable"]
        XCTAssertTrue(unavailable.exists)
        XCTAssertLessThan(abs(retry.frame.midY - unavailable.frame.midY), 280)
        let repeatedPath = tooLarge.staticTexts.matching(NSPredicate(format: "label == %@", "Sources/App.swift"))
        XCTAssertLessThanOrEqual(repeatedPath.count, 1)
    }

    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", scenario]
        app.launch()
        return app
    }

    func testAccessibilityExtraLargeKeepsRowsActionsAndReportReadable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mobileScenario", "comprehensive",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
        ]
        app.launch()

        let project = app.staticTexts["Scenario Workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(project.frame.width, project.frame.height, "project name frame \(project.frame)")
        XCTAssertFalse(
            app.images.allElementsBoundByIndex.contains { $0.frame.intersects(project.frame.insetBy(dx: 4, dy: 4)) },
            "project name intersects an icon \(project.frame)"
        )

        project.tap()
        let title = app.staticTexts["Scenario approval"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(title.frame.width, app.frame.width * 0.62, "session title frame \(title.frame)")
        let badge = app.staticTexts["Waiting for you"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertFalse(title.frame.intersects(badge.frame), "title \(title.frame) intersects badge \(badge.frame)")

        title.tap()
        let window = app.windows.firstMatch.frame
        for identifier in ["pending-question", "pending-approval"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(button.frame.minX, window.minX - 1, identifier)
            XCTAssertLessThanOrEqual(button.frame.maxX, window.maxX + 1, "\(identifier) \(button.frame)")
            XCTAssertGreaterThan(button.frame.width, 80, identifier)
        }
        let composer = app.textFields["session-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.label, "Message the agent")
        XCTAssertFalse(((composer.value as? String) ?? "").contains("Message the a"))
        XCTAssertTrue(app.staticTexts["Answer the question or approval first."].exists)

        let warnings = app.descendants(matching: .any)["report-diagnostics-warnings"]
        let errors = app.descendants(matching: .any)["report-diagnostics-errors"]
        XCTAssertTrue(makeHittable(warnings, in: app, moving: .later))
        XCTAssertTrue(makeHittable(errors, in: app, moving: .later))
        XCTAssertLessThan(warnings.frame.height, errors.frame.height + 8, "warnings \(warnings.frame) errors \(errors.frame) label \(warnings.label)")
        XCTAssertFalse(warnings.label.contains("\n"))

        let diagnostics = app.staticTexts["Diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        let feed = app.scrollViews["session-feed"]
        for _ in 0..<8 where !diagnostics.isHittable {
            drag(feed, moving: .earlier)
        }
        XCTAssertTrue(diagnostics.isHittable, "diagnostics frame \(diagnostics.frame)")
        diagnostics.tap()
        let path = app.staticTexts["Sources/App.swift:12:5"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(path.frame.width, path.frame.height, "diagnostic path \(path.frame)")
        let changedPath = app.staticTexts["Sources/App.swift"]
        XCTAssertTrue(makeHittable(changedPath, in: app, moving: .later))
        XCTAssertGreaterThan(changedPath.frame.width, changedPath.frame.height, "changed path \(changedPath.frame)")

        let changed = app.buttons["file-changed-Sources/App.swift"]
        XCTAssertTrue(scrollFullyAboveComposer(changed, in: app), "file card \(changed.frame) composer \(composer.frame)")
    }

    func testWaitingSessionLandsOnTheFirstUnansweredCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()

        let feed = app.scrollViews["session-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let question = app.staticTexts["Which follow-up should run?"]
        let started = app.staticTexts["Session started"]
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            question.exists && feed.frame.height > 100
                && question.frame.minY >= feed.frame.minY - 1
                && question.frame.minY < feed.frame.maxY
                && started.exists
                && started.frame.maxY < feed.frame.minY
        }, object: question)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 5), .completed, "question \(question.frame) feed \(feed.frame)")
        XCTAssertTrue(started.exists)
        XCTAssertLessThan(started.frame.maxY, feed.frame.minY, "session started \(started.frame) feed \(feed.frame)")
        XCTAssertTrue(app.buttons["pending-question"].exists)
        XCTAssertTrue(app.buttons["pending-approval"].exists)

        let inspection = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "separate paragraph")).firstMatch
        XCTAssertTrue(inspection.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "InspectionI")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "continuing.The")).firstMatch.exists)
    }

    func testNewEventsStayPutAfterLeavingTheEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        app.buttons["Create session"].tap()
        let task = app.textViews["Initial task"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        task.typeText("Inspect the simulated workspace")
        app.buttons["Create"].tap()

        let feed = app.scrollViews["session-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let anchor = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Created feed line 01")).firstMatch
        let tail = app.staticTexts["The scenario task completed without a live connection."]
        XCTAssertTrue(tail.waitForExistence(timeout: 5))
        var leftTheEnd = false
        for _ in 0..<12 {
            if anchor.exists, tail.exists, feed.frame.height > 100,
               anchor.frame.minY >= feed.frame.minY - 1,
               anchor.frame.maxY <= feed.frame.maxY + 1,
               tail.frame.minY > feed.frame.maxY {
                leftTheEnd = true
                break
            }
            drag(feed, moving: .earlier)
        }
        XCTAssertTrue(leftTheEnd, "anchor \(anchor.frame) tail \(tail.frame) feed \(feed.frame)")

        let composer = app.textFields["session-composer"]
        composer.tap()
        composer.typeText("Leave the tail")
        let anchorY = anchor.frame.minY
        app.buttons["Send message"].tap()
        let sent = app.staticTexts["Leave the tail"]
        let stayed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sent.exists && anchor.exists && feed.frame.height > 100
                && abs(anchor.frame.minY - anchorY) < 48
                && anchor.frame.maxY > feed.frame.minY
                && anchor.frame.minY < feed.frame.maxY
                && sent.frame.minY > feed.frame.maxY - 1
        }, object: sent)
        XCTAssertEqual(XCTWaiter.wait(for: [stayed], timeout: 5), .completed, "anchor \(anchor.frame) was \(anchorY) sent \(sent.frame) feed \(feed.frame)")
    }

    func testFailedProjectListKeepsUnpairAndCancelDoesNotUnpair() {
        let failed = launch(scenario: "request-failure")
        XCTAssertTrue(failed.buttons["Unpair this iPhone"].waitForExistence(timeout: 5))
        failed.buttons["Unpair this iPhone"].tap()
        let alert = failed.alerts["Unpair this iPhone?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(failed.staticTexts["Scenario request failure"].waitForExistence(timeout: 2))
        XCTAssertTrue(failed.buttons["Retry"].exists)
        XCTAssertTrue(failed.buttons["Unpair this iPhone"].exists)
        XCTAssertFalse(failed.staticTexts["No Mac paired"].exists)
    }

    func testDisabledCreateSessionExplainsWhy() {
        let noAgents = launch(scenario: "no-agents")
        XCTAssertTrue(noAgents.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        noAgents.staticTexts["Scenario Workspace"].tap()
        let create = noAgents.buttons["Create session"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled)
        XCTAssertTrue(noAgents.staticTexts["This project has no agent enabled."].exists)
        XCTAssertTrue(noAgents.buttons["Browse files"].exists)
        XCTAssertTrue(noAgents.buttons["Changes"].exists)
        XCTAssertFalse(noAgents.staticTexts["New"].exists)
        XCTAssertFalse(noAgents.staticTexts["Files"].exists)

        let offline = launch(scenario: "offline-session")
        XCTAssertTrue(offline.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        XCTAssertTrue(offline.staticTexts["Mac Offline"].exists)
        offline.staticTexts["Scenario Workspace"].tap()
        let offlineCreate = offline.buttons["Create session"]
        XCTAssertTrue(offlineCreate.waitForExistence(timeout: 5))
        XCTAssertFalse(offlineCreate.isEnabled)
        XCTAssertTrue(offline.staticTexts["You can create a session when your Mac is online."].exists)
        XCTAssertTrue(offline.buttons["Browse files"].exists)
        XCTAssertFalse(offline.staticTexts["New"].exists)
    }

    func testNewEventsFollowWhileStillAtTheEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        app.buttons["Create session"].tap()
        let task = app.textViews["Initial task"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        task.typeText("Inspect the simulated workspace")
        app.buttons["Create"].tap()

        let feed = app.scrollViews["session-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let tail = app.staticTexts["The scenario task completed without a live connection."]
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tail.exists && feed.frame.height > 100
                && tail.frame.minY >= feed.frame.minY - 1
                && tail.frame.maxY <= feed.frame.maxY + 1
        }, object: tail)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 5), .completed, "tail \(tail.frame) feed \(feed.frame)")

        let composer = app.textFields["session-composer"]
        composer.tap()
        composer.typeText("Stay at the tail")
        app.buttons["Send message"].tap()
        let sent = app.staticTexts["Stay at the tail"]
        let followed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sent.exists && feed.frame.height > 100
                && sent.frame.minY >= feed.frame.minY - 1
                && sent.frame.minY < feed.frame.maxY
        }, object: sent)
        XCTAssertEqual(XCTWaiter.wait(for: [followed], timeout: 5), .completed, "sent \(sent.frame) feed \(feed.frame)")
    }

    func testToolBlocksSummarizeAndCommandsUseTheirOwnBlock() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "interactions"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Scenario approval"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario approval"].tap()

        let tool = app.staticTexts["Read README"]
        XCTAssertTrue(makeHittable(tool, in: app, moving: .later))
        XCTAssertTrue(app.staticTexts["Running"].exists)
        let fullJSON = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UNIQUE-TAIL")).firstMatch
        XCTAssertFalse(fullJSON.isHittable)
        let disclosure = app.buttons["tool-json-read_file"]
        XCTAssertTrue(makeHittable(disclosure, in: app, moving: .later))
        disclosure.tap()
        XCTAssertTrue(fullJSON.waitForExistence(timeout: 5))
        XCTAssertTrue(makeHittable(fullJSON, in: app, moving: .later))

        let command = app.staticTexts["swift test"]
        XCTAssertTrue(makeHittable(command, in: app, moving: .later))
        XCTAssertTrue(app.staticTexts["Completed · exit 0"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["command-block"].exists)
    }

    private func scrollFullyAboveComposer(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let composer = app.textFields["session-composer"]
        let feed = app.scrollViews["session-feed"]
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        guard feed.waitForExistence(timeout: 2), composer.waitForExistence(timeout: 2) else { return false }
        for _ in 0..<16 {
            if element.exists,
               element.frame.minY >= navigationBottom - 1,
               element.frame.maxY <= composer.frame.minY + 1 {
                return true
            }
            let direction: FeedDirection = element.exists && element.frame.maxY > composer.frame.minY ? .later : .earlier
            drag(feed, moving: direction)
        }
        return false
    }

    private func openChanges(scenario: String) -> XCUIApplication {
        let app = launch(scenario: scenario)
        XCTAssertTrue(app.staticTexts["Scenario Workspace"].waitForExistence(timeout: 5))
        app.staticTexts["Scenario Workspace"].tap()
        let changes = app.buttons["session-list-changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        changes.tap()
        return app
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

    private func assertLaidOutInFull(_ label: String, font: UIFont, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts[label].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), label, file: file, line: line)
        let query = app.staticTexts.matching(NSPredicate(format: "label == %@", label))
        let expected = (label as NSString).size(withAttributes: [.font: font]).width
        let window = app.windows.firstMatch.frame
        var frames: [String] = []
        var visible = false
        for index in 0..<query.count {
            let candidate = query.element(boundBy: index)
            frames.append("\(candidate.frame)")
            let startsOnScreen = candidate.frame.minX >= window.minX - 1 && candidate.frame.minX < window.maxX
            let glyphsFit = candidate.frame.width + 1 >= expected && candidate.frame.minX + expected <= window.maxX + 2
            if startsOnScreen && glyphsFit { visible = true }
        }
        XCTAssertTrue(visible, "\(label) expected width \(expected) window \(window) frames \(frames.joined(separator: " "))", file: file, line: line)
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
