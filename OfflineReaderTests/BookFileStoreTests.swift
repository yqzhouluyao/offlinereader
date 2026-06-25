import XCTest
@testable import OfflineReader

final class BookFileStoreTests: XCTestCase {
    func testInstallsResolvesAndDeletesBookFiles() async throws {
        let store = try BookFileStore()
        let stagedURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("epub")
        try Data("fake epub payload".utf8).write(to: stagedURL)

        let bookID = UUID()
        let files = try await store.install(
            stagedEPUB: stagedURL,
            bookID: bookID,
            coverData: Data("cover".utf8),
            coverExtension: "jpg"
        )
        let publicationURL = try await store.resolve(relativePath: files.publicationRelativePath)
        let coverPath = try XCTUnwrap(files.coverRelativePath)
        let coverURL = try await store.resolve(relativePath: coverPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: publicationURL.path))
        XCTAssertEqual(try Data(contentsOf: coverURL), Data("cover".utf8))

        try await store.deleteInstalledFiles(bookID: bookID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicationURL.path))
    }

    func testInstallsSupportedBookFileWithOriginalExtension() async throws {
        let store = try BookFileStore()
        let stagedURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("pdf")
        try Data(repeating: 0x25, count: 2_048).write(to: stagedURL)

        let files = try await store.install(
            stagedFile: stagedURL,
            bookID: UUID(),
            fileExtension: "pdf",
            coverData: nil,
            coverExtension: nil
        )
        let publicationURL = try await store.resolve(relativePath: files.publicationRelativePath)

        XCTAssertEqual(publicationURL.pathExtension, "pdf")
    }

    func testRejectsPathTraversal() async throws {
        let store = try BookFileStore()

        do {
            _ = try await store.resolve(relativePath: "../outside.epub")
            XCTFail("Expected path traversal to be rejected")
        } catch {
            XCTAssertTrue(error is ReaderAppError)
        }
    }
}
