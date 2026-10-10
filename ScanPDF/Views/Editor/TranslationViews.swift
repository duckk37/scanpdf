import SwiftUI

@MainActor
struct TranslatePDFSheet: View {
    let sourceURL: URL
    let name: String
    let pageCount: Int
    let preservesPassword: Bool
    let onSave: (Data, TranslationOutputKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = TranslationJobModel()
    @State private var address = TranslationConnectionStore.savedAddress
    @State private var token = ""
    @State private var source: TranslationSourceLanguage = .auto
    @State private var output: TranslationOutputKind = .mono
    @State private var configurationError: String?

    private var connectionLocked: Bool { model.phase.isBusy || model.hasPendingWork || model.job != nil }
    private var needsSource: Bool { model.health?.provider.lowercased() == "bing" && source == .auto }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(name, systemImage: "doc.richtext").lineLimit(2)
                    Text("\(pageCount) trang · Dịch toàn tài liệu sang tiếng Việt")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Kết nối máy tính") {
                    TranslationConnectionFields(address: $address, token: $token).disabled(connectionLocked)
                    if !connectionLocked {
                        Button("Kiểm tra và lưu kết nối") { model.checkConnection(address: address, token: token) }
                    }
                    if let health = model.health {
                        TranslationHealthDetails(health: health)
                    }
                    if let configurationError { Text(configurationError).font(.footnote).foregroundStyle(.red) }
                }
                Section("Ngôn ngữ") {
                    Picker("Ngôn ngữ gốc", selection: $source) {
                        ForEach(TranslationSourceLanguage.allCases) { Text($0.title).tag($0) }
                    }.disabled(connectionLocked)
                    LabeledContent("Dịch sang", value: "Tiếng Việt")
                    if needsSource {
                        Text("Bing cần chọn ngôn ngữ gốc cụ thể. Tự nhận diện dùng được với dịch vụ hỗ trợ trên PC.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                statusSection
                actionSection

                Section("Dịch qua ScanPDF PC") {
                    Text("PC phải bật ScanPDF PC và cùng mạng Wi-Fi với iPhone/iPad. Công cụ dịch và mô hình được cài/tải trên PC. Dịch vụ, mô hình và API key cũng cấu hình trên PC; iOS chỉ dùng mã ghép nối.")
                    Text("PDF được gửi tới PC. Khi chọn dịch vụ trực tuyến, PC gửi văn bản tới dịch vụ đó. Công cụ cố gắng giữ bố cục, công thức và hình minh họa; hãy kiểm tra bản dịch trước khi sử dụng.")
                    Text("Chức năng này dành cho PDF gốc có văn bản. PDF scan/ảnh, kể cả ảnh toàn trang có lớp OCR ẩn, chưa được hỗ trợ để dịch giữ bố cục.")
                    if preservesPassword {
                        Text("PDF được gửi tới PC dưới dạng đã mở khóa để dịch. Bản dịch lưu vào thư viện được bảo vệ lại bằng mật khẩu hiện tại.")
                    }
                    Text("Tài liệu gốc được giữ nguyên. Giữ ứng dụng mở để theo dõi và tải bản dịch; PC vẫn xử lý nếu iPhone tạm mất kết nối.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Dịch PDF sang tiếng Việt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.hasPendingWork ? "Để PC tiếp tục" : "Đóng") { dismiss() }.disabled(model.phase.isBusy)
                }
            }
            .interactiveDismissDisabled(model.phase.isBusy || model.hasPendingWork)
            .task { loadConnection() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && model.phase == .interrupted { model.resume() }
            }
            .onChange(of: address) { _, _ in resetUnusedConnection() }
            .onChange(of: token) { _, _ in resetUnusedConnection() }
            .onChange(of: model.job?.outputs) { _, outputs in
                if let outputs, !outputs.contains(output), let first = outputs.first { output = first }
            }
            .onDisappear { model.stopMonitoring() }
            .tint(.teal)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if model.phase != .idle || model.job != nil {
            Section("Tiến độ") {
                HStack {
                    if model.phase.isBusy { ProgressView() }
                    Text(model.phase.title).font(.subheadline.weight(.semibold))
                }
                if model.phase == .uploading {
                    ProgressView(value: model.uploadProgress)
                    Text("Đã gửi \(Int(model.uploadProgress * 100))% PDF").font(.caption.monospacedDigit())
                }
                if let job = model.job {
                    ProgressView(value: job.progress, total: 100)
                    Text("\(Int(job.progress))% · \(job.message)").font(.caption).foregroundStyle(.secondary)
                    Text("Tác vụ: \(job.id.uuidString.lowercased())").font(.caption2.monospaced()).textSelection(.enabled)
                }
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            if model.phase == .ready, let job = model.job {
                Picker("Bản cần lưu", selection: $output) {
                    ForEach(job.outputs) { Text($0.title).tag($0) }
                }
                Button {
                    model.download(kind: output, completion: onSave)
                } label: { Label("Lưu bản dịch vào thư viện", systemImage: "square.and.arrow.down") }
                    .disabled(!job.outputs.contains(output))
            } else if model.phase == .interrupted {
                Button("Tiếp tục theo dõi") { model.resume() }
                Button("Hủy tác vụ trên PC", role: .destructive) { model.cancel() }
                Button("Đổi kết nối · PC cũ có thể vẫn xử lý") { model.newConnection() }
            } else if model.phase.isBusy {
                if model.phase != .cancelling {
                    Button(model.phase == .downloading ? "Ngừng tải bản dịch" : "Hủy dịch", role: .destructive) { model.cancel() }
                }
            } else {
                Button {
                    let filename = name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
                    model.start(pdf: sourceURL, filename: filename, address: address, token: token, source: source)
                } label: { Label("Dịch qua PC", systemImage: "character.bubble") }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.isEmpty || needsSource)
            }
            if [.ready, .failed, .cancelled].contains(model.phase), model.job != nil {
                Button("Tác vụ mới · Đổi thiết lập dịch") { model.newConnection() }
            }
        } footer: {
            if model.phase == .ready { Text("Bản tiếng Việt và bản song ngữ được lưu thành PDF mới.") }
            if model.phase == .interrupted { Text("Không gửi lại PDF khi PC đang xử lý. Tiếp tục theo dõi dùng đúng tác vụ đã tạo.") }
        }
    }

    private func loadConnection() {
        do {
            if let connection = try TranslationConnectionStore.load() {
                address = connection.serverURL.absoluteString
                token = connection.token
            }
        } catch { configurationError = error.localizedDescription }
    }

    private func resetUnusedConnection() {
        if !model.phase.isBusy && !model.hasPendingWork && model.job == nil { model.newConnection() }
    }
}

@MainActor
struct TranslationSettingsView: View {
    @StateObject private var model = TranslationJobModel()
    @State private var address = TranslationConnectionStore.savedAddress
    @State private var token = ""
    @State private var localError: String?

    var body: some View {
        Form {
            Section("Máy tính của bạn") {
                TranslationConnectionFields(address: $address, token: $token).disabled(model.phase.isBusy)
                Button("Kiểm tra và lưu kết nối") { model.checkConnection(address: address, token: token) }
                    .disabled(model.phase.isBusy || address.isEmpty || token.isEmpty)
                if model.phase.isBusy { ProgressView("Đang kết nối…") }
                if let health = model.health { TranslationHealthDetails(health: health) }
                if let error = model.errorMessage ?? localError { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section("Cách kết nối") {
                Text("1. Mở ScanPDF PC trên máy tính và bật máy chủ Wi-Fi.")
                Text("2. Kết nối iPhone/iPad cùng Wi-Fi, nhập địa chỉ và mã ghép nối hiển thị trên PC.")
                Text("3. Cho phép quyền Mạng cục bộ khi iOS hỏi. Nếu đã từ chối, bật lại trong Cài đặt → ScanPDF → Mạng cục bộ.")
                Text("Công cụ dịch, mô hình và dịch vụ được cấu hình trên PC. Mã ghép nối lưu trong Keychain của thiết bị này.")
            }.font(.footnote).foregroundStyle(.secondary)
            Section {
                Button("Xóa kết nối đã lưu", role: .destructive) {
                    do {
                        try TranslationConnectionStore.clear()
                        address = ""
                        token = ""
                        model.newConnection()
                    } catch { localError = error.localizedDescription }
                }.disabled(model.phase.isBusy)
                Link("ScanPDF PC trên GitHub", destination: URL(string: "https://github.com/duckk37/scanpdf")!)
            }
        }
        .navigationTitle("Kết nối PC để dịch")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                if let connection = try TranslationConnectionStore.load() {
                    address = connection.serverURL.absoluteString
                    token = connection.token
                }
            } catch { localError = error.localizedDescription }
        }
        .onDisappear { model.stopMonitoring() }
        .onChange(of: address) { _, _ in if !model.phase.isBusy { model.newConnection() } }
        .onChange(of: token) { _, _ in if !model.phase.isBusy { model.newConnection() } }
        .tint(.teal)
    }
}

private struct TranslationConnectionFields: View {
    @Binding var address: String
    @Binding var token: String
    var body: some View {
        TextField("http://192.168.1.10:8765", text: $address)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel("Địa chỉ ScanPDF PC")
        SecureField("Mã ghép nối trên PC", text: $token)
            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
    }
}

private struct TranslationHealthDetails: View {
    let health: TranslationHealth
    var body: some View {
        Label(health.engineReady ? "Đã kết nối PC · Công cụ dịch đã cài" : "Đã kết nối PC · Cần cài công cụ dịch", systemImage: health.engineReady ? "checkmark.circle" : "desktopcomputer")
            .font(.footnote).foregroundStyle(health.engineReady ? Color.teal : Color.orange)
        LabeledContent("Dịch vụ trên PC", value: health.provider).font(.caption)
    }
}
