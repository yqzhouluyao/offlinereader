import Foundation
import Observation
@preconcurrency import ReadiumShared

@MainActor
@Observable
final class ReaderViewModel {
    enum LoadState {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let container: AppContainer
    private let bookID: UUID
    private var lastSaveAt: Date = .distantPast
    private var pendingSaveTask: Task<Void, Never>?
    private var searchGeneration = 0

    var state: LoadState = .idle
    var book: BookRecord?
    var session: (any ReaderSessionProtocol)?
    var isChromeVisible = true
    var tocItems: [TableOfContentsItem] = []
    var preferences: ReaderPreferencesSnapshot
    var currentSectionTitle: String = "正文"
    var currentPageNumber: Int = 1
    var totalPageCount: Int?
    var bookmarks: [ReaderBookmark] = []
    var searchResults: [ReaderSearchResultItem] = []
    var isSearching = false
    var listeningState: ReaderListeningState = .inactive
    var isCurrentBookmarkSelected = false
    var progressPercentText: String {
        let percent = Int((readingProgress * 100).rounded())
        return "\(percent)%"
    }

    var readProgressText: String {
        if let totalPageCount {
            return "已读\(currentPageNumber)/\(totalPageCount)页"
        }
        return "已读\(progressPercentText)"
    }

    var pageText: String {
        if let totalPageCount {
            return "\(currentPageNumber)/\(totalPageCount) 页"
        }
        return "\(currentPageNumber)/-- 页"
    }

    var shareText: String {
        guard let book else {
            return "OfflineReader"
        }
        let author = book.displayAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        if author.isEmpty {
            return "《\(book.title)》"
        }
        return "《\(book.title)》 - \(author)"
    }

    var isListeningAvailable: Bool {
        session?.isListeningAvailable == true
    }

    var shouldShowReaderListeningControls: Bool {
        listeningState.isActive || activeListeningSnapshot != nil
    }

    var isReaderListeningPlaying: Bool {
        if listeningState.isActive {
            return listeningState.isPlaying
        }
        return activeListeningSnapshot?.isPlaying ?? false
    }

    var isReaderListeningLoading: Bool {
        listeningState.isActive && listeningState.isLoading
    }

    var readerListeningRemainingText: String {
        if listeningState.isActive {
            return listeningState.remainingTimeText
        }
        return activeListeningSnapshot?.remainingTimeText ?? "--:--"
    }

    private var activeListeningSnapshot: ListeningSessionSnapshot? {
        guard let snapshot = container.listeningStore.session,
              snapshot.bookID == bookID
        else {
            return nil
        }
        return snapshot
    }

    private var readingProgress: Double {
        (book?.readingProgress ?? 0).clamped(to: 0 ... 1)
    }

    init(container: AppContainer, bookID: UUID) {
        self.container = container
        self.bookID = bookID
        self.preferences = container.preferencesStore.load()
    }

