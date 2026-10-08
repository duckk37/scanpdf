import PDFKit
import SwiftUI
import UIKit

@MainActor
struct DocumentDetailView: View {
    let item: LibraryDocument
    var initialTool: String? = nil
    @EnvironmentObject private var store: DocumentStore
    @StateObject private var workingFiles = EditorWorkingFiles()
    @State private var document: PDFDocument?
    @State private var currentPage = 0
    @State private var selectedPages: Set<Int> = []
    @State private var activeSheet: EditorSheet?
    @State private var alert: EditorAlert?
    @State private var isLoading = true
    @State private var isProcessing = false
    @State private var processingTitle = ""
    @State private var showFullScreen = false
    @State private var showShare = false
    @State private var sourceWasLocked = false
    @State private var protectionPassword: String?
    @State private var unlockedURL: URL?
    @State private var unlockError: String?
    @State private var hasLaunchedInitialTool = false
    @State private var ocrText = ""
    @State private var confirmRemovePassword = false
    @State private var pendingSheetAction: (() -> Void)?
    @State private var showImageShare = false
    @State private var exportedImageURLs: [URL] = []
    @State private var imageExportDirectory: URL?

    private var currentItem: LibraryDocument { store.documents.first { $0.id == item.id } ?? item }
    private var sourceURL: URL { unlockedURL ?? store.url(for: currentItem) }
    private let columns = [GridItem(.adaptive(minimum: 98), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                documentHeader
                if let document {
                    preview(document)
                    pageNavigator(document)
                    toolGrid
                    if sourceWasLocked {
                        Label("Các thay đổi vẫn được bảo vệ bằng mật khẩu hiện tại.", systemImage: "lock.shield")
                            .font(.footnote).foregroundStyle(EditorPalette.muted)
                    }
                } else if isLoading {
                    ProgressView("Đang mở PDF…").frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ContentUnavailableView {
                        Label(sourceWasLocked ? "Tài liệu được bảo vệ" : "Không mở được PDF", systemImage: sourceWasLocked ? "lock.doc" : "doc.badge.ellipsis")
                    } description: {
                        Text(sourceWasLocked ? "Nhập mật khẩu để xem và sử dụng các công cụ PDF." : "Bạn có thể thử mở lại tài liệu.")
                    } actions: {
                        Button(sourceWasLocked ? "Nhập mật khẩu" : "Thử lại") {
                            if sourceWasLocked { unlockError = nil; activeSheet = .password }
                            else { Task { await loadDocument() } }
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }.padding(20)
        }
        .background(EditorPalette.paper)
        .navigationTitle("Tài liệu")
        .navigationBarTitleDisplayMode(.inline)
        .tint(EditorPalette.teal)
        .navigationBarBackButtonHidden(isProcessing)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Chia sẻ PDF").disabled(isProcessing || isLoading)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Đổi tên", systemImage: "pencil") { activeSheet = .rename }
                    Button("In PDF", systemImage: "printer") { printDocument() }.disabled(document == nil)
                    if document != nil {
                        Button("Tìm trong PDF", systemImage: "magnifyingglass") { activeSheet = .search }
                        Button("Xem toàn màn hình", systemImage: "arrow.up.left.and.arrow.down.right") { showFullScreen = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Tùy chọn tài liệu").disabled(isProcessing || isLoading)
            }
        }
        .sheet(item: $activeSheet, onDismiss: {
            let action = pendingSheetAction
            pendingSheetAction = nil
            action?()
        }) { sheet in sheetContent(sheet) }
        .sheet(isPresented: $showShare) { ActivitySheet(items: [store.url(for: currentItem)]) }
        .sheet(isPresented: $showImageShare, onDismiss: {
            if let imageExportDirectory { workingFiles.remove(imageExportDirectory) }
            imageExportDirectory = nil
            exportedImageURLs = []
        }) { ActivitySheet(items: exportedImageURLs.map { $0 as Any }) }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let document { FullScreenPDFView(document: document, name: currentItem.name, currentPage: $currentPage) }
        }
        .alert(item: $alert) { entry in
            Alert(title: Text(entry.title), message: Text(entry.message), dismissButton: .default(Text("Đóng")))
        }
        .confirmationDialog("Tạo bản sao không có mật khẩu?", isPresented: $confirmRemovePassword, titleVisibility: .visible) {
            Button("Tạo bản sao đã mở khóa") {
                runPDFOperation(title: "Đang gỡ mật khẩu…", outputName: currentItem.name + " - Mở khóa", preserveProtection: false) {
                    try PDFService.open(url: $0)
                }
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Bản sao mới có thể mở mà không cần mật khẩu. Tài liệu gốc vẫn được bảo vệ.")
        }
        .overlay {
            if isProcessing && activeSheet != .password {
                ZStack {
                    Color.black.opacity(0.22).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(processingTitle).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        Text("Vui lòng giữ ứng dụng mở.").font(.caption).foregroundStyle(.secondary)
                    }.padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                        .padding(40)
                }
            }
        }
        .task { await loadDocument() }
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentItem.name).font(.title2.bold()).foregroundStyle(EditorPalette.ink)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if let document {
                    Label("\(document.pageCount) trang", systemImage: "doc.on.doc")
                } else if sourceWasLocked {
                    Label("Có mật khẩu", systemImage: "lock.fill")
                }
                Text(ByteCountFormatter.string(fromByteCount: currentItem.byteCount, countStyle: .file))
                Spacer()
            }.font(.caption).foregroundStyle(EditorPalette.muted)
        }
    }

    private func preview(_ document: PDFDocument) -> some View {
        VStack(spacing: 0) {
            PDFViewer(document: document, currentPage: $currentPage)
                .frame(height: 360)
                .accessibilityLabel("Bản xem trước PDF")
            HStack {
                Text("Trang \(min(currentPage + 1, document.pageCount))/\(document.pageCount)")
                    .font(.caption.monospacedDigit()).foregroundStyle(EditorPalette.muted)
                Spacer()
                Button { showFullScreen = true } label: {
                    Label("Mở rộng", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                }
            }.padding(12).background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(EditorPalette.ink.opacity(0.06), lineWidth: 1))
    }

    private func pageNavigator(_ document: PDFDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Các trang").font(.headline).foregroundStyle(EditorPalette.ink)
                Spacer()
                if !selectedPages.isEmpty {
                    Button("Bỏ chọn (\(selectedPages.count))") { selectedPages.removeAll() }.font(.caption)
                }
            }
            Text("Chạm trang để xem và chọn cho thao tác tiếp theo.").font(.caption).foregroundStyle(EditorPalette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        Button {
                            currentPage = index
                            if selectedPages.contains(index) { selectedPages.remove(index) }
                            else { selectedPages.insert(index) }
                        } label: {
                            VStack(spacing: 7) {
                                PDFPageThumbnail(document: document, index: index, size: CGSize(width: 76, height: 104))
                                    .overlay(alignment: .topTrailing) {
                                        if selectedPages.contains(index) {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(EditorPalette.teal)
                                                .background(.white, in: Circle()).padding(4)
                                        }
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(currentPage == index ? EditorPalette.teal : .clear, lineWidth: 2))
                                Text("\(index + 1)").font(.caption.monospacedDigit())
                                    .foregroundStyle(currentPage == index ? EditorPalette.teal : EditorPalette.muted)
                            }
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Trang \(index + 1), \(selectedPages.contains(index) ? "đã chọn" : "chưa chọn")")
                    }
                }.padding(.vertical, 3)
            }
        }
    }

    private var toolGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Công cụ PDF").font(.headline).foregroundStyle(EditorPalette.ink)
            LazyVGrid(columns: columns, spacing: 12) {
                tool("Trích trang", icon: "doc.on.doc", id: "extract")
                tool("Xoay trang", icon: "rotate.right", id: "rotate")
                tool("Xóa trang", icon: "trash", id: "delete")
                tool("Sắp xếp", icon: "arrow.up.arrow.down", id: "reorder")
                tool("Chèn PDF", icon: "doc.badge.plus", id: "insert")
                tool("Nhân bản", icon: "plus.square.on.square", id: "duplicate")
                tool("Đánh số", icon: "list.number", id: "numberPages")
                tool("Xuất ảnh", icon: "photo.on.rectangle", id: "exportImages")
                tool("Nén PDF", icon: "arrow.down.right.and.arrow.up.left", id: "compress")
                tool("Watermark", icon: "textformat", id: "watermark")
                tool("Mật khẩu", icon: "lock", id: "protect")
                if sourceWasLocked { tool("Gỡ mật khẩu", icon: "lock.open", id: "unlock") }
                tool("Đọc chữ OCR", icon: "text.viewfinder", id: "ocr")
                tool("Chữ ký", icon: "signature", id: "sign")
            }
        }.disabled(isProcessing || isLoading)
    }

    private func tool(_ title: String, icon: String, id: String) -> some View {
        Button { presentTool(id) } label: {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 23, weight: .medium)).foregroundStyle(EditorPalette.teal)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(EditorPalette.ink)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 86)
            .padding(.horizontal, 6)
            .background(.white, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(EditorPalette.ink.opacity(0.04), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case .password:
            UnlockPDFSheet(isProcessing: isProcessing, error: unlockError, onUnlock: unlockDocument) {
                activeSheet = nil
            }
        case .rename:
            RenamePDFSheet(currentName: currentItem.name) { name in
                finishSheetThen {
                    do { try store.rename(currentItem, to: name) }
                    catch { showError(error) }
                }
            }
        case .pages(let action):
            if let document {
                PageOperationSheet(document: document, action: action,
                                   suggestedName: currentItem.name + " - Trích trang", initialSelection: selectedPages,
                                   onConfirm: { request in finishSheetThen { applyPageOperation(request) } })
            }
        case .reorder:
            if let document {
                ReorderPagesSheet(document: document) { order in
                    finishSheetThen {
                        runPDFOperation(title: "Đang sắp xếp…", overwrite: true) { try PDFService.reorder(url: $0, order: order) }
                    }
                }
            }
        case .compress:
            CompressPDFSheet { quality, dimension in
                finishSheetThen {
                    runPDFOperation(title: "Đang nén PDF…", outputName: currentItem.name + " - Nén") {
                        try PDFService.compress(url: $0, quality: quality, maxDimension: dimension)
                    }
                }
            }
        case .watermark:
            WatermarkPDFSheet { text in
                finishSheetThen {
                    runPDFOperation(title: "Đang thêm watermark…", outputName: currentItem.name + " - Watermark") {
                        try PDFService.watermark(url: $0, text: text)
                    }
                }
            }
        case .protect:
            ProtectPDFSheet { password in
                finishSheetThen {
                    runDataOperation(title: "Đang bảo vệ PDF…", outputName: currentItem.name + " - Bảo vệ", preserveProtection: false) {
                        try PDFService.protect(url: $0, password: password)
                    }
                }
            }
        case .signature:
            SignatureView(pageNumber: currentPage + 1) { image, placement in
                finishSheetThen { addSignature(image, placement: placement) }
            }
        case .ocr:
            OCRTextSheet(text: ocrText, name: currentItem.name)
        case .search:
            if document != nil { PDFSearchSheet(url: sourceURL) { index in currentPage = index } }
        case .exportImages:
            if let document {
                ExportPDFImagesSheet(document: document, initialSelection: selectedPages) { request in
                    finishSheetThen { exportPDFImages(request) }
                }
            }
        case .insert:
            InsertPDFSheet(currentPage: currentPage) { request in
                finishSheetThen { insertPDF(request) }
            }
        case .numberPages:
            if let document {
                NumberPDFPagesSheet(pageCount: document.pageCount) { position, start in
                    finishSheetThen {
                        runPDFOperation(title: "Đang đánh số trang…", outputName: currentItem.name + " - Đánh số") {
                            try PDFService.numberPages(url: $0, position: position, start: start)
                        }
                    }
                }
            }
        }
    }

    private func presentTool(_ id: String) {
        guard document != nil, !isProcessing else { return }
        switch id {
        case "extract": activeSheet = .pages(.extract)
        case "rotate": activeSheet = .pages(.rotate)
        case "delete": activeSheet = .pages(.delete)
        case "reorder": activeSheet = .reorder
        case "compress": activeSheet = .compress
        case "watermark": activeSheet = .watermark
        case "protect": activeSheet = .protect
        case "unlock":
            if sourceWasLocked { confirmRemovePassword = true }
            else { alert = EditorAlert(title: "Không cần gỡ mật khẩu", message: "Tài liệu này đang mở được mà không cần mật khẩu.") }
        case "ocr": recognizeText()
        case "sign": activeSheet = .signature
        case "duplicate": activeSheet = .pages(.duplicate)
        case "insert": activeSheet = .insert
        case "numberPages": activeSheet = .numberPages
        case "exportImages": activeSheet = .exportImages
        default: break
        }
    }

    private func launchInitialToolIfNeeded() {
        guard !hasLaunchedInitialTool, let initialTool else { return }
        hasLaunchedInitialTool = true
        presentTool(initialTool)
    }

    private func finishSheetThen(_ action: @escaping () -> Void) {
        pendingSheetAction = action
        activeSheet = nil
    }

    private func loadDocument() async {
        isLoading = true
        let url = store.url(for: currentItem)
        let password = protectionPassword
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> EditorLoadResult in
                guard let source = PDFDocument(url: url) else { throw PDFServiceError.invalidPDF }
                if source.isLocked {
                    guard let password else { return .locked }
                    let unlocked = try PDFService.unlock(url: url, password: password)
                    guard let data = unlocked.dataRepresentation() else { throw PDFServiceError.renderingFailed }
                    return .ready(data, wasLocked: true)
                }
                let opened = try PDFService.open(url: url)
                guard let data = opened.dataRepresentation() else { throw PDFServiceError.renderingFailed }
                return .ready(data, wasLocked: false)
            }.value
            switch loaded {
            case .locked:
                document = nil
                sourceWasLocked = true
                unlockError = nil
                activeSheet = .password
            case .ready(let data, let wasLocked):
                try install(data: data, wasLocked: wasLocked)
                launchInitialToolIfNeeded()
            }
        } catch {
            document = nil
            showError(error)
        }
        isLoading = false
    }

    private func install(data: Data, wasLocked: Bool) throws {
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw PDFServiceError.invalidPDF }
        let replacementURL = wasLocked ? try workingFiles.write(data) : nil
        if let previous = unlockedURL { workingFiles.remove(previous) }
        unlockedURL = replacementURL
        sourceWasLocked = wasLocked
        document = pdf
        currentPage = min(currentPage, pdf.pageCount - 1)
        selectedPages = selectedPages.filter { $0 < pdf.pageCount }
    }

    private func unlockDocument(_ password: String) {
        guard !isProcessing else { return }
        isProcessing = true
        unlockError = nil
        let url = store.url(for: currentItem)
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let unlocked = try PDFService.unlock(url: url, password: password)
                    guard let data = unlocked.dataRepresentation() else { throw PDFServiceError.renderingFailed }
                    return data
                }.value
                try install(data: data, wasLocked: true)
                protectionPassword = password
                isProcessing = false
                finishSheetThen { launchInitialToolIfNeeded() }
            } catch {
                unlockError = error.localizedDescription
                isProcessing = false
            }
        }
    }

    private func applyPageOperation(_ request: PageOperationRequest) {
        switch request {
        case .extract(let pages, let name):
            runPDFOperation(title: "Đang trích xuất trang…", outputName: name) { try PDFService.extract(url: $0, pages: pages) }
        case .rotate(let pages, let degrees):
            runPDFOperation(title: "Đang xoay trang…", overwrite: true) { try PDFService.rotate(url: $0, pages: pages, degrees: degrees) }
        case .delete(let pages):
            runPDFOperation(title: "Đang xóa trang…", overwrite: true) { try PDFService.deletePages(url: $0, pages: pages) }
        case .duplicate(let pages):
            runPDFOperation(title: "Đang nhân bản trang…", overwrite: true) { try PDFService.duplicate(url: $0, pages: pages) }
        }
    }

    private func insertPDF(_ request: InsertPDFRequest) {
        do {
            let importedURL = try workingFiles.makeFileURL()
            runPDFOperation(title: "Đang chèn PDF…", overwrite: true) { currentURL in
                defer { try? FileManager.default.removeItem(at: importedURL) }
                try request.data.write(to: importedURL, options: .atomic)
                return try PDFService.insert(url: currentURL, from: importedURL, at: request.insertionIndex)
            }
        } catch { showError(error) }
    }

    private func exportPDFImages(_ request: PDFImageExportRequest) {
        guard document != nil, !isProcessing else { return }
        isProcessing = true
        processingTitle = "Đang xuất \(request.pages.count) trang thành ảnh…"
        let url = sourceURL
        let name = currentItem.name
        Task {
            var directory: URL?
            do {
                let destination = try workingFiles.makeExportDirectory()
                directory = destination
                let urls = try await Task.detached(priority: .userInitiated) {
                    let images = try PDFService.exportImages(url: url, pages: request.pages, format: request.format,
                                                            maxDimension: request.maxDimension, quality: request.quality)
                    let unsafeCharacters = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
                    let cleanName = String(name.prefix(70)).components(separatedBy: unsafeCharacters).joined(separator: "-")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let basename = cleanName.isEmpty ? "Tài liệu" : cleanName
                    return try images.map { image in
                        let pageNumber = String(format: "%03d", image.pageIndex + 1)
                        let output = destination.appendingPathComponent("\(basename) - trang-\(pageNumber)")
                            .appendingPathExtension(request.format.fileExtension)
                        try image.data.write(to: output, options: .atomic)
                        return output
                    }
                }.value
                exportedImageURLs = urls
                imageExportDirectory = destination
                isProcessing = false
                showImageShare = true
            } catch {
                if let directory { workingFiles.remove(directory) }
                isProcessing = false
                showError(error)
            }
        }
    }

    private func addSignature(_ image: UIImage, placement: SignaturePlacement) {
        let index = currentPage
        // Keep the signature's proportions on portrait and landscape pages.
        let bounds = document?.page(at: index)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let rotation = document?.page(at: index)?.rotation ?? 0
        let landscapeRotation = (rotation % 180 + 180) % 180 == 90
        let pageSize = landscapeRotation ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let width: CGFloat = 0.34
        let height = min(0.16, max(0.025, width * pageSize.width / max(1, pageSize.height) * image.size.height / max(1, image.size.width)))
        let x: CGFloat = placement == .bottomLeft ? 0.06 : (placement == .center ? (1 - width) / 2 : 1 - width - 0.06)
        let y: CGFloat = placement == .center ? (1 - height) / 2 : 1 - height - 0.07
        let rect = CGRect(x: x, y: y, width: width, height: height)
        runPDFOperation(title: "Đang thêm chữ ký…", outputName: currentItem.name + " - Đã ký") {
            try PDFService.signature(url: $0, page: index, image: image, relativeRect: rect)
        }
    }

    private func runPDFOperation(title: String, outputName: String? = nil, overwrite: Bool = false,
                                 preserveProtection: Bool = true, work: @escaping @Sendable (URL) throws -> PDFDocument) {
        runDataOperation(title: title, outputName: outputName, overwrite: overwrite, preserveProtection: preserveProtection) { url in
            let result = try work(url)
            guard let data = result.dataRepresentation() else { throw PDFServiceError.renderingFailed }
            return data
        }
    }

    private func runDataOperation(title: String, outputName: String? = nil, overwrite: Bool = false,
                                  preserveProtection: Bool = true, work: @escaping @Sendable (URL) throws -> Data) {
        guard document != nil, !isProcessing else { return }
        isProcessing = true
        processingTitle = title
        let url = sourceURL
        let original = currentItem
        let password = preserveProtection ? protectionPassword : nil
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let result = try work(url)
                    if let password {
                        let intermediate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
                        defer { try? FileManager.default.removeItem(at: intermediate) }
                        try result.write(to: intermediate, options: .atomic)
                        return try PDFService.protect(url: intermediate, password: password)
                    }
                    return result
                }.value
                if overwrite {
                    try store.replace(original, with: data)
                    selectedPages.removeAll()
                    await loadDocument()
                } else {
                    let saved = try store.save(data: data, name: outputName ?? original.name + " - Bản sao")
                    alert = EditorAlert(title: "Đã lưu bản sao", message: "“\(saved.name)” đã được thêm vào thư viện.")
                }
            } catch { showError(error) }
            isProcessing = false
        }
    }

    private func recognizeText() {
        guard !isProcessing else { return }
        isProcessing = true
        processingTitle = "Đang nhận dạng văn bản…"
        let url = sourceURL
        Task {
            do {
                let text = try await PDFService.recognizeText(url: url)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    alert = EditorAlert(title: "Chưa tìm thấy văn bản", message: "Thử tài liệu có chữ rõ nét hơn. OCR chạy trực tiếp trên thiết bị.")
                } else {
                    ocrText = text
                    activeSheet = .ocr
                }
            } catch { showError(error) }
            isProcessing = false
        }
    }

    private func printDocument() {
        guard UIPrintInteractionController.isPrintingAvailable else {
            alert = EditorAlert(title: "Không thể in", message: "Dịch vụ in hiện không khả dụng trên thiết bị này.")
            return
        }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = currentItem.name
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = sourceURL
        let completion: (UIPrintInteractionController, Bool, Error?) -> Void = { _, _, error in
            if let error { Task { @MainActor in showError(error) } }
        }
        if UIDevice.current.userInterfaceIdiom == .pad,
           let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let view = scene.windows.first(where: \.isKeyWindow)?.rootViewController?.view {
            controller.present(from: CGRect(x: view.bounds.midX, y: 60, width: 1, height: 1), in: view,
                               animated: true, completionHandler: completion)
        } else {
            controller.present(animated: true, completionHandler: completion)
        }
    }

    private func showError(_ error: Error) {
        alert = EditorAlert(title: "Không thể hoàn tất", message: error.localizedDescription)
    }
}

