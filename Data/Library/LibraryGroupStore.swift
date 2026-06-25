import Foundation

struct LibraryBookGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var bookIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        bookIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bookIDs = bookIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class LibraryGroupStore {
    private let defaults: UserDefaults
    private let key = "offlineReader.library.groups.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [LibraryBookGroup] {
        guard let data = defaults.data(forKey: key),
              let groups = try? JSONDecoder().decode([LibraryBookGroup].self, from: data)
        else {
            return []
        }
        return groups.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    func save(_ groups: [LibraryBookGroup]) {
        guard let data = try? JSONEncoder().encode(groups) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }
}
