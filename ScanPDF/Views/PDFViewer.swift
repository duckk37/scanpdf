import PDFKit
import SwiftUI

/// Keeps PDFKit's native text selection, pinch zoom and link handling.
struct PDFViewer: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor.secondarySystemBackground
        view.showsPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        if let page = document.page(at: currentPage), view.currentPage !== page {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator {
        var parent: PDFViewer
        private var observer: NSObjectProtocol?

        init(_ parent: PDFViewer) { self.parent = parent }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                guard let self, let page = view?.currentPage else { return }
                let index = self.parent.document.index(for: page)
                guard index != NSNotFound, index != self.parent.currentPage else { return }
                // Avoid changing SwiftUI state during updateUIView.
                DispatchQueue.main.async { [weak self] in self?.parent.currentPage = index }
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        deinit { stopObserving() }
    }
}

struct PDFPageThumbnail: View {
    let document: PDFDocument
    let index: Int
    var size: CGSize = CGSize(width: 112, height: 148)
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(Color.white)
                    .overlay(Image(systemName: "doc.richtext").foregroundStyle(.secondary))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: ObjectIdentifier(document).hashValue ^ index) {
            image = document.page(at: index)?.thumbnail(of: size, for: .cropBox)
        }
        .accessibilityLabel("Trang \(index + 1)")
    }
}

struct FullScreenPDFView: View {
    let document: PDFDocument
    let name: String
    @Binding var currentPage: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFViewer(document: document, currentPage: $currentPage)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Đóng") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(min(currentPage + 1, document.pageCount))/\(document.pageCount)")
                            .font(.caption.monospacedDigit())
                    }
                }
        }
    }
}
