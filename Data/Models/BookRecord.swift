import Foundation
import SwiftData

@Model
final class BookRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var sha256: String

    var title: String
    var authorsJSON: Data
    var languageCodesJSON: Data

    var mediaType: String
    var fileRelativePath: String
    var coverRelativePath: String?
    var originalFileName: String
    var fileSize: Int64

    var addedAt: Date
    var lastOpenedAt: Date?
    var updatedAt: Date

    var readingProgress: Double
    var readingLocatorData: Data?

    var importSourceRawValue: String
    var recordVersion: Int

    init(
        id: UUID,
        sha256: String,
        title: String,
        authors: [String],
        languageCodes: [String],
        mediaType: String,
        fileRelativePath: String,
        coverRelativePath: String?,
        originalFileName: String,
        fileSize: Int64,
        addedAt: Date,
        lastOpenedAt: Date?,
        updatedAt: Date,
        readingProgress: Double,
        readingLocatorData: Data?,
        importSource: ImportSource,
        recordVersion: Int
    ) throws {
        self.id = id
        self.sha256 = sha256
        self.title = title
        self.authorsJSON = try Self.encode(authors)
        self.languageCodesJSON = try Self.encode(languageCodes)
        self.mediaType = mediaType
        self.fileRelativePath = fileRelativePath
        self.coverRelativePath = coverRelativePath
        self.originalFileName = originalFileName
        self.fileSize = fileSize
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.updatedAt = updatedAt
        self.readingProgress = readingProgress.clamped(to: 0 ... 1)
        self.readingLocatorData = readingLocatorData
        self.importSourceRawValue = importSource.rawValue
        self.recordVersion = recordVersion
    }

    var authors: [String] {
        (try? Self.decode([String].self, from: authorsJSON)) ?? []
    }

    var languageCodes: [String] {
        (try? Self.decode([String].self, from: languageCodesJSON)) ?? []
    }

    var displayAuthor: String {
        authors.isEmpty ? String(localized: "book.unknown_author") : authors.joined(separator: ", ")
    }

    var displayProgress: String {
        if readingProgress <= 0.001 {
            return String(localized: "book.not_started")
        }
        return readingProgress.formatted(.percent.precision(.fractionLength(0)))
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
