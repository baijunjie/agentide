import XCTest
import AgentIDEProtocol
@testable import AgentIDEiOS

final class MobileScenarioTests: XCTestCase {
    func testLaunchArgumentSelectsScenario() {
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "-mobileScenario", "offline"]), .offline)
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "--mobile-scenario=request-failure"]), .requestFailure)
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "--mobile-scenario=timeout"]), .timeout)
        XCTAssertEqual(MobileScenario.fromLaunchArguments(["app", "--mobile-scenario=invalid-response"]), .invalidResponse)
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
        XCTAssertEqual(decodedSnapshot.recentEvents.count, 5)
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
        XCTAssertEqual(events.last?.sequence, 9)
        XCTAssertTrue(runtime.drain().isEmpty)
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
        XCTAssertEqual(timestamps.last, "2026-09-27T00:01:04.000Z")
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
