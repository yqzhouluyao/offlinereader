import Foundation
import PDFKit
import UIKit

@MainActor
protocol BookImportServiceProtocol: AnyObject, Sendable {
    func importBook(_ request: ImportRequest) async throws -> ImportResult
}

@MainActor
final class BookImportService: BookImportServiceProtocol, @unchecked Sendable {
    private let repository: BookRepositoryProtocol
    private let fileStore: BookFileStore
    private let publicationFactory: PublicationFactoryProtocol
    private let hasher: FileHasher
    private let validator: BookFileValidator
    private let fileManager: FileManager

    init(
        repository: BookRepositoryProtocol,
        fileStore: BookFileStore,
        publicationFactory: PublicationFactoryProtocol,
        hasher: FileHasher = FileHasher(),
        validator: BookFileValidator = BookFileValidator(),
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.publicationFactory = publicationFactory
        self.hasher = hasher
        self.validator = validator
        self.fileManager = fileManager
    }

    func importBook(_ request: ImportRequest) async throws -> ImportResult {
        do {
            let validated = try validator.validate(url: request.stagedFileURL)
            let sha256 = try await hasher.sha256Hex(for: request.stagedFileURL)

            if let existing = try repository.book(sha256: sha256) {
                try? fileManager.removeItem(at: request.stagedFileURL)
                return .duplicate(existingBookID: existing.id)
            }

            let inspection = try await inspect(request.stagedFileURL, format: validated.format)
            let bookID = UUID()
            let installedFiles = try await fileStore.install(
                stagedFile: request.stagedFileURL,
                bookID: bookID,
                fileExtension: validated.format.primaryFileExtension,
                coverData: inspection.coverData,
                coverExtension: inspection.coverExtension
            )

            do {
                let title = normalizedTitle(inspection.title, fallbackFileName: request.originalFileName)
                let draft = ImportedBookDraft(
                    id: bookID,
                    sha256: sha256,
                    title: title,
                    authors: inspection.authors.isEmpty ? [String(localized: "book.unknown_author")] : inspection.authors,
                    languageCodes: inspection.languageCodes,
                    mediaType: inspection.mediaType,
                    files: installedFiles,
                    originalFileName: request.originalFileName,
                    fileSize: validated.fileSize,
                    source: request.source
                )
                _ = try repository.insert(draft)
                AppLog.fileImport.info("Import completed bookID=\(bookID.uuidString, privacy: .public) size=\(validated.fileSize, privacy: .public)")
                return .imported(bookID: bookID)
            } catch {
                try? await fileStore.deleteInstalledFiles(bookID: bookID)
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: request.stagedFileURL)
            throw error
        }
    }

    private func inspect(_ url: URL, format: SupportedBookFormat) async throws -> PublicationInspection {
        switch format {
        case .epub:
            return try await publicationFactory.inspect(localURL: url, knownMediaType: format.mediaType)
        case .pdf:
            return try inspectPDF(url)
        case .plainText:
            return try inspectPlainText(url)
        }
    }

    private func inspectPDF(_ url: URL) throws -> PublicationInspection {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ReaderAppError.corruptedEPUB
        }

        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbnail = document.page(at: 0)?
            .thumbnail(of: CGSize(width: 420, height: 630), for: .cropBox)
            .jpegData(compressionQuality: 0.86)

        return PublicationInspection(
            title: title?.nilIfEmpty ?? String(localized: "book.untitled"),
            authors: author?.nilIfEmpty.map { [$0] } ?? [],
            languageCodes: [],
            mediaType: SupportedBookFormat.pdf.mediaType,
            isFixedLayout: false,
            isRestricted: false,
            coverData: thumbnail,
            coverExtension: thumbnail == nil ? nil : "jpg"
        )
    }

    private func inspectPlainText(_ url: URL) throws -> PublicationInspection {
        _ = try Self.readPlainText(url)
        return PublicationInspection(
            title: String(localized: "book.untitled"),
            authors: [],
            languageCodes: [],
            mediaType: SupportedBookFormat.plainText.mediaType,
            isFixedLayout: false,
            isRestricted: false,
            coverData: nil,
            coverExtension: nil
        )
    }

    private func normalizedTitle(_ value: String, fallbackFileName: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != String(localized: "book.untitled") {
            return trimmed
        }
        let fallback = URL(fileURLWithPath: fallbackFileName).deletingPathExtension().lastPathComponent
        return fallback.isEmpty ? String(localized: "book.untitled") : fallback
    }

    static func readPlainText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let encodings: [String.Encoding] = [.utf8, .unicode, .utf16LittleEndian, .utf16BigEndian, .isoLatin1]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        throw ReaderAppError.corruptedEPUB
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
