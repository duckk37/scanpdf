import SwiftUI

enum LibraryEntryAction: Hashable { case scan, photos, files, merge }

struct RootView: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var tab = 0
    @State private var entry: LibraryEntryAction?
    @State private var importError: String?

    var body: some View {
        TabView(selection: $tab) {
            LibraryView(entry: $entry)
                .tabItem { Label("Thư viện", systemImage: "square.stack.3d.up") }.tag(0)
            ToolsView { action in tab = 0; entry = action }
                .tabItem { Label("Công cụ", systemImage: "square.grid.2x2") }.tag(1)
            AboutView()
                .tabItem { Label("Thông tin", systemImage: "info.circle") }.tag(2)
        }
        .onOpenURL { url in
            do { _ = try store.importPDF(from: url); tab = 0 }
            catch { importError = error.localizedDescription }
        }
        .alert("Không thể nhập PDF", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("Đóng", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
    }
}

struct AboutView: View {
    @EnvironmentObject private var store: DocumentStore
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "doc.viewfinder").font(.largeTitle).foregroundStyle(Theme.teal)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ScanPDF").font(.title2.bold())
                            Text("Quét gọn. Lưu trọn.").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 14)
                    LabeledContent("Phiên bản", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0")
                    LabeledContent("Tài liệu", value: "\(store.documents.count)")
                    LabeledContent("Dung lượng", value: ByteCountFormatter.string(fromByteCount: store.documents.reduce(0) { $0 + $1.byteCount }, countStyle: .file))
                }
                Section("Tài liệu của bạn") {
                    Label("Quét và xử lý trực tiếp trên thiết bị", systemImage: "iphone")
                    Label("Không cần tài khoản hoặc máy chủ", systemImage: "lock.shield")
                    Text("Thư viện nằm trong dữ liệu của app. Hãy chia sẻ các PDF quan trọng sang Files để có bản sao trước khi gỡ app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Những điều cần biết") {
                    Text("Quét camera cần iPhone/iPad có hỗ trợ. OCR phụ thuộc các ngôn ngữ mà iOS hỗ trợ và chất lượng ảnh; hãy kiểm tra lại kết quả nhận dạng.")
                    Text("Nén PDF chuyển trang thành ảnh và làm mất lớp văn bản, biểu mẫu và chú thích có thể sửa. App luôn lưu bản nén thành tài liệu mới.")
                    Text("Chữ ký vẽ là hình ảnh trên tài liệu, không phải chữ ký số dùng chứng thư.")
                }.font(.footnote)
                Section {
                    Link(destination: URL(string: "https://github.com/duckk37/scanpdf")!) {
                        Label("Mã nguồn trên GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://docs.sidestore.io/docs/faq")!) {
                        Label("Hướng dẫn SideStore", systemImage: "arrow.down.app")
                    }
                }
            }
            .navigationTitle("Thông tin")
        }
    }
}
