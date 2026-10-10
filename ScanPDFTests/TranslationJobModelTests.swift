import Foundation
import XCTest
@testable import ScanPDF

final class TranslationJobModelTests: XCTestCase {
    @MainActor
    func testLostUploadResponseRecoversSameRequestWithoutRepeatingPost() async throws {
        let service = MockTranslationService()
        service.submitError = URLError(.networkConnectionLost)
        service.lookupJob = .fixture(status: .completed)
        let model = makeModel(service)
        let file = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let task = try XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10:8765", token: "pair", source: .auto))
        await task.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(service.submissions.count, 1)
        XCTAssertEqual(service.lookupIDs, [service.submissions[0].requestID])
        XCTAssertEqual(model.requestID, service.submissions[0].requestID)
        XCTAssertEqual(model.job?.id, service.lookupJob.id)
        XCTAssertFalse(model.hasPendingWork)
    }

    @MainActor
    func testBingRequiresExplicitSourceBeforeUploadAndThenUsesSelectedLanguage() async throws {
        let service = MockTranslationService()
        service.healthValue = .fixture(provider: "bing")
        let model = makeModel(service)
        let file = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let auto = try XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10", token: "pair", source: .auto))
        await auto.value
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.errorMessage?.contains("Bing") == true)
        XCTAssertTrue(service.submissions.isEmpty)
        XCTAssertFalse(model.hasPendingWork)

        let english = try XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10", token: "pair", source: .en))
        await english.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(service.submissions.map(\.source), [.en])
    }

    @MainActor
    func testBadPairTokenNeverUploadsOrStoresConnection() async throws {
        let service = MockTranslationService()
        service.healthError = TranslationError.unauthorized
        var stored = 0
        let model = TranslationJobModel(factory: { _, _ in service }, saveConnection: { _ in stored += 1 }, pollInterval: .milliseconds(1))
        let file = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let task = try XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10", token: "bad", source: .auto))
        await task.value
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(service.submissions.isEmpty)
        XCTAssertEqual(stored, 0)
        XCTAssertFalse(model.hasPendingWork)
    }

    @MainActor
    func testUploadProgressAndPollingFinishWithCompletedJob() async throws {
        let service = MockTranslationService()
        service.submitJob = .fixture(status: .queued, progress: 0)
        service.statusJobs = [.fixture(id: service.submitJob.id, status: .running, progress: 65), .fixture(id: service.submitJob.id, status: .completed)]
        let model = TranslationJobModel(factory: { _, progress in service.progress = progress; return service }, saveConnection: { _ in }, pollInterval: .milliseconds(1))
        let file = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let task = try XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10", token: "pair", source: .auto))
        await task.value
        XCTAssertEqual(model.uploadProgress, 0.35, accuracy: 0.0001)
        XCTAssertEqual(service.statusIDs, [service.submitJob.id, service.submitJob.id])
        XCTAssertEqual(model.job?.progress, 100)
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor
    func testInterruptedUnknownUploadCanBeFoundAndCancelledOnPC() async throws {
        let service = MockTranslationService()
        service.submitError = URLError(.networkConnectionLost)
        service.lookupError = URLError(.notConnectedToInternet)
        let model = makeModel(service)
        let file = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let task = try XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10", token: "pair", source: .auto))
        await task.value
        XCTAssertEqual(model.phase, .interrupted)
        XCTAssertNil(model.job)
        XCTAssertTrue(model.hasPendingWork)
        XCTAssertNil(model.start(pdf: file, filename: "duplicate.pdf", address: "http://192.168.1.10", token: "pair", source: .auto))

        service.lookupError = nil
        service.lookupJob = .fixture(status: .running, progress: 30)
        service.cancelJob = .fixture(id: service.lookupJob.id, status: .cancelled, progress: 30)
        let cancellation = try XCTUnwrap(model.cancel())
        await cancellation.value
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertFalse(model.hasPendingWork)
        XCTAssertEqual(service.cancellationIDs, [service.lookupJob.id])
        XCTAssertEqual(service.submissions.count, 1)
        XCTAssertEqual(Set(service.lookupIDs), Set([service.submissions[0].requestID]))
    }

    @MainActor
    func testCancellationDoesNotClaimUnknownServerJobWasCancelled() async throws {
        let service = MockTranslationService()
        service.submitError = URLError(.networkConnectionLost)
        service.lookupError = URLError(.notConnectedToInternet)
        let model = makeModel(service)
        let file = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try await XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10", token: "pair", source: .auto)).value
        service.lookupError = TranslationError.missingJob
        try await XCTUnwrap(model.cancel()).value
        XCTAssertEqual(model.phase, .interrupted)
        XCTAssertTrue(model.hasPendingWork)
        XCTAssertTrue(service.cancellationIDs.isEmpty)
        XCTAssertTrue(model.errorMessage?.contains("Chưa xác nhận") == true)
    }

    @MainActor
    func testNewConnectionClearsRecoveryIdentityAndDoesNotReuseOldCredentials() async throws {
        let old = MockTranslationService()
        old.submitError = URLError(.networkConnectionLost)
        old.lookupError = URLError(.notConnectedToInternet)
        let fresh = MockTranslationService()
        var connections: [TranslationConnection] = []
        let model = TranslationJobModel(factory: { connection, _ in
            connections.append(connection)
            return connection.token == "old-pair" ? old : fresh
        }, saveConnection: { _ in }, pollInterval: .milliseconds(1), retryInterval: .milliseconds(1))
        let file = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try await XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10", token: "old-pair", source: .auto)).value
        let oldIdentity = try XCTUnwrap(model.requestID)
        model.newConnection()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.job)
        XCTAssertNil(model.health)
        XCTAssertNil(model.requestID)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.uploadProgress, 0)
        XCTAssertFalse(model.hasPendingWork)
        XCTAssertNil(model.resume())

        try await XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.20", token: "new-pair", source: .ja)).value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotEqual(model.requestID, oldIdentity)
        XCTAssertEqual(connections.map(\.token), ["old-pair", "new-pair"])
        XCTAssertEqual(fresh.submissions.map(\.source), [.ja])
        XCTAssertTrue(old.cancellationIDs.isEmpty)
    }

    @MainActor
    func testDownloadFailureKeepsReadyJobForRetryAndPassesChosenArtifact() async throws {
        let service = MockTranslationService()
        let model = makeModel(service)
        let file = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try await XCTUnwrap(model.start(pdf: file, filename: "math.pdf", address: "http://192.168.1.10", token: "pair", source: .auto)).value
        service.downloadError = URLError(.networkConnectionLost)
        var output: Data?
        try await XCTUnwrap(model.download(kind: .dual) { data, _ in output = data }).value
        XCTAssertNil(output)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.errorMessage)
        service.downloadError = nil
        try await XCTUnwrap(model.download(kind: .dual) { data, kind in
            output = data
            XCTAssertEqual(kind, .dual)
        }).value
        XCTAssertEqual(output, service.downloadData)
        XCTAssertEqual(service.downloadKinds, [.dual, .dual])
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    private func makeModel(_ service: MockTranslationService) -> TranslationJobModel {
        TranslationJobModel(factory: { _, _ in service }, saveConnection: { _ in }, pollInterval: .milliseconds(1), retryInterval: .milliseconds(1))
    }

    private func makeUploadFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        try Data("%PDF-1.7\nupload fixture".utf8).write(to: file)
        return file
    }
}

