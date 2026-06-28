import FlyingFox
import Foundation

actor WiFiTransferService {
    private let fileStore: BookFileStore
    private let importService: BookImportServiceProtocol
    private let libraryProvider: @Sendable () async throws -> [TransferLibraryItem]
    private let downloadProvider: @Sendable (UUID) async throws -> TransferDownloadItem
    private let deleteHandler: @Sendable (UUID) async throws -> Void
    private let addressResolver: @Sendable () -> String?
    private let preferredPort: UInt16
    private let fallbackPorts: [UInt16]
    private var server: HTTPServer?
    private var serverTask: Task<Void, any Error>?
    private var token: TransferToken?
    private var endpoint: TransferEndpoint?
    private var activeUploads: [UUID: UploadSession] = [:]
    private var state: WiFiTransferViewState = .idle {
        didSet { publish() }
    }
    private var continuations: [UUID: AsyncStream<WiFiTransferSnapshot>.Continuation] = [:]

    init(
        fileStore: BookFileStore,
        importService: BookImportServiceProtocol,
        libraryProvider: @escaping @Sendable () async throws -> [TransferLibraryItem] = { [] },
        downloadProvider: @escaping @Sendable (UUID) async throws -> TransferDownloadItem = { _ in
            throw ReaderAppError.missingBookFile
        },
        deleteHandler: @escaping @Sendable (UUID) async throws -> Void = { _ in
            throw ReaderAppError.missingBookFile
        },
        addressResolver: @escaping @Sendable () -> String? = { LocalAddressResolver.wifiAddress() },
        port: UInt16 = 8080,
        fallbackPorts: [UInt16]? = nil
    ) {
        self.fileStore = fileStore
        self.importService = importService
        self.libraryProvider = libraryProvider
        self.downloadProvider = downloadProvider
        self.deleteHandler = deleteHandler
        self.addressResolver = addressResolver
        self.preferredPort = port
        self.fallbackPorts = fallbackPorts ?? Self.defaultFallbackPorts(excluding: port)
    }

    func snapshots() -> AsyncStream<WiFiTransferSnapshot> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            Task { await self?.addContinuation(id, continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func start() async throws -> TransferEndpoint {
        try await stop()
        guard let address = addressResolver() else {
            state = .failed(message: ReaderAppError.localNetworkUnavailable.localizedDescription, recoverable: true)
            throw ReaderAppError.localNetworkUnavailable
        }
        state = .starting
        let token = TransferToken.make()
        self.token = token

        var lastError: Error?
        for candidatePort in candidatePorts {
            do {
                let endpoint = try await startServer(address: address, port: candidatePort, token: token)
                AppLog.wifiImport.info("Transfer server listening on port \(candidatePort, privacy: .public)")
                return endpoint
            } catch {
                lastError = error
                AppLog.wifiImport.error("Transfer server failed on port \(candidatePort, privacy: .public): \(String(describing: error), privacy: .public)")
                await tearDownServer(timeout: 0)
            }
        }

        tokenDidFailToStart()
        if let lastError {
            AppLog.wifiImport.error("Transfer server exhausted all ports: \(String(describing: lastError), privacy: .public)")
        }
        throw ReaderAppError.transferServerFailed
    }

    func stop() async throws {
        for session in activeUploads.values {
            await session.cancelAndDelete()
        }
        activeUploads = [:]
        await tearDownServer(timeout: 1)
        endpoint = nil
        token = nil
        state = .idle
    }

    func rotateToken() async throws -> TransferEndpoint {
        try await start()
    }

    func currentSnapshot() -> WiFiTransferSnapshot {
        WiFiTransferSnapshot(state: state)
    }

    private var candidatePorts: [UInt16] {
        [preferredPort] + fallbackPorts.filter { $0 != preferredPort }
    }

    private static func defaultFallbackPorts(excluding port: UInt16) -> [UInt16] {
        (8080 ... 8099).compactMap { candidate in
            let candidatePort = UInt16(candidate)
            return candidatePort == port ? nil : candidatePort
        }
    }

    private func startServer(address: String, port: UInt16, token: TransferToken) async throws -> TransferEndpoint {
        let server = HTTPServer(port: port, logger: .disabled)
        await installRoutes(on: server)
        self.server = server

        let runTask = Task<Void, any Error> {
            try await server.run()
        }
        serverTask = runTask
        try await waitUntilServerIsListening(server)

        guard let url = URL(string: "http://\(address):\(port)") else {
            throw ReaderAppError.transferServerFailed
        }
        let endpoint = TransferEndpoint(url: url, expiresAt: token.expiresAt)
        self.endpoint = endpoint
        state = .ready(url: url, expiresAt: token.expiresAt)
        return endpoint
    }

    private func waitUntilServerIsListening(_ server: HTTPServer) async throws {
        try await server.waitUntilListening(timeout: 1.5)
        guard await server.isListening else {
            throw ReaderAppError.transferServerFailed
        }
    }

    private func tearDownServer(timeout: TimeInterval) async {
        serverTask?.cancel()
        serverTask = nil
        if let server {
            await server.stop(timeout: timeout)
        }
        server = nil
    }

    private func tokenDidFailToStart() {
        endpoint = nil
        token = nil
        state = .failed(message: ReaderAppError.transferServerFailed.localizedDescription, recoverable: true)
    }

    private func installRoutes(on server: HTTPServer) async {
        await server.appendRoute("GET /") { [self] _ in
            guard let token = await self.currentTokenValue() else {
                return Self.textResponse("Transfer server is not ready.", status: .serviceUnavailable)
            }
            return Self.htmlResponse(TransferWebPage.html(token: token))
        }

        await server.appendRoute("GET /t/:token") { [self] request in
            let requestedToken = Self.routeParameter("token", in: request) ?? ""
            guard await self.isValidToken(requestedToken) else {
                return Self.textResponse("Not found", status: .notFound)
            }
            return HTTPResponse(statusCode: .movedPermanently, headers: HTTPHeaders([.location: "/"]))
        }

        await server.appendRoute("GET /files") { [self] request in
            guard await self.isAuthorized(request) else {
                return Self.textResponse("Unauthorized", status: .notFound)
            }
            return try await self.listBooks()
        }

        await server.appendRoute("GET /files/:bookId/download") { [self] request in
            guard await self.isAuthorized(request) else {
                return Self.textResponse("Unauthorized", status: .notFound)
            }
            return try await self.downloadBook(request)
        }

        await server.appendRoute("DELETE /files/:bookId") { [self] request in
            guard await self.isAuthorized(request) else {
                return Self.textResponse("Unauthorized", status: .notFound)
            }
            return try await self.deleteBook(request)
        }

        await server.appendRoute("POST /files/:bookId") { [self] request in
            guard await self.isAuthorized(request) else {
                return Self.textResponse("Unauthorized", status: .notFound)
            }
            guard request.query["_method"]?.lowercased() == "delete" else {
                return Self.textResponse("Unsupported method.", status: .methodNotAllowed)
            }
            return try await self.deleteBook(request)
        }

        await server.appendRoute("POST /api/v1/uploads") { [self] request in
            guard await self.isAuthorized(request) else {
                return Self.textResponse("Unauthorized", status: .notFound)
            }
            return try await self.createUpload(request)
        }

        await server.appendRoute("PUT /api/v1/uploads/:uploadId/chunks/:index") { [self] request in
            guard await self.isAuthorized(request) else {
                return Self.textResponse("Unauthorized", status: .notFound)
            }
            return try await self.appendChunk(request)
        }

        await server.appendRoute("POST /api/v1/uploads/:uploadId/complete") { [self] request in
            guard await self.isAuthorized(request) else {
                return Self.textResponse("Unauthorized", status: .notFound)
            }
            return try await self.completeUpload(request)
        }

        await server.appendRoute("GET /api/v1/uploads/:uploadId") { [self] request in
            guard await self.isAuthorized(request) else {
                return Self.textResponse("Unauthorized", status: .notFound)
            }
            return try await self.uploadStatus(request)
        }
    }

    private func listBooks() async throws -> HTTPResponse {
        try Self.encodableJSONResponse(await libraryProvider())
    }

    private func downloadBook(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let bookID = Self.routeParameter("bookId", in: request).flatMap(UUID.init(uuidString:)) else {
            return Self.textResponse("Missing book.", status: .notFound)
        }

        let item = try await downloadProvider(bookID)
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            return Self.textResponse("Missing book file.", status: .notFound)
        }

        let data = try Data(contentsOf: item.fileURL)
        let contentDisposition = Self.contentDisposition(fileName: item.fileName)
        return HTTPResponse(
            statusCode: .ok,
            headers: HTTPHeaders([
                .contentType: item.mediaType,
                HTTPHeader("Content-Disposition"): contentDisposition,
                HTTPHeader("Content-Length"): "\(data.count)"
            ]),
            body: data
        )
    }

    private func deleteBook(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let bookID = Self.routeParameter("bookId", in: request).flatMap(UUID.init(uuidString:)) else {
            return Self.textResponse("Missing book.", status: .notFound)
        }

        try await deleteHandler(bookID)
        return HTTPResponse(statusCode: .noContent)
    }

    private func createUpload(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try await request.bodyData
        let payload = try JSONDecoder().decode(UploadCreateRequest.self, from: body)
        let fileName = UploadSession.sanitizedFileName(payload.fileName)
        let format: SupportedBookFormat
        do {
            format = try BookFileValidator().validate(fileName: fileName, fileSize: payload.fileSize)
        } catch let error as ReaderAppError {
            switch error {
            case .unsupportedFileType:
                return Self.textResponse("Unsupported file type.", status: .badRequest)
            case .fileTooSmall:
                return Self.textResponse("File too small.", status: .badRequest)
            case .fileTooLarge:
                return Self.textResponse("File too large.", status: .payloadTooLarge)
            default:
                return Self.textResponse("Invalid file.", status: .badRequest)
            }
        } catch {
            return Self.textResponse("Invalid file.", status: .badRequest)
        }

        let uploadID = UUID()
        let tempURL = try await fileStore.makeUploadURL(
            uploadID: uploadID,
            fileExtension: format.primaryFileExtension
        )
        let session = try UploadSession(
            uploadID: uploadID,
            fileName: fileName,
            fileSize: payload.fileSize,
            tempURL: tempURL
        )
        activeUploads[uploadID] = session
        state = .receiving(fileName: fileName, progress: 0)
        return Self.jsonResponse([
            "uploadId": uploadID.uuidString,
            "chunkSize": UploadSession.chunkSize,
            "nextChunkIndex": 0,
            "format": format.rawValue
        ])
    }

    private func appendChunk(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let uploadID = Self.routeParameter("uploadId", in: request).flatMap(UUID.init(uuidString:)),
              let session = activeUploads[uploadID],
              let index = Self.routeParameter("index", in: request).flatMap(Int.init)
        else {
            return Self.textResponse("Missing upload.", status: .notFound)
        }
        let body = try await request.bodyData
        do {
            try await session.appendChunk(index: index, rangeHeader: request.headers[.contentRange], body: body)
        } catch {
            return Self.textResponse("Invalid chunk.", status: .conflict)
        }
        let updated = await session.snapshot()
        state = .receiving(
            fileName: updated.fileName,
            progress: Double(updated.receivedBytes) / Double(max(updated.fileSize, 1))
        )
        return HTTPResponse(statusCode: .noContent)
    }

    private func completeUpload(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let uploadID = Self.routeParameter("uploadId", in: request).flatMap(UUID.init(uuidString:)),
              let session = activeUploads[uploadID]
        else {
            return Self.textResponse("Missing upload.", status: .notFound)
        }
        let snapshot = await session.snapshot()
        let stagedURL: URL
        do {
            stagedURL = try await session.complete()
        } catch {
            return Self.textResponse("Upload incomplete.", status: .conflict)
        }
        state = .importing(fileName: snapshot.fileName)
        let request = ImportRequest(
            stagedFileURL: stagedURL,
            originalFileName: snapshot.fileName,
            source: .wifiTransfer
        )
        do {
            let result = try await importService.importBook(request)
            let bookID: UUID
            switch result {
            case .imported(let id), .duplicate(let id):
                bookID = id
            }
            let title = URL(fileURLWithPath: snapshot.fileName).deletingPathExtension().lastPathComponent
            await session.markSucceeded(bookID: bookID, title: title)
            activeUploads[uploadID] = nil
            state = .succeeded(bookID: bookID, title: title)
            return Self.jsonResponse(["bookID": bookID.uuidString, "title": title])
        } catch {
            await session.markFailed(error.localizedDescription)
            activeUploads[uploadID] = nil
            state = .failed(message: error.localizedDescription, recoverable: true)
            return Self.textResponse(error.localizedDescription, status: .badRequest)
        }
    }

    private func uploadStatus(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let uploadID = Self.routeParameter("uploadId", in: request).flatMap(UUID.init(uuidString:)),
              let session = activeUploads[uploadID]
        else {
            return Self.textResponse("Missing upload.", status: .notFound)
        }
        let snapshot = await session.snapshot()
        return Self.jsonResponse([
            "uploadId": snapshot.uploadID.uuidString,
            "receivedBytes": snapshot.receivedBytes,
            "nextChunkIndex": snapshot.nextChunkIndex
        ])
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        if let header = request.headers[HTTPHeader("X-Transfer-Token")],
           isValidToken(header) {
            return true
        }
        if let queryToken = request.query["token"],
           isValidToken(queryToken) {
            return true
        }
        return false
    }

    private func currentTokenValue() -> String? {
        guard let token, token.expiresAt > Date() else {
            return nil
        }
        return token.value
    }

    private func isValidToken(_ candidate: String) -> Bool {
        guard let token else {
            return false
        }
        return token.isValid(candidate)
    }

    private func publish() {
        let snapshot = WiFiTransferSnapshot(state: state)
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func addContinuation(_ id: UUID, _ continuation: AsyncStream<WiFiTransferSnapshot>.Continuation) {
        continuations[id] = continuation
        continuation.yield(WiFiTransferSnapshot(state: state))
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func jsonResponse(_ value: [String: Any], status: HTTPStatusCode = .ok) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        return HTTPResponse(statusCode: status, headers: HTTPHeaders([.contentType: "application/json"]), body: data)
    }

    private static func encodableJSONResponse<T: Encodable>(_ value: T, status: HTTPStatusCode = .ok) throws -> HTTPResponse {
        let data = try JSONEncoder().encode(value)
        return HTTPResponse(statusCode: status, headers: HTTPHeaders([.contentType: "application/json"]), body: data)
    }

    private static func textResponse(_ text: String, status: HTTPStatusCode) -> HTTPResponse {
        HTTPResponse(
            statusCode: status,
            headers: HTTPHeaders([.contentType: "text/plain; charset=utf-8"]),
            body: Data(text.utf8)
        )
    }

    private static func htmlResponse(_ html: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: HTTPHeaders([.contentType: "text/html; charset=utf-8"]),
            body: Data(html.utf8)
        )
    }

    private static func routeParameter(_ name: String, in request: HTTPRequest) -> String? {
        request.routeParameters[name, of: String.self]
    }

    private static func contentDisposition(fileName: String) -> String {
        let fallback = fileName.unicodeScalars
            .map { scalar in scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x22 && scalar.value != 0x5C ? Character(scalar) : "_" }
            .reduce(into: "") { $0.append($1) }
        let asciiName = fallback.isEmpty ? "book" : fallback
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? asciiName
        return #"attachment; filename="\#(asciiName)"; filename*=UTF-8''\#(encodedName)"#
    }
}