    func load() async {
        guard case .idle = state else { return }
        state = .loading
        do {
            guard let record = try container.repository.book(id: bookID) else {
                throw ReaderAppError.missingBookFile
            }
            book = record
            let fileURL = try await container.fileStore.resolve(relativePath: record.fileRelativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ReaderAppError.missingBookFile
            }
            let format = SupportedBookFormat(mediaType: record.mediaType)
                ?? SupportedBookFormat(fileExtension: fileURL.pathExtension)
                ?? .epub
            let session = try await makeSession(for: record, fileURL: fileURL, format: format)
            bookmarks = container.readerBookmarkStore.load(bookID: record.id)
            session.onLocationChanged = { [weak self] data, progress in
                self?.updateCurrentBookmarkSelection(locatorData: data)
                self?.schedulePositionSave(locatorData: data, progress: progress)
            }
            session.onChromeToggleRequested = { [weak self] in
                self?.isChromeVisible.toggle()
            }
            session.onListeningStateChanged = { [weak self, container, record] state in
                if let self {
                    self.syncListeningStore(with: state)
                } else {
                    Self.syncListeningStore(
                        container: container,
                        book: record,
                        state: state,
                        fallbackSectionTitle: record.title
                    )
                }
            }
            self.session = session
            try await session.start()
            tocItems = await session.tableOfContents()
            totalPageCount = await session.totalPageCount()
            updateCurrentSectionTitle(from: session.currentLocatorData)
            updateCurrentPage(from: session.currentLocatorData, progress: record.readingProgress)
            updateCurrentBookmarkSelection(locatorData: session.currentLocatorData)
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func close() async {
        pendingSaveTask?.cancel()
        if let data = session?.currentLocatorData {
            try? container.repository.updateReadingPosition(
                bookID: bookID,
                locatorData: data,
                progress: book?.readingProgress ?? 0,
                openedAt: Date()
            )
        }
        if listeningState.isActive || activeListeningSnapshot != nil {
            return
        }
        await session?.close()
    }

    func goToTOCItem(_ item: TableOfContentsItem) async {
        do {
            try await session?.goToTableOfContentsItem(item.id)
        } catch {
            state = .failed(String(localized: "reader.toc.jump_failed"))
        }
    }

    func toggleBookmark() {
        guard let locatorData = session?.currentLocatorData else {
            return
        }

        if let existing = bookmarkMatchingCurrentPosition(locatorData: locatorData) {
            deleteBookmark(existing)
            isCurrentBookmarkSelected = false
            return
        }

        let locator = try? LocatorCoding.decode(locatorData)
        let progress = (locator?.locations.totalProgression
            ?? locator?.locations.progression
            ?? book?.readingProgress
            ?? 0
        )
        .clamped(to: 0 ... 1)
        let title = locator?.title?.readerTrimmedNonEmpty
            ?? currentSectionTitle.readerTrimmedNonEmpty
            ?? book?.title.readerTrimmedNonEmpty
            ?? "当前位置"

        let bookmark = ReaderBookmark(
            title: title,
            excerpt: bookmarkExcerpt(from: locator, progress: progress),
            locatorData: locatorData,
            progress: progress
        )
        bookmarks.append(bookmark)
        container.readerBookmarkStore.save(bookmarks, bookID: bookID)
        isCurrentBookmarkSelected = true
    }

    func addBookmark() {
        toggleBookmark()
    }

    func deleteBookmark(_ bookmark: ReaderBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        container.readerBookmarkStore.save(bookmarks, bookID: bookID)
        updateCurrentBookmarkSelection(locatorData: session?.currentLocatorData)
    }

    func goToBookmark(_ bookmark: ReaderBookmark) async {
        do {
            try await session?.go(to: bookmark.locatorData)
            updateCurrentSectionTitle(from: bookmark.locatorData)
            updateCurrentPage(from: bookmark.locatorData, progress: bookmark.progress)
            isCurrentBookmarkSelected = true
        } catch {
            state = .failed("书签位置无法打开")
        }
    }

    func search(query: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let session
        else {
            isSearching = false
            searchResults = []
            return
        }

        isSearching = true
        let results = await session.search(trimmedQuery)
        guard generation == searchGeneration else {
            return
        }
        searchResults = results
        isSearching = false
    }

    func clearSearch() {
        searchGeneration += 1
        searchResults = []
        isSearching = false
    }

    func startListening() async {
        guard let book,
              let session,
              session.isListeningAvailable
        else {
            return
        }
        let playbackSession = session
        listeningState = ReaderListeningState(
            isActive: true,
            isPlaying: true,
            isLoading: true,
            chapterTitle: currentSectionTitle,
            utteranceText: "",
            locatorData: session.currentLocatorData ?? book.readingLocatorData,
            remainingSeconds: 12 * 60
        )
        container.listeningStore.start(
            book: book,
            locatorData: session.currentLocatorData ?? book.readingLocatorData,
            fallbackSectionTitle: currentSectionTitle,
            progress: book.readingProgress,
            isPlaying: true,
            onTogglePlayback: {
                Task { @MainActor in
                    playbackSession.pauseOrResumeListening()
                }
            },
            onStopPlayback: {
                Task { @MainActor in
                    playbackSession.stopListening()
                    await playbackSession.close()
                }
            }
        )
        await session.startListening()
    }

    func pauseOrResumeListening() {
        if listeningState.isActive {
            session?.pauseOrResumeListening()
        } else if activeListeningSnapshot != nil {
            container.listeningStore.togglePlayback()
        }
    }

    func focusListeningPosition() async {
        if listeningState.isActive {
            await session?.focusListeningPosition()
        } else if let locatorData = activeListeningSnapshot.flatMap({ _ in book?.readingLocatorData }) {
            try? await session?.go(to: locatorData)
        }
    }

    func stopListening() {
        if listeningState.isActive {
            session?.stopListening()
            listeningState = .inactive
            if let book {
                container.listeningStore.finish(bookID: book.id)
            }
        } else if activeListeningSnapshot != nil {
            container.listeningStore.stop()
        }
    }

    func goToSearchResult(_ result: ReaderSearchResultItem) async {
        do {
            try await session?.go(to: result.locatorData)
            updateCurrentSectionTitle(from: result.locatorData)
            let locator = try? LocatorCoding.decode(result.locatorData)
            let progress = locator?.locations.totalProgression
                ?? locator?.locations.progression
                ?? book?.readingProgress
                ?? 0
            updateCurrentPage(from: result.locatorData, progress: progress)
        } catch {
            state = .failed("搜索结果位置无法打开")
        }
    }

    func updatePreferences(_ newValue: ReaderPreferencesSnapshot) async {
        preferences = newValue
        container.preferencesStore.save(newValue)
        await session?.applyPreferences(newValue)
    }

    func selectSpeechVoice(_ option: ReaderSpeechVoiceOption) async {
        var updated = preferences
        updated.speechEngine = option.engine
        updated.speechVoiceIdentifier = option.identifier
        let shouldRestartListening = listeningState.isActive
        await updatePreferences(updated)
        if shouldRestartListening {
            await startListening()
        }
    }

    private func makeSession(for record: BookRecord, fileURL: URL, format: SupportedBookFormat) async throws -> any ReaderSessionProtocol {
        switch format {
        case .epub:
            let opened = try await container.publicationFactory.open(localURL: fileURL, knownMediaType: record.mediaType)
            let handle = PublicationHandle(
                bookID: record.id,
                publication: opened.publication,
                title: record.title,
                authors: record.authors
            )
            let initialLocator = await initialLocatorData(for: record, publication: opened.publication)
            return try ReaderSession(
                publicationHandle: handle,
                initialLocatorData: initialLocator,
                preferences: preferences
            )
        case .pdf:
            let opened = try await container.publicationFactory.open(localURL: fileURL, knownMediaType: record.mediaType)
            let handle = PublicationHandle(
                bookID: record.id,
                publication: opened.publication,
                title: record.title,
                authors: record.authors
            )
            return try PDFReaderSession(
                publicationHandle: handle,
                initialLocatorData: record.readingLocatorData,
                preferences: preferences
            )
        case .plainText:
            let text = try BookImportService.readPlainText(fileURL)
            return PlainTextReaderSession(
                bookID: record.id,
                title: record.title,
                text: text,
                initialLocatorData: record.readingLocatorData,
                preferences: preferences
            )
        }
    }

    private func schedulePositionSave(locatorData: Data, progress: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastSaveAt) >= 0.75 else {
            pendingSaveTask?.cancel()
            pendingSaveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                self?.schedulePositionSave(locatorData: locatorData, progress: progress)
            }
            return
        }
        lastSaveAt = now
        do {
            try container.repository.updateReadingPosition(
                bookID: bookID,
                locatorData: locatorData,
                progress: progress,
                openedAt: now
            )
            book?.readingProgress = progress.clamped(to: 0 ... 1)
            updateCurrentSectionTitle(from: locatorData)
            updateCurrentPage(from: locatorData, progress: progress)
            if let book {
                container.listeningStore.update(
                    book: book,
                    locatorData: locatorData,
                    fallbackSectionTitle: currentSectionTitle,
                    progress: progress
                )
            }
        } catch {
            AppLog.reader.error("Failed to save reader position")
        }
    }

