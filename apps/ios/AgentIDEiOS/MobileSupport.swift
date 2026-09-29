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

enum PathWrapping {
    /// `Sources/App.swift:12:5` becomes `Sources/`, `App.swift`, `:12`, `:5`. A line may break only between these parts.
    static func parts(_ path: String) -> [String] {
        var parts: [String] = []
        var segment = ""
        func flushBeforeColon() {
            if !segment.isEmpty { parts.append(segment) }
            segment = ":"
        }
        for character in path {
            if character == "/" {
                segment.append("/")
                parts.append(segment)
                segment = ""
            } else if character == ":" {
                flushBeforeColon()
            } else {
                segment.append(character)
            }
        }
        if !segment.isEmpty { parts.append(segment) }
        return parts
    }

    /// U+2060 keeps a part intact. U+200B sits after `/` and before `:`, which are the only break opportunities.
    static func display(_ path: String) -> String {
        parts(path).map { part in
            part.map { String($0) }.joined(separator: "\u{2060}")
        }.joined(separator: "\u{200B}")
    }
}

struct WrappingPath: View {
    let path: String

    var body: some View {
        PathSegmentLayout {
            ForEach(Array(PathWrapping.parts(path).enumerated()), id: \.offset) { _, part in
                Text(part).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(path)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct PathSegmentLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + size.width > maxWidth {
                totalHeight += rowHeight
                widest = max(widest, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        widest = max(widest, rowWidth)
        return CGSize(width: proposal.width == nil ? widest : min(maxWidth, widest), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX + 0.5 {
                x = bounds.minX
                y += rowHeight
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
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

struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hasPreview = false
    let onCode: (String) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScanner(hasPreview: $hasPreview, onCode: onCode).ignoresSafeArea()
            if !hasPreview {
                ContentUnavailableView(
                    "No Camera Preview",
                    systemImage: "camera.fill",
                    description: Text("This device is not showing a camera picture, so a pairing code cannot be scanned from here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            .padding()
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    @Binding var hasPreview: Bool
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onPreviewChange = { hasPreview = $0 }
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onPreviewChange: ((Bool) -> Void)?
    private let session = AVCaptureSession()
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            DispatchQueue.main.async { self.onPreviewChange?(false) }
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; preview.frame = view.bounds; view.layer.addSublayer(preview)
        DispatchQueue.main.async { self.onPreviewChange?(true) }
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        session.stopRunning(); onCode?(value)
    }
}
