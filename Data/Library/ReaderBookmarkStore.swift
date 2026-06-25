import Foundation

struct ReaderBookmark: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var excerpt: String
    var locatorData: Data
    var progress: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        excerpt: String,
        locatorData: Data,
        progress: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
        self.locatorData = locatorData
        self.progress = progress
        self.createdAt = createdAt
    }
}

@MainActor
final class ReaderBookmarkStore {
    private let defaults: UserDefaults
    private let keyPrefix = "reader.bookmarks.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(bookID: UUID) -> [ReaderBookmark] {
        guard let data = defaults.data(forKey: key(for: bookID)),
              let bookmarks = try? JSONDecoder().decode([ReaderBookmark].self, from: data)
        else {
            return []
        }
        return bookmarks.sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ bookmarks: [ReaderBookmark], bookID: UUID) {
        guard let data = try? JSONEncoder().encode(bookmarks) else {
            return
        }
        defaults.set(data, forKey: key(for: bookID))
    }

    func delete(bookmarkID: UUID, bookID: UUID) {
        let remaining = load(bookID: bookID).filter { $0.id != bookmarkID }
        save(remaining, bookID: bookID)
    }

    func reset(bookID: UUID) {
        defaults.removeObject(forKey: key(for: bookID))
    }

    private func key(for bookID: UUID) -> String {
        keyPrefix + bookID.uuidString
    }
}