    private func updateCurrentBookmarkSelection(locatorData: Data?) {
        isCurrentBookmarkSelected = bookmarkMatchingCurrentPosition(locatorData: locatorData) != nil
    }

    private func bookmarkMatchingCurrentPosition(locatorData: Data?) -> ReaderBookmark? {
        guard let locatorData,
              let locator = try? LocatorCoding.decode(locatorData)
        else {
            return nil
        }
        return bookmarks.first { bookmark in
            guard let bookmarkLocator = try? LocatorCoding.decode(bookmark.locatorData) else {
                return false
            }
            return bookmarkLocator.matchesReaderPage(locator)
        }
    }

    private func syncListeningStore(with state: ReaderListeningState) {
        listeningState = state
        guard let book else {
            return
        }
        Self.syncListeningStore(
            container: container,
            book: book,
            state: state,
            fallbackSectionTitle: currentSectionTitle
        )
    }

    private static func syncListeningStore(
        container: AppContainer,
        book: BookRecord,
        state: ReaderListeningState,
        fallbackSectionTitle: String
    ) {
        guard state.isActive else {
            container.listeningStore.finish(bookID: book.id)
            return
        }
        container.listeningStore.update(
            book: book,
            locatorData: state.locatorData ?? book.readingLocatorData,
            fallbackSectionTitle: state.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).readerTrimmedNonEmpty
                ?? fallbackSectionTitle,
            progress: book.readingProgress,
            isPlaying: state.isPlaying,
            remainingSeconds: state.remainingSeconds
        )
    }

