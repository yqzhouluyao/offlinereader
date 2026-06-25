import Foundation

enum WiFiTransferViewState: Equatable, Sendable {
    case idle
    case requestingPermission
    case starting
    case ready(url: URL, expiresAt: Date)
    case receiving(fileName: String, progress: Double)
    case importing(fileName: String)
    case succeeded(bookID: UUID, title: String)
    case failed(message: String, recoverable: Bool)
}

struct TransferEndpoint: Equatable, Sendable {
    let url: URL
    let expiresAt: Date
}

struct WiFiTransferSnapshot: Equatable, Sendable {
    let state: WiFiTransferViewState
}

struct TransferLibraryItem: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let title: String
    let size: String
    let byteSize: Int64
    let mediaType: String
}

struct TransferDownloadItem: Sendable {
    let fileURL: URL
    let fileName: String
    let mediaType: String
}
