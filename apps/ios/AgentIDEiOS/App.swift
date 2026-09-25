import AVFoundation
import AgentIDEProtocol
import ImageIO
import Security
import SwiftUI
import UIKit

@main
struct AgentIDEiOSApp: App {
    @StateObject private var connection = MobileConnection()
    var body: some Scene { WindowGroup { MobileHomeView().environmentObject(connection) } }
}

private struct PairingPayload: Codable { let version: Int; let server: String; let pairingId: String; let secret: String }
struct RemoteProject: Codable, Identifiable {
    let id: String
    let name: String
    let createdAt: String
    let enabledAgents: [AgentType]
    let online: Bool
}
private struct ProjectListPayload: Decodable { let projects: [RemoteProject] }
private struct FileListPayload: Decodable { let relativePath: String; let entries: [FileEntry] }
private struct SessionListPayload: Decodable { let sessions: [Session] }
private struct SessionCreatePayload: Decodable { let session: Session }
struct RemoteFileContent: Decodable {
    enum Encoding: String, Decodable { case utf8, base64 }
    let relativePath: String
    let encoding: Encoding
    let content: String
}
struct RemoteImageList: Decodable {
    let current: FileEntry
    let siblings: [FileEntry]
}
private struct DecodedImage: @unchecked Sendable {
    let image: UIImage
    let cost: Int
}
struct AcceptedMessage: Equatable {
    let id = UUID()
    let sessionId: String
    let content: String
}

@MainActor
final class MobileConnection: ObservableObject {
    struct Claim: Decodable { let token: String }
    private enum PendingRequest {
        case directory(String)
        case text(String)
        case image(String)
        case imageList(String)
        case sessionList(String)
        case sessionCreate(String)
        case sessionSend(String, String, String)
        case sessionCancel(String, String)
        case sessionSubscribe(String, String)
        case interaction(String, String, String)

        var responseType: String {
            switch self {
            case .directory: "project.listFiles.response"
            case .text, .image: "project.readFile.response"
            case .imageList: "project.listImages.response"
            case .sessionList: "session.list.response"
            case .sessionCreate: "session.create.response"
            case .sessionSend: "session.sendMessage.response"
            case .sessionCancel: "session.cancel.response"
            case .sessionSubscribe: "session.subscribe.response"
            case .interaction: "interaction.respond.response"
            }
        }

        var isInteraction: Bool {
            if case .interaction = self { return true }
            return false
        }
    }
    @Published var online = false
    @Published var paired = false
    @Published var projects: [RemoteProject] = []
    @Published var files: [String: [FileEntry]] = [:]
    @Published var loadingPaths: Set<String> = []
    @Published var fileContents: [String: RemoteFileContent] = [:]
    @Published var imageLists: [String: RemoteImageList] = [:]
    @Published var loadingFiles: Set<String> = []
    @Published var loadingImageLists: Set<String> = []
    @Published var directoryErrors: [String: String] = [:]
    @Published var fileErrors: [String: String] = [:]
    @Published var imageListErrors: [String: String] = [:]
    @Published var sessions: [String: [Session]] = [:]
    @Published var sessionEvents: [String: [AgentEvent]] = [:]
    @Published var sessionFeedItems: [String: [FeedItem]] = [:]
    @Published var eventSessionStatuses: [String: SessionStatus] = [:]
    @Published var historicallyResolvedInteractions: Set<String> = []
    @Published var loadingSessionProjects: Set<String> = []
    @Published var activeSessionOperations: Set<String> = []
    @Published var subscribingSessions: Set<String> = []
    @Published var respondingInteractions: Set<String> = []
    @Published var submittedInteractions: Set<String>
    @Published var resolvedInteractions: Set<String> = []
    @Published var sessionErrors: [String: String] = [:]
    @Published var createdSession: Session?
    @Published var acceptedMessage: AcceptedMessage?
    @Published private var imageRevision = 0
    @Published var error: String?
    private let deviceId: String
    private var macDeviceId: String?
    private var socket: URLSessionWebSocketTask?
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingTimeouts: [String: Task<Void, Never>] = [:]
    private var activeImageKeys: Set<String> = []
    private var sessionProjects: [String: String]
    private var sessionEventSequences: [String: Int]
    private var pendingEventInteractions: [String: Set<String>] = [:]
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 3
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    init() {
        sessionProjects = UserDefaults.standard.dictionary(forKey: "sessionProjects") as? [String: String] ?? [:]
        sessionEventSequences = [:]
        submittedInteractions = Set(UserDefaults.standard.stringArray(forKey: "submittedInteractions") ?? [])
        resolvedInteractions = Set(UserDefaults.standard.stringArray(forKey: "resolvedInteractions") ?? [])
        UserDefaults.standard.removeObject(forKey: "sessionEventSequences")
        if let id = UserDefaults.standard.string(forKey: "deviceId") { deviceId = id }
        else { let id = UUID().uuidString; deviceId = id; UserDefaults.standard.set(id, forKey: "deviceId") }
        if let server = UserDefaults.standard.string(forKey: "relayServer"), let token = CredentialStore.token(for: server) {
            paired = true; connect(server: server, token: token)
        }
    }

