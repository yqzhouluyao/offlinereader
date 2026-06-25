import Foundation
import SwiftData

@MainActor
protocol BookRepositoryProtocol: AnyObject {
    func fetchBooks(sort: LibrarySort) throws -> [BookRecord]
    func book(id: UUID) throws -> BookRecord?
    func book(sha256: String) throws -> BookRecord?
    func insert(_ draft: ImportedBookDraft) throws -> BookRecord
    func updateReadingPosition(bookID: UUID, locatorData: Data, progress: Double, openedAt: Date) throws
    func delete(bookID: UUID) throws
}

@MainActor
final class BookRepository: BookRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchBooks(sort: LibrarySort) throws -> [BookRecord] {
        let descriptor: FetchDescriptor<BookRecord>
        switch sort {
        case .recent:
            descriptor = FetchDescriptor(
                sortBy: [
                    SortDescriptor(\BookRecord.lastOpenedAt, order: .reverse),
                    SortDescriptor(\BookRecord.addedAt, order: .reverse)
                ]
            )
        case .title:
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\BookRecord.title, order: .forward)])
        }
        return try context.fetch(descriptor)
    }

    func book(id: UUID) throws -> BookRecord? {
        var descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func book(sha256: String) throws -> BookRecord? {
        var descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.sha256 == sha256 })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func insert(_ draft: ImportedBookDraft) throws -> BookRecord {
        let now = Date()
        let record = try BookRecord(
            id: draft.id,
            sha256: draft.sha256,
            title: draft.title,
            authors: draft.authors,
            languageCodes: draft.languageCodes,
            mediaType: draft.mediaType,
            fileRelativePath: draft.files.publicationRelativePath,
            coverRelativePath: draft.files.coverRelativePath,
            originalFileName: draft.originalFileName,
            fileSize: draft.fileSize,
            addedAt: now,
            lastOpenedAt: nil,
            updatedAt: now,
            readingProgress: 0,
            readingLocatorData: nil,
            importSource: draft.source,
            recordVersion: 1
        )
        context.insert(record)
        try context.save()
        return record
    }

    func updateReadingPosition(bookID: UUID, locatorData: Data, progress: Double, openedAt: Date) throws {
        guard let record = try book(id: bookID) else {
            throw ReaderAppError.databaseFailure
        }
        record.readingLocatorData = locatorData
        record.readingProgress = progress.clamped(to: 0 ... 1)
        record.lastOpenedAt = openedAt
        record.updatedAt = Date()
        try context.save()
    }

    func delete(bookID: UUID) throws {
        guard let record = try book(id: bookID) else {
            return
        }
        context.delete(record)
        try context.save()
    }
}
