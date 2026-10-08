import Foundation

struct LibraryDocument: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let filename: String
    var createdAt: Date
    var updatedAt: Date
    var pageCount: Int
    var byteCount: Int64
    var isFavorite: Bool

    init(id: UUID, name: String, filename: String, createdAt: Date, updatedAt: Date,
         pageCount: Int, byteCount: Int64, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.filename = filename
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pageCount = pageCount
        self.byteCount = byteCount
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, filename, createdAt, updatedAt, pageCount, byteCount, isFavorite
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        filename = try values.decode(String.self, forKey: .filename)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        pageCount = try values.decode(Int.self, forKey: .pageCount)
        byteCount = try values.decode(Int64.self, forKey: .byteCount)
        // Existing libraries from 1.0 have no favorite flag.
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
