import Foundation

struct ValidatedBookFile: Equatable, Sendable {
    let format: SupportedBookFormat
    let fileSize: Int64
}

struct BookFileValidator: Sendable {
    static let minimumBytes: Int64 = 1024
    static let maximumBytes: Int64 = 200 * 1024 * 1024

    func validate(url: URL) throws -> ValidatedBookFile {
        guard let format = SupportedBookFormat(fileExtension: url.pathExtension) else {
            throw ReaderAppError.unsupportedFileType
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ReaderAppError.unsupportedFileType
        }
        let size = Int64(values.fileSize ?? 0)
        try validate(fileSize: size, format: format)
        return ValidatedBookFile(format: format, fileSize: size)
    }

    func validate(fileName: String, fileSize: Int64) throws -> SupportedBookFormat {
        guard let format = SupportedBookFormat(fileName: fileName) else {
            throw ReaderAppError.unsupportedFileType
        }
        try validate(fileSize: fileSize, format: format)
        return format
    }

    private func validate(fileSize: Int64, format: SupportedBookFormat) throws {
        guard fileSize >= format.minimumBytes else {
            throw ReaderAppError.fileTooSmall
        }
        guard fileSize <= format.maximumBytes else {
            throw ReaderAppError.fileTooLarge(limitMB: Int(format.maximumBytes / 1_024 / 1_024))
        }
    }
}

typealias EPUBPreflightValidator = BookFileValidator
