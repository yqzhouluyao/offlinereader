import SwiftUI

enum AppRoute: Hashable {
    case reader(bookID: UUID)
}

@MainActor
@Observable
final class AppRouter {
    var path: [AppRoute] = []

    func openReader(bookID: UUID) {
        path.append(.reader(bookID: bookID))
    }

    func popToLibrary() {
        path = []
    }
}

struct RootView: View {
    let container: AppContainer
    @State private var router = AppRouter()

    var body: some View {
        NavigationStack(path: $router.path) {
            LibraryView(container: container, router: router)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .reader(let bookID):
                        ReaderView(container: container, router: router, bookID: bookID)
                    }
                }
        }
        .environment(container)
        .environment(router)
    }
}
