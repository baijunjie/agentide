import AVFoundation
import Security
import SwiftUI

@main
struct AgentIDEiOSApp: App {
    @StateObject private var connection = MobileConnection()
    var body: some Scene { WindowGroup { MobileHomeView().environmentObject(connection) } }
}

private struct PairingPayload: Codable { let version: Int; let server: String; let pairingId: String; let secret: String }

@MainActor
private final class MobileConnection: ObservableObject {
    struct Claim: Decodable { let token: String }
    @Published var online = false
    @Published var paired = false
    @Published var error: String?
    private let deviceId: String
    private var socket: URLSessionWebSocketTask?
    init() {
        if let id = UserDefaults.standard.string(forKey: "deviceId") { deviceId = id }
        else { let id = UUID().uuidString; deviceId = id; UserDefaults.standard.set(id, forKey: "deviceId") }
        if let server = UserDefaults.standard.string(forKey: "relayServer"), let token = CredentialStore.token(for: server) { paired = true; connect(server: server, token: token) }
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
    private func connect(server: String, token: String) {
        guard var parts = URLComponents(string: server) else { return }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"; parts.path = "/connect"; parts.queryItems = [.init(name: "deviceId", value: deviceId)]
        guard let url = parts.url else { return }; var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        socket?.cancel()
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(task, server: server, token: token)
    }
    private func receive(_ task: URLSessionWebSocketTask, server: String, token: String) {
        task.receive { [weak self] result in Task { @MainActor in
            guard let self else { return }
            guard self.socket === task else { return }
            switch result {
            case let .success(message):
                let data: Data? = switch message { case let .data(value): value; case let .string(value): Data(value.utf8); @unknown default: nil }
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["type"] as? String == "system.presence", let payload = json["payload"] as? [String: Any] { self.online = payload["online"] as? Bool ?? false }
                self.receive(task, server: server, token: token)
            case .failure:
                self.online = false
                if task.closeCode.rawValue == 4003 {
                    CredentialStore.delete(for: server); self.paired = false; self.socket = nil; return
                }
                try? await Task.sleep(for: .seconds(1)); guard self.socket === task else { return }; self.connect(server: server, token: token)
            }
        } }
    }
}

private struct MobileHomeView: View {
    @EnvironmentObject private var connection: MobileConnection
    @State private var scanning = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: connection.online ? "desktopcomputer.and.macbook" : "desktopcomputer").font(.system(size: 72)).foregroundStyle(connection.online ? .green : .secondary)
                Text(!connection.paired ? "No Mac paired" : connection.online ? "Mac Online" : "Mac Offline").font(.title.bold())
                Button("Scan Pairing QR") { scanning = true }.buttonStyle(.borderedProminent)
                if let error = connection.error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("AgentIDE").sheet(isPresented: $scanning) {
                QRScanner { value in scanning = false; Task { await connection.claim(qrValue: value) } }.ignoresSafeArea()
            }
        }
    }
}

private func isSecure(_ url: URL) -> Bool {
    url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost"))
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
    static func delete(for server: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.agentide.relay", kSecAttrAccount as String: key(for: server)]
        SecItemDelete(query as CFDictionary)
    }
    private static func key(for server: String) -> String {
        guard let parts = URLComponents(string: server), let scheme = parts.scheme, let host = parts.host else { return server }
        return "\(scheme.lowercased())://\(host.lowercased())\(parts.port.map { ":\($0)" } ?? "")"
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.onCode = onCode; return controller }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

private final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input); let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }; session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; preview.frame = view.bounds; view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }; session.stopRunning(); onCode?(value)
    }
}
