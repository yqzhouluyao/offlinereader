import Foundation
import Observation

@MainActor
@Observable
final class WiFiTransferViewModel {
    private let container: AppContainer
    private var snapshotTask: Task<Void, Never>?
    var state: WiFiTransferViewState = .idle

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        snapshotTask?.cancel()
        snapshotTask = Task {
            let stream = await container.wifiTransferService.snapshots()
            for await snapshot in stream {
                state = snapshot.state
            }
        }
        Task {
            do {
                state = .starting
                _ = try await container.wifiTransferService.start()
            } catch {
                state = .failed(message: error.localizedDescription, recoverable: true)
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        Task {
            try? await container.wifiTransferService.stop()
        }
    }

    func restart() {
        start()
    }
}
