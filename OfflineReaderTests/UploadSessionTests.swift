import XCTest
@testable import OfflineReader

final class UploadSessionTests: XCTestCase {
    func testSanitizesUploadedFileName() {
        XCTAssertEqual(UploadSession.sanitizedFileName("../bad\u{0007}.epub"), "bad.epub")
        XCTAssertEqual(UploadSession.sanitizedFileName(""), "book.epub")
    }

    func testParsesContentRange() throws {
        let parsed = try UploadSession.parseContentRange("bytes 4-7/12")

        XCTAssertEqual(parsed.start, 4)
        XCTAssertEqual(parsed.end, 7)
        XCTAssertEqual(parsed.total, 12)
    }

    func testRejectsInvalidContentRange() {
        XCTAssertThrowsError(try UploadSession.parseContentRange("4-7/12"))
    }

    func testBookFileValidatorAcceptsSupportedFormats() throws {
        let validator = BookFileValidator()

        XCTAssertEqual(
            try validator.validate(fileName: "book.epub", fileSize: EPUBPreflightValidator.minimumBytes),
            .epub
        )
        XCTAssertEqual(
            try validator.validate(fileName: "book.pdf", fileSize: EPUBPreflightValidator.minimumBytes),
            .pdf
        )
        XCTAssertEqual(
            try validator.validate(fileName: "book.txt", fileSize: 1),
            .plainText
        )
        XCTAssertThrowsError(try validator.validate(fileName: "book.docx", fileSize: 4096))
    }

    func testReceivesChunksAndCompletesFile() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("epub")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let session = try UploadSession(
            uploadID: UUID(),
            fileName: "book.epub",
            fileSize: 6,
            tempURL: tempURL
        )

        try await session.appendChunk(index: 0, rangeHeader: "bytes 0-2/6", body: Data("abc".utf8))
        try await session.appendChunk(index: 1, rangeHeader: "bytes 3-5/6", body: Data("def".utf8))
        let completedURL = try await session.complete()

