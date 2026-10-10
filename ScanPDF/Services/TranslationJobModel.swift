import Combine
import Foundation

enum TranslationPhase: Equatable {
    case idle, checking, uploading, monitoring, ready, downloading, cancelling, interrupted, failed, cancelled
    var isBusy: Bool { [.checking, .uploading, .monitoring, .downloading, .cancelling].contains(self) }
    var title: String {
        switch self {
        case .idle: return "Sẵn sàng kết nối"
        case .checking: return "Đang kết nối PC…"
        case .uploading: return "Đang gửi PDF tới PC…"
        case .monitoring: return "PC đang dịch tài liệu…"
        case .ready: return "Bản dịch đã sẵn sàng"
        case .downloading: return "Đang tải bản dịch…"
        case .cancelling: return "Đang yêu cầu PC hủy…"
        case .interrupted: return "Đang mất kết nối PC"
        case .failed: return "Chưa hoàn tất dịch"
        case .cancelled: return "Đã hủy dịch"
        }
    }
}

@MainActor
final class TranslationJobModel: ObservableObject {
    @Published private(set) var phase: TranslationPhase = .idle
    @Published private(set) var health: TranslationHealth?
    @Published private(set) var job: TranslationJob?
    @Published private(set) var uploadProgress = 0.0
    @Published private(set) var errorMessage: String?
    private(set) var requestID: UUID?
    private var client: TranslationServicing?
    private var operation: Task<Void, Never>?
    private var submitted = false
    private var generation = UUID()
    private let factory: (TranslationConnection, @escaping @Sendable (Double) -> Void) -> TranslationServicing
    private let saveConnection: (TranslationConnection) throws -> Void
    private let pollInterval: Duration
    private let retryInterval: Duration

    var hasPendingWork: Bool { submitted && (job == nil || job?.status.isTerminal == false) }

    init(factory: @escaping (TranslationConnection, @escaping @Sendable (Double) -> Void) -> TranslationServicing = {
        TranslationClient(connection: $0, uploadProgress: $1)
    }, saveConnection: @escaping (TranslationConnection) throws -> Void = TranslationConnectionStore.save,
         pollInterval: Duration = .seconds(2), retryInterval: Duration = .seconds(2)) {
        self.factory = factory
        self.saveConnection = saveConnection
        self.pollInterval = pollInterval
        self.retryInterval = retryInterval
    }

    @discardableResult
    func checkConnection(address: String, token: String) -> Task<Void, Never>? {
        guard !phase.isBusy, !hasPendingWork else { return nil }
        phase = .checking
        errorMessage = nil
        health = nil
        let task = Task {
            do {
                let connection = try TranslationConnection(address: address, token: token)
                let service = factory(connection, { _ in })
                let response = try await service.health()
                try Task.checkCancellation()
                try saveConnection(connection)
                health = response
                phase = .idle
            } catch { if !Task.isCancelled { report(error, pending: false) } }
        }
        operation = task
        return task
    }

