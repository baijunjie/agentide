import XCTest
import AgentIDEProtocol
@testable import AgentIDEiOS

@MainActor
final class MobileConnectionScenarioTests: XCTestCase {
    func testComprehensiveScenarioExercisesConnectionStateWithoutNetwork() async throws {
        let connection = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive)
        )
        await connection.waitForScenarioIdle()

        XCTAssertTrue(connection.paired)
        XCTAssertTrue(connection.online)
        XCTAssertEqual(connection.projects.map(\.id), ["project-demo"])

        connection.requestSessions(projectId: "project-demo")
        await connection.waitForScenarioIdle()
        let session = try XCTUnwrap(connection.sessions["project-demo"]?.first)
        XCTAssertEqual(session.id, "session-demo")

        connection.openSession(session)
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.sessionEvents[session.id]?.count, 5)
        XCTAssertEqual(connection.status(for: session), .waitingUser)

        connection.respondToApproval(
            session: session,
            interactionId: "approval-demo",
            action: .approveOnce
        )
        await connection.waitForScenarioIdle()
        XCTAssertTrue(connection.isResolved(sessionId: session.id, interactionId: "approval-demo"))
        XCTAssertEqual(connection.status(for: session), .waitingUser)

        connection.respondToQuestion(
            session: session,
            interactionId: "question-demo",
            optionIds: ["tests"],
            freeText: nil
        )
        await connection.waitForScenarioIdle()
        XCTAssertTrue(connection.isResolved(sessionId: session.id, interactionId: "question-demo"))
        XCTAssertEqual(connection.status(for: session), .completed)

        connection.requestFiles(projectId: "project-demo", relativePath: "")
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.entries(projectId: "project-demo", path: "")?.count, 3)

        connection.requestFile(projectId: "project-demo", relativePath: "README.md", binary: false)
        await connection.waitForScenarioIdle()
        XCTAssertTrue(connection.fileContent(projectId: "project-demo", path: "README.md")?.content.contains("Scenario workspace") == true)

        connection.requestImages(projectId: "project-demo", relativePath: "assets/logo.png")
        connection.requestFile(projectId: "project-demo", relativePath: "assets/logo.png", binary: true)
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.imageList(projectId: "project-demo", path: "assets/logo.png")?.current.relativePath, "assets/logo.png")
        XCTAssertNotNil(connection.image(projectId: "project-demo", path: "assets/logo.png"))
    }

    func testScenarioCanCreateAndCompleteSessionWithoutServices() async throws {
        let connection = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive)
        )
        await connection.waitForScenarioIdle()

        connection.createSession(projectId: "project-demo", agentType: .codex, initialTask: "Inspect the project")
        await connection.waitForScenarioIdle()

        let created = try XCTUnwrap(connection.createdSession)
        XCTAssertEqual(created.projectId, "project-demo")
        XCTAssertEqual(connection.status(for: created), .idle)
        XCTAssertTrue(connection.sessionEvents[created.id]?.contains { event in
            if case let .message(message) = event { return message.role == .agent }
            return false
        } == true)

        XCTAssertTrue(connection.sendMessage(session: created, content: "Continue in simulation"))
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.acceptedMessage?.content, "Continue in simulation")
        XCTAssertEqual(connection.status(for: created), .running)
        XCTAssertTrue(connection.sessionEvents[created.id]?.contains { event in
            if case let .message(message) = event { return message.role == .user && message.content == "Continue in simulation" }
            return false
        } == true)

        connection.cancel(session: created)
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.status(for: created), .idle)
        XCTAssertTrue(connection.sessionEvents[created.id]?.contains { event in
            if case let .turnCompleted(turn) = event { return turn.outcome == .cancelled }
            return false
        } == true)
    }

    func testFailureAndOfflineScenariosExposeDeterministicStates() async {
        let failed = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .requestFailure)
        )
        await failed.waitForScenarioIdle()
        XCTAssertTrue(failed.online)
        XCTAssertEqual(failed.error, "Scenario request failure")

        let offline = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .offline)
        )
        await offline.waitForScenarioIdle()
        XCTAssertTrue(offline.paired)
        XCTAssertFalse(offline.online)
        XCTAssertTrue(offline.projects.isEmpty)
    }

    func testTimeoutAndInvalidSourceUseNormalRequestValidation() async throws {
        let timedOut = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .timeout),
            requestTimeout: .milliseconds(1)
        )
        await timedOut.waitForScenarioIdle()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(timedOut.error, "Request timed out")

        let invalid = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .invalidResponse)
        )
        await invalid.waitForScenarioIdle()
        XCTAssertEqual(invalid.error, "Invalid response")
    }

    func testUnknownReplyDoesNotMutateProjects() async throws {
        let connection = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive)
        )
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.projects.map(\.id), ["project-demo"])

        let unsolicited: [String: Any] = [
            "version": 1,
            "id": "unsolicited-response",
            "type": "project.list.response",
            "sourceDeviceId": "scenario-mac",
            "targetDeviceId": "scenario-ios",
            "timestamp": "2026-09-27T00:00:00.000Z",
            "replyTo": "unknown-request",
            "ok": true,
            "payload": ["projects": []]
        ]
        connection.injectScenarioInbound([try JSONSerialization.data(withJSONObject: unsolicited)])
        await connection.waitForScenarioIdle()

        XCTAssertEqual(connection.projects.map(\.id), ["project-demo"])
    }
}
