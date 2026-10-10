import Darwin
import Foundation
import Security

struct TranslationConnection: Equatable {
    let serverURL: URL
    let token: String

    init(address: String, token: String) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65_535).contains(parts.port!) else { throw TranslationError.invalidAddress }
        if scheme == "http", !Self.isLocalHost(host) { throw TranslationError.insecureAddress }
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !cleanToken.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TranslationError.missingToken
        }
        parts.scheme = scheme
        parts.path = ""
        guard let url = parts.url else { throw TranslationError.invalidAddress }
        serverURL = url
        self.token = cleanToken
    }

    static func isLocalHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
           let a = Int(pieces[0]), let b = Int(pieces[1]), let c = Int(pieces[2]), let d = Int(pieces[3]),
           [a, b, c, d].allSatisfy({ (0...255).contains($0) }) {
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168) || (a == 169 && b == 254)
        }
        if host.contains(":") {
            let address = host.components(separatedBy: "%").first ?? host
            var buffer = in6_addr()
            guard address.withCString({ inet_pton(AF_INET6, $0, &buffer) }) == 1 else { return false }
            let bytes = withUnsafeBytes(of: buffer) { Array($0) }
            return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
                || (bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1)
        }
        // A single-label PC name is local; numeric shorthand and hexadecimal IPs are excluded.
        return !host.contains(".") && !host.hasPrefix("0x") && host.contains(where: { $0.isLetter })
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

enum TranslationError: LocalizedError {
    case invalidAddress, insecureAddress, missingToken, keychain(OSStatus), invalidResponse, unsupportedProtocol
    case unauthorized, missingJob, tooLarge, server(String), invalidPDF, cancelled, connectionLost

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Nhập địa chỉ PC dạng http://192.168.1.10:8765, không thêm đường dẫn, tài khoản hoặc tham số."
        case .insecureAddress: return "HTTP chỉ dùng cho PC trong mạng nội bộ. Địa chỉ ngoài mạng nội bộ phải dùng HTTPS có chứng chỉ hợp lệ."
        case .missingToken: return "Nhập mã ghép nối hiển thị trong ScanPDF PC."
        case .keychain: return "Không thể truy cập mã ghép nối trong Keychain. Hãy mở khóa thiết bị rồi thử lại."
        case .invalidResponse: return "PC trả về phản hồi không hợp lệ. Hãy cập nhật ScanPDF trên cả hai thiết bị."
        case .unsupportedProtocol: return "Máy chủ không phải ScanPDF PC tương thích với phiên bản này."
        case .unauthorized: return "Mã ghép nối không đúng hoặc đã đổi trên PC. Hãy nhập lại mã."
        case .missingJob: return "PC không còn tác vụ này. Tác vụ có thể đã được dọn hoặc PC đã khởi động lại."
        case .tooLarge: return "PDF vượt giới hạn 100 MB của máy chủ. Hãy chọn tài liệu nhỏ hơn."
        case .server(let detail): return String(detail.prefix(800))
        case .invalidPDF: return "Bản dịch tải về không phải PDF hợp lệ. Tài liệu gốc vẫn được giữ trong thư viện."
        case .cancelled: return "Đã hủy dịch."
        case .connectionLost: return "Chưa kết nối được PC. Kiểm tra cùng Wi-Fi, máy chủ đang chạy, tường lửa và quyền Mạng cục bộ trong Cài đặt iOS."
        }
    }
}

/// The pairing token is bound to its server origin and stored only in this device's Keychain.
enum TranslationConnectionStore {
    private static let service = "com.duckk37.scanpdf.translation"
    private static let account = "paired-server"
    private static let addressKey = "translation.serverAddress"

    static var savedAddress: String { UserDefaults.standard.string(forKey: addressKey) ?? "" }

    static func load() throws -> TranslationConnection? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TranslationError.keychain(status) }
        guard let data = result as? Data, let secret = try? JSONDecoder().decode(StoredConnection.self, from: data),
              secret.address == savedAddress else { return nil }
        return try TranslationConnection(address: secret.address, token: secret.token)
    }

    static func save(_ connection: TranslationConnection) throws {
        let address = connection.serverURL.absoluteString
        let data = try JSONEncoder().encode(StoredConnection(address: address, token: connection.token))
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw TranslationError.keychain(added) }
        } else if status != errSecSuccess { throw TranslationError.keychain(status) }
        UserDefaults.standard.set(address, forKey: addressKey)
    }

    static func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TranslationError.keychain(status) }
        UserDefaults.standard.removeObject(forKey: addressKey)
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private struct StoredConnection: Codable { let address: String; let token: String }
}
