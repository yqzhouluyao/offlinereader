import SwiftUI
import UIKit

struct ReaderView: View {
    let container: AppContainer
    let router: AppRouter
    let bookID: UUID

    @State private var viewModel: ReaderViewModel
    @State private var toastMessage: String?
    @State private var activePanel: ReaderPanelMode = .summary
    @State private var brightness = Double(UIScreen.main.brightness)
    @State private var followsSystemTheme = false
    @State private var firstLineIndent = false
    @State private var isSearchPresented = false
    @State private var searchQuery = ""

    init(container: AppContainer, router: AppRouter, bookID: UUID) {
        self.container = container
        self.router = router
        self.bookID = bookID
        _viewModel = State(initialValue: ReaderViewModel(container: container, bookID: bookID))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            readerContent
            readerListeningControls
            readerListenButton
            modalDimmingLayer
            readerToast
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            topChrome
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .task { await loadBook() }
        .onChange(of: viewModel.isChromeVisible) { _, isVisible in
            if !isVisible {
                activePanel = .summary
            }
        }
        .onDisappear {
            Task { await viewModel.close() }
        }
        .sheet(isPresented: $isSearchPresented, onDismiss: {
            searchQuery = ""
            viewModel.clearSearch()
        }) {
            ReaderSearchSheet(
                query: $searchQuery,
                results: viewModel.searchResults,
                isSearching: viewModel.isSearching,
                bookTitle: viewModel.book?.title ?? "",
                onSearch: { query in
                    await viewModel.search(query: query)
                },
                onSelectResult: { result in
                    await viewModel.goToSearchResult(result)
                }
            )
                .presentationDetents([.height(260), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(.systemBackground))
                .preferredColorScheme(.light)
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("正在打开…")
        case .failed(let message):
            ContentUnavailableView {
                Label("reader.open_failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .loaded:
            if let session = viewModel.session {
                ReaderViewControllerRepresentable(viewController: session.navigatorViewController)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var readerListenButton: some View {
        if case .loaded = viewModel.state,
           activePanel == .summary,
           viewModel.isListeningAvailable,
           !viewModel.shouldShowReaderListeningControls {
            Button {
                Task {
                    await viewModel.startListening()
                    showToast("已开始听书")
                }
            } label: {
                Image(systemName: "headphones")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(ReaderPalette.accent, in: Circle())
                    .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.bottom, shouldShowChrome ? 102 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            .accessibilityIdentifier("reader.listen")
            .accessibilityLabel("听书")
        }
    }

    @ViewBuilder
    private var readerListeningControls: some View {
        if case .loaded = viewModel.state,
           activePanel == .summary,
           viewModel.shouldShowReaderListeningControls,
           let book = viewModel.book {
            ReaderInlineListeningControls(
                book: book,
                fileStore: container.fileStore,
                isPlaying: viewModel.isReaderListeningPlaying,
                onTogglePlayback: { viewModel.pauseOrResumeListening() },
                onFocusCurrentSentence: {
                    Task { await viewModel.focusListeningPosition() }
                },
                onClose: { viewModel.stopListening() }
            )
            .padding(.horizontal, 24)
            .padding(.bottom, shouldShowChrome ? 30 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("reader.inlineListening")
        }
    }

    @ViewBuilder
    private var topChrome: some View {
        if shouldShowChrome {
            ReaderTopBar(
                progressText: viewModel.readProgressText,
                shareText: viewModel.shareText,
                isBookmarkSelected: viewModel.isCurrentBookmarkSelected,
                onBack: { router.popToLibrary() },
                onTOC: { setActivePanel(.toc) },
                onAddBookmark: {
                    let wasSelected = viewModel.isCurrentBookmarkSelected
                    viewModel.toggleBookmark()
                    showToast(wasSelected ? "已取消书签" : "已添加书签")
                },
                onSearch: { isSearchPresented = true }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        if shouldShowChrome {
            ReaderBottomChrome(
                mode: activePanel,
                sectionTitle: viewModel.currentSectionTitle,
                pageText: viewModel.pageText,
                percentText: viewModel.progressPercentText,
                book: viewModel.book,
                tocItems: viewModel.tocItems,
                bookmarks: viewModel.bookmarks,
                preferences: viewModel.preferences,
                brightness: $brightness,
                followsSystemTheme: $followsSystemTheme,
                firstLineIndent: $firstLineIndent,
                onSelectPanel: setActivePanel(_:),
                onSelectTOCItem: { item in
                    Task {
                        await viewModel.goToTOCItem(item)
                        await MainActor.run {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                activePanel = .summary
                            }
                        }
                    }
                },
                onSelectBookmark: { bookmark in
                    Task {
                        await viewModel.goToBookmark(bookmark)
                        await MainActor.run {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                activePanel = .summary
                            }
                        }
                    }
                },
                onDeleteBookmark: { bookmark in
                    viewModel.deleteBookmark(bookmark)
                },
                onPreferencesChange: { snapshot in
                    Task { await viewModel.updatePreferences(snapshot) }
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var modalDimmingLayer: some View {
        if shouldShowChrome && activePanel != .summary {
            Color.black.opacity(activePanel.usesDimmingLayer ? 0.32 : 0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { setActivePanel(.summary) }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var readerToast: some View {
        if let toastMessage {
            Text(toastMessage)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 42)
                .padding(.vertical, 24)
                .frame(maxWidth: 280)
                .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(false)
        }
    }

    private var shouldShowChrome: Bool {
        guard case .loaded = viewModel.state else {
            return false
        }
        return viewModel.isChromeVisible
    }

    private func setActivePanel(_ panel: ReaderPanelMode) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            activePanel = activePanel == panel ? .summary : panel
        }
    }

    private func loadBook() async {
        await viewModel.load()
        if case .loaded = viewModel.state {
            showToast("本书已缓存，可以离线阅读", duration: 2)
        }
    }

    private func showToast(_ message: String, duration: TimeInterval = 1.35) {
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard toastMessage == message else {
                return
            }
            withAnimation(.easeIn(duration: 0.2)) {
                toastMessage = nil
            }
        }
    }
}

private enum ReaderPanelMode: Equatable {
    case summary
    case toc
    case notes
    case theme
    case settings

    var usesDimmingLayer: Bool {
        self == .toc || self == .notes
    }

    var accessibilityIdentifier: String {
        switch self {
        case .summary: "summary"
        case .toc: "toc"
        case .notes: "notes"
        case .theme: "theme"
        case .settings: "settings"
        }
    }
}

private enum ReaderPalette {
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.16)
    static let secondaryText = Color(red: 0.38, green: 0.42, blue: 0.50)
    static let paleControl = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let divider = Color.black.opacity(0.08)
}

private struct ReaderInlineListeningControls: View {
    let book: BookRecord
    let fileStore: BookFileStore
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    let onFocusCurrentSentence: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                ReaderListeningCoverThumbnail(
                    title: book.title,
                    coverRelativePath: book.coverRelativePath,
                    fileStore: fileStore
                )
                .frame(width: 46, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .shadow(color: .black.opacity(0.22), radius: 5, y: 2)

                Button(action: onTogglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 58, height: 58)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reader.inlineListening.playPause")
                .accessibilityLabel(isPlaying ? "暂停听书" : "继续听书")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(width: 54, height: 58)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reader.inlineListening.close")
                .accessibilityLabel("关闭听书")
            }
            .padding(.leading, 0)
            .padding(.trailing, 8)
            .frame(height: 58)
            .background(Color(red: 0.48, green: 0.51, blue: 0.57).opacity(0.88), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            Spacer(minLength: 18)

            Button(action: onFocusCurrentSentence) {
                Text("听")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(Color(red: 0.43, green: 0.46, blue: 0.52).opacity(0.94), in: Circle())
                    .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.inlineListening.listen")
            .accessibilityLabel("定位到正在朗读的句子")
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(true)
    }
}

private struct ReaderListeningCoverThumbnail: View {
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
                ReaderListeningCoverPlaceholder(title: title)
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

private struct ReaderListeningCoverPlaceholder: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.70, blue: 0.48),
                    Color(red: 0.86, green: 0.19, blue: 0.13)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Text(title.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "书")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct ReaderTopBar: View {
    let progressText: String
    let shareText: String
    let isBookmarkSelected: Bool
    let onBack: () -> Void
    let onTOC: () -> Void
    let onAddBookmark: () -> Void
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .regular))
                    .frame(width: 32, height: 38)
            }
            .buttonStyle(.plain)

            Button(action: onTOC) {
                HStack(spacing: 6) {
                    Text(progressText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ReaderPalette.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(.systemGray3))
                }
                .padding(.horizontal, 10)
                .frame(width: 164, height: 30)
                .background(ReaderPalette.paleControl, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.top.progress")
            .accessibilityLabel(Text("reader.toc"))

            Spacer(minLength: 10)

            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 23, weight: .regular))
                    .frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.top.share")

            Button(action: onAddBookmark) {
                Image(systemName: isBookmarkSelected ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(isBookmarkSelected ? ReaderPalette.accent : Color(.label))
                    .frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.top.addBookmark")
            .accessibilityLabel(Text(isBookmarkSelected ? "取消书签" : "添加书签"))

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 25, weight: .regular))
                    .frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.top.search")
            .accessibilityLabel(Text("搜索"))
        }
        .foregroundStyle(Color(.label))
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.97))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ReaderPalette.divider)
                .frame(height: 1)
        }
        .accessibilityIdentifier("reader.topBar")
    }
}

private struct ReaderSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var query: String
    let results: [ReaderSearchResultItem]
    let isSearching: Bool
    let bookTitle: String
    let onSearch: (String) async -> Void
    let onSelectResult: (ReaderSearchResultItem) async -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ReaderPalette.secondaryText)

