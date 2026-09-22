import AVFoundation
import AgentIDEProtocol
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

@MainActor
final class MobileConnection: ObservableObject {
    struct Claim: Decodable { let token: String }
    @Published var online = false
    @Published var paired = false
    @Published var projects: [RemoteProject] = []
    @Published var files: [String: [FileEntry]] = [:]
    @Published var loadingPaths: Set<String> = []
    @Published var error: String?
    private let deviceId: String
    private var macDeviceId: String?
    private var socket: URLSessionWebSocketTask?

    init() {
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
        guard let macDeviceId else { return }
        send(type: "project.list", target: macDeviceId, payload: [:])
    }

    func requestFiles(projectId: String, relativePath: String) {
        guard let macDeviceId else { return }
        let key = fileKey(projectId: projectId, path: relativePath)
        loadingPaths.insert(key)
        send(type: "project.listFiles", target: macDeviceId, projectId: projectId, payload: ["relativePath": relativePath])
    }

    func entries(projectId: String, path: String) -> [FileEntry]? { files[fileKey(projectId: projectId, path: path)] }
    func isLoading(projectId: String, path: String) -> Bool { loadingPaths.contains(fileKey(projectId: projectId, path: path)) }

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
                if let data { self.handle(data) }
                self.receive(task, server: server, token: token)
            case .failure:
                self.online = false
                if task.closeCode.rawValue == 4003 {
                    CredentialStore.delete(for: server); self.paired = false; self.projects = []; self.files = [:]; self.socket = nil; return
                }
                try? await Task.sleep(for: .seconds(1)); guard self.socket === task else { return }; self.connect(server: server, token: token)
            }
        } }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = message["type"] as? String else { return }
        if type == "system.presence", let payload = message["payload"] as? [String: Any] {
            online = payload["online"] as? Bool ?? false
            macDeviceId = message["sourceDeviceId"] as? String
            if online { requestProjects() }
            return
        }
        if message["ok"] as? Bool == false {
            error = (message["error"] as? [String: Any])?["message"] as? String ?? "Project request failed"
            loadingPaths.removeAll()
            return
        }
        guard let payload = message["payload"], JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if type == "project.list.response", let response = try? JSONDecoder().decode(ProjectListPayload.self, from: payloadData) {
            projects = response.projects
        } else if type == "project.listFiles.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(FileListPayload.self, from: payloadData) {
            let key = fileKey(projectId: projectId, path: response.relativePath)
            files[key] = response.entries; loadingPaths.remove(key)
        }
    }

    private func send(type: String, target: String, projectId: String? = nil, payload: [String: Any]) {
        var message: [String: Any] = ["version": 1, "id": UUID().uuidString, "type": type, "sourceDeviceId": deviceId,
                                      "targetDeviceId": target, "timestamp": ISO8601DateFormatter().string(from: Date()), "payload": payload]
        if let projectId { message["projectId"] = projectId }
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func fileKey(projectId: String, path: String) -> String { "\(projectId):\(path)" }
}

private func isSecure(_ url: URL) -> Bool { url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")) }
