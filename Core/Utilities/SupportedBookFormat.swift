import Foundation
import UniformTypeIdentifiers

enum SupportedBookFormat: String, CaseIterable, Sendable {
    case epub
    case pdf
    case plainText

    var primaryFileExtension: String {
        switch self {
        case .epub: "epub"
        case .pdf: "pdf"
        case .plainText: "txt"
        }
    }

    var mediaType: String {
        switch self {
        case .epub: "application/epub+zip"
        case .pdf: "application/pdf"
        case .plainText: "text/plain"
        }
    }

    var uploadAcceptToken: String {
        switch self {
        case .epub: ".epub,application/epub+zip"
        case .pdf: ".pdf,application/pdf"
        case .plainText: ".txt,text/plain"
        }
    }

    var displayName: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .plainText: "TXT"
        }
    }

    var minimumBytes: Int64 {
        switch self {
        case .plainText:
            1
        case .epub, .pdf:
            1_024
        }
    }

    var maximumBytes: Int64 {
        switch self {
        case .plainText:
            20 * 1_024 * 1_024
        case .epub, .pdf:
            200 * 1_024 * 1_024
        }
    }

    static var supportedDisplayList: String {
        allCases.map(\.displayName).joined(separator: " / ")
    }

    static var supportedExtensions: Set<String> {
        Set(allCases.map(\.primaryFileExtension))
    }

    static var allowedContentTypes: [UTType] {
        [
            UTType(filenameExtension: "epub") ?? .data,
            .pdf,
            .plainText
        ]
    }

    static var uploadAcceptAttribute: String {
        allCases.map(\.uploadAcceptToken).joined(separator: ",")
    }

    init?(fileExtension: String) {
        let normalized = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t\r"))
            .lowercased()
        switch normalized {
        case "epub":
            self = .epub
        case "pdf":
            self = .pdf
        case "txt", "text":
            self = .plainText
        default:
            return nil
        }
    }

    init?(fileName: String) {
        self.init(fileExtension: URL(fileURLWithPath: fileName).pathExtension)
    }

    init?(mediaType: String) {
        switch mediaType.lowercased() {
        case "application/epub+zip":
            self = .epub
        case "application/pdf":
            self = .pdf
        case "text/plain":
            self = .plainText
        default:
            return nil
        }
    }
}
