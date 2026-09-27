import XCTest

final class ScenarioSmokeUITests: XCTestCase {
    func testComprehensiveScenarioOpensSessionAndRendersInteraction() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()

        let project = app.staticTexts["Scenario Workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()

        let session = app.staticTexts["Scenario approval"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        XCTAssertTrue(app.staticTexts["Run tests"].waitForExistence(timeout: 5))
        let approve = app.buttons["Approve Once"]
        XCTAssertTrue(approve.exists)
        XCTAssertTrue(app.buttons["Reject"].exists)
        approve.tap()
        XCTAssertTrue(app.staticTexts["Responded"].waitForExistence(timeout: 5))

        let option = app.buttons["question-option-tests"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        let submit = app.buttons["question-submit-question-demo"]
        let submitEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: submit
        )
        XCTAssertEqual(XCTWaiter.wait(for: [submitEnabled], timeout: 5), .completed)
        submit.tap()
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 5))
    }

    func testComprehensiveScenarioCreatesSessionAndBrowsesFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
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
        app.launchArguments = ["-mobileScenario", "comprehensive"]
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
        XCTAssertTrue(app.staticTexts["Run tests"].waitForExistence(timeout: 5))
    }

    func testComprehensiveScenarioFileChangedOpensMatchingDiff() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileScenario", "comprehensive"]
        app.launch()

        let project = app.staticTexts["Scenario Workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        let session = app.staticTexts["Scenario approval"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let fileChanged = app.buttons["file-changed-Sources/App.swift"]
        XCTAssertTrue(fileChanged.waitForExistence(timeout: 5))
        fileChanged.tap()
        XCTAssertTrue(app.staticTexts["diff-hunk"].waitForExistence(timeout: 5))
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
}
