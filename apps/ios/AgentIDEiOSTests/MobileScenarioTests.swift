import XCTest
import AgentIDEProtocol
@testable import AgentIDEiOS

final class MobileScenarioTests: XCTestCase {
    func testLongDeviceIdentifierShortensWithoutChangingAShortOne() {
        XCTAssertEqual(DeviceIdentifierDisplay.visible("scenario-ios"), "scenario-ios")
        XCTAssertEqual(DeviceIdentifierDisplay.visible(String(repeating: "a", count: 18)), String(repeating: "a", count: 18))
        XCTAssertEqual(DeviceIdentifierDisplay.visible(String(repeating: "b", count: 19)), "bbbbbbbb…bbbb")
    }

    func testToolSummaryClipsToOneShortLine() {
        XCTAssertEqual(ToolSummary.line(nil), "")
        XCTAssertEqual(ToolSummary.line(""), "")
        XCTAssertEqual(ToolSummary.line(String(repeating: "a", count: 80)).count, 80)
        let clipped = ToolSummary.line(String(repeating: "a", count: 81))
        XCTAssertEqual(clipped.count, 80)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testFlickCoastingPastTheEndStopsFollowing() {
        var follow = TailFollow()
        follow.noteUserMoved()
        XCTAssertNil(follow.sample(atBottom: true, tracking: true, dragging: true, decelerating: false, contentReady: true))
        XCTAssertNil(follow.sample(atBottom: true, tracking: false, dragging: false, decelerating: true, contentReady: true))
        XCTAssertEqual(follow.sample(atBottom: false, tracking: false, dragging: false, decelerating: true, contentReady: true), false)
        XCTAssertNil(follow.sample(atBottom: false, tracking: false, dragging: false, decelerating: false, contentReady: true))
    }

    func testProgrammaticDecelerationDoesNotStopFollowing() {
        var follow = TailFollow()
        XCTAssertNil(follow.sample(atBottom: false, tracking: false, dragging: false, decelerating: true, contentReady: true))
        XCTAssertEqual(follow.sample(atBottom: true, tracking: false, dragging: false, decelerating: false, contentReady: true), true)
    }

    func testUnreadyFeedDoesNotTurnFollowingOn() {
        var follow = TailFollow()
        XCTAssertNil(follow.sample(atBottom: true, tracking: false, dragging: false, decelerating: false, contentReady: false))
    }

    func testSettlingBackAtTheEndResumesFollowing() {
        var follow = TailFollow()
        follow.noteUserMoved()
        XCTAssertEqual(follow.sample(atBottom: false, tracking: true, dragging: true, decelerating: false, contentReady: true), false)
        XCTAssertEqual(follow.sample(atBottom: true, tracking: false, dragging: false, decelerating: false, contentReady: true), true)
    }

    func testSessionMarkdownKeepsHeadingAndParagraphsApart() {
        let rendered = String(MarkdownRendering.attributed("""
        ## Inspection

        I inspected the workspace and need approval before continuing.

        The next step is a separate paragraph.
        """).characters)
        XCTAssertTrue(rendered.contains("Inspection"))
        XCTAssertTrue(rendered.contains("separate paragraph"))
        XCTAssertFalse(rendered.contains("InspectionI"))
        XCTAssertFalse(rendered.contains("continuing.The"))
    }

    func testReportDetailTruncationIsBoundedAtFiftyItems() {
        XCTAssertNil(ReportPresentation.truncationText(total: 50))
        XCTAssertEqual(
            ReportPresentation.truncationText(total: 55),
            "Showing the first 50 of 55 items"
        )
    }

    func testLaunchArgumentSelectsScenario() {
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "-mobileScenario", "offline"]), .offline)
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "--mobile-scenario=request-failure"]), .requestFailure)
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "--mobile-scenario=timeout"]), .timeout)
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "--mobile-scenario=invalid-response"]), .invalidResponse)
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "--mobile-scenario=report-layout"]), .reportLayout)
        XCTAssertNil(MobileScenario.fromLaunchArguments(["app"]))
    }

    func testComprehensiveScenarioDecodesProjectsSessionsSnapshotAndFiles() throws {
        let runtime = MobileScenarioRuntime(scenario: .comprehensive)
        XCTAssertEqual(runtime.presence, .init(paired: true, online: true, macDeviceId: "scenario-mac"))
        XCTAssertEqual(object(runtime.start()[0])["type"] as? String, "system.presence")

        let projectsData = try responseData(runtime, type: "project.list", id: "request-projects")
        _ = try JSONDecoder().decode(ResponseEnvelope<JSONValue>.self, from: projectsData)
        let projects = object(projectsData)
        XCTAssertEqual(projects["replyTo"] as? String, "request-projects")
        XCTAssertEqual(try decodePayload(projects, as: ProjectList.self).projects.count, 1)

        let sessions = try response(runtime, type: "session.list", id: "request-sessions", projectId: "project-demo")
        XCTAssertEqual(try decodePayload(sessions, as: SessionList.self).sessions.first?.id, "session-demo")

        let snapshot = try response(runtime, type: "session.getSnapshot", id: "request-snapshot", projectId: "project-demo", sessionId: "session-demo")
        let decodedSnapshot = try decodePayload(snapshot, as: SessionSnapshot.self)
        XCTAssertEqual(decodedSnapshot.recentEvents.count, 11)
        XCTAssertEqual(decodedSnapshot.recentEvents.filter {
            if case .report = $0 { return true }
            return false
        }.count, 5)
        XCTAssertEqual(decodedSnapshot.pendingInteractions.count, 2)

        let files = try response(runtime, type: "project.listFiles", id: "request-files", projectId: "project-demo", payload: ["relativePath": ""])
        XCTAssertEqual(try decodePayload(files, as: FileList.self).entries.count, 3)
        let file = try response(runtime, type: "project.readFile", id: "request-file", projectId: "project-demo", payload: ["relativePath": "README.md", "encoding": "utf8"])
        XCTAssertEqual(try decodePayload(file, as: FileContent.self).relativePath, "README.md")
    }

    func testInteractionResponseQueuesDecodableFollowupEvents() throws {
        let runtime = MobileScenarioRuntime(scenario: .comprehensive)
        let reply = try response(runtime, type: "interaction.respond", id: "request-interaction", projectId: "project-demo", sessionId: "session-demo", payload: ["kind": "approval", "interactionId": "approval-demo", "action": "approve_once"])
        XCTAssertEqual(reply["replyTo"] as? String, "request-interaction")
        let waitingEvents = runtime.drain()
        XCTAssertEqual(waitingEvents.count, 1)
        _ = try waitingEvents.map { try decodePayload(object($0), as: AgentEvent.self) }

        _ = try response(runtime, type: "interaction.respond", id: "request-question", projectId: "project-demo", sessionId: "session-demo", payload: ["kind": "question", "interactionId": "question-demo", "optionIds": ["tests"]])
        let inbound = runtime.drain()
        XCTAssertEqual(inbound.count, 4)
        let events = try inbound.map { data -> AgentEvent in
            _ = try JSONDecoder().decode(Envelope<JSONValue>.self, from: data)
            return try decodePayload(object(data), as: AgentEvent.self)
        }
        XCTAssertEqual(events.last?.sequence, 15)
        XCTAssertTrue(runtime.drain().isEmpty)
    }

    func testFocusedScenariosKeepContiguousEventSequences() throws {
        for scenario in [MobileScenario.interactions, .reports] {
            let runtime = MobileScenarioRuntime(scenario: scenario)
            let snapshot = try response(
                runtime,
                type: "session.getSnapshot",
                id: "request-\(scenario.rawValue)",
                projectId: "project-demo",
                sessionId: "session-demo"
            )
            let events = try decodePayload(snapshot, as: SessionSnapshot.self).recentEvents
            XCTAssertEqual(events.map(\.sequence), Array(events.indices))
        }
    }

    func testOfflineAndFailureScenariosReturnCorrelatedErrors() throws {
        for scenario in [MobileScenario.offline, .requestFailure] {
            let runtime = MobileScenarioRuntime(scenario: scenario)
            let response = try response(runtime, type: "project.list", id: "request-error")
            XCTAssertEqual(response["replyTo"] as? String, "request-error")
            XCTAssertEqual(response["ok"] as? Bool, false)
            XCTAssertNotNil(response["error"])
        }
    }

    func testGeneratedEventTimestampsRemainValidAfterFirstMinute() throws {
        let runtime = MobileScenarioRuntime(scenario: .comprehensive)
        var inbound: [Data] = []

        for requestNumber in 0..<20 {
            _ = try response(
                runtime,
                type: "session.sendMessage",
                id: "request-send-\(requestNumber)",
                projectId: "project-demo",
                sessionId: "session-demo",
                payload: ["content": "Message \(requestNumber)"]
            )
            inbound.append(contentsOf: runtime.drain())
        }

        XCTAssertEqual(inbound.count, 60)
        let timestamps = try inbound.map { data -> String in
            let event = try XCTUnwrap(object(data)["payload"] as? [String: Any])
            _ = try decodePayload(object(data), as: AgentEvent.self)
            return try XCTUnwrap(event["timestamp"] as? String)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertTrue(timestamps.allSatisfy { formatter.date(from: $0) != nil })
        XCTAssertEqual(timestamps.last, "2026-09-27T00:01:10.000Z")
    }

    func testChangesScenariosExposeMixedEmptyAndBinaryStates() throws {
        let comprehensive = MobileScenarioRuntime(scenario: .comprehensive)
        let changes = try response(comprehensive, type: "project.listChanges", id: "changes", projectId: "project-demo")
        let decoded = try decodePayload(changes, as: ProjectChangesResponse.self)
        XCTAssertEqual(decoded.changes.count, 3)
        XCTAssertTrue(decoded.changes.contains { $0.isBinary })

        let clean = MobileScenarioRuntime(scenario: .clean)
        let cleanResponse = try response(clean, type: "project.listChanges", id: "clean", projectId: "project-demo")
        XCTAssertTrue(try decodePayload(cleanResponse, as: ProjectChangesResponse.self).changes.isEmpty)

        let parser = DiffParser.parse("@@ -2,2 +2,3 @@\n-old\n+new\n keep\n")
        XCTAssertEqual(parser[1], .init(text: "-old", oldLine: 2, newLine: nil))
        XCTAssertEqual(parser[2], .init(text: "+new", oldLine: nil, newLine: 2))
        XCTAssertEqual(parser[3], .init(text: " keep", oldLine: 3, newLine: 3))
        XCTAssertEqual(parser.count, 4)
        XCTAssertEqual(parser.last, .init(text: " keep", oldLine: 3, newLine: 3))

        let noNewline = DiffParser.parse("@@ -1 +1 @@\n-old\n+new\n\\ No newline at end of file\n keep\n")
        XCTAssertEqual(noNewline[3], .init(text: "\\ No newline at end of file", oldLine: nil, newLine: nil))
        XCTAssertEqual(noNewline[4], .init(text: " keep", oldLine: 2, newLine: 2))
    }

    func testChangesWorkspaceReturnsThroughDiffAndRoundTripsRecovery() throws {
        let change = try JSONDecoder().decode(GitChange.self, from: Data("""
        {"relativePath":"Sources/App.swift","kind":"modified","area":"unstaged","isBinary":false,"oldSize":1,"newSize":2}
        """.utf8))
        var state = WorkspaceNavigationState()
        state.showChanges()
        state.prepareDiff(change)
        state.activatePreparedDiff()
        XCTAssertEqual(state.level, .diff(change))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceNavigationState.self, from: JSONEncoder().encode(state)), state)
        XCTAssertTrue(WorkspaceChangesRestore.needsRefresh(for: state.level))
        state.goBack()
        XCTAssertEqual(state.level, .changes)
        XCTAssertTrue(WorkspaceChangesRestore.needsRefresh(for: state.level))
        state.goBack()
        XCTAssertEqual(state.level, .session)
        XCTAssertFalse(WorkspaceChangesRestore.needsRefresh(for: state.level))
    }

    func testChangedFileNavigationCoordinatorConsumesOnlyMatchingResults() throws {
        let change = try JSONDecoder().decode(GitChange.self, from: Data("""
        {"relativePath":"Sources/App.swift","kind":"modified","area":"unstaged","isBinary":false}
        """.utf8))
        let response = try JSONDecoder().decode(ProjectChangesResponse.self, from: Data("""
        {"isGitRepository":true,"changes":[{"relativePath":"Sources/App.swift","kind":"modified","area":"unstaged","isBinary":false}]}
        """.utf8))
        var coordinator = ChangedFileNavigationCoordinator()
        coordinator.begin(path: change.relativePath, generation: 2)
        XCTAssertNil(coordinator.consume(
            completion: .init(generation: 1, outcome: .succeeded),
            response: response
        ))
        XCTAssertNotNil(coordinator.pending)
        XCTAssertEqual(coordinator.consume(
            completion: .init(generation: 2, outcome: .succeeded),
            response: response
        ), change)
        XCTAssertNil(coordinator.pending)

        coordinator.begin(path: change.relativePath, generation: 3)
        let clean = try JSONDecoder().decode(ProjectChangesResponse.self, from: Data("""
        {"isGitRepository":true,"changes":[]}
        """.utf8))
        XCTAssertNil(coordinator.consume(
            completion: .init(generation: 3, outcome: .succeeded),
            response: clean
        ))
        XCTAssertNil(coordinator.pending)

        coordinator.begin(path: change.relativePath, generation: 4)
        XCTAssertNil(coordinator.consume(
            completion: .init(generation: 4, outcome: .failed(.init(message: "Unavailable"))),
            response: nil
        ))
        XCTAssertNil(coordinator.pending)
    }

    private func response(_ runtime: MobileScenarioRuntime, type: String, id: String, projectId: String? = nil, sessionId: String? = nil, payload: [String: Any] = [:]) throws -> [String: Any] {
        object(try responseData(runtime, type: type, id: id, projectId: projectId, sessionId: sessionId, payload: payload))
    }

    private func responseData(_ runtime: MobileScenarioRuntime, type: String, id: String, projectId: String? = nil, sessionId: String? = nil, payload: [String: Any] = [:]) throws -> Data {
        var request: [String: Any] = ["version": 1, "id": id, "type": type, "sourceDeviceId": "scenario-ios", "targetDeviceId": "scenario-mac", "timestamp": "2026-09-27T00:00:00.000Z", "payload": payload]
        if let projectId { request["projectId"] = projectId }
        if let sessionId { request["sessionId"] = sessionId }
        let data = try JSONSerialization.data(withJSONObject: request)
        return try XCTUnwrap(runtime.receive(data).first)
    }

    private func object(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func decodePayload<T: Decodable>(_ envelope: [String: Any], as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(envelope["payload"])))
    }
}

private struct ProjectList: Decodable { let projects: [RemoteProject] }
private struct SessionList: Decodable { let sessions: [Session] }
private struct FileList: Decodable { let relativePath: String; let entries: [FileEntry] }
private struct FileContent: Decodable { let relativePath: String; let encoding: String; let content: String }
