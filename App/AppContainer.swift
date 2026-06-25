import Foundation
import SwiftData
@preconcurrency import ReadiumShared

struct ListeningSessionSnapshot: Identifiable, Equatable {
    let bookID: UUID
    var bookTitle: String
    var author: String
    var coverRelativePath: String?
    var chapterTitle: String
    var remainingSeconds: Int
    var isPlaying: Bool

    var id: UUID { bookID }

    var remainingTimeText: String {
        let seconds = max(remainingSeconds, 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
@Observable
final class ListeningSessionStore {
    var session: ListeningSessionSnapshot?
    @ObservationIgnored
    private var onTogglePlayback: (() -> Void)?
    @ObservationIgnored
    private var onStopPlayback: (() -> Void)?

    func start(
        book: BookRecord,
        locatorData: Data?,
        fallbackSectionTitle: String? = nil,
        progress: Double? = nil,
        isPlaying: Bool = true,
        remainingSeconds: Int? = nil,
        onTogglePlayback: (() -> Void)? = nil,
        onStopPlayback: (() -> Void)? = nil
    ) {
        let chapter = Self.chapterEstimate(
            book: book,
            locatorData: locatorData,
            fallbackSectionTitle: fallbackSectionTitle,
            progress: progress
        )
        session = ListeningSessionSnapshot(
            bookID: book.id,
            bookTitle: book.title,
            author: book.displayAuthor,
            coverRelativePath: book.coverRelativePath,
            chapterTitle: chapter.title,
            remainingSeconds: remainingSeconds ?? chapter.remainingSeconds,
            isPlaying: isPlaying
        )
        if let onTogglePlayback {
            self.onTogglePlayback = onTogglePlayback
        }
        if let onStopPlayback {
            self.onStopPlayback = onStopPlayback
        }
    }

    func update(
        book: BookRecord,
        locatorData: Data?,
        fallbackSectionTitle: String? = nil,
        progress: Double? = nil,
        isPlaying: Bool? = nil,
        remainingSeconds: Int? = nil
    ) {
        guard session?.bookID == book.id else {
            return
        }
        let chapter = Self.chapterEstimate(
            book: book,
            locatorData: locatorData,
            fallbackSectionTitle: fallbackSectionTitle,
            progress: progress
        )
        session?.bookTitle = book.title
        session?.author = book.displayAuthor
        session?.coverRelativePath = book.coverRelativePath
        session?.chapterTitle = chapter.title
        session?.remainingSeconds = remainingSeconds ?? chapter.remainingSeconds
        if let isPlaying {
            session?.isPlaying = isPlaying
        }
    }

    func togglePlayback() {
        if let onTogglePlayback {
            onTogglePlayback()
        } else {
            session?.isPlaying.toggle()
        }
    }

    func stop() {
        let stopPlayback = onStopPlayback
        clear()
        stopPlayback?()
    }

    func finish(bookID: UUID) {
        guard session?.bookID == bookID else {
            return
        }
        clear()
    }

    private func clear() {
        session = nil
        onTogglePlayback = nil
        onStopPlayback = nil
    }

    private static func chapterEstimate(
        book: BookRecord,
        locatorData: Data?,
        fallbackSectionTitle: String?,
        progress: Double?
    ) -> (title: String, remainingSeconds: Int) {
        let locator = locatorData.flatMap { try? LocatorCoding.decode($0) }
        let title = locator?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallbackSectionTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "正文"
        let chapterProgress = (locator?.locations.progression
            ?? progress
            ?? book.readingProgress
        )
        .clamped(to: 0 ... 1)
        let estimatedChapterSeconds = 12 * 60
        let remaining = Int((1 - chapterProgress) * Double(estimatedChapterSeconds)).roundedUpToMinuteFloor
        return (title, remaining)
    }
}

private extension Int {
    var roundedUpToMinuteFloor: Int {
        Swift.max(60, self)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

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
    let listeningStore: ListeningSessionStore

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
        let listeningStore = ListeningSessionStore()
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
        self.listeningStore = listeningStore

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
