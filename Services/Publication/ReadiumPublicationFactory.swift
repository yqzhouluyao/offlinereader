import Foundation
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import UIKit

@MainActor
final class ReadiumPublicationFactory: PublicationFactoryProtocol {
    private let httpClient: HTTPClient
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    init() {
        httpClient = DefaultHTTPClient()
        assetRetriever = AssetRetriever(httpClient: httpClient)
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            ),
            contentProtections: []
        )
    }

    func inspect(localURL: URL, knownMediaType: String?) async throws -> PublicationInspection {
        let opened = try await open(localURL: localURL, knownMediaType: knownMediaType)
        let publication = opened.publication
        defer { publication.close() }

        guard publication.conforms(to: .epub) else {
            throw ReaderAppError.unsupportedFileType
        }
        guard !publication.isRestricted else {
            throw ReaderAppError.drmNotSupported
        }
        guard publication.metadata.layout != .fixed else {
            throw ReaderAppError.fixedLayoutNotSupported
        }

        let cover = await loadCoverData(from: publication)
        return PublicationInspection(
            title: publication.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(localized: "book.untitled"),
            authors: publication.metadata.authors.map(\.name),
            languageCodes: publication.metadata.languages,
            mediaType: opened.mediaType,
            isFixedLayout: publication.metadata.layout == .fixed,
            isRestricted: publication.isRestricted,
            coverData: cover.data,
            coverExtension: cover.fileExtension
        )
    }

    func open(localURL: URL, knownMediaType: String?) async throws -> OpenedPublication {
        guard let fileURL = FileURL(url: localURL) else {
            throw ReaderAppError.missingBookFile
        }

        let assetResult: Result<Asset, AssetRetrieveURLError>
        if let knownMediaType, let mediaType = MediaType(knownMediaType) {
            assetResult = await assetRetriever.retrieve(url: fileURL, mediaType: mediaType)
        } else {
            assetResult = await assetRetriever.retrieve(url: fileURL)
        }

        let asset: Asset
        switch assetResult {
        case .success(let value):
            asset = value
        case .failure:
            throw ReaderAppError.corruptedEPUB
        }

        let mediaType = asset.format.mediaType?.string ?? MediaType.epub.string
        let publicationResult = await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false,
            sender: nil
        )

        switch publicationResult {
        case .success(let publication):
            return OpenedPublication(publication: publication, mediaType: mediaType)
        case .failure(.formatNotSupported):
            throw ReaderAppError.unsupportedFileType
        case .failure(.reading):
            throw ReaderAppError.corruptedEPUB
        }
    }

    private func loadCoverData(from publication: Publication) async -> (data: Data?, fileExtension: String?) {
        switch await publication.coverFitting(maxSize: CGSize(width: 420, height: 630)) {
        case .success(let image):
            guard let image else {
                return (nil, nil)
            }
            if let data = image.jpegData(compressionQuality: 0.86) {
                return (data, "jpg")
            }
            return (image.pngData(), "png")
        case .failure:
            return (nil, nil)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
