import PDFKit
import SwiftUI

enum PDFPageAction: String {
    case extract, rotate, delete, duplicate

    var title: String {
        switch self {
        case .extract: return "Trích xuất trang"
        case .rotate: return "Xoay trang"
        case .delete: return "Xóa trang"
        case .duplicate: return "Nhân bản trang"
        }
    }
}

enum PageOperationRequest {
    case extract(pages: [Int], name: String)
    case rotate(pages: [Int], degrees: Int)
    case delete(pages: [Int])
    case duplicate(pages: [Int])
}

struct PageOperationSheet: View {
    let document: PDFDocument
    let action: PDFPageAction
    let suggestedName: String
    let initialSelection: Set<Int>
    let onConfirm: (PageOperationRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int> = []
    @State private var degrees = 90
    @State private var outputName = ""
    @State private var confirmDelete = false

    private var canConfirm: Bool {
        !selection.isEmpty && (action != .delete || selection.count < document.pageCount)
            && (action != .extract || !outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Đã chọn \(selection.count)/\(document.pageCount) trang")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(selection.count == document.pageCount ? "Bỏ chọn" : "Chọn tất cả") {
                            selection = selection.count == document.pageCount ? [] : Set(0..<document.pageCount)
                        }.font(.subheadline)
                    }
                    if action == .rotate {
                        Picker("Hướng xoay", selection: $degrees) {
                            Text("90° phải").tag(90)
                            Text("90° trái").tag(-90)
                            Text("180°").tag(180)
                        }.pickerStyle(.segmented)
                    }
                    if action == .extract {
                        TextField("Tên bản sao mới", text: $outputName)
                            .textFieldStyle(.roundedBorder)
                        Text("Các trang được chọn sẽ được lưu theo thứ tự hiện tại vào một PDF mới.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if action == .delete {
                        Text(selection.count == document.pageCount
                             ? "Cần giữ lại ít nhất một trang trong tài liệu."
                             : "Các trang đã chọn sẽ bị xóa khỏi tài liệu này.")
                            .font(.footnote).foregroundStyle(selection.count == document.pageCount ? Color.red : Color.secondary)
                    }
                    if action == .duplicate {
                        Text("Thêm một bản sao ngay sau mỗi trang đã chọn. Thay đổi được lưu vào tài liệu hiện tại.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 16)], spacing: 18) {
                        ForEach(0..<document.pageCount, id: \.self) { index in
                            Button {
                                if selection.contains(index) { selection.remove(index) }
                                else { selection.insert(index) }
                            } label: {
                                VStack(spacing: 8) {
                                    PDFPageThumbnail(document: document, index: index, size: CGSize(width: 96, height: 128))
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: selection.contains(index) ? "checkmark.circle.fill" : "circle")
                                                .font(.title3).foregroundStyle(selection.contains(index) ? Color.teal : Color.gray)
                                                .background(.white, in: Circle()).padding(5)
                                        }
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(selection.contains(index) ? Color.teal : Color.clear, lineWidth: 2))
                                    Text("Trang \(index + 1)").font(.caption).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Trang \(index + 1), \(selection.contains(index) ? "đã chọn" : "chưa chọn")")
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action == .delete ? "Xóa" : "Áp dụng") {
                        if action == .delete { confirmDelete = true } else { submit() }
                    }.bold().disabled(!canConfirm)
                }
            }
            .confirmationDialog("Xóa \(selection.count) trang đã chọn?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Xóa trang", role: .destructive) { submit() }
                Button("Hủy", role: .cancel) {}
            } message: { Text("Thay đổi này sẽ được lưu vào tài liệu hiện tại.") }
            .onAppear {
                selection = initialSelection
                outputName = suggestedName
            }
            .tint(.teal)
        }
    }

    private func submit() {
        let pages = selection.sorted()
        switch action {
        case .extract: onConfirm(.extract(pages: pages, name: outputName.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .rotate: onConfirm(.rotate(pages: pages, degrees: degrees))
        case .delete: onConfirm(.delete(pages: pages))
        case .duplicate: onConfirm(.duplicate(pages: pages))
        }
    }
}

struct ReorderPagesSheet: View {
    let document: PDFDocument
    let onSave: ([Int]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var order: [Int] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.self) { index in
                        HStack(spacing: 14) {
                            PDFPageThumbnail(document: document, index: index, size: CGSize(width: 42, height: 56))
                            Text("Trang gốc \(index + 1)").font(.subheadline.weight(.medium))
                        }.padding(.vertical, 3)
                    }
                    .onMove { offsets, destination in order.move(fromOffsets: offsets, toOffset: destination) }
                } header: {
                    Text("Kéo tay nắm bên phải để đổi thứ tự")
                } footer: {
                    Text("Lưu sẽ cập nhật tài liệu hiện tại.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Sắp xếp trang")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { onSave(order) }
                        .bold().disabled(order.isEmpty || order == Array(0..<document.pageCount))
                }
            }
            .onAppear { order = Array(0..<document.pageCount) }
            .tint(.teal)
        }
    }
}

