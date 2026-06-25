import XCTest
@testable import OfflineReader

final class SHA256Tests: XCTestCase {
    func testHashesFileContents() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("abc".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let hash = try await FileHasher().sha256Hex(for: tempURL)

        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