                TextField("搜索本书", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(.label))
                    .tint(ReaderPalette.accent)
                    .submitLabel(.search)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color(.systemGray3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(ReaderPalette.paleControl, in: Capsule())

            searchContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button("完成") {
                dismiss()
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(ReaderPalette.accent)
            .frame(height: 42)
        }
        .foregroundStyle(Color(.label))
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .background(Color(.systemBackground))
        .task(id: query) {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedQuery.isEmpty {
                await onSearch("")
                return
            }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else {
                return
            }
            await onSearch(trimmedQuery)
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            VStack(spacing: 8) {
                Text("搜索本书")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.29, blue: 0.36))
                Text(bookTitle)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(ReaderPalette.secondaryText)
                    .lineLimit(1)
            }
        } else if isSearching {
            ProgressView()
                .tint(ReaderPalette.accent)
        } else if results.isEmpty {
            Text("暂无搜索结果")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(red: 0.25, green: 0.29, blue: 0.36))
        } else {
            List {
                ForEach(results) { result in
                    Button {
                        Task {
                            await onSelectResult(result)
                            dismiss()
                        }
                    } label: {
                        ReaderSearchResultRow(result: result)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color(.systemBackground))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct ReaderSearchResultRow: View {
    let result: ReaderSearchResultItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.label))
                .lineLimit(1)

            Text(result.snippet)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(ReaderPalette.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

private struct ReaderBottomChrome: View {
    let mode: ReaderPanelMode
    let sectionTitle: String
    let pageText: String
    let percentText: String
    let book: BookRecord?
    let tocItems: [TableOfContentsItem]
    let bookmarks: [ReaderBookmark]
    let preferences: ReaderPreferencesSnapshot
    @Binding var brightness: Double
    @Binding var followsSystemTheme: Bool
    @Binding var firstLineIndent: Bool
    let onSelectPanel: (ReaderPanelMode) -> Void
    let onSelectTOCItem: (TableOfContentsItem) -> Void
    let onSelectBookmark: (ReaderBookmark) -> Void
    let onDeleteBookmark: (ReaderBookmark) -> Void
    let onPreferencesChange: (ReaderPreferencesSnapshot) -> Void

    var body: some View {
        Group {
            switch mode {
            case .summary:
                ReaderSummaryPanel(
                    sectionTitle: sectionTitle,
                    pageText: pageText,
                    percentText: percentText,
                    activePanel: mode,
                    onSelectPanel: onSelectPanel
                )
            case .theme:
                ReaderThemePanel(
                    preferences: preferences,
                    brightness: $brightness,
                    followsSystemTheme: $followsSystemTheme,
                    activePanel: mode,
                    onPreferencesChange: onPreferencesChange,
                    onSelectPanel: onSelectPanel
                )
            case .settings:
                ReaderSettingsPanel(
                    preferences: preferences,
                    firstLineIndent: $firstLineIndent,
                    activePanel: mode,
                    onPreferencesChange: onPreferencesChange,
                    onSelectPanel: onSelectPanel
                )
            case .toc:
                ReaderContentsPanel(
                    book: book,
                    tocItems: tocItems,
                    bookmarks: bookmarks,
                    activePanel: mode,
                    onSelectTOCItem: onSelectTOCItem,
                    onSelectBookmark: onSelectBookmark,
                    onDeleteBookmark: onDeleteBookmark,
                    onSelectPanel: onSelectPanel
                )
            case .notes:
                ReaderNotesPanel(
                    book: book,
                    activePanel: mode,
                    onSelectPanel: onSelectPanel
                )
            }
        }
        .accessibilityIdentifier("reader.bottomPanel.\(mode.accessibilityIdentifier)")
    }
}

private struct ReaderSummaryPanel: View {
    let sectionTitle: String
    let pageText: String
    let percentText: String
    let activePanel: ReaderPanelMode
    let onSelectPanel: (ReaderPanelMode) -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Text(sectionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.22, green: 0.27, blue: 0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 12)

                Button { onSelectPanel(.toc) } label: {
                    HStack(spacing: 7) {
                        Text(pageText)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color(red: 0.32, green: 0.36, blue: 0.44))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(ReaderPalette.paleControl, in: Capsule())
                }
                .buttonStyle(.plain)

                Text(percentText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color(red: 0.22, green: 0.27, blue: 0.35))
                    .frame(minWidth: 36, alignment: .trailing)
            }

            ReaderPanelNavBar(activePanel: activePanel, onSelectPanel: onSelectPanel)
        }
        .padding(.horizontal, 26)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .safeAreaPadding(.bottom, 14)
        .readerPanelSurface(cornerRadius: 0)
    }
}

