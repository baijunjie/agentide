import Foundation
import AgentIDEProtocol

enum MobileScenario: String, CaseIterable {
    case comprehensive
    case interactions
    case reports
    case reportLayout = "report-layout"
    case offline
    case requestFailure = "request-failure"
    case timeout
    case invalidResponse = "invalid-response"
    case clean
    case notGit = "not-git"
    case binary
    case tooLarge = "too-large"
    case searchEmpty = "search-empty"
    case searchLimited = "search-limited"
    case searchMissingDirectory = "search-missing-directory"

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> MobileScenario? {
#if DEBUG
        for (index, argument) in arguments.enumerated() {
            if argument == "-mobileScenario", index + 1 < arguments.count {
                return MobileScenario(rawValue: arguments[index + 1])
            }
            if argument.hasPrefix("--mobile-scenario=") {
                return MobileScenario(rawValue: String(argument.dropFirst("--mobile-scenario=".count)))
            }
        }
#endif
        return nil
    }
}

struct MobileScenarioPresence: Equatable {
    let paired: Bool
    let online: Bool
    let macDeviceId: String?
}

struct ScenarioSentMessage: Equatable {
    let sessionId: String
    let content: String
}

/// A deterministic in-process stand-in for the Mac endpoint. It exchanges the same envelope JSON
/// as the relay connection so simulator tests cover decoding and request correlation as well as UI state.
final class MobileScenarioRuntime {
    private let scenario: MobileScenario
    private let macDeviceId = "scenario-mac"
    private var responseNumber = 0
    private var eventNumber = 0
    private var createdSessionNumber = 0
    private var sessions: [String: [[String: Any]]]
    private var events: [String: [[String: Any]]]
    private var pendingInteractions: [String: [[String: Any]]]
    private var deferredInbound: [Data] = []
    private(set) var sentMessages: [ScenarioSentMessage] = []
    private var heldChangesRequests: [String: [String: Any]] = [:]
    private var heldSearchRequests: [String: [String: Any]] = [:]
    private var requests: [String: [String: Any]] = [:]
    private(set) var requestIdsByType: [String: [String]] = [:]
    var holdsChangesResponses = false
    var holdsDiffResponses = false
    var holdsSearchResponses = false
    private(set) var cancelledSearchIds: [String] = []

    let presence: MobileScenarioPresence

