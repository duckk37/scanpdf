import XCTest
import PDFKit
import UIKit
@testable import ScanPDF

final class DocumentStoreTests: XCTestCase {
    @MainActor
    func testSavedDocumentSurvivesReloadAndRename() async throws {
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
    func testRejectsInvalidPDFWithoutAddingLibraryEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        XCTAssertThrowsError(try store.save(data: Data("bad pdf".utf8), name: "Bad"))
        XCTAssertThrowsError(try store.save(document: PDFDocument(), name: "Empty"))
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Library").path).count, 0)
    }

    @MainActor
    func testRecoversPDFFilesWhenMetadataIsCorrupt() async throws {
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

    @MainActor
    func testUpgradesLegacyLibraryAndPersistsFavoriteWithoutChangingPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let pdf = try PDFService.makePDF(images: [UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { _ in }])
        let item = try store.save(document: pdf, name: "Tài liệu cũ")
        let originalData = try Data(contentsOf: store.url(for: item))
        let indexURL = root.appendingPathComponent("library.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]])
        legacy[0].removeValue(forKey: "isFavorite")
        try JSONSerialization.data(withJSONObject: legacy).write(to: indexURL, options: .atomic)

        let upgraded = DocumentStore(rootURL: root)
        XCTAssertNil(upgraded.initializationError)
        XCTAssertEqual(upgraded.documents.first?.name, item.name)
        XCTAssertEqual(upgraded.documents.first?.isFavorite, false)
        try upgraded.toggleFavorite(item)
        let reloaded = DocumentStore(rootURL: root)
        XCTAssertEqual(reloaded.documents.first?.isFavorite, true)
        XCTAssertEqual(reloaded.documents.first?.updatedAt, item.updatedAt)
        XCTAssertEqual(try Data(contentsOf: reloaded.url(for: item)), originalData)
        try reloaded.toggleFavorite(item)
        XCTAssertEqual(DocumentStore(rootURL: root).documents.first?.isFavorite, false)
    }
}