private struct ReaderThemePanel: View {
    let preferences: ReaderPreferencesSnapshot
    @Binding var brightness: Double
    @Binding var followsSystemTheme: Bool
    let activePanel: ReaderPanelMode
    let onPreferencesChange: (ReaderPreferencesSnapshot) -> Void
    let onSelectPanel: (ReaderPanelMode) -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                ReaderBrightnessControl(brightness: $brightness)
                    .layoutPriority(1)

                Toggle(
                    isOn: Binding(
                        get: { followsSystemTheme },
                        set: { isOn in
                            followsSystemTheme = isOn
                            if isOn {
                                updateTheme(UITraitCollection.current.userInterfaceStyle == .dark ? .night : .day)
                            }
                        }
                    )
                ) {
                    Text("跟随系统")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(red: 0.25, green: 0.29, blue: 0.36))
                }
                .toggleStyle(ReaderCapsuleToggleStyle())
                .frame(width: 128)
            }

            HStack(spacing: 14) {
                ReaderThemeButton(
                    title: "白色",
                    fill: .white,
                    foreground: Color(red: 0.16, green: 0.18, blue: 0.22),
                    border: Color(red: 0.55, green: 0.24, blue: 0.02),
                    isSelected: preferences.theme == .day
                ) {
                    updateTheme(.day)
                }

                ReaderThemeButton(
                    title: "黄色",
                    fill: Color(red: 0.89, green: 0.86, blue: 0.78),
                    foreground: Color(red: 0.62, green: 0.39, blue: 0.04),
                    border: .clear,
                    isSelected: preferences.theme == .sepia
                ) {
                    updateTheme(.sepia)
                }

                ReaderThemeButton(
                    title: "护眼",
                    fill: Color(red: 0.70, green: 0.82, blue: 0.70),
                    foreground: Color(red: 0.03, green: 0.49, blue: 0.12),
                    border: .clear,
                    isSelected: preferences.theme == .eyeCare
                ) {
                    updateTheme(.eyeCare)
                }

                ReaderThemeButton(
                    title: "夜间",
                    fill: Color(red: 0.09, green: 0.10, blue: 0.12),
                    foreground: Color(.systemGray2),
                    border: .clear,
                    isSelected: preferences.theme == .night
                ) {
                    updateTheme(.night)
                }
            }

            ReaderPanelNavBar(activePanel: activePanel, onSelectPanel: onSelectPanel)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .safeAreaPadding(.bottom, 14)
        .readerPanelSurface(cornerRadius: 0)
    }

    private func updateTheme(_ theme: ReaderPreferencesSnapshot.Theme) {
        var updated = preferences
        updated.theme = theme
        onPreferencesChange(updated)
    }
}

