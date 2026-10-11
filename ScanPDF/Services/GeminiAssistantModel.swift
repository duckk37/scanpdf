import Combine
import Foundation

@MainActor
final class GeminiAssistantModel: ObservableObject {
    @Published private(set) var isSending = false
    @Published private(set) var response: GeminiAssistantResponse?
    @Published private(set) var answeredMode: GeminiAssistantMode?
    @Published private(set) var errorMessage: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let factory: (TranslationConnection) -> GeminiAssistantServicing
    private let saveConnection: (TranslationConnection) throws -> Void

    init(factory: @escaping (TranslationConnection) -> GeminiAssistantServicing = { GeminiAssistantClient(connection: $0) },
         saveConnection: @escaping (TranslationConnection) throws -> Void = TranslationConnectionStore.save) {
        self.factory = factory
        self.saveConnection = saveConnection
    }

    @discardableResult
    func ask(pdf: URL, address: String, token: String, mode: GeminiAssistantMode, question: String, consent: Bool) -> Task<Void, Never>? {
        guard !isSending else { return nil }
        errorMessage = nil
        do {
            guard consent else { throw GeminiAssistantError.consentRequired }
            _ = try GeminiAssistantClient.validatedQuestion(mode: mode, question: question)
            let connection = try TranslationConnection(address: address, token: token)
            let service = factory(connection)
            generation = UUID()
            let activeGeneration = generation
            isSending = true
            response = nil
            answeredMode = nil
            let task = Task {
                do {
                    let answer = try await service.answer(pdf: pdf, mode: mode, question: question)
                    try Task.checkCancellation()
                    guard generation == activeGeneration else { return }
                    response = answer
                    answeredMode = mode
                    do { try saveConnection(connection) }
                    catch { errorMessage = "Đã nhận câu trả lời nhưng chưa lưu được kết nối: " + error.localizedDescription }
                } catch {
                    guard !Task.isCancelled, generation == activeGeneration else { return }
                    if let network = error as? URLError {
                        let reason = network.code == .timedOut ? "Hết thời gian chờ câu trả lời Gemini." : "Mất kết nối tới PC. Kiểm tra Wi-Fi và quyền Mạng cục bộ."
                        errorMessage = reason + " PC/Google có thể vẫn đang xử lý. Ứng dụng không tự gửi lại; thử lại sẽ tạo yêu cầu mới."
                    } else { errorMessage = error.localizedDescription }
                }
                if generation == activeGeneration { isSending = false }
            }
            operation = task
            return task
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        isSending = false
    }
}
