import SwiftUI

@MainActor
struct GeminiAssistantSheet: View {
    let sourceURL: URL
    let name: String
    let pageCount: Int
    let wasProtected: Bool
    let onSelectPage: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = GeminiAssistantModel()
    @State private var address = TranslationConnectionStore.savedAddress
    @State private var token = ""
    @State private var mode: GeminiAssistantMode = .summary
    @State private var question = ""
    @State private var consent = false
    @State private var localError: String?
    @State private var byteCount: Int?
    @State private var showShare = false

    private var questionValid: Bool { (try? GeminiAssistantClient.validatedQuestion(mode: mode, question: question)) != nil }
    private var fileAllowed: Bool { pageCount <= 60 && byteCount.map { $0 <= GeminiAssistantClient.maxUploadBytes } == true }
    private var canAsk: Bool { consent && fileAllowed && questionValid && !address.isEmpty && !token.isEmpty && !model.isSending }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(name, systemImage: "doc.richtext").lineLimit(2)
                    Text("\(pageCount) trang · Gemini đọc toàn bộ PDF, gồm cả trang scan/ảnh.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !fileAllowed {
                        Text("Giới hạn 10 MB và 60 trang. Hãy trích phần tài liệu cần hỏi thành PDF nhỏ hơn.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section("Kết nối ScanPDF PC") {
                    TranslationConnectionFields(address: $address, token: $token)
                        .disabled(model.isSending)
                    Text("API key và mô hình Gemini được cấu hình trên PC. iPhone/iPad chỉ dùng mã ghép nối.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Bạn muốn làm gì?") {
                    Picker("Chức năng", selection: $mode) {
                        ForEach(GeminiAssistantMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.isSending)
                    if mode != .summary {
                        Text(mode == .question ? "Câu hỏi về tài liệu" : "Phần muốn giải thích (có thể để trống)")
                            .font(.subheadline)
                        TextEditor(text: $question).frame(minHeight: 105)
                            .disabled(model.isSending).accessibilityLabel("Nội dung hỏi Gemini")
                        Text("\(question.precomposedStringWithCanonicalMapping.unicodeScalars.count)/3.000 ký tự")
                            .font(.caption.monospacedDigit()).foregroundStyle(questionValid ? Color.secondary : Color.red)
                    }
                }
                Section("Gửi tài liệu tới Google") {
                    Text("Khi bạn nhấn nút bên dưới, toàn bộ PDF được gửi tới PC, sau đó PC gửi PDF và câu hỏi tới Google Gemini. Chỉ gửi tài liệu mà bạn muốn chia sẻ với dịch vụ này. Có thể phát sinh phí/quota theo API key trên PC.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if wasProtected {
                        Text("PDF có mật khẩu được gửi dưới dạng đã mở khóa. Mật khẩu không được gửi tới Google. Tài liệu gốc trong thư viện được giữ nguyên.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Đồng ý gửi PDF tới Google qua PC", isOn: $consent).disabled(model.isSending)
                    if model.isSending {
                        ProgressView("Gemini đang đọc tài liệu…")
                        Button("Ngừng chờ câu trả lời", role: .destructive) { model.cancel() }
                        Text("PC có thể tiếp tục xử lý sau khi bạn ngừng chờ trên iOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            model.ask(pdf: sourceURL, address: address, token: token, mode: mode, question: question, consent: consent)
                        } label: { Label(mode == .summary ? "Tóm tắt bằng Gemini" : mode == .question ? "Gửi câu hỏi tới Gemini" : "Giải thích bằng Gemini", systemImage: "sparkles") }
                            .disabled(!canAsk)
                    }
                    if let error = model.errorMessage ?? localError {
                        Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if let reply = model.response {
                    Section(model.answeredMode?.title ?? "Câu trả lời") {
                        Text(reply.answer).textSelection(.enabled)
                        Text("Mô hình: \(reply.model)").font(.caption).foregroundStyle(.secondary)
                        Button { showShare = true } label: { Label("Chia sẻ câu trả lời", systemImage: "square.and.arrow.up") }
                    }
                    if !reply.pages.isEmpty {
                        Section("Trang Gemini gợi ý đối chiếu") {
                            ForEach(Array(Set(reply.pages)).sorted(), id: \.self) { page in
                                Button("Xem trang \(page)") {
                                    onSelectPage(page - 1)
                                    dismiss()
                                }
                            }
                        }
                    }
                    Section {
                        Text("Câu trả lời và số trang do AI đề xuất, có thể không chính xác. Hãy đối chiếu với tài liệu trước khi sử dụng. Trợ lý trả lời bằng văn bản; chức năng dịch PDF giữ bố cục nằm ở công cụ Dịch sang tiếng Việt.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Trợ lý Gemini")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() }.disabled(model.isSending) } }
            .interactiveDismissDisabled(model.isSending)
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showShare) { ActivitySheet(items: [shareText]) }
            .task {
                do {
                    byteCount = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    if let connection = try TranslationConnectionStore.load() {
                        address = connection.serverURL.absoluteString
                        token = connection.token
                    }
                } catch { localError = error.localizedDescription }
            }
            .onDisappear { model.cancel() }
            .tint(.teal)
        }
    }

    private var shareText: String {
        guard let reply = model.response else { return "" }
        let pages = Array(Set(reply.pages)).sorted().map(String.init).joined(separator: ", ")
        return "\(name)\n\(model.answeredMode?.title ?? "Gemini")\n\n\(reply.answer)\n\nTrang Gemini gợi ý: \(pages.isEmpty ? "Không nêu trang" : pages)\nMô hình: \(reply.model)\nCâu trả lời do AI tạo; hãy đối chiếu với tài liệu."
    }
}
