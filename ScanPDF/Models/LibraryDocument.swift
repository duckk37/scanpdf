import Foundation

struct LibraryDocument: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let filename: String
    var createdAt: Date
    var updatedAt: Date
    var pageCount: Int
    var byteCount: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
