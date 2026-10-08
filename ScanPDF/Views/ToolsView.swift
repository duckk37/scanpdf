import SwiftUI

struct PDFTool: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
}

struct ToolsView: View {
    @EnvironmentObject private var store: DocumentStore
    let create: (LibraryEntryAction) -> Void
    @State private var selectedTool: PDFTool?

    private let tools: [PDFTool] = [
        .init(id: "extract", title: "Tách / trích trang", subtitle: "Lưu các trang thành PDF mới", icon: "doc.on.doc"),
        .init(id: "rotate", title: "Xoay trang", subtitle: "Chỉnh hướng từng trang", icon: "rotate.right"),
        .init(id: "reorder", title: "Sắp xếp trang", subtitle: "Đổi thứ tự bằng kéo thả", icon: "arrow.up.arrow.down"),
        .init(id: "insert", title: "Chèn PDF", subtitle: "Thêm trang từ PDF khác", icon: "doc.badge.plus"),
        .init(id: "duplicate", title: "Nhân bản trang", subtitle: "Tạo bản sao ngay sau trang gốc", icon: "plus.square.on.square"),
        .init(id: "delete", title: "Xóa trang", subtitle: "Bỏ các trang không cần", icon: "doc.badge.minus"),
        .init(id: "exportImages", title: "PDF thành ảnh", subtitle: "Xuất trang dạng PNG / JPEG", icon: "photo.stack"),
        .init(id: "numberPages", title: "Đánh số trang", subtitle: "Chọn vị trí và số bắt đầu", icon: "number.square"),
        .init(id: "compress", title: "Nén PDF", subtitle: "Giảm dung lượng để chia sẻ", icon: "arrow.down.right.and.arrow.up.left"),
        .init(id: "watermark", title: "Watermark", subtitle: "Thêm chữ lên tài liệu", icon: "textformat"),
        .init(id: "sign", title: "Chữ ký", subtitle: "Vẽ và chèn chữ ký", icon: "signature"),
        .init(id: "ocr", title: "Nhận dạng chữ", subtitle: "Trích văn bản bằng OCR", icon: "text.viewfinder"),
        .init(id: "protect", title: "Đặt mật khẩu", subtitle: "Tạo bản PDF được bảo vệ", icon: "lock"),
        .init(id: "unlock", title: "Gỡ mật khẩu", subtitle: "Cần mật khẩu hiện tại", icon: "lock.open")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Một nơi cho mọi PDF.").font(.title2.bold())
                        Text("Tạo mới, chỉnh sửa và chia sẻ ngay trên thiết bị.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("TẠO TÀI LIỆU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ToolTile(title: "Quét camera", subtitle: "Tự nhận cạnh tài liệu", icon: "doc.viewfinder") { create(.scan) }
                        ToolTile(title: "Ảnh thành PDF", subtitle: "Chọn ảnh trong thư viện", icon: "photo.on.rectangle") { create(.photos) }
                        ToolTile(title: "Nhập PDF", subtitle: "Mở từ Files hoặc iCloud", icon: "folder") { create(.files) }
                        ToolTile(title: "Ghép PDF", subtitle: "Kết hợp nhiều tài liệu", icon: "square.stack") { create(.merge) }
                    }
                    Text("CHỈNH SỬA PDF").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(tools) { tool in
                            ToolTile(title: tool.title, subtitle: tool.subtitle, icon: tool.icon) { selectedTool = tool }
                        }
                    }
                }.padding(20)
            }
            .background(Theme.paper)
            .navigationTitle("Công cụ PDF")
            .sheet(item: $selectedTool) { tool in
                NavigationStack {
                    List {
                        if store.documents.isEmpty {
                            ContentUnavailableView("Thư viện đang trống", systemImage: "doc", description: Text("Nhập hoặc quét một tài liệu để dùng công cụ này."))
                            Button("Nhập PDF") { selectedTool = nil; create(.files) }
                        } else {
                            Section("Chọn PDF để \(tool.title.lowercased())") {
                                ForEach(store.documents.sorted { $0.updatedAt > $1.updatedAt }) { item in
                                    NavigationLink {
                                        DocumentDetailView(item: item, initialTool: tool.id)
                                    } label: { DocumentRow(item: item, url: store.url(for: item)) }
                                }
                            }
                        }
                    }
                    .navigationTitle(tool.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { selectedTool = nil } } }
                }.environmentObject(store)
            }
        }
    }
}
