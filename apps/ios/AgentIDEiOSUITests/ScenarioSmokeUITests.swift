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

        let answer = app.textFields["Your answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.tap()
        answer.typeText("Review changes")
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

        let message = app.textFields["Message the agent"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.tap()
        message.typeText("Cancel this simulated turn")
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
    }
}
