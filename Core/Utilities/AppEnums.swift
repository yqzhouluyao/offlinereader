import Foundation

enum LibrarySort: String, Codable, CaseIterable, Identifiable, Sendable {
    case recent
    case title

    var id: String { rawValue }

    var titleKey: LocalizedStringResource {
        switch self {
        case .recent: "library.sort.recent"
        case .title: "library.sort.title"
        }
    }
}

enum ImportSource: String, Codable, Sendable {
    case fileImporter
    case wifiTransfer
}

struct InstalledBookFiles: Equatable, Sendable {
    let publicationRelativePath: String
    let coverRelativePath: String?
}

struct ImportedBookDraft: Sendable {
    let id: UUID
    let sha256: String
    let title: String
    let authors: [String]
    let languageCodes: [String]
    let mediaType: String
    let files: InstalledBookFiles
    let originalFileName: String
    let fileSize: Int64
    let source: ImportSource
}

struct ImportRequest: Sendable {
    let stagedFileURL: URL
    let originalFileName: String
    let source: ImportSource
}

enum ImportResult: Sendable, Equatable {
    case imported(bookID: UUID)
    case duplicate(existingBookID: UUID)
}
