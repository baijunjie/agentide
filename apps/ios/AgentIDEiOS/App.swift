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

@MainActor
final class MobileConnection: ObservableObject {
    struct Claim: Decodable { let token: String }
    private enum PendingRequest {
        case directory(String)
        case text(String)
        case image(String)
        case imageList(String)
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
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 3
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    init() {
        sessionProjects = UserDefaults.standard.dictionary(forKey: "sessionProjects") as? [String: String] ?? [:]
        sessionEventSequences = UserDefaults.standard.dictionary(forKey: "sessionEventSequences") as? [String: Int] ?? [:]
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
                    self.fileContents = [:]; self.imageLists = [:]; self.imageCache.removeAllObjects(); self.socket = nil; return
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
            switch event {
            case .turnCompleted, .sessionCompleted: sessionProjects.removeValue(forKey: sessionId)
            default: sessionProjects[sessionId] = projectId
            }
            sessionEventSequences[sessionId] = max(sessionEventSequences[sessionId] ?? -1, sequence)
            UserDefaults.standard.set(sessionProjects, forKey: "sessionProjects")
            UserDefaults.standard.set(sessionEventSequences, forKey: "sessionEventSequences")
            send(type: "agent.event.ack", target: source, projectId: projectId, sessionId: sessionId, payload: ["sequence": sequence])
            return
        }
        var handled = false
        if type == "project.list.response", let response = try? JSONDecoder().decode(ProjectListPayload.self, from: payloadData) {
            projects = response.projects; handled = true
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
            if pending != nil { finishPending(id, error: "Not connected") }
            return
        }
        socket.send(.string(text)) { [weak self] sendError in
            guard let sendError else { return }
            Task { @MainActor in self?.finishPending(id, error: sendError.localizedDescription) }
        }
    }

    private func finishPending(_ id: String, error message: String?) {
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
        }
    }

    private func failAllPending(message: String) {
        for id in Array(pendingRequests.keys) { finishPending(id, error: message) }
    }

    private func resubscribeSessions() {
        guard let macDeviceId else { return }
        for (sessionId, projectId) in sessionProjects {
            send(type: "session.subscribe", target: macDeviceId, projectId: projectId, sessionId: sessionId,
                 payload: ["afterSequence": sessionEventSequences[sessionId] ?? -1])
        }
    }

    private func fileKey(projectId: String, path: String) -> String { "\(projectId):\(path)" }
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
