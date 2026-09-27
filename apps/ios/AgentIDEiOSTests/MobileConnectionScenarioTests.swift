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
        XCTAssertEqual(connection.sessionEvents[session.id]?.count, 11)
        XCTAssertEqual(connection.sessionEvents[session.id]?.filter {
            if case .report = $0 { return true }
            return false
        }.count, 5)
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

    func testReportDeliveryDeduplicatesAndInsertsOlderSequencesInOrder() async throws {
        let connection = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive))
        await connection.waitForScenarioIdle()
        connection.requestSessions(projectId: "project-demo")
        await connection.waitForScenarioIdle()
        let session = try XCTUnwrap(connection.sessions["project-demo"]?.first)
        connection.openSession(session)
        await connection.waitForScenarioIdle()

        let newest = try reportEnvelope(sequence: 12, reportId: "report-12")
        let older = try reportEnvelope(sequence: 11, reportId: "report-11")
        connection.injectScenarioInbound([newest, newest, older])
        await connection.waitForScenarioIdle()

        XCTAssertEqual(connection.sessionEvents[session.id]?.map(\.sequence), Array(0...12))
        XCTAssertEqual(connection.sessionEvents[session.id]?.filter {
            if case .report = $0 { return true }
            return false
        }.count, 7)
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

    private func reportEnvelope(sequence: Int, reportId: String) throws -> Data {
        let report: [String: Any] = [
            "id": "event-\(sequence)",
            "sessionId": "session-demo",
            "sequence": sequence,
            "timestamp": "2026-09-27T00:00:\(String(format: "%02d", sequence)).000Z",
            "type": "report",
            "reportVersion": 1,
            "reportId": reportId,
            "kind": "plan",
            "title": "Plan \(sequence)",
            "summary": "Injected report",
            "payload": ["steps": [["title": "Verify ordering", "status": "completed"]]]
        ]
        let envelope: [String: Any] = [
            "version": 1,
            "id": "inbound-\(sequence)-\(reportId)",
            "type": "agent.event",
            "sourceDeviceId": "scenario-mac",
            "targetDeviceId": "scenario-ios",
            "projectId": "project-demo",
            "sessionId": "session-demo",
            "timestamp": "2026-09-27T00:00:00.000Z",
            "payload": report
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    func testFileSearchCoversResultsEmptyLimitFailureAndOffline() async throws {
        let comprehensive = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive))
        await comprehensive.waitForScenarioIdle()
        XCTAssertNotNil(comprehensive.searchFiles(projectId: "project-demo", query: "context"))
        await comprehensive.waitForScenarioIdle()
        XCTAssertEqual(comprehensive.fileSearch(projectId: "project-demo")?.results.map(\.relativePath), ["Sources/Context Guide.md"])
        XCTAssertFalse(try XCTUnwrap(comprehensive.fileSearch(projectId: "project-demo")).hasMore)

        let empty = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .searchEmpty))
        await empty.waitForScenarioIdle()
        empty.searchFiles(projectId: "project-demo", query: "missing")
        await empty.waitForScenarioIdle()
        XCTAssertTrue(try XCTUnwrap(empty.fileSearch(projectId: "project-demo")).results.isEmpty)

        let limited = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .searchLimited))
        await limited.waitForScenarioIdle()
        limited.searchFiles(projectId: "project-demo", query: "source", limit: 2)
        await limited.waitForScenarioIdle()
        XCTAssertTrue(try XCTUnwrap(limited.fileSearch(projectId: "project-demo")).hasMore)

        let failed = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .requestFailure))
        await failed.waitForScenarioIdle()
        failed.searchFiles(projectId: "project-demo", query: "readme")
        await failed.waitForScenarioIdle()
        XCTAssertEqual(failed.fileSearchError(projectId: "project-demo")?.code, "SCENARIO_FAILURE")

        let offline = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .offline))
        await offline.waitForScenarioIdle()
        XCTAssertNil(offline.searchFiles(projectId: "project-demo", query: "readme"))
        XCTAssertEqual(offline.fileSearchError(projectId: "project-demo")?.code, "MAC_OFFLINE")
    }

    func testFileSearchValidatesUnicodeScalarQueryBounds() async {
        let connection = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive))
        await connection.waitForScenarioIdle()
        XCTAssertNotNil(connection.searchFiles(projectId: "project-demo", query: "e\u{301}"))
        await connection.waitForScenarioIdle()
        connection.recordFileSearch(projectId: "project-demo", query: "e\u{301}")
        XCTAssertEqual(connection.fileSearchHistory(projectId: "project-demo").first, "e\u{301}")
        XCTAssertNil(connection.searchFiles(projectId: "project-demo", query: String(repeating: "😀", count: 257)))
        XCTAssertEqual(projectFileSearchQueryTrimmingWhiteSpace("\u{85}ab\u{3000}"), "ab")
        XCTAssertEqual(projectFileSearchQueryTrimmingWhiteSpace("\u{FEFF}ab\u{200B}"), "\u{FEFF}ab\u{200B}")
    }

    func testReplacingLeavingAndTimingOutSearchCancelAndIgnoreStaleResponses() async throws {
        let runtime = MobileScenarioRuntime(scenario: .comprehensive)
        runtime.holdsSearchResponses = true
        let connection = MobileConnection(scenarioRuntime: runtime)
        await connection.waitForScenarioIdle()

        let oldSearchId = try XCTUnwrap(connection.searchFiles(projectId: "project-demo", query: "old"))
        let oldRequestId = try XCTUnwrap(runtime.requestIdsByType["project.searchFiles"]?.last)
        let newSearchId = try XCTUnwrap(connection.searchFiles(projectId: "project-demo", query: "new"))
        let newRequestId = try XCTUnwrap(runtime.requestIdsByType["project.searchFiles"]?.last)
        XCTAssertNotEqual(oldRequestId, newRequestId)
        XCTAssertTrue(runtime.cancelledSearchIds.contains(oldSearchId))

        let newResponse = try XCTUnwrap(runtime.respondToHeldSearch(
            newRequestId,
            results: [runtime.searchEntry(name: "new.swift", path: "Sources/new.swift")]
        ))
        connection.injectScenarioInbound([newResponse])
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.fileSearch(projectId: "project-demo")?.searchId, newSearchId)

        let oldResponse = try XCTUnwrap(runtime.failHeldSearch(oldRequestId))
        connection.injectScenarioInbound([oldResponse])
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.fileSearch(projectId: "project-demo")?.results.first?.relativePath, "Sources/new.swift")
        XCTAssertNil(connection.fileSearchError(projectId: "project-demo"))
        XCTAssertNil(connection.error)

        let leavingSearchId = try XCTUnwrap(connection.searchFiles(projectId: "project-demo", query: "leave"))
        connection.cancelFileSearch(projectId: "project-demo")
        await connection.waitForScenarioIdle()
        XCTAssertTrue(runtime.cancelledSearchIds.contains(leavingSearchId))
        let cancelRequestId = try XCTUnwrap(runtime.requestIdsByType["project.cancelSearch"]?.last)
        let cancelFailure = try XCTUnwrap(runtime.failureResponse(
            for: cancelRequestId,
            type: "project.cancelSearch.response",
            code: "PROJECT_SEARCH_FAILED",
            message: "Late cancel failure"
        ))
        connection.injectScenarioInbound([cancelFailure])
        await connection.waitForScenarioIdle()
        XCTAssertNil(connection.error)

        let timeoutRuntime = MobileScenarioRuntime(scenario: .timeout)
        let timedOut = MobileConnection(scenarioRuntime: timeoutRuntime, requestTimeout: .milliseconds(1))
        await timedOut.waitForScenarioIdle()
        let timedOutSearchId = try XCTUnwrap(timedOut.searchFiles(projectId: "project-demo", query: "timeout"))
        try await Task.sleep(for: .milliseconds(20))
        await timedOut.waitForScenarioIdle()
        XCTAssertEqual(timedOut.fileSearchError(projectId: "project-demo")?.code, "TIMEOUT")
        XCTAssertTrue(timeoutRuntime.cancelledSearchIds.contains(timedOutSearchId))
    }

    func testFileSearchHistoryIsBoundedAndClearableWithoutScenarioPersistence() async {
        let connection = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive))
        await connection.waitForScenarioIdle()
        for index in 0..<12 {
            connection.recordFileSearch(projectId: "project-demo", query: "query-\(index)")
        }
        XCTAssertEqual(connection.fileSearchHistory(projectId: "project-demo").count, 10)
        connection.removeFileSearchHistory(projectId: "project-demo", query: "query-11")
        XCTAssertFalse(connection.fileSearchHistory(projectId: "project-demo").contains("query-11"))
        connection.clearFileSearchHistory(projectId: "project-demo")
        XCTAssertTrue(connection.fileSearchHistory(projectId: "project-demo").isEmpty)
    }

    func testFileSearchHistoryStorePersistsBoundsAndProjectIsolation() throws {
        let suiteName = "MobileConnectionScenarioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FileSearchHistoryStore(defaults: defaults)
        store.save((0..<12).map { "query-\($0)" }, projectId: "project-one")
        store.save(["other"], projectId: "project-two")

        let restored = FileSearchHistoryStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        XCTAssertEqual(restored.load(projectId: "project-one")?.count, 10)
        XCTAssertEqual(restored.load(projectId: "project-two"), ["other"])
        restored.save([], projectId: "project-one")
        XCTAssertEqual(store.load(projectId: "project-one"), [])
    }

    func testChangesStatesCoverSuccessCleanNonGitAndBinary() async throws {
        let comprehensive = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive))
        await comprehensive.waitForScenarioIdle()
        comprehensive.requestChanges(projectId: "project-demo")
        await comprehensive.waitForScenarioIdle()
        let changes = try XCTUnwrap(comprehensive.changes(projectId: "project-demo"))
        XCTAssertTrue(changes.isGitRepository)
        let binary = try XCTUnwrap(changes.changes.first(where: { $0.isBinary }))
        comprehensive.requestDiff(projectId: "project-demo", change: binary)
        await comprehensive.waitForScenarioIdle()
        XCTAssertNil(try XCTUnwrap(comprehensive.diff(projectId: "project-demo", change: binary)).diff)

        let clean = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .clean))
        await clean.waitForScenarioIdle()
        clean.requestChanges(projectId: "project-demo")
        await clean.waitForScenarioIdle()
        XCTAssertTrue(try XCTUnwrap(clean.changes(projectId: "project-demo")).changes.isEmpty)

        let nonGit = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .notGit))
        await nonGit.waitForScenarioIdle()
        nonGit.requestChanges(projectId: "project-demo")
        await nonGit.waitForScenarioIdle()
        XCTAssertFalse(try XCTUnwrap(nonGit.changes(projectId: "project-demo")).isGitRepository)
    }

    func testChangesRefreshClearsDiffsAndCanRequestThemAgain() async throws {
        let runtime = MobileScenarioRuntime(scenario: .comprehensive)
        let connection = MobileConnection(scenarioRuntime: runtime)
        await connection.waitForScenarioIdle()
        connection.requestChanges(projectId: "project-demo")
        await connection.waitForScenarioIdle()
        let change = try XCTUnwrap(connection.changes(projectId: "project-demo")?.changes.first)
        connection.requestDiff(projectId: "project-demo", change: change)
        await connection.waitForScenarioIdle()
        XCTAssertNotNil(connection.diff(projectId: "project-demo", change: change))

        connection.requestChanges(projectId: "project-demo")
        XCTAssertNil(connection.diff(projectId: "project-demo", change: change))
        await connection.waitForScenarioIdle()
        connection.requestDiff(projectId: "project-demo", change: change)
        await connection.waitForScenarioIdle()
        XCTAssertNotNil(connection.diff(projectId: "project-demo", change: change))
    }

    func testDiffUsesResponseMetadataAndBinaryFailureCanRetry() async throws {
        let runtime = MobileScenarioRuntime(scenario: .comprehensive)
        let connection = MobileConnection(scenarioRuntime: runtime)
        await connection.waitForScenarioIdle()
        connection.requestChanges(projectId: "project-demo")
        await connection.waitForScenarioIdle()
        let change = try XCTUnwrap(connection.changes(projectId: "project-demo")?.changes.first)
        runtime.holdsDiffResponses = true
        connection.requestDiff(projectId: "project-demo", change: change)
        let id = try XCTUnwrap(runtime.requestIdsByType["project.readDiff"]?.last)
        let response = try XCTUnwrap(runtime.response(for: id, type: "project.readDiff.response", payload: [
            "change": runtime.change(path: change.relativePath, binary: true),
        ]))
        connection.injectScenarioInbound([response])
        await connection.waitForScenarioIdle()
        XCTAssertTrue(try XCTUnwrap(connection.diff(projectId: "project-demo", change: change)).change.isBinary)

        let failedRuntime = MobileScenarioRuntime(scenario: .tooLarge)
        let failed = MobileConnection(scenarioRuntime: failedRuntime)
        await failed.waitForScenarioIdle()
        failed.requestChanges(projectId: "project-demo")
        await failed.waitForScenarioIdle()
        let binary = try XCTUnwrap(failed.changes(projectId: "project-demo")?.changes.first)
        failed.requestDiff(projectId: "project-demo", change: binary)
        await failed.waitForScenarioIdle()
        XCTAssertNotNil(failed.diffError(projectId: "project-demo", change: binary))
        failed.requestDiff(projectId: "project-demo", change: binary)
        await failed.waitForScenarioIdle()
        XCTAssertEqual(failedRuntime.requestIdsByType["project.readDiff"]?.count, 2)
    }

    func testChangesListIdentityKeepsStagedAndUnstagedCopiesDistinct() throws {
        let staged = try JSONDecoder().decode(GitChange.self, from: Data("""
        {"relativePath":"Sources/App.swift","kind":"modified","area":"staged","isBinary":false}
        """.utf8))
        let unstaged = try JSONDecoder().decode(GitChange.self, from: Data("""
        {"relativePath":"Sources/App.swift","kind":"modified","area":"unstaged","isBinary":false}
        """.utf8))
        XCTAssertNotEqual(ChangesListIdentifier.value(for: staged), ChangesListIdentifier.value(for: unstaged))
    }

    func testDiffFailuresRetainStructuredRetryableErrors() async throws {
        let runtime = MobileScenarioRuntime(scenario: .tooLarge)
        let connection = MobileConnection(scenarioRuntime: runtime)
        await connection.waitForScenarioIdle()
        connection.requestChanges(projectId: "project-demo")
        await connection.waitForScenarioIdle()
        let change = try XCTUnwrap(connection.changes(projectId: "project-demo")?.changes.first)
        connection.requestDiff(projectId: "project-demo", change: change)
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.diffError(projectId: "project-demo", change: change), .init(message: "Diff exceeds the transfer limit", code: "DIFF_TOO_LARGE"))

        let failed = MobileConnection(scenarioRuntime: MobileScenarioRuntime(scenario: .requestFailure))
        await failed.waitForScenarioIdle()
        failed.requestChanges(projectId: "project-demo")
        await failed.waitForScenarioIdle()
        XCTAssertEqual(failed.changesError(projectId: "project-demo"), .init(message: "Scenario request failure", code: "SCENARIO_FAILURE"))
    }

    func testChangesResponsesRejectStaleAndDiffResponsesRejectEachMismatchedField() async throws {
        let runtime = MobileScenarioRuntime(scenario: .comprehensive)
        let connection = MobileConnection(scenarioRuntime: runtime)
        await connection.waitForScenarioIdle()
        runtime.holdsChangesResponses = true
        connection.requestChanges(projectId: "project-demo")
        connection.requestChanges(projectId: "project-demo")
        let allIds = try XCTUnwrap(runtime.requestIdsByType["project.listChanges"])
        XCTAssertGreaterThanOrEqual(allIds.count, 2)
        let ids = Array(allIds.suffix(2))
        let old = ids[ids.startIndex]
        let newest = ids[ids.index(after: ids.startIndex)]
        connection.injectScenarioInbound([try XCTUnwrap(runtime.respondToHeldChanges(newest, changes: [runtime.change(path: "new.swift")]))])
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.changes(projectId: "project-demo")?.changes.first?.relativePath, "new.swift")
        XCTAssertEqual(connection.changesCompletion(projectId: "project-demo")?.generation, 2)
        XCTAssertFalse(connection.isLoadingChanges(projectId: "project-demo"))
        connection.injectScenarioInbound([try XCTUnwrap(runtime.respondToHeldChanges(old, changes: [runtime.change(path: "old.swift")]))])
        await connection.waitForScenarioIdle()
        XCTAssertEqual(connection.changes(projectId: "project-demo")?.changes.first?.relativePath, "new.swift")
        XCTAssertEqual(connection.changesCompletion(projectId: "project-demo")?.generation, 2)
        XCTAssertFalse(connection.isLoadingChanges(projectId: "project-demo"))

        let change = try XCTUnwrap(connection.changes(projectId: "project-demo")?.changes.first)
        runtime.holdsDiffResponses = true
        for mismatch in ["project", "path", "area"] {
            connection.requestDiff(projectId: "project-demo", change: change)
            let diffId = try XCTUnwrap(runtime.requestIdsByType["project.readDiff"]?.last)
            var payload: [String: Any] = ["change": runtime.change(path: change.relativePath, area: change.area.rawValue), "diff": "@@ -1 +1 @@\n-x\n+y\n"]
            if mismatch == "path" { payload["change"] = runtime.change(path: "other.swift", area: change.area.rawValue) }
            if mismatch == "area" { payload["change"] = runtime.change(path: change.relativePath, area: "staged") }
            let response = try XCTUnwrap(runtime.response(for: diffId, type: "project.readDiff.response", payload: payload))
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
            if mismatch == "project" { object["projectId"] = "other-project" }
            connection.injectScenarioInbound([try JSONSerialization.data(withJSONObject: object)])
            await connection.waitForScenarioIdle()
            XCTAssertNil(connection.diff(projectId: "project-demo", change: change))
            XCTAssertEqual(connection.diffError(projectId: "project-demo", change: change)?.message, "Invalid response")
        }
    }

    private func testSession(id: String, projectId: String = "project-demo") throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data("""
        {"id":"\(id)","projectId":"\(projectId)","agentType":"codex","title":"Draft","status":"idle","createdAt":"2026-09-27T00:00:00Z","updatedAt":"2026-09-27T00:00:00Z"}
        """.utf8))
    }
}
