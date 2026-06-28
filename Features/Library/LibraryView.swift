import SwiftUI
import UIKit

private enum LibrarySheet: Identifiable {
    case importOptions
    case wifiTransfer

    var id: String {
        switch self {
        case .importOptions: "importOptions"
        case .wifiTransfer: "wifiTransfer"
        }
    }
}

private enum LibraryOverlay: Identifiable {
    case moveToGroup
    case newGroup

    var id: String {
        switch self {
        case .moveToGroup: "moveToGroup"
        case .newGroup: "newGroup"
        }
    }
}

struct LibraryView: View {
    let container: AppContainer
    let router: AppRouter

    @State private var viewModel: LibraryViewModel
    @State private var sheet: LibrarySheet?
    @State private var activeOverlay: LibraryOverlay?
    @State private var actionBook: BookRecord?
    @State private var showFileImporter = false
    @State private var showDeleteSelectedConfirmation = false
    @State private var newGroupName = ""

    init(container: AppContainer, router: AppRouter) {
        self.container = container
        self.router = router
        _viewModel = State(initialValue: LibraryViewModel(container: container))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LibraryPalette.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                LibraryHeaderView(
                    isEditing: viewModel.isEditing,
                    selectedCount: viewModel.selectedBookIDs.count,
                    totalCount: viewModel.books.count,
                    onImport: { sheet = .importOptions },
                    onSelectAll: { viewModel.toggleSelectAll() },
                    onCancelEditing: { viewModel.cancelEditing() }
                )
                content
            }

