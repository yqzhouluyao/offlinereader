import SwiftData
import SwiftUI

private enum AppBoot {
    case ready(AppContainer)
    case failed(String)

    @MainActor
    static func make() -> AppBoot {
        do {
            let usesInMemoryStore = ProcessInfo.processInfo.arguments.contains("-ui-testing")
            return .ready(try AppContainer.make(inMemory: usesInMemoryStore))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

@main
struct OfflineReaderApp: App {
    private let boot: AppBoot

    init() {
        boot = AppBoot.make()
    }

    var body: some Scene {
        WindowGroup {
            switch boot {
            case .ready(let container):
                RootView(container: container)
                    .modelContainer(container.modelContainer)
                    .task { await container.bootstrap() }
            case .failed(let message):
                LaunchFailureView(message: message)
            }
        }
    }
}

private struct LaunchFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            String(localized: "app.launch_failed"),
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
        .padding()
    }
}