private enum EditorPalette {
    static let ink = Color(red: 0.08, green: 0.15, blue: 0.24)
    static let teal = Color(red: 0.02, green: 0.53, blue: 0.51)
    static let paper = Color(uiColor: .systemGroupedBackground)
    static let muted = Color.secondary
}

private enum EditorSheet: Identifiable, Equatable {
    case password, rename, pages(PDFPageAction), reorder, compress, watermark, protect, signature, ocr, search
    case exportImages, insert, numberPages
    var id: String {
        switch self {
        case .password: return "password"
        case .rename: return "rename"
        case .pages(let action): return action.rawValue
        case .reorder: return "reorder"
        case .compress: return "compress"
        case .watermark: return "watermark"
        case .protect: return "protect"
        case .signature: return "signature"
        case .ocr: return "ocr"
        case .search: return "search"
        case .exportImages: return "exportImages"
        case .insert: return "insert"
        case .numberPages: return "numberPages"
        }
    }
}

private struct EditorAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum EditorLoadResult {
    case locked
    case ready(Data, wasLocked: Bool)
}

/// Unencrypted working copies live only in temporary storage and are removed with the editor.
private final class EditorWorkingFiles: ObservableObject {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScanPDF-Editor-" + UUID().uuidString, isDirectory: true)

    func write(_ data: Data) throws -> URL {
        let url = try makeFileURL()
        try data.write(to: url, options: .atomic)
        return url
    }

    func makeFileURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
    }

    func makeExportDirectory() throws -> URL {
        let destination = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
