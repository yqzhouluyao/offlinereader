import Foundation

actor BookFileStore {
    private let fileManager: FileManager
    private let applicationSupportURL: URL
    private let temporaryBaseURL: URL

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let booksDirectory = support.appending(path: "Library/Books", directoryHint: .isDirectory)
        let temporaryDirectory = fileManager.temporaryDirectory.appending(path: "OfflineReader", directoryHint: .isDirectory)
        applicationSupportURL = booksDirectory
        temporaryBaseURL = temporaryDirectory
        try Self.createDirectoryIfNeeded(booksDirectory, fileManager: fileManager)
        try Self.createDirectoryIfNeeded(temporaryDirectory, fileManager: fileManager)
        try Self.createDirectoryIfNeeded(temporaryDirectory.appending(path: "Incoming", directoryHint: .isDirectory), fileManager: fileManager)
        try Self.createDirectoryIfNeeded(temporaryDirectory.appending(path: "Uploads", directoryHint: .isDirectory), fileManager: fileManager)
        try Self.createDirectoryIfNeeded(temporaryDirectory.appending(path: "Trash", directoryHint: .isDirectory), fileManager: fileManager)
    }

    private var incomingDirectory: URL {
        temporaryBaseURL.appending(path: "Incoming", directoryHint: .isDirectory)
    }

    private var uploadsDirectory: URL {
        temporaryBaseURL.appending(path: "Uploads", directoryHint: .isDirectory)
    }

    private var trashDirectory: URL {
        temporaryBaseURL.appending(path: "Trash", directoryHint: .isDirectory)
    }

    func makeIncomingURL(fileExtension: String) throws -> URL {
        try createDirectoryIfNeeded(incomingDirectory)
        let ext = sanitizedExtension(fileExtension)
        return incomingDirectory.appending(path: UUID().uuidString).appendingPathExtension(ext)
    }

    func makeUploadURL(uploadID: UUID, fileExtension: String) throws -> URL {
        try createDirectoryIfNeeded(uploadsDirectory)
        return uploadsDirectory.appending(path: uploadID.uuidString).appendingPathExtension(sanitizedExtension(fileExtension))
    }

    func makeUploadURL(uploadID: UUID) throws -> URL {
        try makeUploadURL(uploadID: uploadID, fileExtension: "epub")
    }

    func install(
        stagedFile: URL,
        bookID: UUID,
        fileExtension: String,
        coverData: Data?,
        coverExtension: String?
    ) throws -> InstalledBookFiles {
        let bookDirectory = applicationSupportURL.appending(path: bookID.uuidString, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: bookDirectory.path) {
            try fileManager.removeItem(at: bookDirectory)
        }
        try createDirectoryIfNeeded(bookDirectory)

        let publicationURL = bookDirectory
            .appending(path: "publication")
            .appendingPathExtension(sanitizedExtension(fileExtension))
        try fileManager.moveItem(at: stagedFile, to: publicationURL)

        var coverRelativePath: String?
        if let coverData {
            let ext = sanitizedExtension(coverExtension ?? "jpg")
            let coverURL = bookDirectory.appending(path: "cover").appendingPathExtension(ext)
            try coverData.write(to: coverURL, options: [.atomic])
            coverRelativePath = try relativePath(for: coverURL)
        }

        return InstalledBookFiles(
            publicationRelativePath: try relativePath(for: publicationURL),
            coverRelativePath: coverRelativePath
        )
    }

    func install(stagedEPUB: URL, bookID: UUID, coverData: Data?, coverExtension: String?) throws -> InstalledBookFiles {
        try install(
            stagedFile: stagedEPUB,
            bookID: bookID,
            fileExtension: "epub",
            coverData: coverData,
            coverExtension: coverExtension
        )
    }

    func deleteInstalledFiles(bookID: UUID) throws {
        let url = applicationSupportURL.appending(path: bookID.uuidString, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let trashURL = trashDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try createDirectoryIfNeeded(trashDirectory)
        try fileManager.moveItem(at: url, to: trashURL)
        try fileManager.removeItem(at: trashURL)
    }

    func cleanExpiredTemporaryFiles(olderThan date: Date) throws {
        for directory in [incomingDirectory, uploadsDirectory, trashDirectory] {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            for url in urls {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                if (values.contentModificationDate ?? .distantPast) < date {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    func resolve(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw ReaderAppError.missingBookFile
        }
        let url = applicationSupportURL.appending(path: relativePath)
        let standardizedBase = applicationSupportURL.standardizedFileURL.path
        let standardizedTarget = url.standardizedFileURL.path
        guard standardizedTarget.hasPrefix(standardizedBase) else {
            throw ReaderAppError.missingBookFile
        }
        return url
    }

    private func relativePath(for url: URL) throws -> String {
        let base = applicationSupportURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(base) else {
            throw ReaderAppError.missingBookFile
        }
        let index = target.index(target.startIndex, offsetBy: base.count)
        return String(target[index...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func sanitizedExtension(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t\r"))
        let allowed = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(allowed)).lowercased().isEmpty ? "epub" : String(String.UnicodeScalarView(allowed)).lowercased()
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        try Self.createDirectoryIfNeeded(url, fileManager: fileManager)
    }

    private static func createDirectoryIfNeeded(_ url: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
