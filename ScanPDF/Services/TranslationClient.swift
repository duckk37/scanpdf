import Foundation

struct TranslationHealth: Decodable {
    let protocolVersion: Int
    let app: String
    let engine: String
    let targetLanguage: String
    let scanTranslation: Bool
    let engineReady: Bool
    let maxUploadBytes: Int64
    let provider: String
}

enum TranslationOutputKind: String, Codable, CaseIterable, Identifiable {
    case mono, dual
    var id: String { rawValue }
    var title: String { self == .mono ? "Chỉ tiếng Việt" : "Song ngữ gốc + Việt" }
}

enum TranslationSourceLanguage: String, CaseIterable, Identifiable {
    case auto, en, zh, ja, ko, fr, de, es, ru, pt, it, ar, th
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Tự nhận diện"
        case .en: return "Tiếng Anh"
        case .zh: return "Tiếng Trung"
        case .ja: return "Tiếng Nhật"
        case .ko: return "Tiếng Hàn"
        case .fr: return "Tiếng Pháp"
        case .de: return "Tiếng Đức"
        case .es: return "Tiếng Tây Ban Nha"
        case .ru: return "Tiếng Nga"
        case .pt: return "Tiếng Bồ Đào Nha"
        case .it: return "Tiếng Ý"
        case .ar: return "Tiếng Ả Rập"
        case .th: return "Tiếng Thái"
        }
    }
}

enum TranslationJobState: String, Codable {
    case queued, running, completed, failed, cancelled
    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

struct TranslationJob: Decodable {
    let id: UUID
    let filename: String
    let status: TranslationJobState
    let progress: Double
    let stage: String
    let message: String
    let error: String?
    let outputs: [TranslationOutputKind]
}

protocol TranslationServicing {
    func health() async throws -> TranslationHealth
    func submit(pdf: URL, filename: String, requestID: UUID, source: TranslationSourceLanguage) async throws -> TranslationJob
    func lookup(requestID: UUID) async throws -> TranslationJob
    func status(jobID: UUID) async throws -> TranslationJob
    func cancel(jobID: UUID) async throws -> TranslationJob
    func download(jobID: UUID, kind: TranslationOutputKind) async throws -> Data
}

/// No provider API keys cross the iOS connection; service=server uses the PC's configuration.
final class TranslationClient: TranslationServicing {
    private let connection: TranslationConnection
    private let session: URLSession
    private let transport: TranslationSessionDelegate

    init(connection: TranslationConnection, configuration: URLSessionConfiguration = .ephemeral,
         uploadProgress: (@Sendable (Double) -> Void)? = nil) {
        self.connection = connection
        transport = TranslationSessionDelegate(uploadProgress: uploadProgress)
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: transport, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func health() async throws -> TranslationHealth {
        let health: TranslationHealth = try await json(request(path: ["health"]))
        guard health.protocolVersion == 1, health.app == "ScanPDF", health.targetLanguage == "vi",
              health.maxUploadBytes > 0 else { throw TranslationError.unsupportedProtocol }
        return health
    }

    func submit(pdf: URL, filename: String, requestID: UUID, source: TranslationSourceLanguage = .auto) async throws -> TranslationJob {
        var upload = try request(path: ["jobs"], method: "POST", query: [
            URLQueryItem(name: "filename", value: filename), URLQueryItem(name: "service", value: "server"),
            URLQueryItem(name: "source", value: source.rawValue), URLQueryItem(name: "target", value: "vi")
        ])
        upload.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        upload.setValue(requestID.uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        let (data, response) = try await session.upload(for: upload, fromFile: pdf)
        return try decodeJob(data, response: response)
    }

    func lookup(requestID: UUID) async throws -> TranslationJob {
        try await job(request(path: ["requests", requestID.uuidString.lowercased()]))
    }

    func status(jobID: UUID) async throws -> TranslationJob {
        let result = try await job(request(path: ["jobs", jobID.uuidString.lowercased()]))
        guard result.id == jobID else { throw TranslationError.invalidResponse }
        return result
    }

    func cancel(jobID: UUID) async throws -> TranslationJob {
        let result = try await job(request(path: ["jobs", jobID.uuidString.lowercased()], method: "DELETE"))
        guard result.id == jobID else { throw TranslationError.invalidResponse }
        return result
    }

    func download(jobID: UUID, kind: TranslationOutputKind) async throws -> Data {
        var download = try request(path: ["jobs", jobID.uuidString.lowercased(), "download"],
                                   query: [URLQueryItem(name: "kind", value: kind.rawValue)])
        download.setValue("application/pdf", forHTTPHeaderField: "Accept")
        let (file, response) = try await session.download(for: download)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        if !(200...299).contains(response.statusCode) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try validate(response, data: handle.read(upToCount: 1_048_576) ?? Data())
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/pdf") == true else {
            throw TranslationError.invalidPDF
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 300 * 1_024 * 1_024 else {
            throw TranslationError.server("Bản dịch quá lớn để tải vào ứng dụng. Bạn có thể lấy tệp trực tiếp trên PC.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.starts(with: Data("%PDF-".utf8)) else { throw TranslationError.invalidPDF }
            do { _ = try PDFService.open(url: file) }
            catch { throw TranslationError.invalidPDF }
            return data
        }.value
    }

    private func request(path: [String], method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        let endpoint = path.reduce(connection.serverURL) { $0.appendingPathComponent($1) }
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw TranslationError.invalidAddress }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw TranslationError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(connection.token, forHTTPHeaderField: "X-Pair-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func json<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        guard data.count <= 1_048_576 else { throw TranslationError.invalidResponse }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw TranslationError.invalidResponse }
    }

    private func job(_ request: URLRequest) async throws -> TranslationJob {
        let (data, response) = try await session.data(for: request)
        return try decodeJob(data, response: response)
    }

    private func decodeJob(_ data: Data, response: URLResponse) throws -> TranslationJob {
        try validate(response, data: data)
        guard data.count <= 1_048_576 else { throw TranslationError.invalidResponse }
        let job: TranslationJob
        do { job = try decoder.decode(TranslationJob.self, from: data) }
        catch { throw TranslationError.invalidResponse }
        guard job.progress.isFinite, (0...100).contains(job.progress) else { throw TranslationError.invalidResponse }
        guard job.status != .completed || !job.outputs.isEmpty else { throw TranslationError.invalidResponse }
        return job
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        switch response.statusCode {
        case 200...299: return
        case 401: throw TranslationError.unauthorized
        case 404: throw TranslationError.missingJob
        case 413: throw TranslationError.tooLarge
        default:
            struct Failure: Decodable { let detail: String }
            if let error = try? JSONDecoder().decode(Failure.self, from: data) { throw TranslationError.server(error.detail) }
            throw TranslationError.server("Máy chủ PC trả về lỗi HTTP \(response.statusCode). Hãy kiểm tra cửa sổ ScanPDF PC.")
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private final class TranslationSessionDelegate: NSObject, URLSessionTaskDelegate {
    let uploadProgress: (@Sendable (Double) -> Void)?
    init(uploadProgress: (@Sendable (Double) -> Void)?) { self.uploadProgress = uploadProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 {
            uploadProgress?(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The protocol has no redirects. Never forward a pairing token or uploaded PDF to another origin.
        completionHandler(nil)
    }
}