private struct ReaderSettingsPanel: View {
    let preferences: ReaderPreferencesSnapshot
    @Binding var firstLineIndent: Bool
    let activePanel: ReaderPanelMode
    let onPreferencesChange: (ReaderPreferencesSnapshot) -> Void
    let onSelectPanel: (ReaderPanelMode) -> Void

    var body: some View {
        VStack(spacing: 14) {
            ReaderSliderRow(
                title: "字号",
                leadingLabel: "小",
                trailingLabel: "大",
                value: levelBinding(\.fontSizeLevel)
            )

            ReaderPageTurnSegmentRow(
                title: "翻页",
                options: ReaderPreferencesSnapshot.PageTurnMode.allCases,
                selected: preferences.pageTurnMode
            ) { mode in
                updatePageTurnMode(mode)
            }

            ReaderLevelSegmentRow(
                title: "行距",
                options: [("紧凑", .one), ("适中", .three), ("较松", .five)],
                selected: preferences.lineHeightLevel
            ) { level in
                update(\.lineHeightLevel, to: level)
            }

            ReaderLevelSegmentRow(
                title: "边距",
                options: [("较小", .one), ("适中", .three), ("较大", .five)],
                selected: preferences.marginLevel
            ) { level in
                update(\.marginLevel, to: level)
            }

            HStack(spacing: 16) {
                ReaderFontSegmentRow(
                    selected: preferences.font,
                    onSelect: { font in updateFont(font) }
                )
                .layoutPriority(1)

                Toggle(isOn: $firstLineIndent) {
                    Text("首行缩进")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ReaderPalette.secondaryText)
                }
                .toggleStyle(ReaderCapsuleToggleStyle())
                .frame(width: 142)
            }

            ReaderPanelNavBar(activePanel: activePanel, onSelectPanel: onSelectPanel)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .safeAreaPadding(.bottom, 14)
        .readerPanelSurface(cornerRadius: 0)
    }