    init(scenario: MobileScenario) {
        self.scenario = scenario
        presence = MobileScenarioPresence(
            paired: true,
            online: scenario != .offline,
            macDeviceId: scenario == .offline ? nil : "scenario-mac"
        )

        let session = Self.session(id: "session-demo", status: "waiting_user")
        sessions = ["project-demo": [session]]
        let initialEvents = [
            Self.event(id: "event-0", sessionId: "session-demo", sequence: 0, type: "session.started", extra: ["nativeSessionId": "scenario-native"]),
            Self.event(id: "event-1", sessionId: "session-demo", sequence: 1, type: "message", extra: ["role": "agent", "content": "## Inspection\n\nI inspected the workspace and need approval before continuing.\n\nThe next step is a separate paragraph.", "format": "markdown"]),
            Self.event(id: "event-2", sessionId: "session-demo", sequence: 2, type: "status", extra: ["status": "waiting_user", "message": "Waiting for simulator input"]),
            Self.report(
                id: "event-3", sequence: 3, reportId: "tests-demo", kind: "test_report",
                title: "Test Report", summary: "42 tests completed with one failure",
                payload: [
                    "total": 42, "passed": 40, "failed": 1, "skipped": 1,
                    "failures": [["name": "WorkspaceTests.testRestore", "message": "Expected restored report state"]],
                ]
            ),
            Self.report(
                id: "event-4", sequence: 4, reportId: "plan-demo", kind: "plan",
                title: "Execution Plan", summary: "Implementation is in progress",
                payload: ["steps": [
                    ["title": "Define protocol", "status": "completed"],
                    ["title": "Render reports", "status": "in_progress"],
                    ["title": "Verify recovery", "status": "pending"],
                ]]
            ),
            Self.report(
                id: "event-5", sequence: 5, reportId: "todo-demo", kind: "todo",
                title: "Todo", summary: "One item is blocked",
                payload: ["items": (0..<55).map { index in
                    ["title": "Task \(index + 1)", "status": index == 0 ? "blocked" : index < 20 ? "completed" : "not_started"]
                }]
            ),
            Self.report(
                id: "event-6", sequence: 6, reportId: "diagnostics-demo", kind: "diagnostics",
                title: "Diagnostics", summary: "One source issue needs attention",
                payload: ["items": [[
                    "severity": "error", "message": "Preview state is stale",
                    "relativePath": "Sources/App.swift", "line": 12, "column": 5,
                ]]]
            ),
            Self.report(
                id: "event-7", sequence: 7, reportId: "future-demo", kind: "coverage",
                title: "Coverage", summary: "A newer AgentIDE produced this report",
                payload: ["percentage": 87.5]
            ),
            Self.event(id: "event-8", sessionId: "session-demo", sequence: 8, type: "file.changed", extra: ["relativePath": "Sources/App.swift", "change": "modified"]),
            Self.event(id: "event-9", sessionId: "session-demo", sequence: 9, type: "question.requested", extra: ["interactionId": "question-demo", "question": "Which follow-up should run?", "options": [["id": "tests", "label": "Run tests"], ["id": "review", "label": "Review changes"]], "allowFreeText": true]),
            Self.event(id: "event-10", sessionId: "session-demo", sequence: 10, type: "approval.requested", extra: ["interactionId": "approval-demo", "title": "Run tests", "actions": ["approve_once", "reject"]])
        ]
        let selectedEvents: [[String: Any]]
        switch scenario {
        case .interactions:
            let toolOutput = "alpha " + String(repeating: "word ", count: 30) + "UNIQUE-TAIL"
            selectedEvents = initialEvents.filter { ($0["type"] as? String) != "report" } + [
                Self.event(id: "event-tool-started", sessionId: "session-demo", sequence: 0, type: "tool.started", extra: [
                    "toolName": "read_file", "title": "Read README", "input": ["path": "README.md"],
                ]),
                Self.event(id: "event-tool-finished", sessionId: "session-demo", sequence: 0, type: "tool.finished", extra: [
                    "toolName": "read_file", "output": ["content": toolOutput],
                ]),
                Self.event(id: "event-command", sessionId: "session-demo", sequence: 0, type: "command", extra: [
                    "command": "swift test", "status": "completed", "exitCode": 0,
                ]),
            ]
        case .reports:
            selectedEvents = initialEvents.filter { event in
                let type = event["type"] as? String
                return type == "session.started" || type == "report"
            }
        case .reportLayout:
            selectedEvents = initialEvents.filter { ($0["id"] as? String) == "event-3" }
        default:
            selectedEvents = initialEvents
        }
        let scenarioEvents = scenario == .comprehensive ? selectedEvents : selectedEvents.enumerated().map { index, event in
            var normalized = event
            normalized["sequence"] = index
            return normalized
        }
        events = ["session-demo": scenarioEvents]
        pendingInteractions = ["session-demo": scenarioEvents.filter { event in
            let type = event["type"] as? String
            return type == "approval.requested" || type == "question.requested"
        }]
    }

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> MobileScenarioRuntime? {
        MobileScenario.fromLaunchArguments(arguments).map(MobileScenarioRuntime.init)
    }

    func start() -> [Data] {
        [encode(envelope(type: "system.presence", payload: ["online": presence.online]))]
    }

