import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFImageExportRequest {
    let pages: [Int]
    let format: PDFImageFormat
    let maxDimension: CGFloat
    let quality: CGFloat
}

struct ExportPDFImagesSheet: View {
    let document: PDFDocument
    let initialSelection: Set<Int>
    let onExport: (PDFImageExportRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int> = []
    @State private var format: PDFImageFormat = .png
    @State private var maxDimension = 2000
    @State private var quality = 0.9

    private var estimatedPixels: Double {
        selection.reduce(0) { total, index in
            guard let bounds = document.page(at: index)?.bounds(for: .cropBox),
                  bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return .infinity }
            let scale = min(4, CGFloat(maxDimension) / max(bounds.width, bounds.height))
            return total + Double(ceil(max(1, bounds.width * scale)) * ceil(max(1, bounds.height * scale)))
        }
    }

    private var exceedsLimit: Bool { selection.count > 40 || estimatedPixels > 40_000_000 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ảnh xuất") {
                    Picker("Định dạng", selection: $format) {
                        Text("PNG · Không mất chất lượng").tag(PDFImageFormat.png)
                        Text("JPEG · Dung lượng nhỏ").tag(PDFImageFormat.jpeg)
                    }
                    Picker("Cạnh dài tối đa", selection: $maxDimension) {
                        Text("1.200 px").tag(1200)
                        Text("2.000 px").tag(2000)
                        Text("3.000 px").tag(3000)
                    }
                    if format == .jpeg {
                        HStack { Text("Chất lượng JPEG"); Spacer(); Text("\(Int(quality * 100))%").monospacedDigit() }
                        Slider(value: $quality, in: 0.4...1, step: 0.05)
                    }
                }

                Section {
                    HStack {
                        Text("Đã chọn \(selection.count)/\(document.pageCount) trang")
                        Spacer()
                        Button(selection.count == document.pageCount ? "Bỏ chọn" : "Chọn tất cả") {
                            selection = selection.count == document.pageCount ? [] : Set(0..<document.pageCount)
                        }.font(.caption)
                    }
                    ScrollView {
                        EditorPageSelectionGrid(document: document, selection: $selection)
                    }.frame(height: document.pageCount <= 3 ? 146 : 320)
                } header: { Text("Chọn trang cần xuất") }

                Section {
                    if exceedsLimit {
                        Label("Giảm số trang hoặc kích thước ảnh trước khi xuất.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).font(.footnote)
                    }
                    Text("Mỗi lần xuất tối đa 40 trang và 40 triệu pixel để sử dụng bộ nhớ ổn định. Tổng đã chọn: \(pixelSummary).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Mỗi trang thành một tệp ảnh để chia sẻ hoặc lưu vào Tệp/Ảnh. Ảnh không có mật khẩu PDF và không chứa lớp văn bản OCR.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PDF thành ảnh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xuất ảnh") {
                        onExport(PDFImageExportRequest(pages: selection.sorted(), format: format,
                                                      maxDimension: CGFloat(maxDimension), quality: CGFloat(quality)))
                    }.bold().disabled(selection.isEmpty || exceedsLimit)
                }
            }
            .onAppear { selection = initialSelection.isEmpty ? Set(0..<document.pageCount) : initialSelection }
            .tint(.teal)
        }
    }

    private var pixelSummary: String {
        guard estimatedPixels.isFinite else { return "kích thước trang không hợp lệ" }
        return String(format: "%.1f triệu pixel", estimatedPixels / 1_000_000)
    }
}

private struct EditorPageSelectionGrid: View {
    let document: PDFDocument
    @Binding var selection: Set<Int>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 14) {
            ForEach(0..<document.pageCount, id: \.self) { index in
                Button {
                    if selection.contains(index) { selection.remove(index) }
                    else { selection.insert(index) }
                } label: {
                    VStack(spacing: 6) {
                        PDFPageThumbnail(document: document, index: index, size: CGSize(width: 78, height: 104))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: selection.contains(index) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(index) ? Color.teal : Color.gray)
                                    .background(.white, in: Circle()).padding(4)
                            }
                        Text("Trang \(index + 1)").font(.caption).foregroundStyle(.primary)
                    }
                }.buttonStyle(.plain)
                    .accessibilityLabel("Trang \(index + 1), \(selection.contains(index) ? "đã chọn" : "chưa chọn")")
            }
        }.padding(.vertical, 8)
    }
}

struct InsertPDFRequest {
    let data: Data
    let insertionIndex: Int
}