    func claim(qrValue: String) async {
        do {
            let payload = try JSONDecoder().decode(PairingPayload.self, from: Data(qrValue.utf8))
            guard payload.version == 1, let base = URL(string: payload.server), isSecure(base), let url = URL(string: "/pairing/claim", relativeTo: base) else { throw URLError(.badURL) }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["pairingId": payload.pairingId, "secret": payload.secret, "deviceId": deviceId, "name": UIDevice.current.name])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 else { throw URLError(.userAuthenticationRequired) }
            let claim = try JSONDecoder().decode(Claim.self, from: data)
            UserDefaults.standard.set(payload.server, forKey: "relayServer"); CredentialStore.save(claim.token, for: payload.server); paired = true
            connect(server: payload.server, token: claim.token)
        } catch { self.error = error.localizedDescription }
    }

    func requestProjects() {
        guard online, let macDeviceId else { return }
        send(type: "project.list", target: macDeviceId, payload: [:])
    }

    func requestSessions(projectId: String) {
        guard online, let macDeviceId else { sessionErrors[projectId] = "Mac is offline"; return }
        guard !loadingSessionProjects.contains(projectId) else { return }
        sessionErrors.removeValue(forKey: projectId)
        loadingSessionProjects.insert(projectId)
        send(type: "session.list", target: macDeviceId, projectId: projectId, payload: [:], pending: .sessionList(projectId))
    }

    func createSession(projectId: String, agentType: AgentType, initialTask: String) {
        let task = initialTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { sessionErrors[projectId] = "Enter an initial task"; return }
        guard online, let macDeviceId else { sessionErrors[projectId] = "Mac is offline"; return }
        let operation = "create:\(projectId)"
        guard !activeSessionOperations.contains(operation) else { return }
        sessionErrors.removeValue(forKey: projectId)
        activeSessionOperations.insert(operation)
        send(type: "session.create", target: macDeviceId, projectId: projectId,
             payload: ["agentType": agentType.rawValue, "initialTask": task], pending: .sessionCreate(projectId))
    }

    func openSession(_ session: Session) {
        sessionProjects[session.id] = session.projectId
        persistSessionCursors()
        subscribe(sessionId: session.id, projectId: session.projectId)
    }

    @discardableResult
    func sendMessage(session: Session, content: String) -> Bool {
        let message = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        guard online, let macDeviceId else { sessionErrors[session.id] = "Mac is offline"; return false }
        let operation = "send:\(session.id)"
        guard !activeSessionOperations.contains(operation) else { return false }
        sessionProjects[session.id] = session.projectId
        persistSessionCursors()
        sessionErrors.removeValue(forKey: session.id)
        activeSessionOperations.insert(operation)
        send(type: "session.sendMessage", target: macDeviceId, projectId: session.projectId, sessionId: session.id,
             payload: ["content": message, "afterSequence": sessionEventSequences[session.id] ?? -1], pending: .sessionSend(session.projectId, session.id, message))
        return true
    }

    func cancel(session: Session) {
        guard online, let macDeviceId else { sessionErrors[session.id] = "Mac is offline"; return }
        let operation = "cancel:\(session.id)"
        guard !activeSessionOperations.contains(operation) else { return }
        sessionErrors.removeValue(forKey: session.id)
        activeSessionOperations.insert(operation)
        send(type: "session.cancel", target: macDeviceId, projectId: session.projectId, sessionId: session.id,
             payload: [:], pending: .sessionCancel(session.projectId, session.id))
    }

    func respondToApproval(session: Session, interactionId: String, action: ApprovalAction) {
        respond(session: session, interactionId: interactionId,
                payload: ["kind": "approval", "interactionId": interactionId, "action": action.rawValue])
    }

    func respondToQuestion(session: Session, interactionId: String, optionIds: [String], freeText: String?) {
        var payload: [String: Any] = ["kind": "question", "interactionId": interactionId]
        if !optionIds.isEmpty { payload["optionIds"] = optionIds }
        if let freeText, !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["freeText"] = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard payload["optionIds"] != nil || payload["freeText"] != nil else { return }
        respond(session: session, interactionId: interactionId, payload: payload)
    }

    func isResponding(sessionId: String, interactionId: String) -> Bool {
        respondingInteractions.contains(interactionKey(sessionId: sessionId, interactionId: interactionId))
    }

    func isSubmitted(sessionId: String, interactionId: String) -> Bool {
        submittedInteractions.contains(interactionKey(sessionId: sessionId, interactionId: interactionId))
    }

    func isResolved(sessionId: String, interactionId: String) -> Bool {
        resolvedInteractions.contains(interactionKey(sessionId: sessionId, interactionId: interactionId))
    }

    func isHistoricallyResolved(sessionId: String, interactionId: String) -> Bool {
        historicallyResolvedInteractions.contains(interactionKey(sessionId: sessionId, interactionId: interactionId))
    }

    func status(for session: Session) -> SessionStatus { eventSessionStatuses[session.id] ?? session.status }

    func requestFiles(projectId: String, relativePath: String) {
        let key = fileKey(projectId: projectId, path: relativePath)
        guard online, let macDeviceId else { directoryErrors[key] = "Mac is offline"; return }
        guard !loadingPaths.contains(key) else { return }
        directoryErrors.removeValue(forKey: key)
        loadingPaths.insert(key)
        send(type: "project.listFiles", target: macDeviceId, projectId: projectId,
             payload: ["relativePath": relativePath], pending: .directory(key))
    }

    func requestFile(projectId: String, relativePath: String, binary: Bool) {
        let key = fileKey(projectId: projectId, path: relativePath)
        guard online, let macDeviceId else { fileErrors[key] = "Mac is offline"; return }
        let isCached = binary ? imageCache.object(forKey: key as NSString) != nil : fileContents[key] != nil
        guard !isCached, !loadingFiles.contains(key) else { return }
        fileErrors.removeValue(forKey: key)
        if binary { activeImageKeys.insert(key) }
        loadingFiles.insert(key)
        send(type: "project.readFile", target: macDeviceId, projectId: projectId,
             payload: ["relativePath": relativePath, "encoding": binary ? "base64" : "utf8"],
             pending: binary ? .image(key) : .text(key))
    }

    func requestImages(projectId: String, relativePath: String) {
        let key = fileKey(projectId: projectId, path: relativePath)
        guard online, let macDeviceId else { imageListErrors[key] = "Mac is offline"; return }
        guard imageLists[key] == nil, !loadingImageLists.contains(key) else { return }
        imageListErrors.removeValue(forKey: key)
        loadingImageLists.insert(key)
        send(type: "project.listImages", target: macDeviceId, projectId: projectId,
             payload: ["relativePath": relativePath], pending: .imageList(key))
    }

    func entries(projectId: String, path: String) -> [FileEntry]? { files[fileKey(projectId: projectId, path: path)] }
    func isLoading(projectId: String, path: String) -> Bool { loadingPaths.contains(fileKey(projectId: projectId, path: path)) }
    func fileContent(projectId: String, path: String) -> RemoteFileContent? { fileContents[fileKey(projectId: projectId, path: path)] }
    func imageList(projectId: String, path: String) -> RemoteImageList? { imageLists[fileKey(projectId: projectId, path: path)] }
    func image(projectId: String, path: String) -> UIImage? {
        _ = imageRevision
        return imageCache.object(forKey: fileKey(projectId: projectId, path: path) as NSString)
    }
    func directoryError(projectId: String, path: String) -> String? { directoryErrors[fileKey(projectId: projectId, path: path)] }
    func fileError(projectId: String, path: String) -> String? { fileErrors[fileKey(projectId: projectId, path: path)] }
    func imageListError(projectId: String, path: String) -> String? { imageListErrors[fileKey(projectId: projectId, path: path)] }
    func isLoadingFile(projectId: String, path: String) -> Bool { loadingFiles.contains(fileKey(projectId: projectId, path: path)) }
    func isLoadingImageList(projectId: String, path: String) -> Bool { loadingImageLists.contains(fileKey(projectId: projectId, path: path)) }
    func releaseImages(projectId: String, paths: [String]) {
        let keys = Set(paths.map { fileKey(projectId: projectId, path: $0) })
        let requestIds = pendingRequests.compactMap { id, pending -> String? in
            guard case let .image(key) = pending, keys.contains(key) else { return nil }
            return id
        }
        for id in requestIds { finishPending(id, error: nil) }
        for key in keys {
            activeImageKeys.remove(key)
            imageCache.removeObject(forKey: key as NSString)
        }
        imageRevision += 1
    }

    private func connect(server: String, token: String) {
        guard var parts = URLComponents(string: server) else { return }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"; parts.path = "/connect"; parts.queryItems = [.init(name: "deviceId", value: deviceId)]
        guard let url = parts.url else { return }; var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        socket?.cancel(); let task = URLSession.shared.webSocketTask(with: request); socket = task; task.resume(); receive(task, server: server, token: token)
    }

    private func receive(_ task: URLSessionWebSocketTask, server: String, token: String) {
        task.receive { [weak self] result in Task { @MainActor in
            guard let self, self.socket === task else { return }
            switch result {
            case let .success(message):
                let data: Data? = switch message { case let .data(value): value; case let .string(value): Data(value.utf8); @unknown default: nil }
                if let data { await self.handle(data) }
                self.receive(task, server: server, token: token)
            case .failure:
                self.online = false
                self.failAllPending(message: "Connection lost")
                if task.closeCode.rawValue == 4003 {
                    CredentialStore.delete(for: server); self.paired = false; self.projects = []; self.files = [:]
                    self.fileContents = [:]; self.imageLists = [:]; self.sessions = [:]; self.sessionEvents = [:]
                    self.sessionFeedItems = [:]; self.eventSessionStatuses = [:]; self.historicallyResolvedInteractions = []
                    self.pendingEventInteractions = [:]
                    self.sessionProjects = [:]; self.sessionEventSequences = [:]
                    self.submittedInteractions = []; self.resolvedInteractions = []
                    self.persistSessionCursors(); self.persistInteractionStates()
                    self.imageCache.removeAllObjects(); self.socket = nil; return
                }
                try? await Task.sleep(for: .seconds(1)); guard self.socket === task else { return }; self.connect(server: server, token: token)
            }
        } }
    }

    private func handle(_ data: Data) async {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = message["type"] as? String else { return }
        if type == "system.presence", let payload = message["payload"] as? [String: Any] {
            online = payload["online"] as? Bool ?? false
            macDeviceId = message["sourceDeviceId"] as? String
            if online { requestProjects(); resubscribeSessions() }
            else { failAllPending(message: "Mac is offline") }
            return
        }
        let replyTo = message["replyTo"] as? String
        if let replyTo, let pending = pendingRequests[replyTo],
           !matchesResponse(pending, type: type, source: message["sourceDeviceId"] as? String,
                            projectId: message["projectId"] as? String, sessionId: message["sessionId"] as? String) {
            finishPending(replyTo, error: "Invalid response")
            return
        }
        if message["ok"] as? Bool == false {
            let message = (message["error"] as? [String: Any])?["message"] as? String ?? "Project request failed"
            if let replyTo { finishPending(replyTo, error: message) }
            else { error = message }
            return
        }
        guard let payload = message["payload"], JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            if let replyTo { finishPending(replyTo, error: "Invalid response") }
            return
        }
        if type == "agent.event", let source = message["sourceDeviceId"] as? String,
           let projectId = message["projectId"] as? String, let sessionId = message["sessionId"] as? String,
           let value = payload as? [String: Any], let sequence = value["sequence"] as? Int,
           let event = try? JSONDecoder().decode(AgentEvent.self, from: payloadData) {
            if case .sessionCompleted = event { sessionProjects.removeValue(forKey: sessionId) }
            else { sessionProjects[sessionId] = projectId }
            var events = sessionEvents[sessionId] ?? []
            if events.last?.sequence == sequence {
                // A lost ACK can cause the Mac to redeliver the latest event.
            } else if events.last?.sequence ?? -1 < sequence {
                events.append(event)
                sessionEvents[sessionId] = events
                var feed = sessionFeedItems[sessionId] ?? []
                appendFeedEvent(event, to: &feed)
                sessionFeedItems[sessionId] = feed
                updateDerivedSessionState(event, sessionId: sessionId)
            } else if !events.contains(where: { $0.sequence == sequence }) {
                let index = events.firstIndex(where: { $0.sequence > sequence }) ?? events.endIndex
                events.insert(event, at: index)
                sessionEvents[sessionId] = events
                sessionFeedItems[sessionId] = feedItems(events)
                rebuildDerivedSessionState(sessionId: sessionId, events: events)
            }
            sessionEventSequences[sessionId] = max(sessionEventSequences[sessionId] ?? -1, sequence)
            persistSessionCursors()
            send(type: "agent.event.ack", target: source, projectId: projectId, sessionId: sessionId, payload: ["sequence": sequence])
            return
        }
        var handled = false
        if type == "project.list.response", let response = try? JSONDecoder().decode(ProjectListPayload.self, from: payloadData) {
            projects = response.projects; handled = true
        } else if type == "session.list.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(SessionListPayload.self, from: payloadData) {
            if let replyTo, case let .some(.sessionList(expectedProjectId)) = pendingRequests[replyTo], expectedProjectId == projectId {
                sessions[projectId] = response.sessions.sorted { $0.updatedAt > $1.updatedAt }
                handled = true
            }
        } else if type == "session.create.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(SessionCreatePayload.self, from: payloadData) {
            if let replyTo, case let .some(.sessionCreate(expectedProjectId)) = pendingRequests[replyTo], expectedProjectId == projectId {
                guard message["sessionId"] as? String == response.session.id else {
                    finishPending(replyTo, error: "Invalid response")
                    return
                }
                var values = sessions[projectId] ?? []
                values.removeAll { $0.id == response.session.id }
                values.insert(response.session, at: 0)
                sessions[projectId] = values
                createdSession = response.session
                openSession(response.session)
                handled = true
            }
        } else if type == "session.sendMessage.response" || type == "session.cancel.response" || type == "session.subscribe.response" || type == "interaction.respond.response" {
            handled = replyTo.flatMap { pendingRequests[$0] } != nil
        } else if type == "project.listFiles.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(FileListPayload.self, from: payloadData) {
            let key = fileKey(projectId: projectId, path: response.relativePath)
            if let replyTo, case let .some(.directory(expectedKey)) = pendingRequests[replyTo], expectedKey == key {
                files[key] = response.entries; handled = true
            }
        } else if type == "project.readFile.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(RemoteFileContent.self, from: payloadData) {
            let key = fileKey(projectId: projectId, path: response.relativePath)
            if let replyTo, response.encoding == .utf8,
               case let .some(.text(expectedKey)) = pendingRequests[replyTo], expectedKey == key {
                fileContents[key] = response
                handled = true
            } else if let replyTo, response.encoding == .base64,
                      case let .some(.image(expectedKey)) = pendingRequests[replyTo], expectedKey == key,
                      let decoded = await Task.detached(priority: .userInitiated, operation: { decodeImage(response.content) }).value {
                if activeImageKeys.contains(key) {
                    imageCache.setObject(decoded.image, forKey: key as NSString, cost: decoded.cost)
                    imageRevision += 1
                }
                handled = true
            }
        } else if type == "project.listImages.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(RemoteImageList.self, from: payloadData) {
            let key = fileKey(projectId: projectId, path: response.current.relativePath)
            if let replyTo, case let .some(.imageList(expectedKey)) = pendingRequests[replyTo], expectedKey == key {
                imageLists[key] = response; handled = true
            }
        }
        if let replyTo { finishPending(replyTo, error: handled ? nil : "Invalid response") }
    }

    private func send(type: String, target: String, projectId: String? = nil, sessionId: String? = nil,
                      payload: [String: Any], pending: PendingRequest? = nil) {
        let id = UUID().uuidString
        var message: [String: Any] = ["version": 1, "id": id, "type": type, "sourceDeviceId": deviceId,
                                      "targetDeviceId": target, "timestamp": ISO8601DateFormatter().string(from: Date()), "payload": payload]
        if let projectId { message["projectId"] = projectId }
        if let sessionId { message["sessionId"] = sessionId }
        if let pending {
            pendingRequests[id] = pending
            pendingTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.finishPending(id, error: "Request timed out")
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8), let socket else {
            if let pending { finishPending(id, error: "Not connected", clearInteractionSubmission: pending.isInteraction) }
            return
        }
        socket.send(.string(text)) { [weak self] sendError in
            guard let sendError else { return }
            Task { @MainActor in self?.finishPending(id, error: sendError.localizedDescription, clearInteractionSubmission: pending?.isInteraction == true) }
        }
    }

    private func finishPending(_ id: String, error message: String?, clearInteractionSubmission: Bool = false) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        switch pending {
        case let .directory(key):
            loadingPaths.remove(key)
            if let message { directoryErrors[key] = message }
        case let .text(key), let .image(key):
            loadingFiles.remove(key)
            if let message { fileErrors[key] = message }
        case let .imageList(key):
            loadingImageLists.remove(key)
            if let message { imageListErrors[key] = message }
        case let .sessionList(projectId):
            loadingSessionProjects.remove(projectId)
            if let message { sessionErrors[projectId] = message }
        case let .sessionCreate(projectId):
            activeSessionOperations.remove("create:\(projectId)")
            if let message { sessionErrors[projectId] = message }
        case let .sessionSend(_, sessionId, content):
            activeSessionOperations.remove("send:\(sessionId)")
            if let message { sessionErrors[sessionId] = message }
            else {
                eventSessionStatuses[sessionId] = .running
                acceptedMessage = AcceptedMessage(sessionId: sessionId, content: content)
            }
        case let .sessionCancel(_, sessionId):
            activeSessionOperations.remove("cancel:\(sessionId)")
            if let message { sessionErrors[sessionId] = message }
        case let .sessionSubscribe(_, sessionId):
            subscribingSessions.remove(sessionId)
            if let message { sessionErrors[sessionId] = message }
            else { sessionErrors.removeValue(forKey: sessionId) }
        case let .interaction(_, sessionId, interactionId):
            let key = interactionKey(sessionId: sessionId, interactionId: interactionId)
            respondingInteractions.remove(key)
            if let message, message.localizedCaseInsensitiveContains("not pending") {
                sessionErrors.removeValue(forKey: sessionId)
                submittedInteractions.remove(key)
                resolvedInteractions.insert(key)
            } else if let message {
                sessionErrors[sessionId] = message
                submittedInteractions.remove(key)
            }
            if clearInteractionSubmission { submittedInteractions.remove(key) }
            if message == nil {
                submittedInteractions.remove(key)
                resolvedInteractions.insert(key)
            }
            persistInteractionStates()
        }
    }

    private func failAllPending(message: String) {
        for id in Array(pendingRequests.keys) { finishPending(id, error: message) }
    }

    private func resubscribeSessions() {
        for (sessionId, projectId) in sessionProjects {
            subscribe(sessionId: sessionId, projectId: projectId)
        }
    }

    private func respond(session: Session, interactionId: String, payload: [String: Any]) {
        guard online, let macDeviceId else { sessionErrors[session.id] = "Mac is offline"; return }
        let key = interactionKey(sessionId: session.id, interactionId: interactionId)
        guard !respondingInteractions.contains(key), !resolvedInteractions.contains(key) else { return }
        sessionErrors.removeValue(forKey: session.id)
        respondingInteractions.insert(key)
        submittedInteractions.insert(key)
        persistInteractionStates()
        send(type: "interaction.respond", target: macDeviceId, projectId: session.projectId, sessionId: session.id,
             payload: payload, pending: .interaction(session.projectId, session.id, interactionId))
    }

    private func subscribe(sessionId: String, projectId: String) {
        guard online, let macDeviceId else { sessionErrors[sessionId] = "Mac is offline"; return }
        guard !subscribingSessions.contains(sessionId) else { return }
        subscribingSessions.insert(sessionId)
        sessionErrors.removeValue(forKey: sessionId)
        let afterSequence = sessionEvents[sessionId]?.last?.sequence ?? -1
        send(type: "session.subscribe", target: macDeviceId, projectId: projectId, sessionId: sessionId,
             payload: ["afterSequence": afterSequence], pending: .sessionSubscribe(projectId, sessionId))
    }

    private func persistSessionCursors() {
        UserDefaults.standard.set(sessionProjects, forKey: "sessionProjects")
    }

    private func persistInteractionStates() {
        UserDefaults.standard.set(Array(submittedInteractions), forKey: "submittedInteractions")
        UserDefaults.standard.set(Array(resolvedInteractions), forKey: "resolvedInteractions")
    }

    private func updateDerivedSessionState(_ event: AgentEvent, sessionId: String) {
        switch event {
        case let .status(value):
            eventSessionStatuses[sessionId] = switch value.status { case .running: .running; case .idle: .idle; case .waitingUser: .waitingUser }
            if value.status == .running || value.status == .idle { resolvePendingEventInteractions(sessionId: sessionId) }
        case .turnCompleted:
            eventSessionStatuses[sessionId] = .idle
            resolvePendingEventInteractions(sessionId: sessionId)
        case let .sessionCompleted(value):
            eventSessionStatuses[sessionId] = switch value.outcome { case .completed: .completed; case .failed: .failed; case .cancelled: .cancelled }
            resolvePendingEventInteractions(sessionId: sessionId)
        case let .approvalRequested(value):
            pendingEventInteractions[sessionId, default: []].insert(interactionKey(sessionId: sessionId, interactionId: value.interactionId))
        case let .questionRequested(value):
            pendingEventInteractions[sessionId, default: []].insert(interactionKey(sessionId: sessionId, interactionId: value.interactionId))
        default: break
        }
    }

    private func rebuildDerivedSessionState(sessionId: String, events: [AgentEvent]) {
        eventSessionStatuses.removeValue(forKey: sessionId)
        pendingEventInteractions[sessionId] = []
        historicallyResolvedInteractions = Set(historicallyResolvedInteractions.filter { !$0.hasPrefix("\(sessionId):") })
        for event in events { updateDerivedSessionState(event, sessionId: sessionId) }
    }

    private func resolvePendingEventInteractions(sessionId: String) {
        historicallyResolvedInteractions.formUnion(pendingEventInteractions[sessionId] ?? [])
        pendingEventInteractions[sessionId] = []
    }

    private func matchesResponse(_ pending: PendingRequest, type: String, source: String?, projectId: String?, sessionId: String?) -> Bool {
        guard type == pending.responseType, source == macDeviceId else { return false }
        switch pending {
        case .directory, .text, .image, .imageList:
            return projectId != nil
        case let .sessionList(expectedProjectId), let .sessionCreate(expectedProjectId):
            return projectId == expectedProjectId
        case let .sessionSend(expectedProjectId, expectedSessionId, _), let .sessionCancel(expectedProjectId, expectedSessionId):
            return projectId == expectedProjectId && sessionId == expectedSessionId
        case let .sessionSubscribe(expectedProjectId, expectedSessionId):
            return projectId == expectedProjectId && sessionId == expectedSessionId
        case let .interaction(expectedProjectId, expectedSessionId, _):
            return projectId == expectedProjectId && sessionId == expectedSessionId
        }
    }

    private func fileKey(projectId: String, path: String) -> String { "\(projectId):\(path)" }
    private func interactionKey(sessionId: String, interactionId: String) -> String { "\(sessionId):\(interactionId)" }
}


private func decodeImage(_ base64: String) -> DecodedImage? {
    guard let data = Data(base64Encoded: base64),
          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceShouldCacheImmediately: true,
              kCGImageSourceThumbnailMaxPixelSize: 2048,
          ] as CFDictionary) else { return nil }
    return .init(image: UIImage(cgImage: image), cost: image.bytesPerRow * image.height)
}

private func isSecure(_ url: URL) -> Bool { url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")) }
