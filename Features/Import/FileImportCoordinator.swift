import Foundation

actor FileImportCoordinator {
    let fileStore: BookFileStore
    let fileManager: FileManager

    init(fileStore: BookFileStore, fileManager: FileManager = .default) {
        self.fileStore = fileStore
        self.fileManager = fileManager
    }

    func stageSecurityScopedFile(from externalURL: URL) async throws -> ImportRequest {
        guard let format = SupportedBookFormat(fileExtension: externalURL.pathExtension) else {
            throw ReaderAppError.unsupportedFileType
        }

        let accessGranted = externalURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                externalURL.stopAccessingSecurityScopedResource()
            }
        }

        let stagedURL = try await fileStore.makeIncomingURL(fileExtension: format.primaryFileExtension)
        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }
        try fileManager.copyItem(at: externalURL, to: stagedURL)
        return ImportRequest(
            stagedFileURL: stagedURL,
            originalFileName: externalURL.lastPathComponent,
            source: .fileImporter
        )
    }
}
