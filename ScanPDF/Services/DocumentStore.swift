import Foundation
import Combine
import PDFKit

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [LibraryDocument] = []
    @Published var initializationError: String?

    private let libraryURL: URL
    private let indexURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documentsRoot = rootURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let supportRoot = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        libraryURL = documentsRoot.appendingPathComponent("Library", isDirectory: true)
        indexURL = supportRoot.appendingPathComponent("library.json")
        do {
            try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: indexURL.path) {
                do {
                    documents = try JSONDecoder().decode([LibraryDocument].self, from: Data(contentsOf: indexURL))
                } catch {
                    let backupURL = supportRoot.appendingPathComponent("library-damaged-\(UUID().uuidString).json")
                    try fileManager.copyItem(at: indexURL, to: backupURL)
                    initializationError = "Danh mục thư viện bị lỗi. Các PDF đã được khôi phục; bạn có thể đổi lại tên tài liệu."
                }
            }
            // Recover a PDF written before an interrupted metadata update.
            let known = Set(documents.map(\.filename))
            let files = try fileManager.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension.lowercased() == "pdf" && !known.contains(file.lastPathComponent) {
                guard let pdf = PDFDocument(url: file) else { continue }
                let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) ?? UUID()
                documents.append(LibraryDocument(id: id, name: "Tài liệu khôi phục", filename: file.lastPathComponent,
                    createdAt: Date(), updatedAt: Date(), pageCount: pdf.pageCount, byteCount: try size(of: file)))
            }
            documents.removeAll { !fileManager.fileExists(atPath: url(for: $0).path) }
            try persist(documents)
        } catch {
            initializationError = "Không thể mở thư viện: \(error.localizedDescription)"
        }
    }

    func url(for item: LibraryDocument) -> URL {
        libraryURL.appendingPathComponent(item.filename)
    }

    @discardableResult
    func save(document: PDFDocument, name: String) throws -> LibraryDocument {
        guard let data = document.dataRepresentation() else { throw LibraryError.writeFailed }
        return try save(data: data, name: name)
    }

    @discardableResult
    func save(data: Data, name: String) throws -> LibraryDocument {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 || pdf.isLocked else { throw LibraryError.invalidPDF }
        let id = UUID()
        let item = LibraryDocument(id: id, name: try normalizedName(name), filename: "\(id.uuidString).pdf",
            createdAt: Date(), updatedAt: Date(), pageCount: pdf.pageCount, byteCount: Int64(data.count))
        let destination = url(for: item)
        try data.write(to: destination, options: .atomic)
        let newDocuments = [item] + documents
        do { try persist(newDocuments) }
        catch { try? fileManager.removeItem(at: destination); throw error }
        documents = newDocuments
        return item
    }

    @discardableResult
    func importPDF(from source: URL) throws -> LibraryDocument {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw LibraryError.invalidPDF }
        return try save(data: result.get(), name: source.deletingPathExtension().lastPathComponent)
    }

    func replace(_ item: LibraryDocument, with document: PDFDocument) throws {
        guard let data = document.dataRepresentation() else { throw LibraryError.writeFailed }
        try replace(item, with: data)
    }

    func replace(_ item: LibraryDocument, with data: Data) throws {
        guard let position = documents.firstIndex(where: { $0.id == item.id }) else { throw LibraryError.missing }
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 || pdf.isLocked else { throw LibraryError.invalidPDF }
        let destination = url(for: documents[position])
        let previousData = try Data(contentsOf: destination)
        try data.write(to: destination, options: .atomic)
        var updated = documents
        updated[position].updatedAt = Date()
        updated[position].pageCount = pdf.pageCount
        updated[position].byteCount = Int64(data.count)
        do { try persist(updated) }
        catch { try? previousData.write(to: destination, options: .atomic); throw error }
        documents = updated
    }

    func rename(_ item: LibraryDocument, to name: String) throws {
        guard let position = documents.firstIndex(where: { $0.id == item.id }) else { throw LibraryError.missing }
        var updated = documents
        updated[position].name = try normalizedName(name)
        updated[position].updatedAt = Date()
        try persist(updated)
        documents = updated
    }

    func delete(_ item: LibraryDocument) throws {
        guard documents.contains(where: { $0.id == item.id }) else { throw LibraryError.missing }
        let destination = url(for: item)
        let backup = try Data(contentsOf: destination)
        try fileManager.removeItem(at: destination)
        let updated = documents.filter { $0.id != item.id }
        do { try persist(updated) }
        catch { try? backup.write(to: destination, options: .atomic); throw error }
        documents = updated
    }

    private func persist(_ items: [LibraryDocument]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: indexURL, options: .atomic)
    }

    private func normalizedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.emptyName }
        return String(name.prefix(120))
    }

    private func size(of url: URL) throws -> Int64 {
        (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

enum LibraryError: LocalizedError {
    case invalidPDF, writeFailed, emptyName, missing
    var errorDescription: String? {
        switch self {
        case .invalidPDF: return "Tệp PDF không hợp lệ hoặc không có trang."
        case .writeFailed: return "Không thể lưu tài liệu PDF."
        case .emptyName: return "Hãy nhập tên tài liệu."
        case .missing: return "Tài liệu không còn trong thư viện."
        }
    }
}