    private func levelBinding(_ keyPath: WritableKeyPath<ReaderPreferencesSnapshot, ReaderPreferencesSnapshot.Level>) -> Binding<Double> {
        Binding(
            get: { Double(preferences[keyPath: keyPath].rawValue) },
            set: { newValue in
                update(keyPath, to: .nearest(to: newValue))
            }
        )
    }

    private func update(
        _ keyPath: WritableKeyPath<ReaderPreferencesSnapshot, ReaderPreferencesSnapshot.Level>,
        to level: ReaderPreferencesSnapshot.Level
    ) {
        var updated = preferences
        updated[keyPath: keyPath] = level
        onPreferencesChange(updated)
    }

    private func updatePageTurnMode(_ mode: ReaderPreferencesSnapshot.PageTurnMode) {
        var updated = preferences
        updated.pageTurnMode = mode
        onPreferencesChange(updated)
    }

    private func updateFont(_ font: ReaderPreferencesSnapshot.FontChoice) {
        var updated = preferences
        updated.font = font
        onPreferencesChange(updated)
    }
}

private struct ReaderContentsPanel: View {
    let book: BookRecord?
    let tocItems: [TableOfContentsItem]
    let bookmarks: [ReaderBookmark]
    let activePanel: ReaderPanelMode
    let onSelectTOCItem: (TableOfContentsItem) -> Void
    let onSelectBookmark: (ReaderBookmark) -> Void
    let onDeleteBookmark: (ReaderBookmark) -> Void
    let onSelectPanel: (ReaderPanelMode) -> Void
    @State private var selectedTab: ReaderContentsTab = .toc

