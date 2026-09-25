import AgentIDEProtocol
import AppKit
import CoreImage.CIFilterBuiltins
import Security
import SwiftUI

private let maxRelayMessageBytes = 1024 * 1024

@main
struct AgentIDEMacApp: App {
    @StateObject private var connection = MacConnection()
    var body: some Scene { WindowGroup { MacHomeView().environmentObject(connection) } }
}

@MainActor
final class MacConnection: ObservableObject {
    private struct EventStreamKey: Hashable { let targetDeviceId: String; let sessionId: String }
    struct Pairing: Decodable { let expiresAt: String; let qrPayload: String; let secret: String }
    struct Device: Decodable, Identifiable { let id: String; let name: String; let online: Bool }
    struct DeviceList: Decodable { let devices: [Device] }
    struct Registration: Decodable { let token: String }
    struct ProjectList: Decodable { let projects: [Project] }
    struct FileList: Decodable { let entries: [FileEntry] }
    struct FileContent: Decodable { let content: String }
    struct SessionList: Decodable { let sessions: [Session] }
    struct EventList: Decodable { let events: [AgentEvent] }

    @Published var server = UserDefaults.standard.string(forKey: "relayServer") ?? "http://127.0.0.1:8787"
    @Published var pairing: Pairing?
    @Published var devices: [Device] = []
    @Published var projects: [Project] = []
    @Published var error: String?
    @Published var connectionState = "Offline"
    private let deviceId: String
    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var sessionStreams: [EventStreamKey: Task<Void, Never>] = [:]
    private var sessionStreamTokens: [EventStreamKey: UUID] = [:]
    private var acknowledgedEventSequences: [EventStreamKey: Int] = [:]
    private var sentEventSequences: [EventStreamKey: Int] = [:]
    private var sessionStreamGenerations: [EventStreamKey: Int] = [:]
    // TODO: Replace the development endpoint with the packaged companion-process endpoint before release.
    private let agentHost = URL(string: "http://127.0.0.1:8788")!

    init() {
        if let id = UserDefaults.standard.string(forKey: "deviceId") { deviceId = id }
        else { let id = UUID().uuidString; deviceId = id; UserDefaults.standard.set(id, forKey: "deviceId") }
        token = CredentialStore.token(for: server)
        Task { [weak self] in
            await self?.refreshProjects()
            if self?.token != nil { self?.connect(); await self?.refreshDevices() }
        }
    }

    func preparePairing() async {
        do {
            guard let relayURL = URL(string: server), isSecure(relayURL) else { throw URLError(.secureConnectionFailed) }
            UserDefaults.standard.set(server, forKey: "relayServer")
            token = CredentialStore.token(for: server)
            if token == nil {
                let body = ["deviceId": deviceId, "name": Host.current().localizedName ?? "Mac", "kind": "mac"]
                let registration: Registration = try await relayRequest("/devices/register", method: "POST", body: body, authenticated: false)
                token = registration.token; CredentialStore.save(registration.token, for: server)
            }
            pairing = try await relayRequest("/pairing/sessions", method: "POST", body: [String: String](), authenticated: true)
            connect(); await refreshDevices()
        } catch { self.error = error.localizedDescription }
    }

    func refreshDevices() async {
        do {
            let list: DeviceList = try await relayRequest("/devices", method: "GET", body: Optional<String>.none, authenticated: true)
            devices = list.devices
        } catch { self.error = error.localizedDescription }
    }

    func revoke(_ device: Device) async {
        do { let _: EmptyResponse = try await relayRequest("/devices/\(device.id)", method: "DELETE", body: Optional<String>.none, authenticated: true); await refreshDevices() }
        catch { self.error = error.localizedDescription }
    }

