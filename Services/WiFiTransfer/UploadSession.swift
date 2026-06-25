import Foundation

enum UploadSessionStatus: Equatable, Sendable {
    case receiving
    case importing
    case succeeded(bookID: UUID, title: String)
    case failed(String)
}

struct UploadSessionSnapshot: Equatable, Sendable {
    let uploadID: UUID
    let fileName: String
    let fileSize: Int64
    let receivedBytes: Int64
    let nextChunkIndex: Int
    let status: UploadSessionStatus
}

struct UploadCreateRequest: Decodable, Sendable {
    let fileName: String
    let fileSize: Int64
}

actor UploadSession {
    static let chunkSize = 4 * 1024 * 1024

    let uploadID: UUID
    let fileName: String
    let fileSize: Int64
    let tempURL: URL

    private var receivedBytes: Int64 = 0
    private var nextExpectedChunkIndex: Int = 0
    private var status: UploadSessionStatus = .receiving
    private var fileHandle: FileHandle?

    init(uploadID: UUID, fileName: String, fileSize: Int64, tempURL: URL) throws {
        self.uploadID = uploadID
        self.fileName = Self.sanitizedFileName(fileName)
        self.fileSize = fileSize
        self.tempURL = tempURL
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: tempURL)
    }

    func appendChunk(index: Int, rangeHeader: String?, body: Data) throws {
        guard case .receiving = status else {
            throw ReaderAppError.uploadInterrupted
        }
        guard body.count <= Self.chunkSize else {
            throw ReaderAppError.fileTooLarge(limitMB: 4)
        }
        guard index == nextExpectedChunkIndex else {
            throw ReaderAppError.uploadInterrupted
        }
        let expectedStart = receivedBytes
        let expectedEnd = receivedBytes + Int64(body.count) - 1
        if let rangeHeader {
            let parsed = try Self.parseContentRange(rangeHeader)
            guard parsed.start == expectedStart,
                  parsed.end == expectedEnd,
                  parsed.total == fileSize
            else {
                throw ReaderAppError.uploadInterrupted
            }
        }
        guard receivedBytes + Int64(body.count) <= fileSize else {
            throw ReaderAppError.uploadInterrupted
        }
        try fileHandle?.write(contentsOf: body)
        receivedBytes += Int64(body.count)
        nextExpectedChunkIndex += 1
    }

    func complete() throws -> URL {
        guard receivedBytes == fileSize else {
            throw ReaderAppError.uploadInterrupted
        }
        try fileHandle?.close()
        fileHandle = nil
        status = .importing
        return tempURL
    }

    func markSucceeded(bookID: UUID, title: String) {
        status = .succeeded(bookID: bookID, title: title)
    }

    func markFailed(_ message: String) {
        status = .failed(message)
    }

    func cancelAndDelete() {
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: tempURL)
        status = .failed(String(localized: "error.upload_interrupted"))
    }

    func snapshot() -> UploadSessionSnapshot {
        UploadSessionSnapshot(
            uploadID: uploadID,
            fileName: fileName,
            fileSize: fileSize,
            receivedBytes: receivedBytes,
            nextChunkIndex: nextExpectedChunkIndex,
            status: status
        )
    }

    static func sanitizedFileName(_ fileName: String) -> String {
        let trimmedInput = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return "book.epub"
        }
        let last = URL(fileURLWithPath: trimmedInput).lastPathComponent
        let scalars = last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", "/", ".", ".."].contains(sanitized) ? "book.epub" : sanitized
    }

    static func parseContentRange(_ value: String) throws -> (start: Int64, end: Int64, total: Int64) {
        let pattern = #"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges == 4,
              let startRange = Range(match.range(at: 1), in: value),
              let endRange = Range(match.range(at: 2), in: value),
              let totalRange = Range(match.range(at: 3), in: value),
              let start = Int64(value[startRange]),
              let end = Int64(value[endRange]),
              let total = Int64(value[totalRange])
        else {
            throw ReaderAppError.uploadInterrupted
        }
        return (start, end, total)
    }
}
