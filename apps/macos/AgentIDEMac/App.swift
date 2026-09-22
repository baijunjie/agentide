import AgentIDEProtocol
import AppKit
import CoreImage.CIFilterBuiltins
import Security
import SwiftUI

@main
struct AgentIDEMacApp: App {
    @StateObject private var connection = MacConnection()
    var body: some Scene { WindowGroup { MacHomeView().environmentObject(connection) } }
}

@MainActor
final class MacConnection: ObservableObject {
    struct Pairing: Decodable { let expiresAt: String; let qrPayload: String; let secret: String }
    struct Device: Decodable, Identifiable { let id: String; let name: String; let online: Bool }
    struct DeviceList: Decodable { let devices: [Device] }
    struct Registration: Decodable { let token: String }
    struct ProjectList: Decodable { let projects: [Project] }
    struct FileList: Decodable { let entries: [FileEntry] }

    @Published var server = UserDefaults.standard.string(forKey: "relayServer") ?? "http://127.0.0.1:8787"
    @Published var pairing: Pairing?
    @Published var devices: [Device] = []
    @Published var projects: [Project] = []
    @Published var error: String?
    @Published var connectionState = "Offline"
    private let deviceId: String
    private var token: String?
    private var socket: URLSessionWebSocketTask?
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
        if type == "system.presence" { await refreshDevices(); return }
        guard let requestId = message["id"] as? String, let source = message["sourceDeviceId"] as? String else { return }
        if type == "project.list" {
            do {
                projects = try await loadProjects()
                sendResponse(to: source, replyTo: requestId, type: "project.list.response", payload: ["projects": projects.map(publicProject)])
            } catch {
                sendResponse(to: source, replyTo: requestId, type: "project.list.response", error: error.localizedDescription)
            }
        } else if type == "project.listFiles", let projectId = message["projectId"] as? String,
                  let payload = message["payload"] as? [String: Any], let path = payload["relativePath"] as? String {
            do {
                let list: FileList = try await hostRequest("/projects/\(projectId)/files/list", method: "POST", body: ["relativePath": path])
                let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list.entries))
                sendResponse(to: source, replyTo: requestId, type: "project.listFiles.response", projectId: projectId, payload: ["relativePath": path, "entries": entries])
            } catch { sendResponse(to: source, replyTo: requestId, type: "project.listFiles.response", projectId: projectId, error: error.localizedDescription) }
        }
    }

    private func publicProject(_ project: Project) -> [String: Any] {
        ["id": project.id, "name": project.name, "createdAt": project.createdAt, "enabledAgents": project.enabledAgents.map(\.rawValue), "online": connectionState == "Connected"]
    }

    private func loadProjects() async throws -> [Project] {
        let list: ProjectList = try await hostRequest("/projects", method: "GET", body: Optional<String>.none)
        return list.projects
    }

    private func sendResponse(to target: String, replyTo: String, type: String, projectId: String? = nil, payload: [String: Any]? = nil, error: String? = nil) {
        var value: [String: Any] = ["version": 1, "id": UUID().uuidString, "type": type, "sourceDeviceId": deviceId, "targetDeviceId": target,
                                    "timestamp": ISO8601DateFormatter().string(from: Date()), "replyTo": replyTo, "ok": error == nil]
        if let projectId { value["projectId"] = projectId }
        if let error {
            value["payload"] = NSNull()
            value["error"] = ["code": "project_request_failed", "message": error]
        } else if let payload { value["payload"] = payload }
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
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
private struct ErrorResponse: Decodable { let error: String }
private func isSecure(_ url: URL) -> Bool { url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")) }
