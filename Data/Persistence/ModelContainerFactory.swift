import Foundation
import SwiftData

enum ModelContainerFactory {
    @MainActor
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([BookRecord.self])
        if !inMemory {
            try ensureApplicationSupportDirectoryExists()
        }
        let configuration = ModelConfiguration(
            "OfflineReader",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func ensureApplicationSupportDirectoryExists() throws {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
