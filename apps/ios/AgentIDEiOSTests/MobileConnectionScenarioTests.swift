import XCTest
import AgentIDEProtocol
@testable import AgentIDEiOS

@MainActor
final class MobileConnectionScenarioTests: XCTestCase {
    func testAgentReferenceFormatsRelativePathsAsLiteralText() {
        XCTAssertEqual(AgentFileReference.format(relativePath: "Sources/Context Guide [draft] 说明.md"), "@Sources/Context Guide [draft] 说明.md")
        XCTAssertNil(AgentFileReference.format(relativePath: ""))
        XCTAssertNil(AgentFileReference.format(relativePath: "/tmp/file.swift"))
        XCTAssertNil(AgentFileReference.format(relativePath: "../file.swift"))
        XCTAssertNil(AgentFileReference.format(relativePath: "Sources\\file.swift"))
    }

    func testDraftsAreSessionScopedAndReferencesAppendWithoutDeduplication() {
        let connection = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive))

        connection.updateDraft("Inspect this", for: "session-one")
        connection.appendToDraft("@Sources/App.swift", for: "session-one")
        connection.appendToDraft("@Sources/App.swift", for: "session-one")
        connection.updateDraft("Other session", for: "session-two")

        XCTAssertEqual(connection.draft(for: "session-one"), "Inspect this\n@Sources/App.swift\n@Sources/App.swift")
        XCTAssertEqual(connection.draft(for: "session-two"), "Other session")
    }

    func testSuccessfulResponseClearsOnlyTheSubmittedDraftVersion() async throws {
        let runtime = MobileScenarioRuntime(scenario: .comprehensive)
        let connection = MobileConnection(scenarioRuntime: runtime)
        await connection.waitForScenarioIdle()
        connection.requestSessions(projectId: "project-demo")
        await connection.waitForScenarioIdle()
        let session = try XCTUnwrap(connection.sessions["project-demo"]?.first)

        connection.updateDraft("@README.md\nExplain this", for: session.id)
        XCTAssertTrue(connection.sendDraft(session: session))
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.draft(for: session.id), "")
        XCTAssertEqual(runtime.sentMessages.last, .init(sessionId: session.id, content: "@README.md\nExplain this"))

        connection.updateDraft("First version", for: session.id)
        XCTAssertTrue(connection.sendDraft(session: session))
        connection.updateDraft("Edited while sending", for: session.id)
        connection.updateDraft("First version", for: session.id)
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.draft(for: session.id), "First version")
    }

    func testFailedSendKeepsDraft() async throws {
        let connection = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .requestFailure))
        await connection.waitForScenarioIdle()
        let session = try JSONDecoder().decode(Session.self, from: Data("""
        {"id":"session-failure","projectId":"project-demo","agentType":"codex","title":"Failure","status":"idle","createdAt":"2026-09-27T00:00:00Z","updatedAt":"2026-09-27T00:00:00Z"}
        """.utf8))

        connection.updateDraft("Keep this draft", for: session.id)
        XCTAssertTrue(connection.sendDraft(session: session))
        await connection.waitForScenarioIdle()

        XCTAssertEqual(connection.draft(for: session.id), "Keep this draft")
        XCTAssertEqual(connection.sessionError(for: session.id), "Scenario request failure")
    }

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
        XCTAssertEqual(connection.status(for: created), .running)
        XCTAssertEqual(connection.draft(for: created.id), "")
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

    func testTimeoutAndOfflineSendKeepDraft() async throws {
        let session = try testSession(id: "session-draft-errors")
        let timedOut = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .timeout),
            requestTimeout: .milliseconds(1)
        )
        await timedOut.waitForScenarioIdle()
        timedOut.updateDraft("Keep after timeout", for: session.id)
        XCTAssertTrue(timedOut.sendDraft(session: session))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(timedOut.draft(for: session.id), "Keep after timeout")
        XCTAssertEqual(timedOut.sessionError(for: session.id), "Request timed out")

        let offline = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .offline))
        await offline.waitForScenarioIdle()
        offline.updateDraft("Keep while offline", for: session.id)
        XCTAssertFalse(offline.sendDraft(session: session))
        XCTAssertEqual(offline.draft(for: session.id), "Keep while offline")
        XCTAssertEqual(offline.sessionError(for: session.id), "Mac is offline")
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

    private func testSession(id: String, projectId: String = "project-demo") throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data("""
        {"id":"\(id)","projectId":"\(projectId)","agentType":"codex","title":"Draft","status":"idle","createdAt":"2026-09-27T00:00:00Z","updatedAt":"2026-09-27T00:00:00Z"}
        """.utf8))
    }
}
