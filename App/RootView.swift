import SwiftUI
import UIKit

enum AppRoute: Hashable {
    case reader(bookID: UUID)
}

@MainActor
@Observable
final class AppRouter {
    var path: [AppRoute] = []

    func openReader(bookID: UUID) {
        if path.last == .reader(bookID: bookID) {
            return
        }
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
        ZStack(alignment: .bottom) {
            NavigationStack(path: $router.path) {
                LibraryView(container: container, router: router)
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .reader(let bookID):
                            ReaderView(container: container, router: router, bookID: bookID)
                        }
                    }
            }

            if router.path.isEmpty, let session = container.listeningStore.session {
                ListeningMiniPlayer(
                    session: session,
                    fileStore: container.fileStore,
                    onOpenBook: { router.openReader(bookID: session.bookID) },
                    onTogglePlayback: { container.listeningStore.togglePlayback() },
                    onClose: { container.listeningStore.stop() }
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: container.listeningStore.session?.id)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: router.path.isEmpty)
        .environment(container)
        .environment(router)
    }
}

private struct ListeningMiniPlayer: View {
    let session: ListeningSessionSnapshot
    let fileStore: BookFileStore
    let onOpenBook: () -> Void
    let onTogglePlayback: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ListeningCoverThumbnail(
                title: session.bookTitle,
                coverRelativePath: session.coverRelativePath,
                fileStore: fileStore
            )
            .frame(width: 54, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(session.chapterTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("\(session.remainingTimeText) \(session.bookTitle)")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onTogglePlayback) {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.white.opacity(0.10), in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.58), lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("listening.miniPlayer.playPause")
            .accessibilityLabel(session.isPlaying ? "暂停听书" : "继续听书")

            Button(action: onOpenBook) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(width: 36, height: 50)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("listening.miniPlayer.playlist")
            .accessibilityLabel("听书列表")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.32), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("listening.miniPlayer.close")
            .accessibilityLabel("关闭听书浮窗")
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(height: 84)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.13).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listening.miniPlayer")
    }
}

private struct ListeningCoverThumbnail: View {
    let title: String
    let coverRelativePath: String?
    let fileStore: BookFileStore
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ListeningCoverPlaceholder(title: title)
            }
        }
        .clipped()
        .task(id: coverRelativePath ?? "") {
            await loadCover()
        }
    }

    private func loadCover() async {
        guard let coverRelativePath,
              let url = try? await fileStore.resolve(relativePath: coverRelativePath),
              let loaded = UIImage(contentsOfFile: url.path)
        else {
            image = nil
            return
        }
        image = loaded
    }
}

private struct ListeningCoverPlaceholder: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.74, blue: 0.45),
                    Color(red: 0.92, green: 0.25, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Text(title.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "书")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
