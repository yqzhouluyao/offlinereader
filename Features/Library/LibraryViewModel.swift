import Foundation
import Observation

enum LibraryShelfMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    var id: String { rawValue }
}

enum LibraryShelfFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case progress
    case category
    case custom

    var id: String { rawValue }
}

@MainActor
enum LibraryPinnedBookStorage {
    private static let key = "offlineReader.library.pinnedBookIDs.v1"

    static func load(defaults: UserDefaults = .standard) -> Set<UUID> {
        guard let values = defaults.array(forKey: key) as? [String] else {
            return []
        }
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    static func save(_ bookIDs: Set<UUID>, defaults: UserDefaults = .standard) {
        let values = bookIDs.map(\.uuidString).sorted()
        defaults.set(values, forKey: key)
    }

    static func remove(bookID: UUID, defaults: UserDefaults = .standard) {
        var bookIDs = load(defaults: defaults)
        bookIDs.remove(bookID)
        save(bookIDs, defaults: defaults)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

@MainActor
@Observable
final class LibraryViewModel {
    private let container: AppContainer
    static let shelfModeKey = "offlineReader.library.shelfMode.v1"

    var books: [BookRecord] = []
    var groups: [LibraryBookGroup] = []
    var sort: LibrarySort = .recent
    var shelfMode: LibraryShelfMode = .grid
    var activeFilter: LibraryShelfFilter = .all
    private(set) var pinnedBookIDs: Set<UUID> = []
    var isEditing = false
    var selectedBookIDs: Set<UUID> = []
    var isImporting = false
    var alertMessage: String?
    var pendingDelete: BookRecord?

    init(container: AppContainer) {
        self.container = container
        if let rawValue = UserDefaults.standard.string(forKey: Self.shelfModeKey),
           let mode = LibraryShelfMode(rawValue: rawValue) {
            shelfMode = mode
        }
        pinnedBookIDs = LibraryPinnedBookStorage.load()
    }

    func load() {
        do {
            books = applyPinnedOrdering(to: try container.repository.fetchBooks(sort: sort))
            groups = container.libraryGroupStore.load()
            pruneMissingBooksFromGroups()
            pruneMissingPinnedBooks()
        } catch {
            alertMessage = ReaderAppError.databaseFailure.localizedDescription
            AppLog.library.error("Failed to fetch library")
        }
    }

    func setSort(_ sort: LibrarySort) {
        self.sort = sort
        load()
    }

    func setShelfMode(_ mode: LibraryShelfMode) {
        shelfMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.shelfModeKey)
    }

    func setFilter(_ filter: LibraryShelfFilter) {
        activeFilter = filter
        if filter == .progress {
            setSort(.recent)
        } else if filter == .custom {
            setSort(.title)
        }
    }

    func book(id: UUID) -> BookRecord? {
        books.first { $0.id == id }
    }

    func books(in group: LibraryBookGroup) -> [BookRecord] {
        let ids = Set(group.bookIDs)
        return applyPinnedOrdering(to: books.filter { ids.contains($0.id) })
    }

    func isPinned(_ book: BookRecord) -> Bool {
        pinnedBookIDs.contains(book.id)
    }

    func togglePinned(_ book: BookRecord) {
        if pinnedBookIDs.contains(book.id) {
            pinnedBookIDs.remove(book.id)
        } else {
            pinnedBookIDs.insert(book.id)
        }
        LibraryPinnedBookStorage.save(pinnedBookIDs)
        books = applyPinnedOrdering(to: books)
    }

    func enterEditing(selecting book: BookRecord? = nil) {
        isEditing = true
        if let book {
            selectedBookIDs.insert(book.id)
        }
    }

    func cancelEditing() {
        isEditing = false
        selectedBookIDs = []
    }

    func toggleSelection(for book: BookRecord) {
        if selectedBookIDs.contains(book.id) {
            selectedBookIDs.remove(book.id)
        } else {
            selectedBookIDs.insert(book.id)
        }
    }

    func toggleSelectAll() {
        let allIDs = Set(books.map(\.id))
        selectedBookIDs = selectedBookIDs == allIDs ? [] : allIDs
    }

    func prepareSingleBookMove(_ book: BookRecord) {
        if isEditing {
            selectedBookIDs.insert(book.id)
        } else {
            selectedBookIDs = [book.id]
        }
    }

    func clearTransientSelectionIfNeeded() {
        if !isEditing {
            selectedBookIDs = []
        }
    }

    func createGroup(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var updated = groups
        let now = Date()
        let group = LibraryBookGroup(
            name: name,
            bookIDs: orderedSelectionIDs(),
            createdAt: now,
            updatedAt: now
        )
        updated.insert(group, at: 0)
        persistGroups(updated)
        activeFilter = .custom
    }

    func moveSelection(to groupID: UUID) {
        let selected = selectedBookIDs
        guard !selected.isEmpty,
              let index = groups.firstIndex(where: { $0.id == groupID })
        else {
            return
        }

        var updated = groups.map { group in
            var group = group
            group.bookIDs.removeAll { selected.contains($0) }
            return group
        }
        var destination = updated[index]
        let existing = Set(destination.bookIDs)
        destination.bookIDs.append(contentsOf: orderedSelectionIDs().filter { !existing.contains($0) })
        destination.updatedAt = Date()
        updated[index] = destination
        persistGroups(updated)
        activeFilter = .custom
        cancelEditing()
    }

    func deleteSelectedBooks() async {
        let selected = selectedBookIDs
        guard !selected.isEmpty else { return }
        for book in books where selected.contains(book.id) {
            await delete(book)
        }
        cancelEditing()
    }

    func importFile(from url: URL) async -> UUID? {
        isImporting = true
        defer { isImporting = false }
        do {
            let request = try await container.fileImportCoordinator.stageSecurityScopedFile(from: url)
            let result = try await container.importService.importBook(request)
            load()
            switch result {
            case .imported(let bookID):
                return bookID
            case .duplicate(let existingBookID):
                alertMessage = ReaderAppError.duplicateBook(existingBookID: existingBookID).localizedDescription
                return existingBookID
            }
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ book: BookRecord) async {
        do {
            try container.repository.delete(bookID: book.id)
            try await container.fileStore.deleteInstalledFiles(bookID: book.id)
            container.readerBookmarkStore.reset(bookID: book.id)
            pinnedBookIDs.remove(book.id)
            LibraryPinnedBookStorage.save(pinnedBookIDs)
            remove(bookID: book.id, fromGroups: groups)
            load()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func orderedSelectionIDs() -> [UUID] {
        books.map(\.id).filter { selectedBookIDs.contains($0) }
    }

    private func applyPinnedOrdering(to books: [BookRecord]) -> [BookRecord] {
        books.enumerated().sorted { lhs, rhs in
            let lhsPinned = pinnedBookIDs.contains(lhs.element.id)
            let rhsPinned = pinnedBookIDs.contains(rhs.element.id)
            if lhsPinned != rhsPinned {
                return lhsPinned && !rhsPinned
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func pruneMissingBooksFromGroups() {
        let bookIDs = Set(books.map(\.id))
        let pruned = groups.map { group in
            var group = group
            group.bookIDs = group.bookIDs.filter { bookIDs.contains($0) }
            return group
        }
        if pruned != groups {
            persistGroups(pruned)
        }
    }

    private func pruneMissingPinnedBooks() {
        let bookIDs = Set(books.map(\.id))
        let pruned = pinnedBookIDs.intersection(bookIDs)
        if pruned != pinnedBookIDs {
            pinnedBookIDs = pruned
            LibraryPinnedBookStorage.save(pruned)
        }
    }

    private func remove(bookID: UUID, fromGroups groups: [LibraryBookGroup]) {
        let updated = groups.map { group in
            var group = group
            group.bookIDs.removeAll { $0 == bookID }
            return group
        }
        persistGroups(updated)
    }

    private func persistGroups(_ groups: [LibraryBookGroup]) {
        self.groups = groups
        container.libraryGroupStore.save(groups)
    }
}