struct CompressPDFSheet: View {
    let onCompress: (CGFloat, CGFloat) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var quality = 0.68
    @State private var maxDimension = 1800

    var body: some View {
        NavigationStack {
            Form {
                Section("Chất lượng ảnh") {
                    HStack { Text("JPEG"); Spacer(); Text("\(Int(quality * 100))%").monospacedDigit() }
                    Slider(value: $quality, in: 0.3...0.9, step: 0.05)
                    Picker("Cạnh dài tối đa", selection: $maxDimension) {
                        Text("1.200 px · Nhỏ").tag(1200)
                        Text("1.800 px · Cân bằng").tag(1800)
                        Text("2.400 px · Rõ nét").tag(2400)
                    }
                }
                Section {
                    Label("Tạo bản sao đã nén", systemImage: "doc.on.doc")
                    Text("Mỗi trang sẽ được chuyển thành ảnh JPEG. Văn bản chọn được, liên kết, biểu mẫu và chú thích sẽ không còn tương tác. Dung lượng có thể tăng với PDF vốn đã nhỏ.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Nén PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Nén") { onCompress(CGFloat(quality), CGFloat(maxDimension)) }.bold()
                }
            }
            .tint(.teal)
        }
    }
}

struct WatermarkPDFSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = "BẢN SAO"

    var body: some View {
        NavigationStack {
            Form {
                Section("Nội dung watermark") {
                    TextField("Ví dụ: BẢN SAO", text: $text, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    Text("Đặt chữ mờ chéo giữa tất cả các trang. Kết quả được lưu thành một bản sao mới trong thư viện.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Thêm watermark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tạo bản sao") { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .bold().disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .tint(.teal)
        }
    }
}

struct ProtectPDFSheet: View {
    let onProtect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Mật khẩu mở tài liệu") {
                    SecureField("Mật khẩu mới", text: $password).textContentType(.newPassword)
                    SecureField("Nhập lại mật khẩu", text: $confirmation).textContentType(.newPassword)
                    if !confirmation.isEmpty && password != confirmation {
                        Text("Mật khẩu nhập lại chưa khớp.").font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    Text("Một bản sao có mật khẩu sẽ được tạo. Hãy lưu mật khẩu ở nơi an toàn; ứng dụng không có chức năng khôi phục mật khẩu.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Bảo vệ PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bảo vệ") { onProtect(password) }
                        .bold().disabled(password.isEmpty || password != confirmation)
                }
            }
            .tint(.teal)
        }
    }
}

struct UnlockPDFSheet: View {
    let isProcessing: Bool
    let error: String?
    let onUnlock: (String) -> Void
    let onCancel: () -> Void
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("PDF này được bảo vệ bằng mật khẩu", systemImage: "lock.doc")
                    SecureField("Mật khẩu mở PDF", text: $password)
                        .textContentType(.password).onSubmit { if !password.isEmpty && !isProcessing { onUnlock(password) } }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if isProcessing { ProgressView("Đang mở khóa…") }
                } footer: {
                    Text("Nhập mật khẩu để xem và chỉnh sửa. Khi chỉnh sửa tài liệu này, mật khẩu vẫn được giữ lại.")
                }
            }
            .navigationTitle("Mở khóa tài liệu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy", action: onCancel).disabled(isProcessing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mở khóa") { onUnlock(password) }.bold().disabled(password.isEmpty || isProcessing)
                }
            }
            .interactiveDismissDisabled(isProcessing)
            .tint(.teal)
        }
    }
}

struct OCRTextSheet: View {
    let text: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var textURL: URL?
    @State private var sharing = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .navigationTitle("Văn bản OCR")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Label(copied ? "Đã sao chép" : "Sao chép", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Spacer()
                    Button {
                        do {
                            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                            let url = directory.appendingPathComponent(String(safeName.prefix(80))).appendingPathExtension("txt")
                            try text.write(to: url, atomically: true, encoding: .utf8)
                            textURL = url
                            sharing = true
                        } catch { exportError = error.localizedDescription }
                    } label: { Label("Xuất TXT", systemImage: "square.and.arrow.up") }
                }
                .font(.subheadline.weight(.semibold)).padding(20).background(.bar)
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Đóng") { dismiss() } } }
            .sheet(isPresented: $sharing, onDismiss: {
                if let textURL { try? FileManager.default.removeItem(at: textURL.deletingLastPathComponent()) }
                textURL = nil
            }) {
                if let textURL { ActivitySheet(items: [textURL]) }
            }
            .alert("Không thể xuất văn bản", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("Đóng", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "") }
            .tint(.teal)
        }
    }
}

struct RenamePDFSheet: View {
    let currentName: String
    let onRename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form { TextField("Tên tài liệu", text: $name) }
                .navigationTitle("Đổi tên PDF")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Lưu") { onRename(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .bold().disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { name = currentName }
                .tint(.teal)
        }
    }
}
