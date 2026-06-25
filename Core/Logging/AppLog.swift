import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "OfflineReader"

    static let lifecycle = Logger(subsystem: subsystem, category: "app.lifecycle")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let fileImport = Logger(subsystem: subsystem, category: "import.file")
    static let wifiImport = Logger(subsystem: subsystem, category: "import.wifi")
    static let publication = Logger(subsystem: subsystem, category: "publication")
    static let reader = Logger(subsystem: subsystem, category: "reader")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
