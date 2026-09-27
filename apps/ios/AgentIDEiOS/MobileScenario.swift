import Foundation
import AgentIDEProtocol

enum MobileScenario: String, CaseIterable {
    case comprehensive
    case offline
    case requestFailure = "request-failure"
    case timeout
    case invalidResponse = "invalid-response"

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
            Self.event(id: "event-1", sessionId: "session-demo", sequence: 1, type: "message", extra: ["role": "agent", "content": "I inspected the workspace and need approval before continuing.", "format": "markdown"]),
            Self.event(id: "event-2", sessionId: "session-demo", sequence: 2, type: "status", extra: ["status": "waiting_user", "message": "Waiting for simulator input"]),
            Self.event(id: "event-3", sessionId: "session-demo", sequence: 3, type: "question.requested", extra: ["interactionId": "question-demo", "question": "Which follow-up should run?", "options": [["id": "tests", "label": "Run tests"], ["id": "review", "label": "Review changes"]], "allowFreeText": true]),
            Self.event(id: "event-4", sessionId: "session-demo", sequence: 4, type: "approval.requested", extra: ["interactionId": "approval-demo", "title": "Run tests", "actions": ["approve_once", "reject"]])
        ]
        events = ["session-demo": initialEvents]
        pendingInteractions = ["session-demo": [initialEvents[4], initialEvents[3]]]
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
            enqueue(event(sessionId: sessionId, type: "message", extra: ["role": "user", "content": (request["payload"] as? [String: Any])?["content"] as? String ?? "", "format": "plain"]))
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
            return [success(for: request, type: "project.listFiles.response", replyTo: requestId, payload: ["relativePath": path, "entries": entries(at: path)])]
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

    private func project() -> [String: Any] {
        ["id": "project-demo", "name": "Scenario Workspace", "createdAt": "2026-09-27T00:00:00.000Z", "enabledAgents": ["codex", "claude"], "online": true]
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
        case "Sources": return [file(name: "App.swift", path: "Sources/App.swift")]
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

    private func encode(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func decodeObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