    var body: some View {
        VStack(spacing: 0) {
            ReaderModalTabHeader(
                leadingTitle: "目录",
                trailingTitle: "书签",
                activeLeading: selectedTab == .toc,
                onLeading: { selectedTab = .toc },
                onTrailing: { selectedTab = .bookmarks }
            )
            .padding(.bottom, 24)

            ReaderBookInfoHeader(book: book, actionTitle: "翻页至")
                .padding(.bottom, 18)

            Divider()

            Group {
                switch selectedTab {
                case .toc:
                    if tocItems.isEmpty {
                        ContentUnavailableView("reader.toc.empty", systemImage: "list.bullet")
                            .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(tocItems) { item in
                                    ReaderTOCRow(item: item) {
                                        onSelectTOCItem(item)
                                    }

                                    Divider()
                                        .padding(.leading, 44 + CGFloat(item.depth) * 18)
                                }
                            }
                        }
                    }
                case .bookmarks:
                    if bookmarks.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 32, weight: .regular))
                                .foregroundStyle(Color(.systemGray3))
                            Text("暂无书签")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ReaderPalette.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(bookmarks) { bookmark in
                                Button {
                                    onSelectBookmark(bookmark)
                                } label: {
                                    ReaderBookmarkRow(bookmark: bookmark)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        onDeleteBookmark(bookmark)
                                    } label: {
                                        Text("删除")
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color(.systemBackground))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }

            ReaderPanelNavBar(activePanel: activePanel, onSelectPanel: onSelectPanel)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .safeAreaPadding(.bottom, 18)
        .frame(height: min(UIScreen.main.bounds.height * 0.82, 760))
        .readerPanelSurface(cornerRadius: 0)
    }
}

private enum ReaderContentsTab {
    case toc
    case bookmarks
}

private struct ReaderTOCRow: View {
    let item: TableOfContentsItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color(.systemGray4))
                    .frame(width: item.depth == 0 ? 8 : 6, height: item.depth == 0 ? 8 : 6)
                    .frame(width: 22)

                Text(item.title)
                    .font(.system(size: item.depth == 0 ? 20 : 18, weight: item.depth == 0 ? .semibold : .regular))
                    .foregroundStyle(item.depth == 0 ? Color(.label) : Color(red: 0.20, green: 0.22, blue: 0.27))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(item.depth) * 18)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }
}

private struct ReaderBookmarkRow: View {
    let bookmark: ReaderBookmark

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "bookmark")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(ReaderPalette.accent)
                .frame(width: 28, height: 36)

            VStack(alignment: .leading, spacing: 13) {
                Text(bookmark.title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(2)

                Text(bookmark.excerpt)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(.systemGray))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
    }
}

private struct ReaderNotesPanel: View {
    let book: BookRecord?
    let activePanel: ReaderPanelMode
    let onSelectPanel: (ReaderPanelMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReaderModalTabHeader(
                leadingTitle: "我的 (0)",
                trailingTitle: nil,
                activeLeading: true,
                onLeading: {},
                onTrailing: {}
            )
            .padding(.bottom, 26)

            ReaderBookNoteCard(book: book)
                .padding(.bottom, 34)

            VStack(spacing: 12) {
                Image(systemName: "highlighter")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color(.systemGray3))
                Text("暂无笔记划线")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ReaderPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ReaderPanelNavBar(activePanel: activePanel, onSelectPanel: onSelectPanel)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .safeAreaPadding(.bottom, 18)
        .frame(height: min(UIScreen.main.bounds.height * 0.82, 760))
        .readerPanelSurface(cornerRadius: 0)
    }
}

private struct ReaderModalTabHeader: View {
    let leadingTitle: String
    let trailingTitle: String?
    let activeLeading: Bool
    let onLeading: () -> Void
    let onTrailing: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: onLeading) {
                ReaderModalTabTitle(title: leadingTitle, isActive: activeLeading)
            }
            .buttonStyle(.plain)
            Spacer()
            if let trailingTitle {
                Button(action: onTrailing) {
                    ReaderModalTabTitle(title: trailingTitle, isActive: !activeLeading)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }
}

private struct ReaderModalTabTitle: View {
    let title: String
    let isActive: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isActive ? ReaderPalette.accent : Color(.systemGray))
            Capsule()
                .fill(isActive ? ReaderPalette.accent : .clear)
                .frame(width: 22, height: 5)
        }
    }
}

private struct ReaderBookInfoHeader: View {
    let book: BookRecord?
    let actionTitle: String

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                ReaderCoverPlaceholder(title: book?.title ?? "")
                    .frame(width: 58, height: 76)

