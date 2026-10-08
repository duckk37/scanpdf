import XCTest
import PDFKit
import UIKit
@testable import ScanPDF

final class DocumentStoreTests: XCTestCase {
    @MainActor
    func testSavedDocumentSurvivesReloadAndRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let pdf = PDFDocument()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let item = try store.save(document: pdf, name: "Hóa đơn")
        try store.rename(item, to: "  Hóa đơn tháng 10  ")
        let reopened = DocumentStore(rootURL: root)
        XCTAssertNil(reopened.initializationError)
        XCTAssertEqual(reopened.documents.count, 1)
        XCTAssertEqual(reopened.documents.first?.name, "Hóa đơn tháng 10")
        XCTAssertEqual(reopened.documents.first?.pageCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.url(for: item).path))
        try reopened.delete(item)
        XCTAssertTrue(DocumentStore(rootURL: root).documents.isEmpty)
    }

    @MainActor
    func testRejectsInvalidPDFWithoutAddingLibraryEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        XCTAssertThrowsError(try store.save(data: Data("bad pdf".utf8), name: "Bad"))
        XCTAssertThrowsError(try store.save(document: PDFDocument(), name: "Empty"))
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Library").path).count, 0)
    }

    @MainActor
    func testRecoversPDFFilesWhenMetadataIsCorrupt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let pdf = try PDFService.makePDF(images: [UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { _ in }])
        let item = try store.save(document: pdf, name: "Original")
        try Data("invalid json".utf8).write(to: root.appendingPathComponent("library.json"))
        let recovered = DocumentStore(rootURL: root)
        XCTAssertNotNil(recovered.initializationError)
        XCTAssertEqual(recovered.documents.map(\.id), [item.id])
        XCTAssertEqual(recovered.documents.first?.pageCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.url(for: item).path))
    }
}