        XCTAssertEqual(try Data(contentsOf: completedURL), Data("abcdef".utf8))
    }

    func testTransferWebPageAllowsMultipleBookSelection() {
        let html = TransferWebPage.html(token: "test-token")

        XCTAssertTrue(html.contains("multiple"))
        XCTAssertTrue(html.contains(".epub,application/epub+zip,.pdf,application/pdf,.txt,text/plain"))
        XCTAssertTrue(html.contains("id=\"dragArea\""))
        XCTAssertTrue(html.contains("您设备上的文件列表"))
        XCTAssertTrue(html.contains("await request(\"/files\")"))
        XCTAssertTrue(html.contains("/download?token="))
        XCTAssertTrue(html.contains("method: \"DELETE\""))
        XCTAssertTrue(html.contains("uploadFiles(Array.from(input.files))"))
        XCTAssertTrue(html.contains("uploadFiles(Array.from(event.dataTransfer.files))"))
    }

    @MainActor
    func testWiFiTransferListsDownloadsAndDeletesLibraryFiles() async throws {
        let importService = RecordingImportService()
        let fileStore = try BookFileStore()
        let bookID = UUID()
        let downloadURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("pdf")
        let fixture = TransferLibraryFixture(bookID: bookID, downloadURL: downloadURL)
        try Data("pdf payload".utf8).write(to: downloadURL)
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        let service = WiFiTransferService(
            fileStore: fileStore,
            importService: importService,
            libraryProvider: { await fixture.items() },
            downloadProvider: { try await fixture.download(bookID: $0) },
            deleteHandler: { await fixture.delete(bookID: $0) },
            addressResolver: { "127.0.0.1" },
            port: 18081
        )

        do {
            let endpoint = try await service.start()
            let token = try await Self.transferToken(from: endpoint.url)

            var listRequest = try URLRequest(url: XCTUnwrap(URL(string: "/files", relativeTo: endpoint.url)?.absoluteURL))
            listRequest.setValue(token, forHTTPHeaderField: "X-Transfer-Token")
            let listData = try await Self.responseData(for: listRequest)
            let files = try JSONDecoder().decode([TransferLibraryItem].self, from: listData)
            let expectedFiles = await fixture.items()
            XCTAssertEqual(files, expectedFiles)

            let downloadURL = try XCTUnwrap(URL(
                string: "/files/\(bookID.uuidString)/download?token=\(token)",
                relativeTo: endpoint.url
            )?.absoluteURL)
            let (downloadData, downloadResponse) = try await Self.response(for: URLRequest(url: downloadURL))
            XCTAssertEqual(downloadData, Data("pdf payload".utf8))
            XCTAssertEqual(downloadResponse.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
            XCTAssertTrue(downloadResponse.value(forHTTPHeaderField: "Content-Disposition")?.contains("Sample.pdf") == true)

            var deleteRequest = try URLRequest(url: XCTUnwrap(URL(
                string: "/files/\(bookID.uuidString)",
                relativeTo: endpoint.url
            )?.absoluteURL))
            deleteRequest.httpMethod = "DELETE"
            deleteRequest.setValue(token, forHTTPHeaderField: "X-Transfer-Token")
            let (_, deleteResponse) = try await Self.response(for: deleteRequest)
            XCTAssertEqual(deleteResponse.statusCode, 204)
            let deletedBookIDs = await fixture.deletedIDs()
            XCTAssertEqual(deletedBookIDs, [bookID])

            try await service.stop()
        } catch {
            try? await service.stop()
            throw error
        }
    }

    @MainActor
    func testWiFiTransferAcceptsMultipleBookFormatsInOneServerSession() async throws {
        let importService = RecordingImportService()
        let fileStore = try BookFileStore()
        let service = WiFiTransferService(
            fileStore: fileStore,
            importService: importService,
            addressResolver: { "127.0.0.1" },
            port: 18080
        )

        do {
            let endpoint = try await service.start()
            let token = try await Self.transferToken(from: endpoint.url)

            let firstTitle = try await Self.uploadFixture(
                named: "first.epub",
                byte: 0x31,
                token: token,
                endpoint: endpoint.url
            )
            let secondTitle = try await Self.uploadFixture(
                named: "second.pdf",
                byte: 0x32,
                token: token,
                endpoint: endpoint.url
            )
            let thirdTitle = try await Self.uploadFixture(
                named: "third.txt",
                byte: 0x33,
                fileSize: 64,
                token: token,
                endpoint: endpoint.url
            )

            try await service.stop()
            XCTAssertEqual(firstTitle, "first")
            XCTAssertEqual(secondTitle, "second")
            XCTAssertEqual(thirdTitle, "third")
            XCTAssertEqual(importService.importedFileNames, ["first.epub", "second.pdf", "third.txt"])
        } catch {
            try? await service.stop()
            throw error
        }
    }

    private static func transferToken(from endpoint: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        try Self.assertSuccess(response)
        let html = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"const token = "([^"]+)";"#)
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let tokenRange = Range(match.range(at: 1), in: html)
        else {
            throw URLError(.userAuthenticationRequired)
        }
        return String(html[tokenRange])
    }

    private static func uploadFixture(
        named fileName: String,
        byte: UInt8,
        fileSize: Int = Int(EPUBPreflightValidator.minimumBytes),
        token: String,
        endpoint: URL
    ) async throws -> String {
        let body = Data(repeating: byte, count: fileSize)
        let createURL = try XCTUnwrap(URL(string: "/api/v1/uploads", relativeTo: endpoint)?.absoluteURL)
        var createRequest = URLRequest(url: createURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue(token, forHTTPHeaderField: "X-Transfer-Token")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "fileName": fileName,
            "fileSize": fileSize
        ])

        let createData = try await responseData(for: createRequest)
        let createResponse = try JSONDecoder().decode(CreateUploadResponse.self, from: createData)

        let uploadURL = try XCTUnwrap(URL(
            string: "/api/v1/uploads/\(createResponse.uploadId)/chunks/0",
            relativeTo: endpoint
        )?.absoluteURL)
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(token, forHTTPHeaderField: "X-Transfer-Token")
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue("bytes 0-\(fileSize - 1)/\(fileSize)", forHTTPHeaderField: "Content-Range")
        uploadRequest.httpBody = body
        _ = try await responseData(for: uploadRequest)

        let completeURL = try XCTUnwrap(URL(
            string: "/api/v1/uploads/\(createResponse.uploadId)/complete",
            relativeTo: endpoint
        )?.absoluteURL)
        var completeRequest = URLRequest(url: completeURL)
        completeRequest.httpMethod = "POST"
        completeRequest.setValue(token, forHTTPHeaderField: "X-Transfer-Token")
        let completeData = try await responseData(for: completeRequest)
        return try JSONDecoder().decode(CompleteUploadResponse.self, from: completeData).title
    }

    private static func responseData(for request: URLRequest) async throws -> Data {
        let (data, _) = try await response(for: request)
        return data
    }

    private static func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try Self.assertSuccess(response)
        return (data, httpResponse)
    }

    @discardableResult
    private static func assertSuccess(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        return httpResponse
    }
}

private struct CreateUploadResponse: Decodable {
    let uploadId: String
}

private struct CompleteUploadResponse: Decodable {
    let title: String
}

private actor TransferLibraryFixture {
    let bookID: UUID
    let downloadURL: URL
    private(set) var deletedBookIDs: [UUID] = []

    init(bookID: UUID, downloadURL: URL) {
        self.bookID = bookID
        self.downloadURL = downloadURL
    }

    func items() -> [TransferLibraryItem] {
        [
            TransferLibraryItem(
                id: bookID,
                name: "Sample.pdf",
                title: "Sample",
                size: "11 B",
                byteSize: 11,
                mediaType: SupportedBookFormat.pdf.mediaType
            )
        ]
    }

    func download(bookID: UUID) throws -> TransferDownloadItem {
        guard bookID == self.bookID else {
            throw ReaderAppError.missingBookFile
        }
        return TransferDownloadItem(
            fileURL: downloadURL,
            fileName: "Sample.pdf",
            mediaType: SupportedBookFormat.pdf.mediaType
        )
    }

    func delete(bookID: UUID) {
        deletedBookIDs.append(bookID)
    }

    func deletedIDs() -> [UUID] {
        deletedBookIDs
    }
}

@MainActor
private final class RecordingImportService: BookImportServiceProtocol, @unchecked Sendable {
    private(set) var importedFileNames: [String] = []

    func importBook(_ request: ImportRequest) async throws -> ImportResult {
        importedFileNames.append(request.originalFileName)
        try? FileManager.default.removeItem(at: request.stagedFileURL)
        return .imported(bookID: UUID())
    }
}
