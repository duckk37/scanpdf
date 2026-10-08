import SwiftUI
import UIKit
import PDFKit
import CoreImage

private struct ScanPage: Identifiable {
    let id = UUID()
    var image: UIImage
}

struct ScanReviewView: View {
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [ScanPage]
    @State private var current = 0
    @State private var name = "Bản quét " + Date.now.formatted(.dateTime.day().month().year())
    @State private var filter: ScanFilter = .original
    @State private var searchable = false
    @State private var busy = false
    @State private var showOrder = false
    @State private var error: String?
    @State private var preview: UIImage?
    let onSave: (LibraryDocument) -> Void

    init(images: [UIImage], onSave: @escaping (LibraryDocument) -> Void) {
        _pages = State(initialValue: images.map { ScanPage(image: $0) })
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemGroupedBackground))
                        if let preview {
                            Image(uiImage: preview).resizable().scaledToFit().padding(12)
                        } else { ProgressView() }
                    }.frame(height: 320)
                    HStack {
                        Button { current = max(0, current - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(current == 0)
                        Spacer()
                        Text("Trang \(current + 1) / \(pages.count)").font(.subheadline.monospacedDigit())
                        Spacer()
                        Button { current = min(pages.count - 1, current + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(current >= pages.count - 1)
                    }.padding(.horizontal, 20)
                    HStack(spacing: 16) {
                        Button { rotateCurrent() } label: { Label("Xoay", systemImage: "rotate.right") }
                        Button { showOrder = true } label: { Label("Sắp xếp", systemImage: "arrow.up.arrow.down") }
                        Button(role: .destructive) {
                            pages.remove(at: current); current = min(current, pages.count - 1)
                        } label: { Image(systemName: "trash") }.disabled(pages.count <= 1)
                    }.font(.subheadline).buttonStyle(.bordered)
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Tên tài liệu", text: $name).font(.headline).textInputAutocapitalization(.sentences)
                        Divider()
                        Picker("Bộ lọc", selection: $filter) {
                            ForEach(ScanFilter.allCases) { option in Text(option.title).tag(option) }
                        }.pickerStyle(.segmented)
                        Toggle("PDF có thể tìm kiếm", isOn: $searchable).font(.subheadline.weight(.medium))
                        Text(searchable ? "Thêm lớp chữ OCR để tìm và sao chép. Thời gian xử lý tùy số trang; ngôn ngữ nhận dạng phụ thuộc iOS." : "Lưu nhanh từ ảnh. Bạn có thể nhận dạng chữ sau trong Công cụ PDF.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    Button { save() } label: {
                        Label("Lưu PDF · \(pages.count) trang", systemImage: "checkmark.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pages.isEmpty || busy)
                }.padding(20)
            }
            .background(Theme.paper)
            .navigationTitle("Hoàn thiện bản quét")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .disabled(busy)
            .overlay { if busy { BusyOverlay(title: searchable ? "Đang nhận dạng và tạo PDF…" : "Đang tạo PDF…") } }
            .task(id: "\(pages.indices.contains(current) ? pages[current].id.uuidString : "empty")-\(filter.rawValue)-\(current)") { await updatePreview() }
            .sheet(isPresented: $showOrder) {
                NavigationStack {
                    List {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            HStack {
                                Image(uiImage: page.image).resizable().scaledToFit().frame(width: 44, height: 60)
                                Text("Trang \(index + 1)")
                            }
                        }.onMove { source, destination in pages.move(fromOffsets: source, toOffset: destination); current = 0 }
                    }
                    .environment(\.editMode, .constant(.active))
                    .navigationTitle("Thứ tự trang").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { showOrder = false } } }
                }
            }
            .alert("Không thể lưu PDF", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Đóng", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func save() {
        let images = pages.map(\.image)
        let chosenFilter = filter
        let useOCR = searchable
        let title = name
        busy = true
        Task {
            defer { busy = false }
            do {
                let pdf = try await Task.detached(priority: .userInitiated) {
                    if useOCR { return try await PDFService.searchablePDF(images: images, filter: chosenFilter) }
                    return try PDFService.makePDF(images: images, filter: chosenFilter)
                }.value
                let item = try store.save(document: pdf, name: title)
                onSave(item)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func rotateCurrent() {
        guard pages.indices.contains(current) else { return }
        let image = pages[current].image
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale
        let size = CGSize(width: image.size.height, height: image.size.width)
        let rotated = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: size.width, y: 0)
            context.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        pages[current] = ScanPage(image: rotated)
    }

    private func updatePreview() async {
        guard pages.indices.contains(current) else { return }
        let image = pages[current].image
        let choice = filter
        preview = nil
        do {
            let processed = try await Task.detached(priority: .userInitiated) {
                try PDFService.preview(image: image, filter: choice)
            }.value
            guard !Task.isCancelled else { return }
            preview = processed
        } catch {
            guard !Task.isCancelled else { return }
            preview = image
            self.error = error.localizedDescription
        }
    }
}