    func receive(_ outbound: Data) -> [Data] {
        guard let request = decodeObject(outbound), let type = request["type"] as? String,
              let requestId = request["id"] as? String else {
            return []
        }
        requestIdsByType[type, default: []].append(requestId)
        requests[requestId] = request
        if type == "project.listChanges", holdsChangesResponses {
            heldChangesRequests[requestId] = request
            return []
        }
        if type == "project.readDiff", holdsDiffResponses { return [] }
        if type == "project.searchFiles", holdsSearchResponses {
            heldSearchRequests[requestId] = request
            return []
        }
        if type == "project.cancelSearch" {
            let searchId = ((request["payload"] as? [String: Any])?["searchId"] as? String) ?? ""
            cancelledSearchIds.append(searchId)
        }
        if scenario == .offline {
            return [failure(for: request, type: "\(type).response", replyTo: requestId, code: "MAC_OFFLINE", message: "Mac is offline")]
        }
        if scenario == .requestFailure {
            return [failure(for: request, type: "\(type).response", replyTo: requestId, code: "SCENARIO_FAILURE", message: "Scenario request failure")]
        }
        if scenario == .timeout {
            return []
        }
        if scenario == .invalidResponse {
            let response = success(for: request, type: "\(type).response", replyTo: requestId, payload: [:])
            guard var object = decodeObject(response) else { return [] }
            object["sourceDeviceId"] = "unexpected-mac"
            return [encode(object)]
        }

        switch type {
        case "project.list":
            return [success(for: request, type: "project.list.response", replyTo: requestId, payload: ["projects": [project()]])]
        case "session.list":
            let projectId = request["projectId"] as? String ?? ""
            return [success(for: request, type: "session.list.response", replyTo: requestId, payload: ["sessions": sessions[projectId] ?? []])]
        case "session.create":
            createdSessionNumber += 1
            let projectId = request["projectId"] as? String ?? "project-demo"
            let created = Self.session(id: "session-created-\(createdSessionNumber)", status: "running", title: "Scenario task")
            sessions[projectId, default: []].append(created)
            events[created["id"] as! String] = []
            pendingInteractions[created["id"] as! String] = []
            let sessionId = created["id"] as! String
            let initialTask = ((request["payload"] as? [String: Any])?["initialTask"] as? String) ?? ""
            enqueue(event(sessionId: sessionId, type: "message", extra: ["role": "user", "content": initialTask, "format": "plain"]))
            enqueue(event(sessionId: sessionId, type: "status", extra: ["status": "running", "message": "Scenario task started"]))
            // A new idle session has to be taller than the phone, or leaving the end cannot be distinguished from already sitting on it.
            for index in 1...14 {
                let line = String(format: "Created feed line %02d", index)
                enqueue(event(sessionId: sessionId, type: "message", extra: ["role": "agent", "content": "\(line). This row keeps the new session taller than the viewport.", "format": "plain"]))
            }
            enqueue(event(sessionId: sessionId, type: "message", extra: ["role": "agent", "content": "The scenario task completed without a live connection.", "format": "markdown"]))
            enqueue(event(sessionId: sessionId, type: "turn.completed", extra: ["outcome": "completed"]))
            enqueue(event(sessionId: sessionId, type: "status", extra: ["status": "idle"]))
            updateSessionStatus(sessionId, status: "idle")
            return [success(for: request, type: "session.create.response", replyTo: requestId, payload: ["session": created], sessionId: created["id"] as? String)]
        case "session.getSnapshot":
            guard let sessionId = request["sessionId"] as? String, let session = session(sessionId) else {
                return [failure(for: request, type: "session.getSnapshot.response", replyTo: requestId, code: "NOT_FOUND", message: "Session not found")]
            }
            return [success(for: request, type: "session.getSnapshot.response", replyTo: requestId, payload: snapshot(session: session, sessionId: sessionId))]
        case "session.subscribe":
            return [success(for: request, type: "session.subscribe.response", replyTo: requestId, payload: [:])]
        case "session.sendMessage":
            guard let sessionId = request["sessionId"] as? String else { return [] }
            let content = (request["payload"] as? [String: Any])?["content"] as? String ?? ""
            sentMessages.append(.init(sessionId: sessionId, content: content))
            enqueue(event(sessionId: sessionId, type: "message", extra: ["role": "user", "content": content, "format": "plain"]))
            enqueue(event(sessionId: sessionId, type: "status", extra: ["status": "running", "message": "Scenario response started"]))
            enqueue(event(sessionId: sessionId, type: "text.delta", extra: ["content": "Working offline…"]))
            updateSessionStatus(sessionId, status: "running")
            return [success(for: request, type: "session.sendMessage.response", replyTo: requestId, payload: [:])]
        case "session.cancel":
            guard let sessionId = request["sessionId"] as? String else { return [] }
            enqueue(event(sessionId: sessionId, type: "turn.completed", extra: ["outcome": "cancelled"]))
            enqueue(event(sessionId: sessionId, type: "status", extra: ["status": "idle", "message": "Scenario turn cancelled"]))
            updateSessionStatus(sessionId, status: "idle")
            return [success(for: request, type: "session.cancel.response", replyTo: requestId, payload: [:])]
        case "interaction.respond":
            guard let sessionId = request["sessionId"] as? String else { return [] }
            let interactionId = ((request["payload"] as? [String: Any])?["interactionId"] as? String) ?? ""
            pendingInteractions[sessionId]?.removeAll { $0["interactionId"] as? String == interactionId }
            if pendingInteractions[sessionId]?.isEmpty == false {
                enqueue(event(sessionId: sessionId, type: "status", extra: ["status": "waiting_user", "message": "Another response is still required"]))
                return [success(for: request, type: "interaction.respond.response", replyTo: requestId, payload: [:])]
            }
            enqueue(event(sessionId: sessionId, type: "status", extra: ["status": "running", "message": "Scenario responses received"]))
            enqueue(event(sessionId: sessionId, type: "message", extra: ["role": "agent", "content": "The approved scenario completed successfully.", "format": "markdown"]))
            enqueue(event(sessionId: sessionId, type: "turn.completed", extra: ["outcome": "completed"]))
            enqueue(event(sessionId: sessionId, type: "session.completed", extra: ["outcome": "completed"]))
            updateSessionStatus(sessionId, status: "completed")
            return [success(for: request, type: "interaction.respond.response", replyTo: requestId, payload: [:])]
        case "project.listFiles":
            let path = ((request["payload"] as? [String: Any])?["relativePath"] as? String) ?? ""
            if scenario == .searchMissingDirectory, path == "Deleted" {
                return [failure(for: request, type: "project.listFiles.response", replyTo: requestId,
                                code: "NOT_FOUND", message: "Folder no longer exists")]
            }
            var listedEntries = entries(at: path)
            if scenario == .searchMissingDirectory, path.isEmpty {
                listedEntries.append(directory(name: "Deleted", path: "Deleted"))
            }
            return [success(for: request, type: "project.listFiles.response", replyTo: requestId, payload: ["relativePath": path, "entries": listedEntries])]
        case "project.readFile":
            let path = ((request["payload"] as? [String: Any])?["relativePath"] as? String) ?? "README.md"
            let encoding = ((request["payload"] as? [String: Any])?["encoding"] as? String) ?? "utf8"
            let content = encoding == "base64"
                ? "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="
                : "# Scenario workspace\n\nThis file is served by the deterministic simulator scenario.\n"
            return [success(for: request, type: "project.readFile.response", replyTo: requestId, payload: ["relativePath": path, "encoding": encoding, "content": content])]
        case "project.listImages":
            let path = ((request["payload"] as? [String: Any])?["relativePath"] as? String) ?? "assets/logo.png"
            let image = file(name: "logo.png", path: path, image: true)
            return [success(for: request, type: "project.listImages.response", replyTo: requestId, payload: ["current": image, "siblings": [image]])]
        case "project.searchFiles":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let searchId = payload["searchId"] as? String ?? ""
            let query = payload["query"] as? String ?? ""
            if scenario == .searchEmpty {
                return [searchResponse(for: request, replyTo: requestId, searchId: searchId, query: query, results: [], hasMore: false)]
            }
            if scenario == .searchMissingDirectory {
                return [searchResponse(for: request, replyTo: requestId, searchId: searchId, query: query,
                                       results: [directory(name: "Deleted", path: "Deleted")], hasMore: false)]
            }
            let allResults = searchEntries().filter { entry in
                let name = entry["name"] as? String ?? ""
                let path = entry["relativePath"] as? String ?? ""
                return name.localizedCaseInsensitiveContains(query) || path.localizedCaseInsensitiveContains(query)
            }
            let limit = payload["limit"] as? Int ?? 50
            let responseResults = scenario == .searchLimited ? Array(allResults.prefix(max(1, min(limit, 2)))) : Array(allResults.prefix(limit))
            return [searchResponse(
                for: request,
                replyTo: requestId,
                searchId: searchId,
                query: query,
                results: responseResults,
                hasMore: scenario == .searchLimited || allResults.count > responseResults.count
            )]
        case "project.cancelSearch":
            return [success(for: request, type: "project.cancelSearch.response", replyTo: requestId, payload: [:])]
        case "project.listChanges":
            let changes: [[String: Any]] = scenario == .clean || scenario == .notGit ? [] : [
                gitChange(path: "Sources/App.swift", kind: "modified", area: "unstaged"),
                gitChange(path: "README.md", kind: "added", area: "staged"),
                gitChange(path: "assets/logo.png", kind: "modified", area: "unstaged", binary: true),
            ]
            return [success(for: request, type: "project.listChanges.response", replyTo: requestId, payload: ["isGitRepository": scenario != .notGit, "changes": changes])]
        case "project.readDiff":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let path = payload["relativePath"] as? String ?? "Sources/App.swift"
            let area = payload["area"] as? String ?? "unstaged"
            if scenario == .tooLarge { return [failure(for: request, type: "project.readDiff.response", replyTo: requestId, code: "DIFF_TOO_LARGE", message: "Diff exceeds the transfer limit")] }
            let binary = scenario == .binary || path == "assets/logo.png"
            let change = gitChange(path: path, kind: path == "README.md" ? "added" : "modified", area: area, binary: binary)
            let diff = binary ? nil : "diff --git a/\(path) b/\(path)\n@@ -1,2 +1,3 @@\n-old line\n+new line\n unchanged\n+another line\n"
            var response: [String: Any] = ["change": change]
            if let diff { response["diff"] = diff }
            return [success(for: request, type: "project.readDiff.response", replyTo: requestId, payload: response)]
        case "agent.event.ack":
            return []
        default:
            return [failure(for: request, type: "\(type).response", replyTo: requestId, code: "UNSUPPORTED", message: "Unsupported scenario request")]
        }
    }