    func addProject() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let _: Project = try await hostRequest("/projects", method: "POST", body: ["rootPath": url.path]); await refreshProjects() }
        catch { self.error = error.localizedDescription }
    }

    func renameProject(_ project: Project, name: String) async {
        do { let _: Project = try await hostRequest("/projects/\(project.id)", method: "PATCH", body: ["name": name]); await refreshProjects() }
        catch { self.error = error.localizedDescription }
    }

    func removeProject(_ project: Project) async {
        do { let _: EmptyResponse = try await hostRequest("/projects/\(project.id)", method: "DELETE", body: Optional<String>.none); await refreshProjects() }
        catch { self.error = error.localizedDescription }
    }

    func refreshProjects() async {
        do { projects = try await loadProjects() }
        catch { self.error = "Agent Host: \(error.localizedDescription)" }
    }

    private func connect() {
        guard let token, var parts = URLComponents(string: server) else { return }
        connectionState = "Connecting"
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"; parts.path = "/connect"; parts.queryItems = [.init(name: "deviceId", value: deviceId)]
        guard let url = parts.url else { return }; var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        socket?.cancel(); let task = URLSession.shared.webSocketTask(with: request); socket = task; task.resume()
        task.sendPing { [weak self, weak task] error in Task { @MainActor in
            guard let self, let task, self.socket === task else { return }
            self.connectionState = error == nil ? "Connected" : "Offline"
        } }
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in Task { @MainActor in
            guard let self, self.socket === task else { return }
            switch result {
            case let .success(message):
                self.connectionState = "Connected"
                let data: Data? = switch message { case let .data(value): value; case let .string(value): Data(value.utf8); @unknown default: nil }
                if let data { await self.handleRelayMessage(data) }
                self.receive(task)
            case .failure:
                self.connectionState = "Offline"; try? await Task.sleep(for: .seconds(1)); guard self.socket === task else { return }; self.connect()
            }
        } }
    }

    private func handleRelayMessage(_ data: Data) async {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = message["type"] as? String else { return }
        if type == "system.presence" {
            if let source = message["sourceDeviceId"] as? String,
               let payload = message["payload"] as? [String: Any], payload["online"] as? Bool == false {
                cancelEventStreams(to: source)
            }
            await refreshDevices()
            return
        }
        guard let source = message["sourceDeviceId"] as? String else { return }
        if type == "agent.event.ack", let sessionId = message["sessionId"] as? String,
           let payload = message["payload"] as? [String: Any], let sequence = payload["sequence"] as? Int {
            let key = EventStreamKey(targetDeviceId: source, sessionId: sessionId)
            guard sequence <= sentEventSequences[key] ?? -1 else { return }
            acknowledgedEventSequences[key] = max(acknowledgedEventSequences[key] ?? -1, sequence)
            return
        }
        guard let requestId = message["id"] as? String else { return }
        if type == "project.list" {
            do {
                projects = try await loadProjects()
                sendResponse(to: source, replyTo: requestId, type: "project.list.response", payload: ["projects": projects.map(publicProject)])
            } catch {
                sendResponse(to: source, replyTo: requestId, type: "project.list.response", error: error.localizedDescription)
            }
        } else if type == "project.listFiles" {
            guard let projectId = message["projectId"] as? String,
                  let payload = message["payload"] as? [String: Any], let path = payload["relativePath"] as? String else {
                sendResponse(to: source, replyTo: requestId, type: "project.listFiles.response", error: "Invalid project.listFiles request")
                return
            }
            do {
                let list: FileList = try await hostRequest("/projects/\(projectId)/files/list", method: "POST", body: ["relativePath": path])
                let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list.entries))
                sendResponse(to: source, replyTo: requestId, type: "project.listFiles.response", projectId: projectId, payload: ["relativePath": path, "entries": entries])
            } catch { sendResponse(to: source, replyTo: requestId, type: "project.listFiles.response", projectId: projectId, error: error.localizedDescription) }
        } else if type == "project.readFile" {
            guard let projectId = message["projectId"] as? String,
                  let payload = message["payload"] as? [String: Any], let path = payload["relativePath"] as? String,
                  let encoding = payload["encoding"] as? String, encoding == "utf8" || encoding == "base64" else {
                sendResponse(to: source, replyTo: requestId, type: "project.readFile.response", error: "Invalid project.readFile request")
                return
            }
            do {
                let operation = encoding == "base64" ? "read-binary" : "read-text"
                let file: FileContent = try await hostRequest("/projects/\(projectId)/files/\(operation)", method: "POST", body: ["relativePath": path])
                sendResponse(to: source, replyTo: requestId, type: "project.readFile.response", projectId: projectId,
                             payload: ["relativePath": path, "encoding": encoding, "content": file.content])
            } catch { sendResponse(to: source, replyTo: requestId, type: "project.readFile.response", projectId: projectId, error: error.localizedDescription) }
        } else if type == "project.listImages" {
            guard let projectId = message["projectId"] as? String,
                  let payload = message["payload"] as? [String: Any], let path = payload["relativePath"] as? String else {
                sendResponse(to: source, replyTo: requestId, type: "project.listImages.response", error: "Invalid project.listImages request")
                return
            }
            do {
                let list: FileList = try await hostRequest("/projects/\(projectId)/files/list-images", method: "POST", body: ["relativePath": path])
                guard let current = list.entries.first(where: { $0.relativePath == path }) else {
                    throw NSError(domain: "AgentIDE", code: 404, userInfo: [NSLocalizedDescriptionKey: "Image not found"])
                }
                let currentValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
                let siblingValues = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list.entries))
                sendResponse(to: source, replyTo: requestId, type: "project.listImages.response", projectId: projectId,
                             payload: ["current": currentValue, "siblings": siblingValues])
            } catch { sendResponse(to: source, replyTo: requestId, type: "project.listImages.response", projectId: projectId, error: error.localizedDescription) }
        } else if type == "session.list" {
            guard let projectId = message["projectId"] as? String else {
                sendResponse(to: source, replyTo: requestId, type: "session.list.response", error: "Invalid session.list request", errorCode: "session_request_failed")
                return
            }
            do {
                let encodedProjectId = projectId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectId
                let list: SessionList = try await hostRequest("/sessions?projectId=\(encodedProjectId)", method: "GET", body: Optional<String>.none)
                let sessionValues = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list.sessions))
                sendResponse(to: source, replyTo: requestId, type: "session.list.response", projectId: projectId, payload: ["sessions": sessionValues])
            } catch {
                sendResponse(to: source, replyTo: requestId, type: "session.list.response", projectId: projectId, error: error.localizedDescription, errorCode: "session_request_failed")
            }
        } else if type == "session.create" {
            guard let projectId = message["projectId"] as? String,
                  let payload = message["payload"] as? [String: Any],
                  let agentType = payload["agentType"] as? String,
                  let initialTask = payload["initialTask"] as? String else {
                sendResponse(to: source, replyTo: requestId, type: "session.create.response", error: "Invalid session.create request", errorCode: "session_request_failed")
                return
            }
            do {
                let session: Session = try await hostRequest("/sessions", method: "POST", body: ["projectId": projectId, "agentType": agentType, "initialPrompt": initialTask])
                let sessionValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
                sendResponse(to: source, replyTo: requestId, type: "session.create.response", projectId: projectId, sessionId: session.id, payload: ["session": sessionValue])
                streamEvents(for: session.id, projectId: projectId, to: source, afterSequence: -1)
            } catch {
                sendResponse(to: source, replyTo: requestId, type: "session.create.response", projectId: projectId, error: error.localizedDescription, errorCode: "session_request_failed")
            }
        } else if type == "session.sendMessage" {
            guard let projectId = message["projectId"] as? String,
                  let sessionId = message["sessionId"] as? String,
                  let payload = message["payload"] as? [String: Any],
                  let content = payload["content"] as? String else {
                sendResponse(to: source, replyTo: requestId, type: "session.sendMessage.response", error: "Invalid session.sendMessage request", errorCode: "session_request_failed")
                return
            }
            do {
                let session: Session = try await hostRequest("/sessions/\(sessionId)", method: "GET", body: Optional<String>.none)
                guard session.projectId == projectId else { throw NSError(domain: "AgentIDE", code: 400, userInfo: [NSLocalizedDescriptionKey: "Session does not belong to project"]) }
                let _: EmptyResponse = try await hostRequest("/sessions/\(sessionId)/messages", method: "POST", body: ["content": content])
                sendResponse(to: source, replyTo: requestId, type: "session.sendMessage.response", projectId: projectId, sessionId: sessionId, payload: [:])
                streamEvents(for: sessionId, projectId: projectId, to: source, afterSequence: payload["afterSequence"] as? Int ?? -1)
            } catch {
                sendResponse(to: source, replyTo: requestId, type: "session.sendMessage.response", projectId: projectId, sessionId: sessionId, error: error.localizedDescription, errorCode: "session_request_failed")
            }
        } else if type == "session.subscribe" {
            guard let projectId = message["projectId"] as? String,
                  let sessionId = message["sessionId"] as? String,
                  let payload = message["payload"] as? [String: Any],
                  let afterSequence = payload["afterSequence"] as? Int else {
                sendResponse(to: source, replyTo: requestId, type: "session.subscribe.response", error: "Invalid session.subscribe request", errorCode: "session_request_failed")
                return
            }
            do {
                let session: Session = try await hostRequest("/sessions/\(sessionId)", method: "GET", body: Optional<String>.none)
                guard session.projectId == projectId else { throw NSError(domain: "AgentIDE", code: 400, userInfo: [NSLocalizedDescriptionKey: "Session does not belong to project"]) }
                streamEvents(for: sessionId, projectId: projectId, to: source, afterSequence: afterSequence, resetCursor: true)
                sendResponse(to: source, replyTo: requestId, type: "session.subscribe.response", projectId: projectId, sessionId: sessionId, payload: [:])
            } catch {
                sendResponse(to: source, replyTo: requestId, type: "session.subscribe.response", projectId: projectId, sessionId: sessionId, error: error.localizedDescription, errorCode: "session_request_failed")
            }
        } else if type == "session.cancel" {
            guard let projectId = message["projectId"] as? String,
                  let sessionId = message["sessionId"] as? String else {
                sendResponse(to: source, replyTo: requestId, type: "session.cancel.response", error: "Invalid session.cancel request", errorCode: "session_request_failed")
                return
            }
            do {
                let session: Session = try await hostRequest("/sessions/\(sessionId)", method: "GET", body: Optional<String>.none)
                guard session.projectId == projectId else { throw NSError(domain: "AgentIDE", code: 400, userInfo: [NSLocalizedDescriptionKey: "Session does not belong to project"]) }
                let _: EmptyResponse = try await hostRequest("/sessions/\(sessionId)/cancel", method: "POST", body: EmptyResponse())
                sendResponse(to: source, replyTo: requestId, type: "session.cancel.response", projectId: projectId, sessionId: sessionId, payload: [:])
            } catch {
                sendResponse(to: source, replyTo: requestId, type: "session.cancel.response", projectId: projectId, sessionId: sessionId, error: error.localizedDescription, errorCode: "session_request_failed")
            }
        } else if type == "interaction.respond" {
            guard let projectId = message["projectId"] as? String,
                  let sessionId = message["sessionId"] as? String,
                  let payload = message["payload"] as? [String: Any],
                  let interactionId = payload["interactionId"] as? String else {
                sendResponse(to: source, replyTo: requestId, type: "interaction.respond.response", error: "Invalid interaction.respond request", errorCode: "session_request_failed")
                return
            }
            do {
                let session: Session = try await hostRequest("/sessions/\(sessionId)", method: "GET", body: Optional<String>.none)
                guard session.projectId == projectId else { throw NSError(domain: "AgentIDE", code: 400, userInfo: [NSLocalizedDescriptionKey: "Session does not belong to project"]) }
                let kind = payload["kind"] as? String ?? (payload["action"] == nil ? "question" : "approval")
                let body: InteractionResponseRequest
                if kind == "approval", let action = payload["action"] as? String {
                    body = InteractionResponseRequest(kind: kind, interactionId: interactionId, action: action)
                } else if kind == "question" {
                    let optionIds = payload["optionIds"] as? [String]
                    let freeText = payload["freeText"] as? String
                    guard optionIds != nil || freeText != nil else {
                        throw NSError(domain: "AgentIDE", code: 400, userInfo: [NSLocalizedDescriptionKey: "Question response requires an option or free text"])
                    }
                    body = InteractionResponseRequest(kind: kind, interactionId: interactionId, optionIds: optionIds, freeText: freeText)
                } else {
                    throw NSError(domain: "AgentIDE", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid interaction response"])
                }
                let _: EmptyResponse = try await hostRequest("/sessions/\(sessionId)/interactions", method: "POST", body: body)
                sendResponse(to: source, replyTo: requestId, type: "interaction.respond.response", projectId: projectId, sessionId: sessionId, payload: [:])
            } catch {
                sendResponse(to: source, replyTo: requestId, type: "interaction.respond.response", projectId: projectId, sessionId: sessionId, error: error.localizedDescription, errorCode: "session_request_failed")
            }
        }
    }

    private func streamEvents(for sessionId: String, projectId: String, to target: String, afterSequence: Int, resetCursor: Bool = false) {
        let key = EventStreamKey(targetDeviceId: target, sessionId: sessionId)
        if resetCursor {
            sessionStreams[key]?.cancel()
            sessionStreams.removeValue(forKey: key)
            sessionStreamTokens.removeValue(forKey: key)
            sessionStreamGenerations.removeValue(forKey: key)
            acknowledgedEventSequences[key] = afterSequence
            sentEventSequences[key] = afterSequence
        } else {
            acknowledgedEventSequences[key] = max(acknowledgedEventSequences[key] ?? -1, afterSequence)
        }
        sessionStreamGenerations[key] = (sessionStreamGenerations[key] ?? 0) + 1
        guard sessionStreams[key] == nil else { return }
        let streamToken = UUID()
        sessionStreamTokens[key] = streamToken
        sessionStreams[key] = Task { [weak self] in
            defer {
                if self?.sessionStreamTokens[key] == streamToken {
                    self?.sessionStreams.removeValue(forKey: key)
                    self?.sessionStreamTokens.removeValue(forKey: key)
                    self?.sessionStreamGenerations.removeValue(forKey: key)
                }
            }
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let generation = self.sessionStreamGenerations[key]
                    let sequence = self.acknowledgedEventSequences[key] ?? -1
                    let list: EventList = try await self.hostRequest("/sessions/\(sessionId)/events?afterSequence=\(sequence)", method: "GET", body: Optional<String>.none)
                    guard !Task.isCancelled, self.sessionStreamTokens[key] == streamToken else { return }
                    var latestEventIsTerminal = false
                    for event in list.events {
                        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
                        guard let value = payload as? [String: Any], let eventSequence = value["sequence"] as? Int else { continue }
                        while !Task.isCancelled, (self.acknowledgedEventSequences[key] ?? -1) < eventSequence {
                            guard self.sessionStreamTokens[key] == streamToken else { return }
                            try await self.sendPush(to: target, type: "agent.event", projectId: projectId, sessionId: sessionId,
                                                    payload: self.relayPayload(for: value, projectId: projectId, sessionId: sessionId,
                                                                               target: target, sequence: eventSequence))
                            guard !Task.isCancelled, self.sessionStreamTokens[key] == streamToken else { return }
                            self.sentEventSequences[key] = max(self.sentEventSequences[key] ?? -1, eventSequence)
                            try? await Task.sleep(for: .seconds(1))
                        }
                        switch event {
                        case .turnCompleted, .sessionCompleted: latestEventIsTerminal = true
                        default: latestEventIsTerminal = false
                        }
                    }
                    if latestEventIsTerminal, self.sessionStreamGenerations[key] == generation { return }
                    if list.events.isEmpty {
                        let session: Session = try await self.hostRequest("/sessions/\(sessionId)", method: "GET", body: Optional<String>.none)
                        guard !Task.isCancelled, self.sessionStreamTokens[key] == streamToken else { return }
                        if session.status == .idle || session.status == .completed || session.status == .failed || session.status == .cancelled { return }
                    }
                } catch {
                    if Task.isCancelled { return }
                    self.error = "Agent Host: \(error.localizedDescription)"
                    try? await Task.sleep(for: .seconds(1))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func cancelEventStreams(to target: String) {
        let keys = sessionStreams.keys.filter { $0.targetDeviceId == target }
        for key in keys {
            sessionStreams[key]?.cancel()
            sessionStreams.removeValue(forKey: key)
            sessionStreamTokens.removeValue(forKey: key)
            sessionStreamGenerations.removeValue(forKey: key)
            sentEventSequences.removeValue(forKey: key)
            acknowledgedEventSequences.removeValue(forKey: key)
        }
    }

    private func relayPayload(for event: [String: Any], projectId: String, sessionId: String, target: String, sequence: Int) -> [String: Any] {
        let probe: [String: Any] = ["version": 1, "id": UUID().uuidString, "type": "agent.event", "sourceDeviceId": deviceId,
                                    "targetDeviceId": target, "projectId": projectId, "sessionId": sessionId,
                                    "timestamp": ISO8601DateFormatter().string(from: Date()), "payload": event]
        if let data = try? JSONSerialization.data(withJSONObject: probe), data.count <= maxRelayMessageBytes { return event }
        return ["id": UUID().uuidString, "sessionId": sessionId, "sequence": sequence,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "type": "error", "code": "agent_event_too_large", "message": "Agent event exceeded the relay size limit", "recoverable": true]
    }

    private func publicProject(_ project: Project) -> [String: Any] {
        ["id": project.id, "name": project.name, "createdAt": project.createdAt, "enabledAgents": project.enabledAgents.map(\.rawValue), "online": connectionState == "Connected"]
    }

    private func loadProjects() async throws -> [Project] {
        let list: ProjectList = try await hostRequest("/projects", method: "GET", body: Optional<String>.none)
        return list.projects
    }

    private func sendResponse(to target: String, replyTo: String, type: String, projectId: String? = nil, sessionId: String? = nil, payload: [String: Any]? = nil, error: String? = nil, errorCode: String = "project_request_failed") {
        var value: [String: Any] = ["version": 1, "id": UUID().uuidString, "type": type, "sourceDeviceId": deviceId, "targetDeviceId": target,
                                    "timestamp": ISO8601DateFormatter().string(from: Date()), "replyTo": replyTo, "ok": error == nil]
        if let projectId { value["projectId"] = projectId }
        if let sessionId { value["sessionId"] = sessionId }
        if let error {
            value["payload"] = NSNull()
            value["error"] = ["code": errorCode, "message": error]
        } else if let payload { value["payload"] = payload }
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        if data.count > maxRelayMessageBytes {
            value["ok"] = false
            value["payload"] = NSNull()
            value["error"] = ["code": errorCode, "message": "Response is too large"]
            guard let fallback = try? JSONSerialization.data(withJSONObject: value) else { return }
            data = fallback
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func sendPush(to target: String, type: String, projectId: String, sessionId: String, payload: Any) async throws {
        let value: [String: Any] = ["version": 1, "id": UUID().uuidString, "type": type, "sourceDeviceId": deviceId,
                                    "targetDeviceId": target, "projectId": projectId, "sessionId": sessionId,
                                    "timestamp": ISO8601DateFormatter().string(from: Date()), "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= maxRelayMessageBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AgentIDE", code: 413, userInfo: [NSLocalizedDescriptionKey: "Agent event is too large"])
        }
        guard let socket else { throw URLError(.notConnectedToInternet) }
        try await socket.send(.string(text))
    }

    private func relayRequest<Response: Decodable, Body: Encodable>(_ path: String, method: String, body: Body?, authenticated: Bool) async throws -> Response {
        guard let base = URL(string: server), let url = URL(string: path, relativeTo: base) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.httpMethod = method
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated, let token { request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await perform(request)
    }

    private func hostRequest<Response: Decodable, Body: Encodable>(_ path: String, method: String, body: Body?) async throws -> Response {
        guard let url = URL(string: path, relativeTo: agentHost) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.httpMethod = method
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? "Request failed"
            throw NSError(domain: "AgentIDE", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct EmptyResponse: Codable {}
private struct InteractionResponseRequest: Encodable {
    let kind: String
    let interactionId: String
    var action: String?
    var optionIds: [String]?
    var freeText: String?
}
private struct ErrorResponse: Decodable { let error: String }
private func isSecure(_ url: URL) -> Bool { url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")) }
