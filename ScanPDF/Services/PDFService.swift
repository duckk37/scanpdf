import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import PDFKit
import UIKit
import Vision

enum ScanFilter: String, CaseIterable, Identifiable {
    case original
    case grayscale
    case blackAndWhite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Màu gốc"
        case .grayscale: return "Thang xám"
        case .blackAndWhite: return "Đen trắng"
        }
    }
}

enum PDFServiceError: LocalizedError, Equatable {
    case invalidPDF
    case emptyDocument
    case lockedDocument
    case invalidPages
    case duplicatePages
    case invalidOrder
    case invalidRotation
    case invalidImage
    case renderingFailed
    case emptyPassword
    case incorrectPassword
    case encryptionFailed
    case invalidCompression
    case emptyWatermark
    case invalidSignatureRect

    var errorDescription: String? {
        switch self {
        case .invalidPDF: return "Không đọc được tài liệu PDF này. Tệp có thể bị hỏng."
        case .emptyDocument: return "Tài liệu phải có ít nhất một trang."
        case .lockedDocument: return "PDF đang được bảo vệ. Hãy mở khóa bằng mật khẩu trước."
        case .invalidPages: return "Số trang không hợp lệ. Hãy chọn các trang có trong tài liệu."
        case .duplicatePages: return "Mỗi trang chỉ được chọn một lần."
        case .invalidOrder: return "Thứ tự phải chứa tất cả các trang, mỗi trang đúng một lần."
        case .invalidRotation: return "Góc xoay phải là bội số của 90 độ."
        case .invalidImage: return "Không đọc được ảnh hoặc kích thước ảnh không hợp lệ."
        case .renderingFailed: return "Không thể tạo PDF. Hãy thử lại với ít trang hơn."
        case .emptyPassword: return "Vui lòng nhập mật khẩu."
        case .incorrectPassword: return "Mật khẩu không đúng."
        case .encryptionFailed: return "Không thể bảo vệ hoặc mở khóa PDF bằng mật khẩu này."
        case .invalidCompression: return "Chất lượng nén phải từ 0 đến 1 và kích thước ảnh phải lớn hơn 0."
        case .emptyWatermark: return "Vui lòng nhập nội dung watermark."
        case .invalidSignatureRect: return "Vị trí chữ ký phải nằm trong trang và có kích thước lớn hơn 0."
        }
    }
}

/// All page indices are zero-based. Operations produce a new document and never overwrite a source.
/// Merge/extract/rotate/delete/reorder retain PDF pages, their text and annotations.
enum PDFService {
    /// Uses the same image pipeline as PDF export, at a smaller size for the review screen.
    static func preview(image: UIImage, filter: ScanFilter) throws -> UIImage {
        try prepare(image: image, filter: filter, maxDimension: 1_000)
    }

    static func open(url: URL) throws -> PDFDocument {
        let document = try readDocument(url: url)
        guard !document.isLocked else { throw PDFServiceError.lockedDocument }
        guard document.pageCount > 0 else { throw PDFServiceError.emptyDocument }
        return document
    }

    static func makePDF(images: [UIImage], filter: ScanFilter = .original) throws -> PDFDocument {
        guard !images.isEmpty else { throw PDFServiceError.emptyDocument }
        let output = PDFDocument()
        for image in images {
            try autoreleasepool {
                let prepared = try prepare(image: image, filter: filter, maxDimension: 3_000)
                let page = try imagePage(image: prepared, quality: 0.92)
                try appendCopy(page, to: output)
            }
        }
        return output
    }

