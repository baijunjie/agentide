import AVFoundation
import Security
import SwiftUI
import UIKit

enum MobileFailureCopy {
    static func message(_ message: String, code: String? = nil) -> String {
        let timedOut = code == "TIMEOUT" || message == "Request timed out"
        return timedOut ? "\(message). You can try again." : message
    }
}

enum FileRowPresentation {
    /// The root row's relative path repeats the name. A nested path still says where the file is.
    static func subtitle(name: String, relativePath: String) -> String? {
        relativePath == name ? nil : relativePath
    }
}

enum CredentialStore {
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

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.onCode = onCode; return controller }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; preview.frame = view.bounds; view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        session.stopRunning(); onCode?(value)
    }
}
