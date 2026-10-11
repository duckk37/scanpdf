import Foundation

enum GeminiAssistantMode: String, Encodable, CaseIterable, Identifiable {
    case summary, question, explain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .summary: return "Tóm tắt"
        case .question: return "Hỏi đáp"
        case .explain: return "Giải thích"
        }
    }
}

struct GeminiAssistantResponse: Decodable {
    let answer: String
    let pages: [Int]
    let model: String
    let pageCount: Int
}

enum GeminiAssistantError: LocalizedError {
    case consentRequired, invalidQuestion, tooLarge, tooManyPages, invalidResponse, unavailable, server(String)
    var errorDescription: String? {
        switch self {
        case .consentRequired: return "Đồng ý gửi PDF tới Google qua PC trước khi sử dụng Gemini."
        case .invalidQuestion: return "Câu hỏi cần từ 1 đến 3.000 ký tự. Nội dung muốn giải thích có thể để trống, tối đa 3.000 ký tự."
        case .tooLarge: return "Gemini nhận PDF tối đa 10 MB mỗi lần. Hãy trích các trang cần hỏi thành PDF nhỏ hơn."
        case .tooManyPages: return "Gemini nhận tối đa 60 trang mỗi lần. Hãy trích phần tài liệu cần hỏi."
        case .invalidResponse: return "PC trả về câu trả lời Gemini không hợp lệ. Hãy cập nhật ScanPDF trên cả hai thiết bị."
        case .unavailable: return "Gemini chưa sẵn sàng. Mở ScanPDF PC, cấu hình API key Gemini và bật máy chủ Wi-Fi."
        case .server(let message): return String(message.prefix(800))
        }
    }
}

protocol GeminiAssistantServicing {
    func answer(pdf: URL, mode: GeminiAssistantMode, question: String) async throws -> GeminiAssistantResponse
}

final class GeminiAssistantClient: GeminiAssistantServicing {
    static let maxUploadBytes = 10 * 1_024 * 1_024
    private let connection: TranslationConnection
    private let session: URLSession
    private let transport: TranslationSessionDelegate

    init(connection: TranslationConnection, configuration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection
        transport = TranslationSessionDelegate(uploadProgress: nil)
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 150
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: transport, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func answer(pdf: URL, mode: GeminiAssistantMode, question: String) async throws -> GeminiAssistantResponse {
        let cleanQuestion = try Self.validatedQuestion(mode: mode, question: question)
        let pageCount = try await Task.detached(priority: .userInitiated) {
            let size = try pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maxUploadBytes else { throw GeminiAssistantError.tooLarge }
            let document = try PDFService.open(url: pdf)
            guard document.pageCount <= 60 else { throw GeminiAssistantError.tooManyPages }
            return document.pageCount
        }.value
        try Task.checkCancellation()
        struct Options: Encodable { let mode: GeminiAssistantMode; let question: String }
        let options = try JSONEncoder().encode(Options(mode: mode, question: cleanQuestion))
        var request = URLRequest(url: connection.serverURL.appendingPathComponent("assistant"))
        request.httpMethod = "POST"
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(connection.token, forHTTPHeaderField: "X-Pair-Token")
        request.setValue(options.base64EncodedString(), forHTTPHeaderField: "X-Assistant-Options")
        // One explicit request per button press. No application-level retry or provider key is sent from iOS.
        let (data, response) = try await session.upload(for: request, fromFile: pdf)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else { throw GeminiAssistantError.invalidResponse }
        switch response.statusCode {
        case 200...299: break
        case 401: throw TranslationError.unauthorized
        case 413: throw GeminiAssistantError.tooLarge
        case 503: throw GeminiAssistantError.unavailable
        default:
            struct Failure: Decodable { let detail: String }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) { throw GeminiAssistantError.server(failure.detail) }
            throw GeminiAssistantError.server("PC trả về lỗi HTTP \(response.statusCode). Kiểm tra Gemini trong ScanPDF PC rồi thử lại.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(GeminiAssistantResponse.self, from: data),
              reply.pageCount == pageCount, (1...60).contains(reply.pageCount),
              reply.pages.count <= 60, Set(reply.pages).count == reply.pages.count,
              reply.pages.allSatisfy({ (1...reply.pageCount).contains($0) }),
              !reply.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reply.answer.unicodeScalars.count <= 20_000,
              reply.model.hasPrefix("gemini-") else { throw GeminiAssistantError.invalidResponse }
        return reply
    }

    static func validatedQuestion(mode: GeminiAssistantMode, question: String) throws -> String {
        let clean = mode == .summary ? "" : question.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.unicodeScalars.count <= 3_000, mode != .question || !clean.isEmpty else { throw GeminiAssistantError.invalidQuestion }
        return clean
    }
}