    private func updateCurrentPage(from locatorData: Data?, progress: Double) {
        let decodedPosition = locatorData
            .flatMap { try? LocatorCoding.decode($0) }?
            .locations
            .position

        if let decodedPosition {
            currentPageNumber = clampPage(decodedPosition)
            return
        }

        guard let totalPageCount else {
            currentPageNumber = 1
            return
        }
        let page = Int((progress.clamped(to: 0 ... 1) * Double(totalPageCount)).rounded(.down)) + 1
        currentPageNumber = clampPage(page)
    }

    private func clampPage(_ value: Int) -> Int {
        guard let totalPageCount else {
            return max(1, value)
        }
        return min(max(1, value), max(1, totalPageCount))
    }

    private func updateCurrentSectionTitle(from locatorData: Data?) {
        guard let locatorData,
              let locator = try? LocatorCoding.decode(locatorData),
              let title = locator.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return
        }
        currentSectionTitle = title
    }

    private func bookmarkExcerpt(from locator: Locator?, progress: Double) -> String {
        if let snippet = locator?.readerBookmarkSnippet {
            return snippet
        }

        if let totalPageCount {
            let page = clampPage(Int((progress * Double(totalPageCount)).rounded(.down)) + 1)
            return "第\(page)/\(totalPageCount)页 · 已读\(Int((progress * 100).rounded()))%"
        }
        return "已读\(Int((progress * 100).rounded()))%"
    }

    private func initialLocatorData(for record: BookRecord, publication: Publication) async -> Data? {
        let storedLocator = record.readingLocatorData

        guard record.readingProgress <= 0.01 else {
            return storedLocator
        }
        return await contentStartLocatorData(in: publication) ?? storedLocator
    }

    private func contentStartLocatorData(in publication: Publication) async -> Data? {
        let tocStartLink: Link?
        switch await publication.tableOfContents() {
        case .success(let links):
            tocStartLink = links.first
        case .failure:
            tocStartLink = nil
        }

        let startLink = publication.linkWithRel(.start)
            ?? tocStartLink
            ?? publication.readingOrder.first { !$0.isCoverLikeReadingOrderLink }
            ?? publication.readingOrder.first

        guard let startLink else {
            return nil
        }

        let locator = await publication.locate(startLink) ?? Locator(
            href: startLink.url().removingFragment(),
            mediaType: startLink.mediaType ?? .xhtml,
            title: startLink.title,
            locations: Locator.Locations(progression: 0)
        )
        return try? LocatorCoding.encode(locator)
    }
}

private extension Link {
    var isCoverLikeReadingOrderLink: Bool {
        if rels.contains(.cover) {
            return true
        }

        let lowercasedHREF = href.withoutFragment.lowercased()
        return lowercasedHREF.isCoverLikePathComponent
    }
}

private extension String {
    var withoutFragment: String {
        split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? self
    }

    var isCoverLikePathComponent: Bool {
        let lowercased = lowercased()
        return lowercased.contains("cover") || lowercased.contains("titlepage")
    }

    var readerTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var readerCollapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Locator {
    func matchesReaderPage(_ other: Locator) -> Bool {
        guard href.string.withoutFragment == other.href.string.withoutFragment else {
            return false
        }

        if let position = locations.position,
           let otherPosition = other.locations.position {
            return position == otherPosition
        }

        if let totalProgression = locations.totalProgression,
           let otherTotalProgression = other.locations.totalProgression {
            return abs(totalProgression - otherTotalProgression) <= 0.002
        }

        if let progression = locations.progression,
           let otherProgression = other.locations.progression {
            return abs(progression - otherProgression) <= 0.015
        }

        return false
    }

    var readerBookmarkSnippet: String? {
        let sanitizedText = text.sanitized()
        let snippet = [
            sanitizedText.before,
            sanitizedText.highlight,
            sanitizedText.after
        ]
        .compactMap { $0 }
        .joined()
        .readerCollapsedWhitespace
        return snippet.isEmpty ? nil : snippet
    }
}