    func drain() -> [Data] {
        defer { deferredInbound = [] }
        return deferredInbound
    }

    func respondToHeldChanges(_ requestId: String, changes: [[String: Any]], isGitRepository: Bool = true) -> Data? {
        guard let request = heldChangesRequests.removeValue(forKey: requestId) else { return nil }
        return success(for: request, type: "project.listChanges.response", replyTo: requestId,
                       payload: ["isGitRepository": isGitRepository, "changes": changes])
    }

    func respondToHeldSearch(_ requestId: String, results: [[String: Any]], hasMore: Bool = false) -> Data? {
        guard let request = heldSearchRequests.removeValue(forKey: requestId),
              let payload = request["payload"] as? [String: Any],
              let searchId = payload["searchId"] as? String,
              let query = payload["query"] as? String else { return nil }
        return searchResponse(for: request, replyTo: requestId, searchId: searchId, query: query, results: results, hasMore: hasMore)
    }

    func failHeldSearch(_ requestId: String, message: String = "Search failed") -> Data? {
        guard let request = heldSearchRequests.removeValue(forKey: requestId) else { return nil }
        return failure(for: request, type: "project.searchFiles.response", replyTo: requestId,
                       code: "PROJECT_SEARCH_FAILED", message: message)
    }

    func failureResponse(for requestId: String, type: String, code: String, message: String) -> Data? {
        guard let request = requests[requestId] else { return nil }
        return failure(for: request, type: type, replyTo: requestId, code: code, message: message)
    }