                VStack(alignment: .leading, spacing: 8) {
                    Text(book?.title ?? String(localized: "book.untitled"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(.systemGray))
                        .lineLimit(1)

                    Text(book?.displayAuthor ?? String(localized: "book.unknown_author"))
                        .font(.headline)
                        .foregroundStyle(Color(.systemGray))
                        .lineLimit(1)
                }

                Spacer()

                Button(action: {}) {
                    HStack(spacing: 6) {
                        Text("查看详情")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.headline)
                    .foregroundStyle(Color(.systemGray))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 20) {
                Text("已读\(Int(((book?.readingProgress ?? 0) * 100).rounded()))%")
                Divider().frame(height: 20)
                Text("累计--")
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.bold))
                Spacer()
                Button(action: {}) {
                    HStack(spacing: 8) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(.systemGray))
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .font(.headline)
            .foregroundStyle(Color(.systemGray))
        }
    }
}

private struct ReaderBookNoteCard: View {
    let book: BookRecord?

    var body: some View {
        HStack(spacing: 16) {
            ReaderCoverPlaceholder(title: book?.title ?? "")
                .frame(width: 72, height: 96)

            VStack(alignment: .leading, spacing: 10) {
                Text(book?.title ?? String(localized: "book.untitled"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color(red: 0.14, green: 0.16, blue: 0.20))
                    .lineLimit(1)

                Text("0条笔记")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ReaderPalette.secondaryText)

                Text("已读\(Int(((book?.readingProgress ?? 0) * 100).rounded()))%")
                    .font(.subheadline)
                    .foregroundStyle(Color(.systemGray))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            Button(action: {}) {
                Text("去整理")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .background(ReaderPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(ReaderPalette.paleControl, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct ReaderCoverPlaceholder: View {
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.97, green: 0.88, blue: 0.66),
                            Color(red: 0.90, green: 0.33, blue: 0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(title.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "书")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.75), lineWidth: 1)
        )
    }
}

private struct ReaderPanelNavBar: View {
    let activePanel: ReaderPanelMode
    let onSelectPanel: (ReaderPanelMode) -> Void

    var body: some View {
        HStack {
            ReaderPanelButton(systemImage: "line.3.horizontal", title: "目录", isActive: activePanel == .toc) {
                onSelectPanel(.toc)
            }
            .accessibilityIdentifier("reader.bottom.tab.toc")

            Spacer()

            ReaderPanelButton(systemImage: "bookmark", title: "笔记划线", isActive: activePanel == .notes) {
                onSelectPanel(.notes)
            }
            .accessibilityIdentifier("reader.bottom.tab.notes")

            Spacer()

            ReaderPanelButton(systemImage: "sun.max", title: "主题亮度", isActive: activePanel == .theme) {
                onSelectPanel(.theme)
            }
            .accessibilityIdentifier("reader.bottom.tab.theme")

            Spacer()

            ReaderPanelButton(systemImage: "gearshape", title: "设置", isActive: activePanel == .settings) {
                onSelectPanel(.settings)
            }
            .accessibilityIdentifier("reader.bottom.tab.settings")
        }
    }
}

private struct ReaderPanelButton: View {
    let systemImage: String
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 25, weight: .regular))
                    .frame(width: 34, height: 30)
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .foregroundStyle(isActive ? ReaderPalette.accent : Color(red: 0.25, green: 0.29, blue: 0.36))
            .frame(width: 70, height: 58)
        }
        .buttonStyle(.plain)
    }
}

private struct ReaderBrightnessControl: View {
    @Binding var brightness: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
                .font(.system(size: 23, weight: .regular))
            Slider(
                value: Binding(
                    get: { brightness },
                    set: { newValue in
                        brightness = newValue.clamped(to: 0.05 ... 1)
                        UIScreen.main.brightness = brightness
                    }
                ),
                in: 0.05 ... 1
            )
            .tint(Color(.systemGray4))

            Image(systemName: "sun.max")
                .font(.system(size: 23, weight: .regular))
        }
        .foregroundStyle(ReaderPalette.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(ReaderPalette.paleControl, in: Capsule())
    }
}

