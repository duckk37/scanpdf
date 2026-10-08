import SwiftUI
import PhotosUI
import PDFKit
import VisionKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @Binding var entry: LibraryEntryAction?
    @State private var path: [LibraryDocument] = []
    @State private var search = ""
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var showScanner = false
    @State private var pendingScanImages: [UIImage] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var capture: CaptureBatch?
    @State private var share: SharePayload?
    @State private var renameItem: LibraryDocument?
    @State private var newName = ""
    @State private var deleteItem: LibraryDocument?
    @State private var error: String?
    @State private var busy = false
    @State private var cameraDenied = false
    @State private var mergeName = "PDF đã ghép"
    @State private var showMerge = false
    @AppStorage("librarySort") private var sortValue = LibrarySort.recent.rawValue
    @AppStorage("libraryFavoritesOnly") private var favoritesOnly = false

    private var sort: LibrarySort { LibrarySort(rawValue: sortValue) ?? .recent }
    private var sortedDocuments: [LibraryDocument] { store.documents.sorted(by: sort.comesBefore) }

    private var filtered: [LibraryDocument] {
        sortedDocuments.filter {
            (!favoritesOnly || $0.isFavorite) && (search.isEmpty || $0.name.localizedStandardContains(search))
        }
    }
    private var emptyTitle: String {
        if !search.isEmpty { return "Không tìm thấy tài liệu" }
        return favoritesOnly ? "Chưa có tài liệu yêu thích" : "Bắt đầu với bản quét đầu tiên"
    }
    private var emptyDescription: String {
        if !search.isEmpty { return favoritesOnly ? "Thử tên khác hoặc tắt bộ lọc yêu thích." : "Thử tìm bằng tên khác." }
        return favoritesOnly ? "Nhấn giữ tài liệu và chọn Yêu thích. Tắt bộ lọc để xem toàn bộ thư viện." : "Quét tài liệu, nhập ảnh hoặc mở PDF từ Files."
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    scanBanner
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tài liệu của bạn").font(.title3.bold())
                            Text("\(store.documents.count) tài liệu · Lưu trên thiết bị").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !store.documents.isEmpty {
                            Button(selecting ? "Xong" : "Chọn") {
                                selecting.toggle(); selection.removeAll()
                            }.font(.subheadline.weight(.semibold))
                        }
                    }
                    HStack {
                        Button { favoritesOnly.toggle() } label: {
                            Label(favoritesOnly ? "Đang xem yêu thích" : "Yêu thích", systemImage: favoritesOnly ? "star.fill" : "star")
                        }
                        .buttonStyle(.bordered)
                        .tint(favoritesOnly ? Theme.teal : .secondary)
                        Spacer(minLength: 8)
                        Menu {
                            Picker("Sắp xếp", selection: $sortValue) {
                                ForEach(LibrarySort.allCases) { choice in Text(choice.title).tag(choice.rawValue) }
                            }
                        } label: { Label(sort.title, systemImage: "arrow.up.arrow.down") }
                    }.font(.caption.weight(.medium))
                    if filtered.isEmpty {
                        ContentUnavailableView(emptyTitle,
                            systemImage: !search.isEmpty ? "magnifyingglass" : (favoritesOnly ? "star" : "doc.viewfinder"),
                            description: Text(emptyDescription))
                            .padding(.vertical, 24)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filtered) { item in
                                Button {
                                    if selecting { toggle(item.id) } else { path.append(item) }
                                } label: {
                                    DocumentRow(item: item, url: store.url(for: item), selecting: selecting, selected: selection.contains(item.id))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        do { try store.toggleFavorite(item) } catch { self.error = error.localizedDescription }
                                    } label: { Label(item.isFavorite ? "Bỏ yêu thích" : "Yêu thích", systemImage: item.isFavorite ? "star.slash" : "star") }
                                    Button { share = SharePayload(items: [store.url(for: item)]) } label: { Label("Chia sẻ PDF", systemImage: "square.and.arrow.up") }
                                    Button { renameItem = item; newName = item.name } label: { Label("Đổi tên", systemImage: "pencil") }
                                    Button(role: .destructive) { deleteItem = item } label: { Label("Xóa tài liệu", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }.padding(20)
            }
            .background(Theme.paper)
            .navigationTitle("ScanPDF")
            .searchable(text: $search, prompt: "Tìm tài liệu")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { run(.scan) } label: { Label("Quét camera", systemImage: "doc.viewfinder") }
                        Button { run(.photos) } label: { Label("Ảnh thành PDF", systemImage: "photo.on.rectangle") }
                        Button { run(.files) } label: { Label("Nhập PDF", systemImage: "folder") }
                        Button { run(.merge) } label: { Label("Ghép PDF", systemImage: "doc.on.doc") }
                    } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Text("Đã chọn \(selection.count)").font(.subheadline)
                        Spacer()
                        Button { showMerge = true } label: { Label("Ghép PDF", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderedProminent).disabled(selection.count < 2 || busy)
                    }.padding().background(.regularMaterial)
                }
            }
            .navigationDestination(for: LibraryDocument.self) { DocumentDetailView(item: $0) }
            .overlay { if busy { BusyOverlay(title: "Đang xử lý tài liệu…") } }
            .fullScreenCover(isPresented: $showScanner, onDismiss: {
                if !pendingScanImages.isEmpty {
                    capture = CaptureBatch(images: pendingScanImages)
                    pendingScanImages = []
                }
            }) {
                DocumentScanner { result in
                    showScanner = false
                    switch result {
                    case .success(let images): pendingScanImages = images
                    case .failure(let failure): error = failure.localizedDescription
                    }
                }.ignoresSafeArea()
            }
            .sheet(item: $capture) { batch in
                ScanReviewView(images: batch.images) { item in
                    capture = nil
                    path.append(item)
                }
            }
            .sheet(item: $share) { ActivitySheet(items: $0.items) }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 40, matching: .images)
            .onChange(of: photoItems) { _, items in if !items.isEmpty { loadPhotos(items) } }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .onChange(of: entry) { _, action in if let action { entry = nil; run(action) } }
            .onAppear {
                if let action = entry { entry = nil; run(action) }
                if let failure = store.initializationError { error = failure; store.initializationError = nil }
            }
            .alert("Đổi tên tài liệu", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
                TextField("Tên tài liệu", text: $newName)
                Button("Hủy", role: .cancel) { renameItem = nil }
                Button("Lưu") {
                    if let item = renameItem {
                        do { try store.rename(item, to: newName) } catch { self.error = error.localizedDescription }
                    }
                    renameItem = nil
                }
            }
            .confirmationDialog("Xóa tài liệu khỏi thư viện?", isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }), titleVisibility: .visible) {
                Button("Xóa tài liệu", role: .destructive) {
                    if let item = deleteItem {
                        do { try store.delete(item); selection.remove(item.id) } catch { self.error = error.localizedDescription }
                    }
                    deleteItem = nil
                }
            }
            .alert("Ghép tài liệu", isPresented: $showMerge) {
                TextField("Tên PDF mới", text: $mergeName)
                Button("Hủy", role: .cancel) {}
                Button("Ghép") { mergeSelection() }
            } message: { Text("Các PDF đã chọn được ghép theo thứ tự sắp xếp của thư viện, kể cả tài liệu bị ẩn bởi bộ lọc. PDF có mật khẩu cần được mở khóa trước.") }
            .alert("Không thể hoàn tất", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Đóng", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .alert("Cho phép truy cập camera", isPresented: $cameraDenied) {
                Button("Mở Cài đặt") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                Button("Hủy", role: .cancel) {}
            } message: { Text("Bật quyền Camera cho ScanPDF để quét tài liệu.") }
        }
    }

    private var scanBanner: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Từ giấy thành PDF.").font(.title2.bold())
                    Text("Quét rõ nét, sắp xếp dễ dàng.\nMọi tài liệu ở ngay trong túi bạn.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.78))
                }
                Spacer(minLength: 4)
                Image(systemName: "doc.viewfinder").font(.system(size: 46, weight: .light)).foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
            }
            Button { run(.scan) } label: {
                Label("Quét tài liệu", systemImage: "camera.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
            }
            .foregroundStyle(Theme.ink).background(.white, in: RoundedRectangle(cornerRadius: 13))
            HStack(spacing: 24) {
                Button { run(.photos) } label: { Label("Từ ảnh", systemImage: "photo") }
                Button { run(.files) } label: { Label("Nhập PDF", systemImage: "folder") }
            }.font(.subheadline.weight(.medium)).foregroundStyle(.white)
        }
        .padding(24).foregroundStyle(.white)
        .background(LinearGradient(colors: [Theme.ink, Theme.teal], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))
    }

    private func run(_ action: LibraryEntryAction) {
        guard !busy else { return }
        switch action {
        case .scan:
            guard VNDocumentCameraViewController.isSupported else {
                error = "Thiết bị này không hỗ trợ quét camera. Bạn vẫn có thể nhập ảnh để tạo PDF."; return
            }
            Task {
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                if status == .authorized { showScanner = true }
                else if status == .notDetermined {
                    if await AVCaptureDevice.requestAccess(for: .video) { showScanner = true } else { cameraDenied = true }
                } else { cameraDenied = true }
            }
        case .photos: showPhotos = true
        case .files: showFiles = true
        case .merge:
            if store.documents.count < 2 { error = "Nhập ít nhất hai PDF, rồi chọn các tài liệu muốn ghép." }
            else { selecting = true; selection.removeAll() }
        }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        busy = true
        Task {
            defer { busy = false; photoItems = [] }
            do {
                var images: [UIImage] = []
                for item in items {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw LibraryError.invalidPDF }
                    let image = try await Task.detached(priority: .userInitiated) {
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 2400
                              ] as CFDictionary) else { throw LibraryError.invalidPDF }
                        return UIImage(cgImage: thumbnail)
                    }.value
                    images.append(image)
                }
                capture = CaptureBatch(images: images)
            } catch { self.error = "Không thể đọc ảnh: \(error.localizedDescription)" }
        }
    }

    private func importFiles(_ urls: [URL]) {
        busy = true
        Task {
            defer { busy = false }
            var last: LibraryDocument?
            var failures: [String] = []
            for url in urls {
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        var issue: NSError?
                        var dataResult: Result<Data, Error>?
                        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &issue) { source in
                            dataResult = Result { try Data(contentsOf: source) }
                        }
                        if let issue { throw issue }
                        guard let dataResult else { throw LibraryError.invalidPDF }
                        return try dataResult.get()
                    }.value
                    last = try store.save(data: data, name: url.deletingPathExtension().lastPathComponent)
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if urls.count == 1, let last { path.append(last) }
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }

    private func mergeSelection() {
        let urls = sortedDocuments
            .filter { selection.contains($0.id) }.map { store.url(for: $0) }
        guard urls.count >= 2 else { error = "Hãy chọn ít nhất hai PDF trong thư viện."; return }
        let name = mergeName
        busy = true
        Task {
            defer { busy = false }
            do {
                let pdf = try await Task.detached(priority: .userInitiated) { try PDFService.merge(urls: urls) }.value
                let item = try store.save(document: pdf, name: name)
                selecting = false; selection.removeAll(); path.append(item)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CaptureBatch: Identifiable { let id = UUID(); let images: [UIImage] }
struct SharePayload: Identifiable { let id = UUID(); let items: [Any] }

struct BusyOverlay: View {
    let title: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: 14) { ProgressView(); Text(title).font(.subheadline) }
                .padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }.allowsHitTesting(true)
    }
}