            if viewModel.isEditing {
                LibraryEditActionBar(
                    selectedCount: viewModel.selectedBookIDs.count,
                    onCreateGroup: {
                        newGroupName = ""
                        activeOverlay = .newGroup
                    },
                    onMoveToGroup: { activeOverlay = .moveToGroup },
                    onDelete: { showDeleteSelectedConfirmation = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            overlayLayer
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { viewModel.load() }
        .refreshable { viewModel.load() }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .importOptions:
                ImportSheet {
                    sheet = nil
                    showFileImporter = true
                } onWiFi: {
                    sheet = .wifiTransfer
                }
            case .wifiTransfer:
                WiFiTransferView(container: container) { bookID in
                    sheet = nil
                    router.openReader(bookID: bookID)
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: SupportedBookFormat.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            Task {
                if case .success(let urls) = result,
                   let url = urls.first,
                   let bookID = await viewModel.importFile(from: url) {
                    router.openReader(bookID: bookID)
                } else if case .failure(let error) = result {
                    viewModel.alertMessage = error.localizedDescription
                }
            }
        }
        .alert("common.error", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .confirmationDialog(
            "library.delete.confirm_title",
            isPresented: Binding(
                get: { viewModel.pendingDelete != nil },
                set: { if !$0 { viewModel.pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("library.delete", role: .destructive) {
                if let book = viewModel.pendingDelete {
                    Task { await viewModel.delete(book) }
                }
                viewModel.pendingDelete = nil
            }
            Button("common.cancel", role: .cancel) {
                viewModel.pendingDelete = nil
            }
        }
        .confirmationDialog(
            "删除所选图书？",
            isPresented: $showDeleteSelectedConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteSelectedBooks() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从列表和本地文件中移除 \(viewModel.selectedBookIDs.count) 本图书。")
        }
        .confirmationDialog(
            "",
            isPresented: Binding(
                get: { actionBook != nil },
                set: { if !$0 { actionBook = nil } }
            ),
            titleVisibility: .hidden
        ) {
            bookActionButtons
        }
        .overlay {
            if viewModel.isImporting {
                ProgressView("library.importing")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            LibraryShelfControlsView(
                bookCount: viewModel.books.count,
                activeFilter: viewModel.activeFilter,
                shelfMode: viewModel.shelfMode,
                isEditing: viewModel.isEditing,
                onFilter: { viewModel.setFilter($0) },
                onToggleMode: {
                    viewModel.setShelfMode(viewModel.shelfMode == .grid ? .list : .grid)
                },
                onStartEditing: { viewModel.enterEditing() }
            )

            if viewModel.books.isEmpty {
                LibraryEmptyStateView {
                    sheet = .importOptions
                }
            } else {
                ScrollView {
                    if viewModel.isEditing {
                        editingBookList
                    } else {
                        libraryShelfContent
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, topTrailing: 18))
                .fill(LibraryPalette.panel)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    @ViewBuilder
    private var libraryShelfContent: some View {
        if viewModel.activeFilter == .custom && !viewModel.groups.isEmpty {
            LibraryGroupGrid(
                groups: viewModel.groups,
                booksForGroup: { viewModel.books(in: $0) },
                fileStore: container.fileStore
            )
            .padding(.horizontal, 22)
            .padding(.top, 20)
        } else if viewModel.activeFilter == .custom {
            LibraryGroupEmptyView {
                newGroupName = ""
                activeOverlay = .newGroup
            }
            .padding(.top, 72)
        }

        if viewModel.activeFilter != .custom || viewModel.groups.isEmpty {
            switch viewModel.shelfMode {
            case .grid:
                bookGrid
            case .list:
                bookList
            }
        }
    }

    private var bookGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: 3),
            alignment: .leading,
            spacing: 28
        ) {
            ForEach(viewModel.books) { book in
                LibraryBookGridItemView(
                    book: book,
                    fileStore: container.fileStore,
                    isPinned: viewModel.isPinned(book),
                    onOpen: { router.openReader(bookID: book.id) },
                    onMore: { actionBook = book }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.36)
                        .onEnded { _ in viewModel.enterEditing(selecting: book) }
                )
                .contextMenu {
                    Button {
                        viewModel.enterEditing(selecting: book)
                    } label: {
                        Label("选择", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        viewModel.pendingDelete = book
                    } label: {
                        Label("library.delete", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 36)
    }

    private var bookList: some View {
        LazyVStack(spacing: 22) {
            ForEach(viewModel.books) { book in
                LibraryBookRowView(
                    book: book,
                    fileStore: container.fileStore,
                    onOpen: { router.openReader(bookID: book.id) },
                    onMore: { actionBook = book }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.36)
                        .onEnded { _ in viewModel.enterEditing(selecting: book) }
                )
                .contextMenu {
                    Button {
                        viewModel.enterEditing(selecting: book)
                    } label: {
                        Label("选择", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        viewModel.pendingDelete = book
                    } label: {
                        Label("library.delete", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 36)
    }

    private var editingBookList: some View {
        LazyVStack(spacing: 16) {
            ForEach(viewModel.books) { book in
                LibrarySelectableBookRowView(
                    book: book,
                    fileStore: container.fileStore,
                    isSelected: viewModel.selectedBookIDs.contains(book.id)
                ) {
                    viewModel.toggleSelection(for: book)
                }
                .accessibilityIdentifier("library.edit.book.\(book.id.uuidString)")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 118)
    }

    @ViewBuilder
    private var overlayLayer: some View {
        if let activeOverlay {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { closeOverlay() }

            switch activeOverlay {
            case .moveToGroup:
                LibraryMoveGroupPanel(
                    groups: viewModel.groups,
                    booksForGroup: { viewModel.books(in: $0) },
                    fileStore: container.fileStore,
                    onClose: { closeOverlay() },
                    onCreateGroup: {
                        newGroupName = ""
                        self.activeOverlay = .newGroup
                    },
                    onSelectGroup: { group in
                        viewModel.moveSelection(to: group.id)
                        closeOverlay()
                    }
                )
                .transition(.move(edge: .bottom))
            case .newGroup:
                LibraryNewGroupPanel(
                    name: $newGroupName,
                    selectedCount: viewModel.selectedBookIDs.count,
                    onClose: { closeOverlay() },
                    onConfirm: {
                        viewModel.createGroup(named: newGroupName)
                        newGroupName = ""
                        closeOverlay()
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
    }

    @ViewBuilder
    private var bookActionButtons: some View {
        if let actionBook {
            Button(viewModel.isPinned(actionBook) ? "取消置顶" : "置顶") {
                viewModel.togglePinned(actionBook)
                self.actionBook = nil
            }
            Button("移动到分组") {
                viewModel.prepareSingleBookMove(actionBook)
                self.actionBook = nil
                activeOverlay = .moveToGroup
            }
            Button("取消", role: .cancel) {
                self.actionBook = nil
            }
        }
    }

    private func closeOverlay() {
        activeOverlay = nil
        viewModel.clearTransientSelectionIfNeeded()
    }
}

private enum LibraryPalette {
    static let background = Color.black
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.09)
    static let panelElevated = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let field = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let primary = Color.white
    static let secondary = Color(red: 0.62, green: 0.62, blue: 0.64)
    static let muted = Color(red: 0.38, green: 0.38, blue: 0.40)
    static let accent = Color(red: 1.0, green: 0.35, blue: 0.19)
    static let blue = Color(red: 0.27, green: 0.47, blue: 1.0)
}

private enum LibraryEditStyle {
    static let titleFont = Font.system(size: 17, weight: .semibold)
    static let subtitleFont = Font.system(size: 13, weight: .medium)
    static let controlFont = Font.system(size: 16, weight: .semibold)
    static let selectIconFont = Font.system(size: 21, weight: .regular)
    static let rowTitleFont = Font.system(size: 17, weight: .semibold)
    static let rowSubtitleFont = Font.system(size: 14, weight: .regular)
    static let rowMetaFont = Font.system(size: 13, weight: .medium)
    static let actionIconFont = Font.system(size: 22, weight: .regular)
    static let actionTitleFont = Font.system(size: 12, weight: .medium)
    static let selectIconWidth: CGFloat = 24
    static let rowCoverSize = CGSize(width: 58, height: 78)
    static let rowAccessorySize: CGFloat = 38
}

private struct LibraryHeaderView: View {
    let isEditing: Bool
    let selectedCount: Int
    let totalCount: Int
    let onImport: () -> Void
    let onSelectAll: () -> Void
    let onCancelEditing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isEditing ? 16 : 0) {
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 21, weight: .medium))
                    Text("搜索书名或作者")
                        .font(.system(size: 17, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(LibraryPalette.muted)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.12), in: Capsule())

                HeaderIconButton(systemImage: "tray.and.arrow.down.fill", badge: nil, action: onImport)
                    .accessibilityIdentifier("library.import")
            }

            if isEditing {
                HStack(alignment: .center) {
                    Button(action: onSelectAll) {
                        HStack(spacing: 7) {
                            Image(systemName: selectedCount == totalCount && totalCount > 0 ? "checkmark.circle.fill" : "circle")
                                .font(LibraryEditStyle.selectIconFont)
                                .frame(width: LibraryEditStyle.selectIconWidth, height: LibraryEditStyle.selectIconWidth)
                            Text("全选")
                                .font(LibraryEditStyle.controlFont)
                        }
                    .foregroundStyle(selectedCount == totalCount && totalCount > 0 ? LibraryPalette.accent : LibraryPalette.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.edit.selectAll")

                    Spacer()

                    VStack(spacing: 3) {
                        Text("选择内容")
                            .font(LibraryEditStyle.titleFont)
                            .foregroundStyle(LibraryPalette.primary)
                        Text("共选择了\(selectedCount)个内容")
                            .font(LibraryEditStyle.subtitleFont)
                            .foregroundStyle(LibraryPalette.secondary)
                    }

                    Spacer()

                    Button("取消", action: onCancelEditing)
                        .font(LibraryEditStyle.controlFont)
                        .foregroundStyle(LibraryPalette.primary)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.edit.cancel")
                }
                .frame(height: 40)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(LibraryPalette.background)
    }
}

private struct LibraryShelfControlsView: View {
    let bookCount: Int
    let activeFilter: LibraryShelfFilter
    let shelfMode: LibraryShelfMode
    let isEditing: Bool
    let onFilter: (LibraryShelfFilter) -> Void
    let onToggleMode: () -> Void
    let onStartEditing: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    FilterChip(title: "全部\(bookCount)", isActive: activeFilter == .all) { onFilter(.all) }
                    FilterChip(title: "进度", isActive: activeFilter == .progress) { onFilter(.progress) }
                    FilterChip(title: "分类", isActive: activeFilter == .category) { onFilter(.category) }
                    FilterChip(title: "自定义", isActive: activeFilter == .custom) { onFilter(.custom) }
                }
            }

            if !isEditing {
                HeaderToolButton(
                    systemImage: shelfMode == .grid ? "list.bullet" : "square.grid.2x2",
                    title: shelfMode == .grid ? "列表" : "宫格",
                    action: onToggleMode
                )
                .accessibilityIdentifier("library.shelf.toggleMode")
                HeaderToolButton(systemImage: "slider.horizontal.3", title: "整理", action: onStartEditing)
                    .accessibilityIdentifier("library.shelf.organize")
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }
}

private struct HeaderIconButton: View {
    let systemImage: String
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(LibraryPalette.accent)
                    .frame(width: 34, height: 44)

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(LibraryPalette.accent, in: Capsule())
                        .offset(x: 6, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct HeaderToolButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LibraryPalette.secondary)
            .frame(width: 42, height: 48)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? LibraryPalette.accent : LibraryPalette.secondary)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.filter.\(title)")
    }
}

private struct LibraryBookGridItemView: View {
    let book: BookRecord
    let fileStore: BookFileStore
    let isPinned: Bool
    let onOpen: () -> Void
    let onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 9) {
                    ZStack(alignment: .topTrailing) {
                        LibraryCoverView(book: book, fileStore: fileStore)
                            .aspectRatio(0.74, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )

                        if isPinned {
                            Image(systemName: "arrow.up.to.line.compact")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.45), in: UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 5)))
                                .accessibilityIdentifier("library.book.pinned.\(book.id.uuidString)")
                        }
                    }

                    Text(book.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LibraryPalette.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(height: 22, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.book.\(book.id.uuidString)")

            HStack(spacing: 5) {
                HStack(spacing: 3) {
                    Text("已读")
                        .foregroundStyle(LibraryPalette.secondary)
                    Text("\(progressPercent)%")
                        .foregroundStyle(LibraryPalette.accent)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                Button(action: onMore) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(LibraryPalette.muted)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多")
                .accessibilityIdentifier("library.more.book.\(book.id.uuidString)")
            }
            .font(.system(size: 14, weight: .medium))
        }
        .contentShape(Rectangle())
    }

    private var progressPercent: Int {
        Int((book.readingProgress * 100).rounded())
    }
}

private struct LibraryBookRowView: View {
    let book: BookRecord
    let fileStore: BookFileStore
    let onOpen: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onOpen) {
                HStack(spacing: 16) {
                    LibraryCoverView(book: book, fileStore: fileStore)
                        .frame(width: 68, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 11) {
                        Text(book.title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(LibraryPalette.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        Text(continueText)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(LibraryPalette.secondary)
                            .lineLimit(1)

                        Text(progressText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LibraryPalette.accent)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.book.\(book.id.uuidString)")

            Spacer(minLength: 12)

            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(LibraryPalette.muted)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
            .accessibilityIdentifier("library.more.book.\(book.id.uuidString)")
        }
        .contentShape(Rectangle())
    }

    private var continueText: String {
        guard let locatorData = book.readingLocatorData,
              let locator = try? LocatorCoding.decode(locatorData),
              let title = locator.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return book.displayAuthor
        }
        return "继续阅读：\(title)"
    }

    private var progressText: String {
        "已读 \(Int((book.readingProgress * 100).rounded()))%"
    }
}

private struct LibrarySelectableBookRowView: View {
    let book: BookRecord
    let fileStore: BookFileStore
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(LibraryEditStyle.selectIconFont)
                    .foregroundStyle(isSelected ? LibraryPalette.accent : Color.white.opacity(0.82))
                    .frame(width: LibraryEditStyle.selectIconWidth, height: LibraryEditStyle.selectIconWidth)

                LibraryCoverView(book: book, fileStore: fileStore)
                    .frame(width: LibraryEditStyle.rowCoverSize.width, height: LibraryEditStyle.rowCoverSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title)
                        .font(LibraryEditStyle.rowTitleFont)
                        .foregroundStyle(LibraryPalette.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text("继续阅读：\(sectionTitle)")
                        .font(LibraryEditStyle.rowSubtitleFont)
                        .foregroundStyle(LibraryPalette.secondary)
                        .lineLimit(1)

                    Text("已读 \(Int((book.readingProgress * 100).rounded()))%")
                        .font(LibraryEditStyle.rowMetaFont)
                        .foregroundStyle(LibraryPalette.accent)
                }

                Spacer(minLength: 8)

                Image(systemName: "book")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: LibraryEditStyle.rowAccessorySize, height: LibraryEditStyle.rowAccessorySize)
                    .background(.black, in: Circle())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sectionTitle: String {
        guard let locatorData = book.readingLocatorData,
              let locator = try? LocatorCoding.decode(locatorData),
              let title = locator.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return book.displayAuthor
        }
        return title
    }
}

private struct LibraryGroupGrid: View {
    let groups: [LibraryBookGroup]
    let booksForGroup: (LibraryBookGroup) -> [BookRecord]
    let fileStore: BookFileStore

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 2),
            alignment: .leading,
            spacing: 22
        ) {
            ForEach(groups) { group in
                let books = booksForGroup(group)
                VStack(alignment: .leading, spacing: 12) {
                    LibraryGroupCoverCollage(books: books, fileStore: fileStore)
                        .frame(width: 116, height: 116)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .clipped()
                    Text(group.name)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(LibraryPalette.primary)
                        .lineLimit(1)
                    Text("共\(books.count)本")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LibraryPalette.secondary)
                }
                .padding(10)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
        }
    }
}

private struct LibraryGroupCoverCollage: View {
    let books: [BookRecord]
    let fileStore: BookFileStore

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let previewBooks = Array(books.prefix(4))
            let inset: CGFloat = side < 90 ? 4 : 6
            let gap: CGFloat = side < 90 ? 3 : 5
            let contentSide = max(0, side - inset * 2)
            let cellSide = max(0, (contentSide - gap) / 2)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.92))

                if books.isEmpty {
                    Image(systemName: "folder")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(LibraryPalette.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: gap) {
                                ForEach(0..<2, id: \.self) { column in
                                    let index = row * 2 + column
                                    if index < previewBooks.count {
                                        LibraryCoverView(book: previewBooks[index], fileStore: fileStore)
                                            .frame(width: cellSide, height: cellSide)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    } else {
                                        Color.clear
                                            .frame(width: cellSide, height: cellSide)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: contentSide, height: contentSide, alignment: .topLeading)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
    }
}

private struct LibraryGroupEmptyView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(LibraryPalette.muted)
            Text("暂无自定义分组")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(LibraryPalette.primary)
            Button("新建分组", action: onCreate)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: 44)
                .background(LibraryPalette.accent, in: Capsule())
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.group.close")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LibraryMoveGroupPanel: View {
    let groups: [LibraryBookGroup]
    let booksForGroup: (LibraryBookGroup) -> [BookRecord]
    let fileStore: BookFileStore
    let onClose: () -> Void
    let onCreateGroup: () -> Void
    let onSelectGroup: (LibraryBookGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(LibraryPalette.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("移动至分组")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(LibraryPalette.primary)

                Spacer()

                Button("新建分组", action: onCreateGroup)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LibraryPalette.secondary)
                    .buttonStyle(.plain)
                    .frame(width: 88, alignment: .trailing)
                    .accessibilityIdentifier("library.group.createFromMove")
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 26)

            if groups.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "folder")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(LibraryPalette.muted)
                    Text("还没有分组")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(LibraryPalette.primary)
                    Text("点击右上角新建分组")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LibraryPalette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(groups) { group in
                            Button {
                                onSelectGroup(group)
                            } label: {
                                LibraryMoveGroupRow(
                                    group: group,
                                    books: booksForGroup(group),
                                    fileStore: fileStore
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.group.move.\(group.id.uuidString)")
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 38)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 540)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, topTrailing: 18))
                .fill(LibraryPalette.panel)
                .ignoresSafeArea(.container, edges: .bottom)
        )
    }
}

private struct LibraryMoveGroupRow: View {
    let group: LibraryBookGroup
    let books: [BookRecord]
    let fileStore: BookFileStore