    func searchEntry(name: String, path: String, directory: Bool = false, image: Bool = false) -> [String: Any] {
        directory ? self.directory(name: name, path: path) : file(name: name, path: path, image: image)
    }

    func change(path: String, area: String = "unstaged", binary: Bool = false) -> [String: Any] {
        gitChange(path: path, kind: "modified", area: area, binary: binary)
    }

    func response(for requestId: String, type: String, payload: [String: Any]) -> Data? {
        guard let request = requests[requestId] else { return nil }
        return success(for: request, type: type, replyTo: requestId, payload: payload)
    }

    private func project() -> [String: Any] {
        ["id": "project-demo", "name": "Scenario Workspace", "createdAt": "2026-09-27T00:00:00.000Z", "enabledAgents": ["codex", "claude"], "online": true]
    }

    private func searchResponse(
        for request: [String: Any],
        replyTo: String,
        searchId: String,
        query: String,
        results: [[String: Any]],
        hasMore: Bool
    ) -> Data {
        success(for: request, type: "project.searchFiles.response", replyTo: replyTo,
                payload: ["searchId": searchId, "query": query, "results": results, "hasMore": hasMore])
    }

    private func searchEntries() -> [[String: Any]] {
        entries(at: "") + entries(at: "Sources") + entries(at: "assets")
    }

    private func snapshot(session: [String: Any], sessionId: String) -> [String: Any] {
        let recent = events[sessionId] ?? []
        let status = pendingInteractions[sessionId]?.isEmpty == false ? "waiting_user" : (session["status"] as? String ?? "idle")
        return ["session": session, "recentEvents": recent, "pendingInteractions": pendingInteractions[sessionId] ?? [], "latestSequence": (recent.last?["sequence"] as? Int) ?? -1, "currentStatus": status]
    }

    private func session(_ id: String) -> [String: Any]? {
        sessions.values.flatMap { $0 }.first { $0["id"] as? String == id }
    }

    private func updateSessionStatus(_ sessionId: String, status: String) {
        for projectId in sessions.keys {
            guard let index = sessions[projectId]?.firstIndex(where: { $0["id"] as? String == sessionId }) else { continue }
            sessions[projectId]?[index]["status"] = status
            return
        }
    }

    private func enqueue(_ event: [String: Any]) {
        guard let sessionId = event["sessionId"] as? String else { return }
        events[sessionId, default: []].append(event)
        deferredInbound.append(encode(envelope(type: "agent.event", payload: event, projectId: "project-demo", sessionId: sessionId)))
    }

