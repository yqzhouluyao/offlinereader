import Foundation
import SwiftData

@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer
    let modelContext: ModelContext
    let repository: BookRepository
    let fileStore: BookFileStore
    let publicationFactory: ReadiumPublicationFactory
    let importService: BookImportService
    let fileImportCoordinator: FileImportCoordinator
    let wifiTransferService: WiFiTransferService
    let preferencesStore: ReaderPreferencesStore
    let libraryGroupStore: LibraryGroupStore
    let readerBookmarkStore: ReaderBookmarkStore

    init(modelContainer: ModelContainer, fileStore: BookFileStore) {
        let modelContext = ModelContext(modelContainer)
        let repository = BookRepository(context: modelContext)
        let publicationFactory = ReadiumPublicationFactory()
        let importService = BookImportService(
            repository: repository,
            fileStore: fileStore,
            publicationFactory: publicationFactory
        )
        let fileImportCoordinator = FileImportCoordinator(fileStore: fileStore)
        let preferencesStore = ReaderPreferencesStore()
        let libraryGroupStore = LibraryGroupStore()
        let readerBookmarkStore = ReaderBookmarkStore()
        let wifiTransferService = WiFiTransferService(
            fileStore: fileStore,
            importService: importService,
            libraryProvider: { [weak repository] in
                try await MainActor.run {
                    guard let repository else { return [] }
                    return try repository.fetchBooks(sort: .recent).map { record in
                        TransferLibraryItem(
                            id: record.id,
                            name: Self.transferFileName(for: record),
                            title: record.title,
                            size: Self.formattedTransferSize(record.fileSize),
                            byteSize: record.fileSize,
                            mediaType: record.mediaType
                        )
                    }
                }
            },
            downloadProvider: { [weak repository, fileStore] bookID in
                let metadata = try await MainActor.run {
                    guard let repository,
                          let record = try repository.book(id: bookID)
                    else {
                        throw ReaderAppError.missingBookFile
                    }
                    return (
                        fileName: Self.transferFileName(for: record),
                        mediaType: record.mediaType,
                        relativePath: record.fileRelativePath
                    )
                }
                let fileURL = try await fileStore.resolve(relativePath: metadata.relativePath)
                return TransferDownloadItem(
                    fileURL: fileURL,
                    fileName: metadata.fileName,
                    mediaType: metadata.mediaType
                )
            },
            deleteHandler: { [weak repository, libraryGroupStore, readerBookmarkStore, fileStore] bookID in
                try await MainActor.run {
                    guard let repository else { return }
                    try repository.delete(bookID: bookID)
                    var groups = libraryGroupStore.load()
                    groups = groups.map { group in
                        var group = group
                        group.bookIDs.removeAll { $0 == bookID }
                        return group
                    }
                    libraryGroupStore.save(groups)
                    readerBookmarkStore.reset(bookID: bookID)
                }
                try await fileStore.deleteInstalledFiles(bookID: bookID)
            }
        )

        self.modelContainer = modelContainer
        self.modelContext = modelContext
        self.repository = repository
        self.fileStore = fileStore
        self.publicationFactory = publicationFactory
        self.importService = importService
        self.fileImportCoordinator = fileImportCoordinator
        self.wifiTransferService = wifiTransferService
        self.preferencesStore = preferencesStore
        self.libraryGroupStore = libraryGroupStore
        self.readerBookmarkStore = readerBookmarkStore

        prepareUITestingStateIfNeeded()
    }

    static func make(inMemory: Bool = false) throws -> AppContainer {
        let container = try ModelContainerFactory.make(inMemory: inMemory)
        let fileStore = try BookFileStore()
        return AppContainer(modelContainer: container, fileStore: fileStore)
    }

    func bootstrap() async {
        try? await fileStore.cleanExpiredTemporaryFiles(olderThan: Date().addingTimeInterval(-24 * 60 * 60))
    }

    private static func transferFileName(for record: BookRecord) -> String {
        let originalName = record.originalFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !originalName.isEmpty {
            return originalName
        }

        let fileExtension = SupportedBookFormat(mediaType: record.mediaType)?.primaryFileExtension
            ?? URL(fileURLWithPath: record.fileRelativePath).pathExtension
        let baseName = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (baseName.isEmpty ? "book" : baseName).appending(".\(fileExtension)")
    }

    private static func formattedTransferSize(_ byteSize: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(max(byteSize, 0))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    private func prepareUITestingStateIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing") else {
            return
        }
        libraryGroupStore.reset()
        seedUITestingLibraryIfNeeded()
    }

    private func seedUITestingLibraryIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing-seed-library") else {
            return
        }
        guard (try? repository.fetchBooks(sort: .recent).isEmpty) == true else {
            return
        }

        let titles = [
            "好战略，坏战略（畅销版）",
            "创新者的窘境（全新修订版）",
            "鞋狗",
            "基业长青",
            "设计心理学（全四册）",
            "硅谷增长黑客实战笔记"
        ]

        for (index, title) in titles.enumerated() {
            let draft = ImportedBookDraft(
                id: UUID(),
                sha256: "ui-testing-\(index)",
                title: title,
                authors: index == 2 ? ["菲尔·奈特"] : ["测试作者"],
                languageCodes: ["zh"],
                mediaType: "application/epub+zip",
                files: InstalledBookFiles(
                    publicationRelativePath: "UITesting/\(index).epub",
                    coverRelativePath: nil
                ),
                originalFileName: "\(title).epub",
                fileSize: 1024,
                source: .fileImporter
            )
            _ = try? repository.insert(draft)
        }
    }

}
