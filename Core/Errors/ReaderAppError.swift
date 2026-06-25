import Foundation

enum ReaderAppError: LocalizedError, Equatable, Sendable {
    case unsupportedFileType
    case fileTooSmall
    case fileTooLarge(limitMB: Int)
    case corruptedEPUB
    case fixedLayoutNotSupported
    case drmNotSupported
    case duplicateBook(existingBookID: UUID)
    case missingBookFile
    case localNetworkUnavailable
    case transferServerFailed
    case transferTokenExpired
    case uploadInterrupted
    case databaseFailure
    case unknown

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return String(localized: "error.unsupported_file_type")
        case .fileTooSmall:
            return String(localized: "error.file_too_small")
        case .fileTooLarge(let limitMB):
            return String(localized: "error.file_too_large \(limitMB)")
        case .corruptedEPUB:
            return String(localized: "error.corrupted_epub")
        case .fixedLayoutNotSupported:
            return String(localized: "error.fixed_layout_not_supported")
        case .drmNotSupported:
            return String(localized: "error.drm_not_supported")
        case .duplicateBook:
            return String(localized: "error.duplicate_book")
        case .missingBookFile:
            return String(localized: "error.missing_book_file")
        case .localNetworkUnavailable:
            return String(localized: "error.local_network_unavailable")
        case .transferServerFailed:
            return String(localized: "error.transfer_server_failed")
        case .transferTokenExpired:
            return String(localized: "error.transfer_token_expired")
        case .uploadInterrupted:
            return String(localized: "error.upload_interrupted")
        case .databaseFailure:
            return String(localized: "error.database_failure")
        case .unknown:
            return String(localized: "error.unknown")
        }
    }
}