    private func event(sessionId: String, type: String, extra: [String: Any]) -> [String: Any] {
        let sequence = events[sessionId]?.count ?? 0
        eventNumber += 1
        return Self.event(id: "event-generated-\(eventNumber)", sessionId: sessionId, sequence: sequence, type: type, extra: extra)
    }

    private func success(for request: [String: Any], type: String, replyTo: String, payload: [String: Any], sessionId: String? = nil) -> Data {
        encode(envelope(type: type, payload: payload, projectId: request["projectId"] as? String, sessionId: sessionId ?? request["sessionId"] as? String, replyTo: replyTo, ok: true))
    }

    private func failure(for request: [String: Any], type: String, replyTo: String, code: String, message: String) -> Data {
        encode(envelope(type: type, payload: nil, projectId: request["projectId"] as? String, sessionId: request["sessionId"] as? String, replyTo: replyTo, ok: false, error: ["code": code, "message": message]))
    }

    private func envelope(type: String, payload: [String: Any]?, projectId: String? = nil, sessionId: String? = nil, replyTo: String? = nil, ok: Bool? = nil, error: [String: Any]? = nil) -> [String: Any] {
        responseNumber += 1
        var value: [String: Any] = ["version": 1, "id": "scenario-inbound-\(responseNumber)", "type": type, "sourceDeviceId": macDeviceId, "targetDeviceId": "scenario-ios", "timestamp": "2026-09-27T00:00:\(String(format: "%02d", responseNumber % 60)).000Z"]
        if let projectId { value["projectId"] = projectId }
        if let sessionId { value["sessionId"] = sessionId }
        if let payload { value["payload"] = payload }
        if let replyTo { value["replyTo"] = replyTo }
        if let ok { value["ok"] = ok }
        if let error { value["error"] = error }
        return value
    }

    private func entries(at path: String) -> [[String: Any]] {
        switch path {
        case "": return [file(name: "README.md", path: "README.md"), directory(name: "Sources", path: "Sources"), directory(name: "assets", path: "assets")]
        case "Sources": return [
            file(name: "App.swift", path: "Sources/App.swift"),
            file(name: "Context Guide.md", path: "Sources/Context Guide.md"),
            file(name: "说明.md", path: "Sources/说明.md"),
        ]
        case "assets": return [file(name: "logo.png", path: "assets/logo.png", image: true)]
        default: return []
        }
    }

    private func file(name: String, path: String, image: Bool = false) -> [String: Any] {
        ["name": name, "relativePath": path, "type": "file", "size": image ? 8 : 96, "extension": name.split(separator: ".").last.map(String.init) ?? "", "isText": !image, "isImage": image]
    }

    private func directory(name: String, path: String) -> [String: Any] {
        ["name": name, "relativePath": path, "type": "directory"]
    }

    private func gitChange(path: String, kind: String, area: String, binary: Bool = false) -> [String: Any] {
        ["relativePath": path, "kind": kind, "area": area, "isBinary": binary, "oldSize": binary ? 8 : 24, "newSize": binary ? 12 : 30]
    }

    private static func session(id: String, status: String, title: String = "Scenario approval") -> [String: Any] {
        ["id": id, "projectId": "project-demo", "agentType": "codex", "nativeSessionId": "native-\(id)", "title": title, "status": status, "createdAt": "2026-09-27T00:00:00.000Z", "updatedAt": "2026-09-27T00:00:00.000Z"]
    }

    private static func event(id: String, sessionId: String, sequence: Int, type: String, extra: [String: Any]) -> [String: Any] {
        let hours = sequence / 3_600 % 24
        let minutes = sequence / 60 % 60
        let seconds = sequence % 60
        let timestamp = String(format: "2026-09-27T%02d:%02d:%02d.000Z", hours, minutes, seconds)
        return ["id": id, "sessionId": sessionId, "sequence": sequence, "timestamp": timestamp, "type": type].merging(extra) { _, new in new }
    }

    private static func report(
        id: String,
        sequence: Int,
        reportId: String,
        kind: String,
        title: String,
        summary: String,
        payload: [String: Any]
    ) -> [String: Any] {
        event(id: id, sessionId: "session-demo", sequence: sequence, type: "report", extra: [
            "reportVersion": 1,
            "reportId": reportId,
            "kind": kind,
            "title": title,
            "summary": summary,
            "payload": payload,
        ])
    }

    private func encode(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func decodeObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
