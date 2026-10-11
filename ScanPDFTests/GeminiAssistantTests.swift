import Foundation
import PDFKit
import UIKit
import XCTest
@testable import ScanPDF

final class GeminiAssistantTests: XCTestCase {
    @MainActor
    func testRawScannedPDFRequestUsesPairTokenAndBase64UnicodeQuestion() async throws {
        let file = try makePDF()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = try makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/assistant")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pair-Token"), "pair-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let encoded = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Assistant-Options"))
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            let options = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(options, ["mode": "question", "question": "Công thức này có ý nghĩa gì?"])
            return (200, Self.reply())
        }
        defer { fixture.remove() }
        let result = try await fixture.client.answer(pdf: file, mode: .question, question: "  Công thức này có ý nghĩa gì?  ")
        XCTAssertEqual(result.answer, "Câu trả lời")
        XCTAssertEqual(result.pages, [1])
        XCTAssertEqual(result.pageCount, 1)
    }

    @MainActor
    func testRejectsWrongPageReferencesEmptyAnswerAndOversizedResponse() async throws {
        let file = try makePDF()
        defer { try? FileManager.default.removeItem(at: file) }
        let invalid = [Self.reply(pages: [0]), Self.reply(pages: [2]), Self.reply(pages: [1, 1]), Self.reply(model: "unsupported-model"),
                       Self.reply(pageCount: 2), Self.reply(pageCount: 61),
                       Self.reply(pages: Array(repeating: 1, count: 61)), Self.reply(answer: " \n"),
                       Self.reply(answer: String(repeating: "a", count: 20_001)), Data(repeating: 32, count: 1_048_577)]
        for body in invalid {
            let fixture = try makeClient { _ in (200, body) }
            defer { fixture.remove() }
            do { _ = try await fixture.client.answer(pdf: file, mode: .summary, question: ""); XCTFail("Expected invalid response") }
            catch GeminiAssistantError.invalidResponse { }
        }
    }

    @MainActor
    func testUnauthorizedAndMissingGeminiConfigurationHaveSpecificErrors() async throws {
        let file = try makePDF()
        defer { try? FileManager.default.removeItem(at: file) }
        let unauthorized = try makeClient { _ in (401, Data("{}".utf8)) }
        defer { unauthorized.remove() }
        do { _ = try await unauthorized.client.answer(pdf: file, mode: .summary, question: ""); XCTFail("Expected token rejection") }
        catch TranslationError.unauthorized { }
        let unavailable = try makeClient { _ in (503, Data("{}".utf8)) }
        defer { unavailable.remove() }
        do { _ = try await unavailable.client.answer(pdf: file, mode: .summary, question: ""); XCTFail("Expected Gemini configuration error") }
        catch GeminiAssistantError.unavailable { }
    }

    @MainActor
    func testRejectsFilesOverTenMiBAndSixtyPagesBeforeSending() async throws {
        var calls = 0
        let fixture = try makeClient { _ in calls += 1; return (200, Self.reply()) }
        defer { fixture.remove() }
        let large = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        try Data(repeating: 0, count: GeminiAssistantClient.maxUploadBytes + 1).write(to: large)
        defer { try? FileManager.default.removeItem(at: large) }
        do { _ = try await fixture.client.answer(pdf: large, mode: .summary, question: ""); XCTFail("Expected size rejection") }
        catch GeminiAssistantError.tooLarge { }
        let pages = try makePDF(pageCount: 61)
        defer { try? FileManager.default.removeItem(at: pages) }
        do { _ = try await fixture.client.answer(pdf: pages, mode: .summary, question: ""); XCTFail("Expected page count rejection") }
        catch GeminiAssistantError.tooManyPages { }
        XCTAssertEqual(calls, 0)
    }

    func testQuestionValidationUsesServerCharacterLimitAndSummaryDiscardsOldQuestion() throws {
        XCTAssertThrowsError(try GeminiAssistantClient.validatedQuestion(mode: .question, question: " \n"))
        XCTAssertThrowsError(try GeminiAssistantClient.validatedQuestion(mode: .explain, question: String(repeating: "x", count: 3_001)))
        XCTAssertEqual(try GeminiAssistantClient.validatedQuestion(mode: .explain, question: ""), "")
        XCTAssertEqual(try GeminiAssistantClient.validatedQuestion(mode: .summary, question: "Old question"), "")
        XCTAssertEqual(try GeminiAssistantClient.validatedQuestion(mode: .question, question: "a\u{0301}"), "á")
    }

    @MainActor
    func testProtectedPDFRequiresUnlockedWorkingCopyAndKeepsOriginalBytes() async throws {
        let source = try makePDF()
        let protected = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        let working = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { for file in [source, protected, working] { try? FileManager.default.removeItem(at: file) } }
        let original = try PDFService.protect(url: source, password: "test-password")
        try original.write(to: protected)
        var calls = 0
        let fixture = try makeClient { _ in calls += 1; return (200, Self.reply()) }
        defer { fixture.remove() }
        do { _ = try await fixture.client.answer(pdf: protected, mode: .summary, question: ""); XCTFail("Expected locked PDF rejection") }
        catch PDFServiceError.lockedDocument { }
        XCTAssertEqual(calls, 0)
        let unlocked = try PDFService.unlock(url: protected, password: "test-password")
        try XCTUnwrap(unlocked.dataRepresentation()).write(to: working)
        _ = try await fixture.client.answer(pdf: working, mode: .summary, question: "")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: protected), original)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: protected)).isLocked)
    }

    @MainActor
    func testNoUploadWithoutConsentAndNoAutomaticRetryAfterConnectionLoss() async throws {
        let service = AssistantServiceMock()
        service.failure = URLError(.networkConnectionLost)
        var factories = 0
        let model = GeminiAssistantModel(factory: { _ in factories += 1; return service }, saveConnection: { _ in })
        let source = URL(fileURLWithPath: "/never-upload-without-consent.pdf")
        XCTAssertNil(model.ask(pdf: source, address: "http://192.168.1.8", token: "pair", mode: .summary, question: "", consent: false))
        XCTAssertEqual(factories, 0)
        XCTAssertEqual(service.calls, 0)
        XCTAssertNotNil(model.errorMessage)
        let task = try XCTUnwrap(model.ask(pdf: source, address: "http://192.168.1.8", token: "pair", mode: .summary, question: "", consent: true))
        await task.value
        XCTAssertEqual(service.calls, 1)
        XCTAssertFalse(model.isSending)
        XCTAssertNil(model.response)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains("không tự gửi lại") == true)
        service.failure = URLError(.timedOut)
        let timeout = try XCTUnwrap(model.ask(pdf: source, address: "http://192.168.1.8", token: "pair", mode: .summary, question: "", consent: true))
        await timeout.value
        XCTAssertTrue(model.errorMessage?.contains("Hết thời gian chờ") == true)
        XCTAssertTrue(model.errorMessage?.contains("thử lại sẽ tạo yêu cầu mới") == true)
        XCTAssertEqual(service.calls, 2)
    }

    @MainActor
    func testCancelledOldResponseCannotReplaceNewAnswerOrConnection() async throws {
        let old = AssistantServiceMock()
        old.waitForReply = true
        let started = expectation(description: "Old request started")
        old.onStart = { started.fulfill() }
        let fresh = AssistantServiceMock()
        fresh.reply = GeminiAssistantResponse(answer: "New answer", pages: [1], model: "gemini-2.5-flash", pageCount: 1)
        var connections: [TranslationConnection] = []
        let model = GeminiAssistantModel(factory: { connection in
            connections.append(connection)
            return connection.token == "old-pair" ? old : fresh
        }, saveConnection: { _ in })
        let source = URL(fileURLWithPath: "/test.pdf")
        let first = try XCTUnwrap(model.ask(pdf: source, address: "http://192.168.1.8", token: "old-pair", mode: .summary, question: "", consent: true))
        await fulfillment(of: [started], timeout: 2)
        model.cancel()
        let next = try XCTUnwrap(model.ask(pdf: source, address: "http://192.168.1.9", token: "new-pair", mode: .question, question: "Câu hỏi?", consent: true))
        await next.value
        old.continuation?.resume(returning: old.reply)
        old.continuation = nil
        await first.value
        XCTAssertEqual(model.response?.answer, "New answer")
        XCTAssertEqual(model.answeredMode, .question)
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(connections.map(\.token), ["old-pair", "new-pair"])
    }

    @MainActor
    private func makePDF(pageCount: Int = 1) throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        let pdf = try PDFService.makePDF(images: Array(repeating: image, count: pageCount))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        try XCTUnwrap(pdf.dataRepresentation()).write(to: file)
        return file
    }

    private func makeClient(handler: @escaping AssistantProtocolStub.Handler) throws -> Fixture {
        let host = "assistant-" + UUID().uuidString.lowercased() + ".local"
        AssistantProtocolStub.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantProtocolStub.self]
        return Fixture(client: GeminiAssistantClient(connection: try TranslationConnection(address: "http://" + host, token: "pair-token"), configuration: configuration), host: host)
    }

    private struct Fixture {
        let client: GeminiAssistantClient
        let host: String
        func remove() { AssistantProtocolStub.unregister(host: host) }
    }

    private static func reply(answer: String = "Câu trả lời", pages: [Int] = [1], pageCount: Int = 1, model: String = "gemini-2.5-flash") -> Data {
        try! JSONSerialization.data(withJSONObject: ["answer": answer, "pages": pages, "model": model, "page_count": pageCount])
    }
}

@MainActor
private final class AssistantServiceMock: GeminiAssistantServicing {
    var reply = GeminiAssistantResponse(answer: "Old answer", pages: [1], model: "gemini-2.5-flash", pageCount: 1)
    var failure: Error?
    var waitForReply = false
    var onStart: (() -> Void)?
    var continuation: CheckedContinuation<GeminiAssistantResponse, Error>?
    private(set) var calls = 0
    func answer(pdf: URL, mode: GeminiAssistantMode, question: String) async throws -> GeminiAssistantResponse {
        calls += 1
        if waitForReply {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                onStart?()
            }
        }
        if let failure { throw failure }
        return reply
    }
}

private final class AssistantProtocolStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }
    static func unregister(host: String) {
        lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }; return handlers[request.url?.host ?? ""] != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url?.host ?? ""]; Self.lock.unlock()
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