    var body: some View {
        HStack(spacing: 18) {
            LibraryGroupCoverCollage(books: books, fileStore: fileStore)
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 12) {
                Text(group.name)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(LibraryPalette.primary)
                Text("共\(books.count)本")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LibraryPalette.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}

private struct LibraryNewGroupPanel: View {
    @Binding var name: String
    let selectedCount: Int
    let onClose: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(LibraryPalette.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.group.new.close")

                Spacer()

                Text("新建分组")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(LibraryPalette.primary)

                Spacer()

                Button("确定", action: onConfirm)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(canConfirm ? LibraryPalette.accent : LibraryPalette.muted)
                    .buttonStyle(.plain)
                    .disabled(!canConfirm)
                    .frame(width: 58, alignment: .trailing)
                    .accessibilityIdentifier("library.group.new.confirm")
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 64)

            TextField("", text: $name, prompt: Text("请输入分组名称").foregroundStyle(LibraryPalette.muted))
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(LibraryPalette.primary)
                .padding(.horizontal, 22)
                .frame(height: 58)
                .background(LibraryPalette.field, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 26)
                .accessibilityIdentifier("library.group.new.name")
                .submitLabel(.done)
                .onSubmit {
                    if canConfirm {
                        onConfirm()
                    }
                }

            if selectedCount > 0 {
                Text("将把已选 \(selectedCount) 本图书加入此分组")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LibraryPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 620)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, topTrailing: 18))
                .fill(LibraryPalette.panel)
                .ignoresSafeArea(.container, edges: .bottom)
        )
    }

    private var canConfirm: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct LibraryEditActionBar: View {
    let selectedCount: Int
    let onCreateGroup: () -> Void
    let onMoveToGroup: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            LibraryEditAction(systemImage: "arrow.up.circle", title: "取消置顶", isEnabled: selectedCount > 0, action: {})
            Spacer()
            LibraryEditAction(systemImage: "plus.circle", title: "新建分组", isEnabled: true, action: onCreateGroup)
                .accessibilityIdentifier("library.edit.createGroup")
            Spacer()
            LibraryEditAction(systemImage: "folder.badge.arrow.right", title: "移动到分组", isEnabled: selectedCount > 0, action: onMoveToGroup)
                .accessibilityIdentifier("library.edit.moveToGroup")
            Spacer()
            LibraryEditAction(systemImage: "trash", title: "删除", isEnabled: selectedCount > 0, action: onDelete)
                .accessibilityIdentifier("library.edit.delete")
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.black.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct LibraryEditAction: View {
    let systemImage: String
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(LibraryEditStyle.actionIconFont)
                    .frame(height: 25)
                Text(title)
                    .font(LibraryEditStyle.actionTitleFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .foregroundStyle(isEnabled ? LibraryPalette.primary : LibraryPalette.muted)
            .frame(width: 70)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct LibraryCoverView: View {
    let book: BookRecord
    let fileStore: BookFileStore
    @State private var coverImage: UIImage?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    PlaceholderCoverView(title: book.title)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: "\(book.id.uuidString)-\(book.coverRelativePath ?? "")") {
            await loadCover()
        }
    }

    private func loadCover() async {
        guard let relativePath = book.coverRelativePath,
              let url = try? await fileStore.resolve(relativePath: relativePath),
              let image = UIImage(contentsOfFile: url.path)
        else {
            coverImage = nil
            return
        }
        coverImage = image
    }
}

private struct LibraryEmptyStateView: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(LibraryPalette.muted)

            Text("暂无书籍")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(LibraryPalette.primary)
                .accessibilityIdentifier("library.empty.title")

            Text("导入 EPUB、PDF 或 TXT 后会显示在这里")
                .font(.system(size: 16))
                .foregroundStyle(LibraryPalette.secondary)

            Button(action: onImport) {
                Label("导入电子书", systemImage: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 46)
                    .background(LibraryPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.empty.import")

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }
}
