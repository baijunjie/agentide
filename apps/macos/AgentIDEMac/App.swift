import CoreImage.CIFilterBuiltins
import Security
import SwiftUI

@main
struct AgentIDEMacApp: App {
    @StateObject private var connection = MacConnection()
    var body: some Scene { WindowGroup { MacHomeView().environmentObject(connection) } }
}

@MainActor
private final class MacConnection: ObservableObject {
    struct Pairing: Decodable { let expiresAt: String; let qrPayload: String; let secret: String }
    struct Device: Decodable, Identifiable { let id: String; let name: String; let online: Bool }
    struct DeviceList: Decodable { let devices: [Device] }
    struct Registration: Decodable { let token: String }
    @Published var server = UserDefaults.standard.string(forKey: "relayServer") ?? "http://127.0.0.1:8787"
    @Published var pairing: Pairing?
    @Published var devices: [Device] = []
    @Published var error: String?
    @Published var connectionState = "Offline"
    private let deviceId: String
    private var token: String?
    private var socket: URLSessionWebSocketTask?

    init() {
        if let id = UserDefaults.standard.string(forKey: "deviceId") { deviceId = id }
        else { let id = UUID().uuidString; deviceId = id; UserDefaults.standard.set(id, forKey: "deviceId") }
        token = CredentialStore.token(for: server)
        if token != nil {
            Task { [weak self] in
                self?.connect()
                await self?.refreshDevices()
            }
        }
    }
    func preparePairing() async {
        do {
            guard let relayURL = URL(string: server), isSecure(relayURL) else { throw URLError(.secureConnectionFailed) }
            UserDefaults.standard.set(server, forKey: "relayServer")
            token = CredentialStore.token(for: server)
            if token == nil {
                let body = ["deviceId": deviceId, "name": Host.current().localizedName ?? "Mac", "kind": "mac"]
                let registration: Registration = try await request("/devices/register", method: "POST", body: body, authenticated: false)
                token = registration.token; CredentialStore.save(registration.token, for: server)
            }
            pairing = try await request("/pairing/sessions", method: "POST", body: [String: String](), authenticated: true)
            connect(); await refreshDevices()
        } catch { self.error = error.localizedDescription }
    }
    func refreshDevices() async {
        do { let list: DeviceList = try await request("/devices", method: "GET", body: Optional<String>.none, authenticated: true); devices = list.devices; connectionState = "Connected" }
        catch { self.error = error.localizedDescription; connectionState = "Offline" }
    }
    func revoke(_ device: Device) async {
        do {
            let _: EmptyResponse = try await request("/devices/\(device.id)", method: "DELETE", body: Optional<String>.none, authenticated: true)
            await refreshDevices()
        } catch { self.error = error.localizedDescription }
    }
    private func connect() {
        guard let token, var parts = URLComponents(string: server) else { return }
        connectionState = "Connecting"
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"; parts.path = "/connect"; parts.queryItems = [.init(name: "deviceId", value: deviceId)]
        guard let url = parts.url else { return }; var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        socket?.cancel()
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(task)
    }
    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in Task { @MainActor in
            guard let self else { return }
            guard self.socket === task else { return }
            if case .success = result { await self.refreshDevices(); self.receive(task) }
            else { self.connectionState = "Offline"; try? await Task.sleep(for: .seconds(1)); guard self.socket === task else { return }; self.connect() }
        } }
    }
    private func request<Response: Decodable, Body: Encodable>(_ path: String, method: String, body: Body?, authenticated: Bool) async throws -> Response {
        guard let base = URL(string: server), let url = URL(string: path, relativeTo: base) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.httpMethod = method
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated, let token { request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.userAuthenticationRequired) }
        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct EmptyResponse: Codable {}

private func isSecure(_ url: URL) -> Bool {
    url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost"))
}

private struct MacHomeView: View {
    @EnvironmentObject private var connection: MacConnection
    var body: some View {
        NavigationSplitView {
            List {
                Label("Pairing", systemImage: "link")
                // TODO: Replace this placeholder with the registered project overview in milestone 03.
                Label("Projects", systemImage: "folder")
            }.navigationTitle("AgentIDE")
        } detail: {
            VStack(spacing: 18) {
                Text("Pair iPhone").font(.largeTitle.bold())
                Label(connection.connectionState, systemImage: connection.connectionState == "Connected" ? "network" : "network.slash")
                TextField("Relay server", text: $connection.server).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                if let pairing = connection.pairing {
                    QRCode(value: pairing.qrPayload).frame(width: 220, height: 220)
                    Text(pairing.secret.prefix(8)).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let expiry = ISO8601DateFormatter().date(from: pairing.expiresAt) ?? context.date
                        Text("Expires in \(max(0, Int(expiry.timeIntervalSince(context.date)))) seconds").foregroundStyle(.secondary)
                    }
                }
                Button(connection.pairing == nil ? "Create Pairing Code" : "Refresh Pairing Code") { Task { await connection.preparePairing() } }.buttonStyle(.borderedProminent)
                ForEach(connection.devices) { device in
                    HStack {
                        Label("\(device.name) — \(device.online ? "Connected" : "Offline")", systemImage: device.online ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                        Button("Revoke") { Task { await connection.revoke(device) } }
                    }
                }
                if let error = connection.error { Text(error).foregroundStyle(.red) }
            }.padding(36)
        }.frame(minWidth: 760, minHeight: 560)
    }
}

private enum CredentialStore {
    static func token(for server: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.agentide.relay", kSecAttrAccount as String: key(for: server), kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, for server: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.agentide.relay", kSecAttrAccount as String: key(for: server)]
        SecItemDelete(query as CFDictionary)
        var value = query; value[kSecValueData as String] = Data(token.utf8); SecItemAdd(value as CFDictionary, nil)
    }
    private static func key(for server: String) -> String {
        guard let parts = URLComponents(string: server), let scheme = parts.scheme, let host = parts.host else { return server }
        return "\(scheme.lowercased())://\(host.lowercased())\(parts.port.map { ":\($0)" } ?? "")"
    }
}

private struct QRCode: View {
    let value: String
    var body: some View { if let image { Image(nsImage: image).interpolation(.none).resizable() } else { Color.secondary } }
    private var image: NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 10, y: 10)), let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