struct InsertPDFSheet: View {
    let currentPage: Int
    let onInsert: (InsertPDFRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var imported: InsertionPDFSource?
    @State private var password = ""
    @State private var insertAfter = true
    @State private var isReading = false
    @State private var isValidating = false
    @State private var errorMessage: String?

    private var isBusy: Bool { isReading || isValidating }

    var body: some View {
        NavigationStack {
            Form {
                Section("PDF cần chèn") {
                    Button {
                        errorMessage = nil
                        showImporter = true
                    } label: {
                        Label(imported == nil ? "Chọn PDF từ Tệp" : "Chọn PDF khác", systemImage: "folder")
                    }.disabled(isBusy)
                    if let imported {
                        Label(imported.name, systemImage: "doc.richtext").lineLimit(2)
                        if imported.isLocked {
                            SecureField("Mật khẩu của PDF được chèn", text: $password).textContentType(.password)
                            Text("PDF này có mật khẩu. Nhập mật khẩu để chèn các trang.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("\(imported.pageCount) trang").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if isReading { ProgressView("Đang đọc PDF…") }
                    if isValidating { ProgressView("Đang kiểm tra PDF…") }
                    if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }

                Section("Vị trí chèn") {
                    Text("Trang hiện tại: \(currentPage + 1)")
                    Picker("Vị trí", selection: $insertAfter) {
                        Text("Trước trang này").tag(false)
                        Text("Sau trang này").tag(true)
                    }.pickerStyle(.segmented)
                }.disabled(isBusy)

                Section {
                    Text("Tất cả các trang của PDF đã chọn sẽ được chèn theo thứ tự gốc. Thay đổi được lưu vào tài liệu hiện tại; mật khẩu hiện có của tài liệu này vẫn được giữ.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Chèn PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() }.disabled(isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chèn") { validateAndInsert() }
                        .bold().disabled(imported == nil || isBusy || (imported?.isLocked == true && password.isEmpty))
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { readImportedPDF(url) }
                case .failure(let error):
                    let nsError = error as NSError
                    if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .interactiveDismissDisabled(isBusy)
            .tint(.teal)
        }
    }

    private func readImportedPDF(_ url: URL) {
        isReading = true
        imported = nil
        password = ""
        errorMessage = nil
        Task {
            do {
                imported = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    var coordinationError: NSError?
                    var readResult: Result<Data, Error>?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                        readResult = Result { try Data(contentsOf: readable) }
                    }
                    if let coordinationError { throw coordinationError }
                    guard let readResult else { throw PDFServiceError.invalidPDF }
                    let data = try readResult.get()
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try data.write(to: staging, options: .atomic)
                    guard let parsed = PDFDocument(data: data) else { throw PDFServiceError.invalidPDF }
                    if !parsed.isLocked { _ = try PDFService.open(url: staging) }
                    return InsertionPDFSource(data: data, name: url.deletingPathExtension().lastPathComponent,
                                              pageCount: parsed.pageCount, isLocked: parsed.isLocked)
                }.value
            } catch { errorMessage = error.localizedDescription }
            isReading = false
        }
    }

    private func validateAndInsert() {
        guard let imported, !isBusy else { return }
        isValidating = true
        errorMessage = nil
        let suppliedPassword = password
        let insertionIndex = currentPage + (insertAfter ? 1 : 0)
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try imported.data.write(to: staging, options: .atomic)
                    let unlocked = try PDFService.unlock(url: staging, password: suppliedPassword)
                    guard let data = unlocked.dataRepresentation() else { throw PDFServiceError.renderingFailed }
                    return data
                }.value
                onInsert(InsertPDFRequest(data: data, insertionIndex: insertionIndex))
            } catch {
                errorMessage = error.localizedDescription
                isValidating = false
            }
        }
    }
}

private struct InsertionPDFSource {
    let data: Data
    let name: String
    let pageCount: Int
    let isLocked: Bool
}

struct NumberPDFPagesSheet: View {
    let pageCount: Int
    let onNumber: (PageNumberPosition, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position: PageNumberPosition = .bottomCenter
    @State private var startingNumber = 1
    private var validStartingNumber: Bool { (1...1_000_000).contains(startingNumber) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Số trang") {
                    HStack {
                        Text("Số bắt đầu")
                        TextField("1", value: $startingNumber, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .accessibilityLabel("Số trang bắt đầu")
                    }
                    Stepper("Điều chỉnh từng số", value: $startingNumber, in: 1...1_000_000)
                    Picker("Vị trí", selection: $position) {
                        ForEach(PageNumberPosition.allCases, id: \.self) { value in Text(value.title).tag(value) }
                    }
                    if validStartingNumber {
                        Text("\(pageCount) trang sẽ được đánh số từ \(startingNumber) đến \(startingNumber + max(0, pageCount - 1)).")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Nhập số bắt đầu từ 1 đến 1.000.000.").font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    Label("Lưu thành một bản sao mới", systemImage: "doc.on.doc")
                    Text("Số trang được thêm ở lề trên hoặc dưới. Bản sao giữ mật khẩu của tài liệu hiện tại và vẫn có thể chọn văn bản gốc. Biểu mẫu và chú thích sẽ được cố định thành nội dung hiển thị.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Đánh số trang")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tạo bản sao") { onNumber(position, startingNumber) }.bold().disabled(!validStartingNumber)
                }
            }
            .tint(.teal)
        }
    }
}
