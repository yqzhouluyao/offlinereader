import Foundation
@preconcurrency import ReadiumShared

struct PublicationInspection: Sendable, Equatable {
    let title: String
    let authors: [String]
    let languageCodes: [String]
    let mediaType: String
    let isFixedLayout: Bool
    let isRestricted: Bool
    let coverData: Data?
    let coverExtension: String?
}

@MainActor
final class PublicationHandle {
    let bookID: UUID
    let publication: Publication
    let title: String
    let authors: [String]

    init(bookID: UUID, publication: Publication, title: String, authors: [String]) {
        self.bookID = bookID
        self.publication = publication
        self.title = title
        self.authors = authors
    }
}

@MainActor
struct OpenedPublication {
    let publication: Publication
    let mediaType: String
}

@MainActor
protocol PublicationFactoryProtocol: AnyObject {
    func inspect(localURL: URL, knownMediaType: String?) async throws -> PublicationInspection
    func open(localURL: URL, knownMediaType: String?) async throws -> OpenedPublication
}
