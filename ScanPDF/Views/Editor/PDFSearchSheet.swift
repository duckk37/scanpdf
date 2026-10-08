import PDFKit
import SwiftUI

struct PDFSearchSheet: View {
    let url: URL
    let onSelectPage: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PDFSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView("Đang tìm văn bản…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasSearched {
                    ContentUnavailableView {
                        Label("Tìm trong tài liệu", systemImage: "magnifyingglass")
                    } description: {
                        Text("Nhập từ khóa để tìm văn bản có sẵn trong PDF. PDF ảnh cần được scan với tùy chọn OCR để tìm được chữ.")
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        Button {
                            onSelectPage(result.page)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Trang \(result.page + 1)").font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                                Text(result.context).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Tìm văn bản")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Từ khóa trong PDF")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty { searchTask?.cancel(); results = []; hasSearched = false; isSearching = false }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Đóng") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Tìm", action: search).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onDisappear { searchTask?.cancel() }
            .alert("Không thể tìm văn bản", isPresented: Binding(get: { searchError != nil }, set: { if !$0 { searchError = nil } })) {
                Button("Đóng", role: .cancel) { searchError = nil }
            } message: { Text(searchError ?? "") }
            .tint(.teal)
        }
    }

    private func search() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isSearching = true
        hasSearched = true
        let sourceURL = url
        searchTask = Task {
            do {
                // Use a separate PDFDocument so searching and the viewer never access the same PDFKit object concurrently.
                let found = try await Task.detached(priority: .userInitiated) { () throws -> [PDFSearchResult] in
                    let source = try PDFService.open(url: sourceURL)
                    return source.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive]).compactMap { match in
                        guard let page = match.pages.first else { return nil }
                        let pageIndex = source.index(for: page)
                        guard pageIndex != NSNotFound else { return nil }
                        let snippet = match.selectionsByLine().compactMap(\.string).joined(separator: " ")
                        return PDFSearchResult(page: pageIndex, context: snippet.isEmpty ? (match.string ?? term) : snippet)
                    }
                }.value
                guard !Task.isCancelled else { return }
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }
}

private struct PDFSearchResult: Identifiable {
    let id = UUID()
    let page: Int
    let context: String
}