    static func merge(urls: [URL]) throws -> PDFDocument {
        guard !urls.isEmpty else { throw PDFServiceError.emptyDocument }
        let output = PDFDocument()
        for url in urls {
            let source = try open(url: url)
            if output.pageCount == 0 { output.documentAttributes = source.documentAttributes }
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { throw PDFServiceError.invalidPDF }
                try appendCopy(page, to: output)
            }
        }
        return output
    }

    static func extract(url: URL, pages: [Int]) throws -> PDFDocument {
        let source = try open(url: url)
        try validate(pages: pages, in: source)
        return try copyPages(source, indices: pages)
    }

    static func rotate(url: URL, pages: [Int], degrees: Int = 90) throws -> PDFDocument {
        guard degrees.isMultiple(of: 90) else { throw PDFServiceError.invalidRotation }
        let source = try open(url: url)
        try validate(pages: pages, in: source)
        let output = try copyPages(source)
        for index in pages {
            guard let page = output.page(at: index) else { throw PDFServiceError.invalidPDF }
            // Reduce the input before addition to avoid integer overflow on malformed input.
            page.rotation = ((page.rotation % 360 + degrees % 360) % 360 + 360) % 360
        }
        return output
    }

    static func deletePages(url: URL, pages: [Int]) throws -> PDFDocument {
        let source = try open(url: url)
        try validate(pages: pages, in: source)
        let selected = Set(pages)
        let retained = (0..<source.pageCount).filter { !selected.contains($0) }
        guard !retained.isEmpty else { throw PDFServiceError.emptyDocument }
        return try copyPages(source, indices: retained)
    }

    static func reorder(url: URL, order: [Int]) throws -> PDFDocument {
        let source = try open(url: url)
        guard order.count == source.pageCount, Set(order) == Set(0..<source.pageCount) else {
            throw PDFServiceError.invalidOrder
        }
        return try copyPages(source, indices: order)
    }

    /// Creates JPEG-backed pages; original text, forms, links and editable annotations are flattened.
    /// File size may grow for PDFs that already contain efficiently compressed images or vector text.
    static func compress(url: URL, quality: CGFloat, maxDimension: CGFloat = 1_600) throws -> PDFDocument {
        guard quality.isFinite, (0...1).contains(quality), maxDimension.isFinite, maxDimension > 0 else {
            throw PDFServiceError.invalidCompression
        }
        let source = try open(url: url)
        let output = PDFDocument()
        output.documentAttributes = source.documentAttributes
        for index in 0..<source.pageCount {
            try autoreleasepool {
                guard let page = source.page(at: index) else { throw PDFServiceError.invalidPDF }
                let size = try displayedSize(of: page)
                let image = try render(page: page, maxDimension: min(maxDimension, 6_000))
                let compressed = try imagePage(image: image, quality: quality, pageSize: size)
                try appendCopy(compressed, to: output)
            }
        }
        return output
    }

    /// Adds a permanent visual watermark while retaining vector page content and searchable text.
    /// Existing annotations are flattened into their visible appearance.
    static func watermark(url: URL, text: String) throws -> PDFDocument {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PDFServiceError.emptyWatermark }
        let source = try open(url: url)
        let output = PDFDocument()
        output.documentAttributes = source.documentAttributes
        for index in 0..<source.pageCount {
            try autoreleasepool {
                guard let page = source.page(at: index) else { throw PDFServiceError.invalidPDF }
                let decorated = try decoratedPage(page) { rect, context in
                    let font = UIFont.boldSystemFont(ofSize: min(72, rect.width * 0.10))
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font, .foregroundColor: UIColor.gray.withAlphaComponent(0.27)
                    ]
                    let string = text as NSString
                    let measured = string.size(withAttributes: attributes)
                    let availableWidth = hypot(rect.width, rect.height) * 0.80
                    let scale = min(1, availableWidth / max(1, measured.width))
                    context.saveGState()
                    context.translateBy(x: rect.midX, y: rect.midY)
                    context.rotate(by: -.pi / 5)
                    context.scaleBy(x: scale, y: scale)
                    string.draw(at: CGPoint(x: -measured.width / 2, y: -measured.height / 2), withAttributes: attributes)
                    context.restoreGState()
                }
                try appendCopy(decorated, to: output)
            }
        }
        return output
    }

    /// The caller can write these bytes directly. Reopening them requires the given password.
    static func protect(url: URL, password: String) throws -> Data {
        guard !password.isEmpty else { throw PDFServiceError.emptyPassword }
        let source = try open(url: url)
        let document = try copyPages(source)
        guard let data = document.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: password,
            PDFDocumentWriteOption.userPasswordOption: password
        ]), let verified = PDFDocument(data: data), verified.isEncrypted, verified.isLocked,
              verified.unlock(withPassword: password), verified.pageCount == source.pageCount else {
            throw PDFServiceError.encryptionFailed
        }
        return data
    }

    /// Returns an unencrypted copy. Possession of the correct password is required for locked PDFs.
    static func unlock(url: URL, password: String) throws -> PDFDocument {
        let source = try readDocument(url: url)
        if source.isLocked {
            guard !password.isEmpty else { throw PDFServiceError.emptyPassword }
            guard source.unlock(withPassword: password) else { throw PDFServiceError.incorrectPassword }
        }
        guard source.pageCount > 0 else { throw PDFServiceError.emptyDocument }
        let copy = try copyPages(source)
        guard let data = copy.dataRepresentation(), let verified = PDFDocument(data: data),
              !verified.isEncrypted, !verified.isLocked, verified.pageCount == source.pageCount else {
            throw PDFServiceError.encryptionFailed
        }
        return verified
    }

    /// `relativeRect` is normalized to the displayed page, with a top-left origin.
    /// This is a visual signature, not a certificate-backed digital signature.
    static func signature(url: URL, page index: Int, image: UIImage, relativeRect: CGRect) throws -> PDFDocument {
        let source = try open(url: url)
        try validate(pages: [index], in: source)
        let values = [relativeRect.minX, relativeRect.minY, relativeRect.width, relativeRect.height]
        guard values.allSatisfy({ $0.isFinite }), relativeRect.width > 0, relativeRect.height > 0,
              relativeRect.minX >= 0, relativeRect.minY >= 0,
              relativeRect.maxX <= 1, relativeRect.maxY <= 1 else {
            throw PDFServiceError.invalidSignatureRect
        }
        guard image.size.width > 0, image.size.height > 0 else { throw PDFServiceError.invalidImage }
        let output = PDFDocument()
        output.documentAttributes = source.documentAttributes
        for pageIndex in 0..<source.pageCount {
            guard let page = source.page(at: pageIndex) else { throw PDFServiceError.invalidPDF }
            if pageIndex == index {
                let decorated = try decoratedPage(page) { rect, _ in
                    let target = CGRect(
                        x: relativeRect.minX * rect.width,
                        y: relativeRect.minY * rect.height,
                        width: relativeRect.width * rect.width,
                        height: relativeRect.height * rect.height
                    )
                    image.draw(in: aspectFit(image.size, in: target))
                }
                try appendCopy(decorated, to: output)
            } else {
                try appendCopy(page, to: output)
            }
        }
        return output
    }

    /// Uses existing text for digital pages and on-device Vision recognition for scanned pages.
    /// Form-feed separators retain page boundaries in exported text.
    static func recognizeText(url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let source = try open(url: url)
            var results = [String]()
            for index in 0..<source.pageCount {
                try Task.checkCancellation()
                let text: String = try autoreleasepool {
                    guard let page = source.page(at: index) else { throw PDFServiceError.invalidPDF }
                    if let existing = page.string, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return existing.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let image = try render(page: page, maxDimension: 2_600)
                    return try recognize(image: image).map(\.text).joined(separator: "\n")
                }
                results.append(text)
            }
            return results.joined(separator: "\n\n\u{000C}\n\n")
        }.value
    }

    /// Each scan page receives invisible, selectable text positioned over its recognized lines.
    static func searchablePDF(images: [UIImage], filter: ScanFilter = .original) async throws -> PDFDocument {
        guard !images.isEmpty else { throw PDFServiceError.emptyDocument }
        return try await Task.detached(priority: .userInitiated) {
            let output = PDFDocument()
            for image in images {
                try Task.checkCancellation()
                try autoreleasepool {
                    let prepared = try prepare(image: image, filter: filter, maxDimension: 3_000)
                    let recognized = try recognize(image: prepared)
                    let size = scanPageSize(for: prepared.size)
                    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
                    let data = renderer.pdfData { context in
                        context.beginPage()
                        prepared.draw(in: CGRect(origin: .zero, size: size))
                        drawSearchableText(recognized, pageSize: size, in: context.cgContext)
                    }
                    guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
                        throw PDFServiceError.renderingFailed
                    }
                    try appendCopy(page, to: output)
                }
            }
            return output
        }.value
    }

    /// The OS decides which languages are available. Vietnamese is preferred only when supported.
    static func supportedOCRLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["vi-VN", "en-US"].filter { supported.contains($0) }
        if !preferred.isEmpty { return preferred }
        return supported.contains("en-GB") ? ["en-GB"] : Array(supported.prefix(1))
    }

    // MARK: - Page construction

    private static func readDocument(url: URL) throws -> PDFDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data) else { throw PDFServiceError.invalidPDF }
        return document
    }

    private static func validate(pages: [Int], in document: PDFDocument) throws {
        guard !pages.isEmpty, pages.allSatisfy({ $0 >= 0 && $0 < document.pageCount }) else {
            throw PDFServiceError.invalidPages
        }
        guard Set(pages).count == pages.count else { throw PDFServiceError.duplicatePages }
    }

    private static func appendCopy(_ page: PDFPage, to document: PDFDocument) throws {
        guard let copy = page.copy() as? PDFPage else { throw PDFServiceError.renderingFailed }
        document.insert(copy, at: document.pageCount)
    }

    private static func copyPages(_ source: PDFDocument, indices: [Int]? = nil) throws -> PDFDocument {
        let output = PDFDocument()
        output.documentAttributes = source.documentAttributes
        for index in indices ?? Array(0..<source.pageCount) {
            guard let page = source.page(at: index) else { throw PDFServiceError.invalidPDF }
            try appendCopy(page, to: output)
        }
        return output
    }

    private static func imagePage(image: UIImage, quality: CGFloat, pageSize: CGSize? = nil) throws -> PDFPage {
        guard let jpeg = image.jpegData(compressionQuality: quality), let encoded = UIImage(data: jpeg) else {
            throw PDFServiceError.invalidImage
        }
        let size = pageSize ?? scanPageSize(for: encoded.size)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let data = renderer.pdfData { context in
            context.beginPage()
            encoded.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let pdf = PDFDocument(data: data), let page = pdf.page(at: 0) else {
            throw PDFServiceError.renderingFailed
        }
        return page
    }

    private static func scanPageSize(for size: CGSize) -> CGSize {
        let scale = min(1, 842 / max(size.width, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func prepare(image: UIImage, filter: ScanFilter, maxDimension: CGFloat) throws -> UIImage {
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { throw PDFServiceError.invalidImage }
        // Drawing normalizes EXIF orientations, including mirrored photos, before OCR and filtering.
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let ratio = min(1, maxDimension / max(pixels.width, pixels.height))
        let size = CGSize(width: max(1, pixels.width * ratio), height: max(1, pixels.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard filter != .original else { return normalized }
        guard let input = CIImage(image: normalized) else { throw PDFServiceError.invalidImage }
        let grayscale = CIFilter.colorControls()
        grayscale.inputImage = input
        grayscale.saturation = 0
        grayscale.contrast = filter == .blackAndWhite ? 1.2 : 1
        guard var result = grayscale.outputImage else { throw PDFServiceError.renderingFailed }
        if filter == .blackAndWhite {
            let threshold = CIFilter.colorThreshold()
            threshold.inputImage = result
            threshold.threshold = 0.50
            guard let binary = threshold.outputImage else { throw PDFServiceError.renderingFailed }
            result = binary
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(result, from: input.extent) else {
            throw PDFServiceError.renderingFailed
        }
        return UIImage(cgImage: cgImage)
    }

    private static func displayedSize(of page: PDFPage) throws -> CGSize {
        let crop = page.bounds(for: .cropBox).standardized
        guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0,
              page.pageRef != nil else { throw PDFServiceError.invalidPDF }
        let angle = ((page.rotation % 360) + 360) % 360
        return angle == 90 || angle == 270 ? CGSize(width: crop.height, height: crop.width) : crop.size
    }

    /// Draws PDF content in UIKit coordinates, accounting for crop origins and `/Rotate`.
    private static func draw(page: PDFPage, in rect: CGRect, context: CGContext) {
        guard let reference = page.pageRef else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let target = CGRect(origin: .zero, size: rect.size)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.clip(to: reference.getBoxRect(.cropBox))
        context.drawPDFPage(reference)
        // Annotations use page-space coordinates relative to the selected box origin.
        let crop = page.bounds(for: .cropBox)
        context.translateBy(x: crop.minX, y: crop.minY)
        for annotation in page.annotations where annotation.shouldDisplay {
            annotation.draw(with: .cropBox, in: context)
        }
        context.restoreGState()
    }

    private static func render(page: PDFPage, maxDimension: CGFloat) throws -> UIImage {
        let pageSize = try displayedSize(of: page)
        // Cap pixel allocation; a corrupt document cannot request an unbounded bitmap.
        let ratio = min(4, maxDimension / max(pageSize.width, pageSize.height))
        let size = CGSize(width: max(1, pageSize.width * ratio), height: max(1, pageSize.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            renderer.fill(rect)
            draw(page: page, in: rect, context: renderer.cgContext)
        }
    }

    private static func decoratedPage(_ page: PDFPage, overlay: (CGRect, CGContext) -> Void) throws -> PDFPage {
        let size = try displayedSize(of: page)
        let bounds = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { renderer in
            renderer.beginPage()
            draw(page: page, in: bounds, context: renderer.cgContext)
            overlay(bounds, renderer.cgContext)
        }
        guard let document = PDFDocument(data: data), let result = document.page(at: 0) else {
            throw PDFServiceError.renderingFailed
        }
        return result
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let ratio = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * ratio, height: size.height * ratio)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    // MARK: - OCR

    struct RecognizedLine {
        let text: String
        /// Vision coordinates: unit rectangle, origin at bottom-left.
        let bounds: CGRect
    }

    private static func recognize(image: UIImage) throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { throw PDFServiceError.invalidImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let languages = try supportedOCRLanguages()
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return RecognizedLine(text: candidate.string, bounds: observation.boundingBox)
        }.sorted { lhs, rhs in
            // Group lines with similar baselines left-to-right; read groups from top to bottom.
            let tolerance = min(lhs.bounds.height, rhs.bounds.height) * 0.5
            if abs(lhs.bounds.midY - rhs.bounds.midY) <= tolerance { return lhs.bounds.minX < rhs.bounds.minX }
            return lhs.bounds.midY > rhs.bounds.midY
        }
    }

    /// Internal for deterministic OCR-layer tests; no Vision recognition is needed in unit tests.
    static func drawSearchableText(_ lines: [RecognizedLine], pageSize: CGSize, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: line.bounds.minX * pageSize.width, y: line.bounds.minY * pageSize.height,
                              width: line.bounds.width * pageSize.width, height: line.bounds.height * pageSize.height)
            guard rect.width > 0, rect.height > 0, !line.text.isEmpty else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height, nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: attributes))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
            guard width > 0, ascent + descent > 0 else { continue }
            let scaleX = rect.width / width
            let scaleY = rect.height / (ascent + descent)
            context.textMatrix = CGAffineTransform(scaleX: scaleX, y: scaleY)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent * scaleY)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }
}