private struct ReaderThemeButton: View {
    let title: String
    let fill: Color
    let foreground: Color
    let border: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(fill, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? ReaderPalette.accent : border, lineWidth: isSelected || border != .clear ? 1.5 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ReaderSliderRow: View {
    let title: String
    let leadingLabel: String
    let trailingLabel: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ReaderPalette.secondaryText)
                .frame(width: 42, alignment: .leading)

            HStack(spacing: 14) {
                Button {
                    adjustValue(by: -1)
                } label: {
                    Text(leadingLabel)
                        .frame(width: 28, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(value <= 1)
                .accessibilityIdentifier("reader.settings.slider.\(title).decrease")

                Slider(value: $value, in: 1 ... 5, step: 1)
                    .tint(Color(.systemGray4))

                Button {
                    adjustValue(by: 1)
                } label: {
                    Text(trailingLabel)
                        .frame(width: 28, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(value >= 5)
                .accessibilityIdentifier("reader.settings.slider.\(title).increase")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(ReaderPalette.secondaryText)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(ReaderPalette.paleControl, in: Capsule())
        }
    }

    private func adjustValue(by delta: Int) {
        let current = Int(value.rounded()).clamped(to: 1 ... 5)
        value = Double((current + delta).clamped(to: 1 ... 5))
    }
}

private struct ReaderPageTurnSegmentRow: View {
    let title: String
    let options: [ReaderPreferencesSnapshot.PageTurnMode]
    let selected: ReaderPreferencesSnapshot.PageTurnMode
    let onSelect: (ReaderPreferencesSnapshot.PageTurnMode) -> Void

    var body: some View {
        ReaderSegmentContainer(title: title) {
            HStack(spacing: 0) {
                ForEach(options) { option in
                    Button { onSelect(option) } label: {
                        Text(option.readerDisplayTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(option == selected ? Color(.label) : ReaderPalette.secondaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(option == selected ? Color(.systemBackground).opacity(0.82) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reader.settings.pageTurn.\(option.rawValue)")
                }
            }
        }
    }
}

private struct ReaderLevelSegmentRow: View {
    let title: String
    let options: [(String, ReaderPreferencesSnapshot.Level)]
    let selected: ReaderPreferencesSnapshot.Level
    let onSelect: (ReaderPreferencesSnapshot.Level) -> Void

    var body: some View {
        ReaderSegmentContainer(title: title) {
            HStack(spacing: 0) {
                ForEach(options, id: \.1) { option in
                    Button { onSelect(option.1) } label: {
                        Text(option.0)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(option.1 == selected ? Color(.label) : ReaderPalette.secondaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(option.1 == selected ? Color(.systemBackground).opacity(0.82) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ReaderFontSegmentRow: View {
    let selected: ReaderPreferencesSnapshot.FontChoice
    let onSelect: (ReaderPreferencesSnapshot.FontChoice) -> Void

    private let options: [(String, ReaderPreferencesSnapshot.FontChoice)] = [
        ("默认", .publisher),
        ("宋体", .serif),
        ("黑体", .sansSerif)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.1) { option in
                Button { onSelect(option.1) } label: {
                    Text(option.0)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(option.1 == selected ? Color(.label) : ReaderPalette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(option.1 == selected ? Color(.systemBackground).opacity(0.82) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(ReaderPalette.paleControl, in: Capsule())
    }
}

private struct ReaderSegmentContainer<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ReaderPalette.secondaryText)
                .frame(width: 42, alignment: .leading)

            content
                .padding(4)
                .frame(height: 52)
                .background(ReaderPalette.paleControl, in: Capsule())
        }
    }
}

private struct ReaderCapsuleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(configuration.isOn ? ReaderPalette.accent : Color(.systemGray5))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 16, height: 16)
                            .padding(2)
                    }

                configuration.label
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(ReaderPalette.paleControl, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func readerPanelSurface(cornerRadius: CGFloat) -> some View {
        frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                UnevenRoundedRectangle(cornerRadii: .init(topLeading: cornerRadius, topTrailing: cornerRadius))
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.08), radius: 18, y: -5)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
    }
}

private extension ReaderPreferencesSnapshot.Level {
    static func nearest(to value: Double) -> Self {
        let rawValue = Int(value.rounded()).clamped(to: 1 ... 5)
        return Self(rawValue: rawValue) ?? .three
    }
}

private extension ReaderPreferencesSnapshot.PageTurnMode {
    var readerDisplayTitle: String {
        switch self {
        case .horizontal:
            "左右平移"
        case .verticalScroll:
            "上下滑动"
        case .curl:
            "仿真翻页"
        }
    }
}
