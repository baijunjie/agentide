import AppKit
import CoreImage.CIFilterBuiltins
import Security
import SwiftUI

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
    private static func key(for server: String) -> String {
        guard let parts = URLComponents(string: server), let scheme = parts.scheme, let host = parts.host else { return server }
        return "\(scheme.lowercased())://\(host.lowercased())\(parts.port.map { ":\($0)" } ?? "")"
    }
}

struct QRCode: View {
    let value: String
    var body: some View { if let image { Image(nsImage: image).interpolation(.none).resizable() } else { Color.secondary } }
    private var image: NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 10, y: 10)), let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
