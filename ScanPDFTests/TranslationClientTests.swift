import Foundation
import XCTest
@testable import ScanPDF

final class TranslationClientTests: XCTestCase {
    func testHealthUsesPairTokenAndDecodesProtocol() async throws {
        let fixture = try makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/health")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pair-Token"), "secret-pair-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Self.healthData())
        }
        defer { fixture.remove() }
        let health = try await fixture.client.health()
        XCTAssertEqual(health.protocolVersion, 1)
        XCTAssertEqual(health.provider, "google")
        XCTAssertTrue(health.engineReady)
        XCTAssertFalse(health.scanTranslation)
        XCTAssertEqual(health.maxUploadBytes, 104_857_600)
    }

    func testUnauthorizedDoesNotExposeServerResponse() async throws {
        let fixture = try makeClient { _ in (401, Data("{\"detail\":\"secret-pair-token\"}".utf8)) }
        defer { fixture.remove() }
        do {
            _ = try await fixture.client.health()
            XCTFail("Expected an authorization error")
        } catch TranslationError.unauthorized {
            XCTAssertFalse(errorDescription(TranslationError.unauthorized).contains("secret-pair-token"))
        }
    }

    func testRejectsUnsupportedProtocolAndInvalidProgress() async throws {
        let healthFixture = try makeClient { _ in (200, Self.healthData(version: 2)) }
        defer { healthFixture.remove() }
        do { _ = try await healthFixture.client.health(); XCTFail("Expected protocol rejection") }
        catch TranslationError.unsupportedProtocol { }

        let id = UUID()
        for progress in [-1.0, 101.0] {
            let fixture = try makeClient { _ in (200, Self.jobData(id: id, progress: progress)) }
            defer { fixture.remove() }
            do { _ = try await fixture.client.status(jobID: id); XCTFail("Expected invalid progress rejection") }
            catch TranslationError.invalidResponse { }
        }
    }

    func testUploadSendsRawPDFRequestIDAndExplicitSourceWithoutProviderSecrets() async throws {
        let requestID = UUID()
        let jobID = UUID()
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        try Data("%PDF-1.7\nrequest fixture".utf8).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }
        let fixture = try makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/jobs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pair-Token"), "secret-pair-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Request-ID"), requestID.uuidString.lowercased())
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Translation-Settings"))
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "filename" }?.value, "Toán học & vật lý.pdf")
            XCTAssertEqual(query.first { $0.name == "service" }?.value, "server")
            XCTAssertEqual(query.first { $0.name == "source" }?.value, "en")
            XCTAssertEqual(query.first { $0.name == "target" }?.value, "vi")
            return (202, Self.jobData(id: jobID, status: "queued", progress: 0))
        }
        defer { fixture.remove() }
        let job = try await fixture.client.submit(pdf: pdf, filename: "Toán học & vật lý.pdf", requestID: requestID, source: .en)
        XCTAssertEqual(job.id, jobID)
        XCTAssertEqual(job.status, .queued)
    }

    func testRequestLookupAndCancellationUseCorrectIdentifiers() async throws {
        let requestID = UUID()
        let jobID = UUID()
        let fixture = try makeClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pair-Token"), "secret-pair-token")
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(request.url?.path, "/jobs/" + jobID.uuidString.lowercased())
                return (200, Self.jobData(id: jobID, status: "cancelled"))
            }
            XCTAssertEqual(request.url?.path, "/requests/" + requestID.uuidString.lowercased())
            return (200, Self.jobData(id: jobID))
        }
        defer { fixture.remove() }
        let found = try await fixture.client.lookup(requestID: requestID)
        XCTAssertEqual(found.id, jobID)
        let cancelled = try await fixture.client.cancel(jobID: jobID)
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testRejectsStatusForAnotherJobAndMissingCompletedOutput() async throws {
        let fixture = try makeClient { _ in (200, Self.jobData(id: UUID())) }
        defer { fixture.remove() }
        do { _ = try await fixture.client.status(jobID: UUID()); XCTFail("Expected mismatched job rejection") }
        catch TranslationError.invalidResponse { }

        let emptyFixture = try makeClient { _ in
            (200, Self.jobData(id: UUID(), status: "completed", progress: 100, outputs: []))
        }
        defer { emptyFixture.remove() }
        do { _ = try await emptyFixture.client.lookup(requestID: UUID()); XCTFail("Expected missing output rejection") }
        catch TranslationError.invalidResponse { }
    }

    func testConnectionRestrictsPlainHTTPToLocalAddressesAndValidatesToken() throws {
        for address in ["http://192.168.1.8:8765", "http://10.0.0.1:8765", "http://pc.local:8765", "http://pc:8765", "http://[fd00::1]:8765"] {
            XCTAssertNoThrow(try TranslationConnection(address: address, token: "pair"))
        }
        for address in ["http://8.8.8.8:8765", "http://example.com", "http://010.0.0.1", "http://172.32.1.1", "http://192.168.1.8/jobs", "http://user:pass@192.168.1.8", "http://192.168.1.8?token=pair"] {
            XCTAssertThrowsError(try TranslationConnection(address: address, token: "pair"))
        }
        XCTAssertNoThrow(try TranslationConnection(address: "https://example.com:8765", token: "pair"))
        XCTAssertThrowsError(try TranslationConnection(address: "http://192.168.1.8", token: "  "))
        XCTAssertThrowsError(try TranslationConnection(address: "http://192.168.1.8", token: "pair\r\nheader"))
    }

    private func makeClient(handler: @escaping TranslationProtocolStub.Handler) throws -> ClientFixture {
        let host = "test-" + UUID().uuidString.lowercased() + ".local"
        TranslationProtocolStub.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationProtocolStub.self]
        return ClientFixture(client: TranslationClient(connection: try TranslationConnection(address: "http://" + host, token: "secret-pair-token"), configuration: configuration), host: host)
    }

    private struct ClientFixture {
        let client: TranslationClient
        let host: String
        func remove() { TranslationProtocolStub.unregister(host: host) }
    }

    private static func healthData(version: Int = 1) -> Data {
        Data("{\"protocol_version\":\(version),\"app\":\"ScanPDF\",\"engine\":\"pdf2zh-next/BabelDOC\",\"target_language\":\"vi\",\"scan_translation\":false,\"engine_ready\":true,\"max_upload_bytes\":104857600,\"provider\":\"google\"}".utf8)
    }

    private static func jobData(id: UUID, status: String = "running", progress: Double = 40, outputs: [String] = ["mono", "dual"]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id.uuidString, "filename": "test.pdf", "status": status, "progress": progress,
                                                    "stage": "translate", "message": "Đang dịch", "error": NSNull(), "outputs": outputs])
    }

    private func errorDescription(_ error: Error) -> String { error.localizedDescription }
}

private final class TranslationProtocolStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }
    static func unregister(host: String) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return handlers[request.url?.host ?? ""] != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        Self.lock.unlock()
        do {
            guard let handler, let url = request.url else { throw URLError(.badURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
