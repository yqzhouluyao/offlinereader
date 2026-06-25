import XCTest
@testable import OfflineReader

@MainActor
final class ReaderBookmarkStoreTests: XCTestCase {
    func testSavesAndDeletesMultipleBookmarksForABook() {
        let suiteName = "ReaderBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ReaderBookmarkStore(defaults: defaults)
        let bookID = UUID()
        let first = ReaderBookmark(
            title: "第一章",
            excerpt: "第一处书签",
            locatorData: Data("first".utf8),
            progress: 0.1
        )
        let second = ReaderBookmark(
            title: "第二章",
            excerpt: "第二处书签",
            locatorData: Data("second".utf8),
            progress: 0.4
        )

        store.save([first, second], bookID: bookID)
        let loaded = store.load(bookID: bookID)
        XCTAssertEqual(loaded.map(\.id), [first.id, second.id])
        XCTAssertEqual(loaded.map(\.title), ["第一章", "第二章"])

        store.delete(bookmarkID: first.id, bookID: bookID)
        XCTAssertEqual(store.load(bookID: bookID).map(\.id), [second.id])
    }
}