struct DocumentRow: View {
    let item: LibraryDocument
    let url: URL
    var selecting = false
    var selected = false
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.teal.opacity(0.07))
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit().padding(5) }
                else { Image(systemName: "doc.richtext").font(.title2).foregroundStyle(Theme.teal) }
            }.frame(width: 56, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                    if item.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.teal).accessibilityLabel("Yêu thích") }
                }
                Text("\(item.pageCount > 0 ? "\(item.pageCount) trang" : "PDF bảo vệ") · \(item.formattedSize)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(item.updatedAt, format: .dateTime.day().month().year()).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: selecting ? (selected ? "checkmark.circle.fill" : "circle") : "chevron.right")
                .foregroundStyle(selecting ? Theme.teal : .secondary)
        }
        .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .task(id: item.updatedAt) {
            thumbnail = await Task.detached(priority: .utility) {
                guard let pdf = PDFDocument(url: url), !pdf.isLocked else { return nil as UIImage? }
                return pdf.page(at: 0)?.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
            }.value
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, name, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: return "Mới sửa nhất"
        case .name: return "Tên A–Z"
        case .size: return "Lớn nhất"
        }
    }
    func comesBefore(_ first: LibraryDocument, _ second: LibraryDocument) -> Bool {
        switch self {
        case .recent:
            if first.updatedAt != second.updatedAt { return first.updatedAt > second.updatedAt }
        case .name:
            let comparison = first.name.localizedStandardCompare(second.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .size:
            if first.byteCount != second.byteCount { return first.byteCount > second.byteCount }
        }
        return first.id.uuidString < second.id.uuidString
    }
}