@MainActor
private final class MockTranslationService: TranslationServicing {
    struct Submission { let requestID: UUID; let source: TranslationSourceLanguage }
    var healthValue = TranslationHealth.fixture()
    var healthError: Error?
    var submitJob = TranslationJob.fixture(status: .completed)
    var submitError: Error?
    var lookupJob = TranslationJob.fixture(status: .completed)
    var lookupError: Error?
    var cancelJob = TranslationJob.fixture(status: .cancelled)
    var downloadError: Error?
    var downloadData = Data("translated PDF".utf8)
    var statusJobs: [TranslationJob] = []
    var progress: (@Sendable (Double) -> Void)?
    private(set) var submissions: [Submission] = []
    private(set) var lookupIDs: [UUID] = []
    private(set) var statusIDs: [UUID] = []
    private(set) var cancellationIDs: [UUID] = []
    private(set) var downloadKinds: [TranslationOutputKind] = []

    func health() async throws -> TranslationHealth {
        if let healthError { throw healthError }
        return healthValue
    }
    func submit(pdf: URL, filename: String, requestID: UUID, source: TranslationSourceLanguage) async throws -> TranslationJob {
        submissions.append(Submission(requestID: requestID, source: source))
        progress?(0.35)
        try await Task.sleep(for: .milliseconds(10))
        if let submitError { throw submitError }
        return submitJob
    }
    func lookup(requestID: UUID) async throws -> TranslationJob {
        lookupIDs.append(requestID)
        if let lookupError { throw lookupError }
        return lookupJob
    }
    func status(jobID: UUID) async throws -> TranslationJob {
        statusIDs.append(jobID)
        return statusJobs.isEmpty ? submitJob : statusJobs.removeFirst()
    }
    func cancel(jobID: UUID) async throws -> TranslationJob {
        cancellationIDs.append(jobID)
        return cancelJob
    }
    func download(jobID: UUID, kind: TranslationOutputKind) async throws -> Data {
        downloadKinds.append(kind)
        if let downloadError { throw downloadError }
        return downloadData
    }
}

private extension TranslationHealth {
    static func fixture(provider: String = "google") -> TranslationHealth {
        TranslationHealth(protocolVersion: 1, app: "ScanPDF", engine: "BabelDOC", targetLanguage: "vi", scanTranslation: false,
                          engineReady: true, maxUploadBytes: 104_857_600, provider: provider)
    }
}

private extension TranslationJob {
    static func fixture(id: UUID = UUID(), status: TranslationJobState, progress: Double = 100) -> TranslationJob {
        TranslationJob(id: id, filename: "math.pdf", status: status, progress: progress, stage: "translate", message: "Tiến độ dịch",
                       error: nil, outputs: status == .completed ? [.mono, .dual] : [])
    }
}