    @discardableResult
    func start(pdf: URL, filename: String, address: String, token: String,
               source: TranslationSourceLanguage) -> Task<Void, Never>? {
        guard !phase.isBusy, !hasPendingWork else { return nil }
        errorMessage = nil
        health = nil
        job = nil
        uploadProgress = 0
        // A new explicit start uses a new identity; an interrupted upload is recovered with GET, never repeated POST.
        requestID = UUID()
        generation = UUID()
        let activeGeneration = generation
        submitted = false
        phase = .checking
        let task = Task {
            do {
                let connection = try TranslationConnection(address: address, token: token)
                let service = factory(connection) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.generation == activeGeneration, self.phase == .uploading else { return }
                        self.uploadProgress = min(1, max(0, value))
                    }
                }
                client = service
                let response = try await service.health()
                try Task.checkCancellation()
                health = response
                guard response.engineReady else {
                    throw TranslationError.server("PC đã kết nối nhưng chưa cài công cụ dịch. Mở ScanPDF PC và cài công cụ trước khi dịch.")
                }
                if response.provider.lowercased() == "bing", source == .auto {
                    throw TranslationError.server("Bing cần ngôn ngữ gốc cụ thể. Hãy chọn ngôn ngữ của PDF hoặc đổi dịch vụ trên PC.")
                }
                let size = try pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, Int64(size) <= min(response.maxUploadBytes, 104_857_600) else { throw TranslationError.tooLarge }
                try saveConnection(connection)
                guard let requestID else { throw TranslationError.invalidResponse }
                phase = .uploading
                submitted = true
                do {
                    let accepted = try await service.submit(pdf: pdf, filename: filename, requestID: requestID, source: source)
                    try Task.checkCancellation()
                    job = accepted
                } catch {
                    try Task.checkCancellation()
                    // A response may be lost after the PC accepted the PDF. Find the same request before considering a new upload.
                    if isConnectionFailure(error) {
                        let recovered = try await service.lookup(requestID: requestID)
                        try Task.checkCancellation()
                        job = recovered
                    } else { submitted = false; throw error }
                }
                guard let id = job?.id else { throw TranslationError.invalidResponse }
                await monitor(service: service, id: id)
            } catch { if !Task.isCancelled { report(error, pending: submitted) } }
        }
        operation = task
        return task
    }

    @discardableResult
    func resume() -> Task<Void, Never>? {
        guard !phase.isBusy, let client, let requestID else { return nil }
        errorMessage = nil
        phase = .monitoring
        let task = Task {
            do {
                if job == nil {
                    let recovered = try await client.lookup(requestID: requestID)
                    try Task.checkCancellation()
                    job = recovered
                }
                guard let id = job?.id else { throw TranslationError.invalidResponse }
                await monitor(service: client, id: id)
            } catch { if !Task.isCancelled { report(error, pending: submitted) } }
        }
        operation = task
        return task
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        guard phase != .cancelling else { return nil }
        operation?.cancel()
        errorMessage = nil
        if phase == .downloading { phase = .ready; return nil }
        if !submitted {
            phase = .cancelled
            requestID = nil
            return nil
        }
        guard let client, let requestID else { return nil }
        phase = .cancelling
        let task = Task {
            do {
                if job == nil {
                    // Allow an accepted upload to register before checking cancellation; never claim an unknown job was cancelled.
                    for attempt in 0..<3 {
                        do {
                            let recovered = try await client.lookup(requestID: requestID)
                            try Task.checkCancellation()
                            job = recovered
                            break
                        }
                        catch TranslationError.missingJob {
                            if attempt == 2 { throw TranslationError.server("Chưa xác nhận được tác vụ trên PC. Kiểm tra ScanPDF PC trước khi gửi lại PDF.") }
                            try await Task.sleep(for: retryInterval)
                        }
                    }
                }
                guard let id = job?.id else { throw TranslationError.invalidResponse }
                let cancelled = try await client.cancel(jobID: id)
                try Task.checkCancellation()
                job = cancelled
                if job?.status == .completed { phase = .ready }
                else if job?.status == .cancelled { phase = .cancelled; submitted = false }
                else if job?.status == .failed { phase = .failed; submitted = false }
                else { throw TranslationError.server("PC chưa xác nhận hủy. Hãy thử theo dõi hoặc hủy lại.") }
            } catch { if !Task.isCancelled { report(error, pending: true) } }
        }
        operation = task
        return task
    }

    @discardableResult
    func download(kind: TranslationOutputKind, completion: @escaping (Data, TranslationOutputKind) -> Void) -> Task<Void, Never>? {
        guard !phase.isBusy, let client, let job, job.status == .completed, job.outputs.contains(kind) else { return nil }
        phase = .downloading
        errorMessage = nil
        let task = Task {
            do {
                let data = try await client.download(jobID: job.id, kind: kind)
                try Task.checkCancellation()
                phase = .ready
                completion(data, kind)
            } catch {
                if !Task.isCancelled { errorMessage = message(for: error); phase = .ready }
            }
        }
        operation = task
        return task
    }

    func newConnection() {
        operation?.cancel()
        operation = nil
        client = nil
        job = nil
        health = nil
        requestID = nil
        generation = UUID()
        submitted = false
        uploadProgress = 0
        errorMessage = nil
        phase = .idle
    }

    func stopMonitoring() { operation?.cancel(); operation = nil }

    private func monitor(service: TranslationServicing, id: UUID) async {
        var failures = 0
        phase = .monitoring
        while !Task.isCancelled {
            if let job, finish(job) { return }
            do {
                try await Task.sleep(for: pollInterval)
                let latest = try await service.status(jobID: id)
                try Task.checkCancellation()
                job = latest
                failures = 0
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                if isConnectionFailure(error), failures < 3 {
                    failures += 1
                    errorMessage = "Đang thử nối lại PC (\(failures)/3)…"
                    do { try await Task.sleep(for: retryInterval * failures) }
                    catch { return }
                } else { report(error, pending: true); return }
            }
        }
    }

    private func finish(_ job: TranslationJob) -> Bool {
        switch job.status {
        case .completed: phase = .ready; submitted = false; errorMessage = nil; return true
        case .cancelled: phase = .cancelled; submitted = false; errorMessage = nil; return true
        case .failed:
            phase = .failed
            submitted = false
            errorMessage = job.error ?? job.message
            return true
        case .queued, .running: return false
        }
    }

    private func report(_ error: Error, pending: Bool) {
        errorMessage = message(for: error)
        if case TranslationError.missingJob = error { submitted = false; phase = .failed }
        else { phase = pending ? .interrupted : .failed }
    }

    private func message(for error: Error) -> String {
        isConnectionFailure(error) ? TranslationError.connectionLost.localizedDescription : error.localizedDescription
    }

    private func isConnectionFailure(_ error: Error) -> Bool { error is URLError }
}
