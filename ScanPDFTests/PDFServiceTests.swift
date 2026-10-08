import CoreGraphics
import PDFKit
import UIKit
import XCTest
@testable import ScanPDF

final class PDFServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PDFServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testScanBuildsPagesAndKeepsAspectRatio() throws {
        let portrait = image(size: CGSize(width: 400, height: 600), color: .white)
        let landscape = image(size: CGSize(width: 600, height: 400), color: .white)
        let document = try PDFService.makePDF(images: [portrait, landscape], filter: .blackAndWhite)
        let reopened = try persisted(document)
        XCTAssertEqual(reopened.pageCount, 2)
        let first = try XCTUnwrap(reopened.page(at: 0)).bounds(for: .mediaBox)
        let second = try XCTUnwrap(reopened.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(first.width / first.height, 2.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(second.width / second.height, 3.0 / 2.0, accuracy: 0.01)
        assertError(.emptyDocument) { _ = try PDFService.makePDF(images: []) }
    }

    func testPreviewBlackAndWhiteUsesBinaryThreshold() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { renderer in
            UIColor(white: 0.1, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
            UIColor(white: 0.95, alpha: 1).setFill()
            renderer.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        }
        let preview = try PDFService.preview(image: source, filter: .blackAndWhite)
        let dark = try pixel(in: preview, normalizedPoint: CGPoint(x: 0.25, y: 0.5))
        let light = try pixel(in: preview, normalizedPoint: CGPoint(x: 0.75, y: 0.5))
        XCTAssertLessThan(dark.red, 0.02)
        XCTAssertGreaterThan(light.red, 0.98)
        XCTAssertEqual(dark.red, dark.green, accuracy: 0.01)
        XCTAssertEqual(light.red, light.blue, accuracy: 0.01)
    }

    func testMergeAndExtractPreserveTextAndOrderAfterSaving() throws {
        let first = try fixture(["Document A / Page 1", "Document A / Page 2"])
        let second = try fixture(["Document B / Page 1"])
        let merged = try persisted(PDFService.merge(urls: [first, second]))
        XCTAssertEqual(merged.pageCount, 3)
        XCTAssertTrue(try XCTUnwrap(merged.page(at: 0)?.string).contains("Document A / Page 1"))
        XCTAssertTrue(try XCTUnwrap(merged.page(at: 2)?.string).contains("Document B / Page 1"))

        let extracted = try persisted(PDFService.extract(url: first, pages: [1, 0]))
        XCTAssertTrue(try XCTUnwrap(extracted.page(at: 0)?.string).contains("Page 2"))
        XCTAssertTrue(try XCTUnwrap(extracted.page(at: 1)?.string).contains("Page 1"))
        assertError(.invalidPages) { _ = try PDFService.extract(url: first, pages: [-1]) }
        assertError(.invalidPages) { _ = try PDFService.extract(url: first, pages: [2]) }
        assertError(.duplicatePages) { _ = try PDFService.extract(url: first, pages: [0, 0]) }
    }

    func testPageCopiesKeepAnnotations() throws {
        let sourceURL = try fixture(["Keep annotations"])
        let source = try PDFService.open(url: sourceURL)
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 180, height: 40), forType: .freeText, withProperties: nil)
        annotation.contents = "Saved note"
        annotation.font = .systemFont(ofSize: 16)
        annotation.fontColor = .blue
        source.page(at: 0)?.addAnnotation(annotation)
        try write(source, to: sourceURL)
        let result = try persisted(PDFService.extract(url: sourceURL, pages: [0]))
        XCTAssertTrue(try XCTUnwrap(result.page(at: 0)).annotations.contains { $0.contents == "Saved note" })
    }

    func testRotateChangesOnlySelectedPagesAndNeverMutatesSourceFile() throws {
        let source = try fixture(["First", "Second"])
        let result = try persisted(PDFService.rotate(url: source, pages: [1], degrees: -90))
        XCTAssertEqual(result.page(at: 0)?.rotation, 0)
        XCTAssertEqual(result.page(at: 1)?.rotation, 270)
        XCTAssertTrue(try XCTUnwrap(result.page(at: 1)?.string).contains("Second"))
        XCTAssertEqual(try PDFService.open(url: source).page(at: 1)?.rotation, 0)
        assertError(.invalidRotation) { _ = try PDFService.rotate(url: source, pages: [0], degrees: 45) }
    }

    func testDeleteAndReorderValidateDocumentStructure() throws {
        let source = try fixture(["One", "Two", "Three"])
        let deleted = try persisted(PDFService.deletePages(url: source, pages: [1]))
        XCTAssertEqual(deleted.pageCount, 2)
        XCTAssertTrue(try XCTUnwrap(deleted.page(at: 1)?.string).contains("Three"))
        let reordered = try persisted(PDFService.reorder(url: source, order: [2, 0, 1]))
        XCTAssertTrue(try XCTUnwrap(reordered.page(at: 0)?.string).contains("Three"))
        XCTAssertTrue(try XCTUnwrap(reordered.page(at: 2)?.string).contains("Two"))
        assertError(.emptyDocument) { _ = try PDFService.deletePages(url: source, pages: [0, 1, 2]) }
        assertError(.invalidOrder) { _ = try PDFService.reorder(url: source, order: [0, 0, 2]) }
        assertError(.invalidOrder) { _ = try PDFService.reorder(url: source, order: [0, 1]) }
    }

    func testProtectionRequiresPasswordAfterPersistenceAndUnlockRemovesEncryption() throws {
        let source = try fixture(["Private document", "Page two"])
        let protectedURL = directory.appendingPathComponent("protected.pdf")
        let protectedData = try PDFService.protect(url: source, password: "secret-123")
        try protectedData.write(to: protectedURL)
        let locked = try XCTUnwrap(PDFDocument(url: protectedURL))
        XCTAssertTrue(locked.isEncrypted)
        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(locked.unlock(withPassword: "wrong"))
        assertError(.lockedDocument) { _ = try PDFService.open(url: protectedURL) }
        assertError(.incorrectPassword) { _ = try PDFService.unlock(url: protectedURL, password: "wrong") }

        let unlocked = try persisted(PDFService.unlock(url: protectedURL, password: "secret-123"))
        XCTAssertFalse(unlocked.isEncrypted)
        XCTAssertFalse(unlocked.isLocked)
        XCTAssertEqual(unlocked.pageCount, 2)
        XCTAssertTrue(try XCTUnwrap(unlocked.page(at: 0)?.string).contains("Private document"))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: protectedURL)).isLocked)
        assertError(.emptyPassword) { _ = try PDFService.protect(url: source, password: "") }
    }

    func testWatermarkRetainsTextAndUsesRotatedDisplayDimensions() throws {
        let source = try fixture(["Original searchable content"])
        let rotatedURL = directory.appendingPathComponent("rotated.pdf")
        try write(PDFService.rotate(url: source, pages: [0]), to: rotatedURL)
        let result = try persisted(PDFService.watermark(url: rotatedURL, text: "CONFIDENTIAL"))
        let page = try XCTUnwrap(result.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 480, accuracy: 0.01)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 320, accuracy: 0.01)
        XCTAssertTrue(try XCTUnwrap(page.string).contains("Original searchable content"))
        XCTAssertTrue(try XCTUnwrap(page.string).contains("CONFIDENTIAL"))
        assertError(.emptyWatermark) { _ = try PDFService.watermark(url: source, text: "   ") }
    }

    func testCompressionProducesReopenablePagesAndRejectsInvalidSettings() throws {
        let source = try fixture(["First", "Second"])
        let result = try persisted(PDFService.compress(url: source, quality: 0.5, maxDimension: 800))
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 320, height: 480))
        assertError(.invalidCompression) { _ = try PDFService.compress(url: source, quality: 1.5) }
        assertError(.invalidCompression) { _ = try PDFService.compress(url: source, quality: .nan) }
        assertError(.invalidCompression) { _ = try PDFService.compress(url: source, quality: 0.5, maxDimension: 0) }
    }

    func testSignaturePersistsAndUsesTopLeftNormalizedCoordinates() throws {
        let source = try fixture(["Signed document"])
        let stamp = image(size: CGSize(width: 100, height: 50), color: .red)
        let result = try persisted(PDFService.signature(url: source, page: 0, image: stamp,
                                                       relativeRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)))
        let page = try XCTUnwrap(result.page(at: 0))
        XCTAssertTrue(try XCTUnwrap(page.string).contains("Signed document"))
        let thumbnail = page.thumbnail(of: CGSize(width: 320, height: 480), for: .cropBox)
        let upper = try pixel(in: thumbnail, normalizedPoint: CGPoint(x: 0.2, y: 0.15))
        let lower = try pixel(in: thumbnail, normalizedPoint: CGPoint(x: 0.2, y: 0.85))
        XCTAssertGreaterThan(upper.red, 0.85)
        XCTAssertLessThan(upper.green, 0.15)
        XCTAssertGreaterThan(lower.green, 0.85)
        assertError(.invalidSignatureRect) {
            _ = try PDFService.signature(url: source, page: 0, image: stamp,
                                         relativeRect: CGRect(x: 0.9, y: 0.9, width: 0.2, height: 0.2))
        }
    }

    func testExistingTextRecognitionPreservesPageBoundaries() async throws {
        let source = try fixture(["Text on first page", "Text on second page"])
        XCTAssertFalse(PDFService.containsImages(try XCTUnwrap(PDFService.open(url: source).page(at: 0))))
        let text = try await PDFService.recognizeText(url: source)
        let pages = text.components(separatedBy: "\u{000C}")
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages[0].contains("first page"))
        XCTAssertTrue(pages[1].contains("second page"))
    }

    func testOCRRecoversScannedBodyWhenPageAlsoHasNativeWatermarkText() async throws {
        let size = CGSize(width: 1_200, height: 1_600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scannedImage = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.black
            ]
            ("SCANNED BODY TEXT" as NSString).draw(at: CGPoint(x: 80, y: 120), withAttributes: attributes)
            ("INVOICE NUMBER 7391" as NSString).draw(at: CGPoint(x: 80, y: 260), withAttributes: attributes)
        }
        let scannedURL = directory.appendingPathComponent("scanned.pdf")
        try write(PDFService.makePDF(images: [scannedImage]), to: scannedURL)
        let mixedURL = directory.appendingPathComponent("mixed.pdf")
        try write(PDFService.watermark(url: scannedURL, text: "WATERMARK"), to: mixedURL)
        let mixedPage = try XCTUnwrap(PDFService.open(url: mixedURL).page(at: 0))
        let native = try XCTUnwrap(mixedPage.string)
        // This is the regression setup: native text exists, but does not describe the scan body.
        XCTAssertTrue(native.contains("WATERMARK"))
        XCTAssertFalse(native.contains("SCANNED BODY TEXT"))
        XCTAssertTrue(PDFService.containsImages(mixedPage))

        let recognized = try await PDFService.recognizeText(url: mixedURL)
        let normalized = recognized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").uppercased()
        XCTAssertTrue(normalized.contains("SCANNED BODY TEXT"), recognized)
        XCTAssertTrue(normalized.contains("INVOICE NUMBER 7391"), recognized)
        XCTAssertTrue(recognized.contains("WATERMARK"))
    }

    func testOCRMergeKeepsNativeTextAndVietnameseDiacritics() {
        let native = "Native   text\nWATERMARK\nma"
        XCTAssertEqual(PDFService.combineText(native: native, recognized: ["native text", "watermark", "má", "Body text"]),
                       native + "\nmá\nBody text")
        XCTAssertEqual(PDFService.combineText(native: native, recognized: []), native)
        // A single letter must not disappear merely because it occurs inside a native word.
        XCTAssertEqual(PDFService.combineText(native: "Watermark", recognized: ["a"]), "Watermark\na")
    }

    func testImageDetectionFindsNestedFormImagesAndInlineImages() throws {
        let nested = try rawPDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 480] /Resources << /XObject << /Outer 4 0 R >> >> /Contents 5 0 R >>",
            stream("/Type /XObject /Subtype /Form /BBox [0 0 320 480] /Resources << /XObject << /Inner 6 0 R >> >>", content: "/Inner Do"),
            stream("", content: "/Outer Do"),
            stream("/Type /XObject /Subtype /Form /BBox [0 0 320 480] /Resources << /XObject << /Photo 7 0 R >> >>", content: "q 100 0 0 100 0 0 cm /Photo Do Q"),
            stream("/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode", content: "FF0000>")
        ])
        XCTAssertTrue(PDFService.containsImages(try XCTUnwrap(nested.page(at: 0))))
        let inline = try rawPDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 480] /Resources << >> /Contents 4 0 R >>",
            stream("", content: "q 100 0 0 100 0 0 cm BI /W 1 /H 1 /CS /RGB /BPC 8 /F /AHx ID FF0000> EI Q")
        ])
        XCTAssertTrue(PDFService.containsImages(try XCTUnwrap(inline.page(at: 0))))
    }

    func testInvisibleOCRLayerIsSearchableAndDoesNotPaintText() throws {
        let size = CGSize(width: 320, height: 480)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let data = renderer.pdfData { renderer in
            renderer.beginPage()
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            PDFService.drawSearchableText([
                .init(text: "Selectable scanned text", bounds: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.1))
            ], pageSize: size, in: renderer.cgContext)
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(try XCTUnwrap(page.string).contains("Selectable scanned text"))
        XCTAssertFalse(try XCTUnwrap(document.findString("scanned", withOptions: [])).isEmpty)
        // The glyph bounds should land in the same bottom-left rectangle as Vision's observation.
        let selection = try XCTUnwrap(page.selection(for: CGRect(x: 25, y: 325, width: 280, height: 70)))
        XCTAssertTrue(try XCTUnwrap(selection.string).contains("scanned"))
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        let color = try pixel(in: thumbnail, normalizedPoint: CGPoint(x: 0.5, y: 0.25))
        XCTAssertGreaterThan(color.red, 0.95)
        XCTAssertGreaterThan(color.green, 0.95)
        XCTAssertGreaterThan(color.blue, 0.95)
    }

    // MARK: - Fixtures

    private func stream(_ dictionary: String, content: String) -> String {
        "<< \(dictionary) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }

    private func rawPDF(objects: [String]) throws -> PDFDocument {
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func fixture(_ texts: [String]) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480))
        let data = renderer.pdfData { renderer in
            for text in texts {
                renderer.beginPage()
                (text as NSString).draw(at: CGPoint(x: 20, y: 180), withAttributes: [.font: UIFont.systemFont(ofSize: 15)])
            }
        }
        try data.write(to: url)
        return url
    }

    private func image(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            color.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func write(_ document: PDFDocument, to url: URL) throws {
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
    }

    private func persisted(_ document: PDFDocument) throws -> PDFDocument {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        try write(document, to: url)
        return try PDFService.open(url: url)
    }

    private func assertError(_ expected: PDFServiceError, file: StaticString = #filePath, line: UInt = #line, action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? PDFServiceError, expected, file: file, line: line)
        }
    }

    private func pixel(in image: UIImage, normalizedPoint: CGPoint) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let x = min(cgImage.width - 1, max(0, Int(normalizedPoint.x * CGFloat(cgImage.width))))
        let y = min(cgImage.height - 1, max(0, Int(normalizedPoint.y * CGFloat(cgImage.height))))
        let sample = try XCTUnwrap(cgImage.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let bitmap = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                                               bitsPerComponent: 8, bytesPerRow: 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            bitmap.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
    }
}
