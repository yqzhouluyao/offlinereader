import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit
import WebKit

struct TableOfContentsItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let depth: Int
    let hasChildren: Bool
}

struct ReaderSearchResultItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let snippet: String
    let locatorData: Data

    init(id: UUID = UUID(), title: String, snippet: String, locatorData: Data) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.locatorData = locatorData
    }
}

@MainActor
protocol ReaderSessionProtocol: AnyObject {
    var bookID: UUID { get }
    var navigatorViewController: UIViewController { get }
    var currentLocatorData: Data? { get }
    var onLocationChanged: ((Data, Double) -> Void)? { get set }
    var onChromeToggleRequested: (() -> Void)? { get set }

    func start() async throws
    func tableOfContents() async -> [TableOfContentsItem]
    func totalPageCount() async -> Int?
    func search(_ query: String) async -> [ReaderSearchResultItem]
    func go(to locatorData: Data) async throws
    func goToTableOfContentsItem(_ itemID: String) async throws
    func applyPreferences(_ snapshot: ReaderPreferencesSnapshot) async
    func close() async
}

@MainActor
final class ReaderSession: NSObject, ReaderSessionProtocol {
    let bookID: UUID
    let publicationHandle: PublicationHandle
    let navigator: EPUBNavigatorViewController
    var onLocationChanged: ((Data, Double) -> Void)?
    var onChromeToggleRequested: (() -> Void)?

    private var tocLinksByID: [String: Link] = [:]
    private var boundaryPageTurner: ChapterBoundaryPageTurner?
    private var directionalNavigationAdapter: DirectionalNavigationAdapter?
    private var horizontalPagePanController: ReaderHorizontalPagePanController?
    private var chromeToggleInputToken: InputObservableToken?
    private var configuredUserContentControllerIDs: Set<ObjectIdentifier> = []
    private var pageTurnMode: ReaderPreferencesSnapshot.PageTurnMode

    var navigatorViewController: UIViewController {
        navigator
    }

    var currentLocatorData: Data? {
        guard let locator = navigator.currentLocation else {
            return nil
        }
        return try? LocatorCoding.encode(locator)
    }

    init(
        publicationHandle: PublicationHandle,
        initialLocatorData: Data?,
        preferences: ReaderPreferencesSnapshot
    ) throws {
        self.bookID = publicationHandle.bookID
        self.publicationHandle = publicationHandle
        self.pageTurnMode = preferences.pageTurnMode
        let locator = try initialLocatorData.map { try LocatorCoding.decode($0) }
        navigator = try EPUBNavigatorViewController(
            publication: publicationHandle.publication,
            initialLocation: locator,
            config: EPUBNavigatorViewController.Configuration(
                preferences: preferences.makeEPUBPreferences(),
                disablePageTurnsWhileScrolling: true
            )
        )
        super.init()
        navigator.delegate = self
        boundaryPageTurner = ChapterBoundaryPageTurner(navigator: navigator)
        setupNavigatorInput()
        updateControlledPagingGestures()
    }

    func start() async throws {
        if let current = navigator.currentLocation, current.locations.totalProgression == nil {
            onLocationChanged?(try LocatorCoding.encode(current), 0)
        }
    }

    func tableOfContents() async -> [TableOfContentsItem] {
        let links: [Link]
        switch await publicationHandle.publication.tableOfContents() {
        case .success(let toc):
            links = toc.isEmpty ? publicationHandle.publication.readingOrder : toc
        case .failure:
            links = publicationHandle.publication.readingOrder
        }
        tocLinksByID = [:]
        return flatten(links: links, depth: 0)
    }

    func totalPageCount() async -> Int? {
        switch await publicationHandle.publication.positions() {
        case .success(let positions):
            return positions.isEmpty ? nil : positions.count
        case .failure:
            return nil
        }
    }

    func search(_ query: String) async -> [ReaderSearchResultItem] {
        await publicationHandle.publication.readerSearchResults(for: query, fallbackTitle: publicationHandle.title)
    }

    func go(to locatorData: Data) async throws {
        let locator = try LocatorCoding.decode(locatorData)
        let didMove = await navigator.go(to: locator, options: .animated)
        if !didMove {
            throw ReaderAppError.unknown
        }
    }

    func goToTableOfContentsItem(_ itemID: String) async throws {
        guard let link = tocLinksByID[itemID] else {
            throw ReaderAppError.unknown
        }
        let didMove = await navigator.go(to: link, options: .animated)
        if !didMove {
            throw ReaderAppError.unknown
        }
    }

    func applyPreferences(_ snapshot: ReaderPreferencesSnapshot) async {
        pageTurnMode = snapshot.pageTurnMode
        navigator.submitPreferences(snapshot.makeEPUBPreferences())
        updateControlledPagingGestures()
    }

    func close() async {
        directionalNavigationAdapter?.unbind()
        directionalNavigationAdapter = nil
        if let chromeToggleInputToken {
            navigator.removeObserver(chromeToggleInputToken)
        }
        chromeToggleInputToken = nil
        horizontalPagePanController?.detach()
        horizontalPagePanController = nil
        boundaryPageTurner?.invalidate()
        boundaryPageTurner = nil
        publicationHandle.publication.close()
    }

    private func flatten(links: [Link], depth: Int) -> [TableOfContentsItem] {
        links.enumerated().flatMap { index, link -> [TableOfContentsItem] in
            let id = "\(depth)-\(index)-\(link.href)"
            tocLinksByID[id] = link
            let title = link.title?.nilIfEmpty ?? String(localized: "reader.toc.untitled")
            return [TableOfContentsItem(id: id, title: title, depth: depth, hasChildren: !link.children.isEmpty)]
                + flatten(links: link.children, depth: depth + 1)
        }
    }

    private func setupNavigatorInput() {
        let adapter = DirectionalNavigationAdapter(
            pointerPolicy: .init(
                types: [.mouse, .touch],
                edges: .horizontal,
                ignoreWhileScrolling: true,
                minimumHorizontalEdgeSize: 88,
                horizontalEdgeThresholdPercent: 0.34
            ),
            animatedTransition: pageTurnMode.usesPagedNavigation,
            onNavigation: { [weak self] in
                self?.scheduleControlledPagingGestureRefresh()
            }
        )
        adapter.bind(to: navigator)
        directionalNavigationAdapter = adapter

        let panController = ReaderHorizontalPagePanController(
            navigator: navigator,
            isPagingEnabled: { [weak self] in
                self?.pageTurnMode.usesPagedNavigation == true
            },
            onNavigation: { [weak self] in
                self?.scheduleControlledPagingGestureRefresh()
            }
        )
        panController.attach(to: navigator.view)
        horizontalPagePanController = panController

        chromeToggleInputToken = navigator.addObserver(.activate { [weak self] _ in
            self?.onChromeToggleRequested?()
            return true
        })
    }

    private func updateControlledPagingGestures() {
        directionalNavigationAdapter?.animatedTransition = pageTurnMode.usesPagedNavigation
        horizontalPagePanController?.isEnabled = pageTurnMode.usesPagedNavigation
        scheduleControlledPagingGestureRefresh()
    }

    private func scheduleControlledPagingGestureRefresh() {
        Task { @MainActor [weak self] in
            self?.navigator.view.disableReadiumResourcePagingScroll()
            try? await Task.sleep(for: .milliseconds(120))
            self?.navigator.view.disableReadiumResourcePagingScroll()
            try? await Task.sleep(for: .milliseconds(420))
            self?.navigator.view.disableReadiumResourcePagingScroll()
        }
    }
}

extension ReaderSession: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard let data = try? LocatorCoding.encode(locator) else {
            return
        }
        onLocationChanged?(data, locator.locations.totalProgression ?? 0)
    }

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        let controllerID = ObjectIdentifier(userContentController)
        guard configuredUserContentControllerIDs.insert(controllerID).inserted else {
            return
        }

        let script = WKUserScript(
            source: Self.boundaryTurnUserScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(script)
        userContentController.add(
            ReaderBoundaryScriptMessageHandler(session: self),
            name: Self.boundaryTurnMessageName
        )
    }

    func navigator(_ navigator: any Navigator, presentError error: NavigatorError) {
        AppLog.reader.error("Navigator error: \(String(describing: error), privacy: .public)")
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {}

    fileprivate func handleBoundaryTurnMessage(_ body: Any) {
        guard let navigationOptions = ReaderChapterBoundaryNavigationPolicy.navigationOptions(for: pageTurnMode) else {
            return
        }
        guard let payload = body as? [String: Any],
              let rawDirection = payload["direction"] as? String,
              let direction = ReaderBoundaryDirection(rawValue: rawDirection)
        else {
            return
        }
        boundaryPageTurner?.requestTurn(direction, options: navigationOptions)
    }

    private static let boundaryTurnMessageName = "offlineReaderBoundaryTurn"

    private static let boundaryTurnUserScriptSource = """
    (() => {
      if (window.__offlineReaderBoundaryTurnInstalled) {
        return;
      }
      window.__offlineReaderBoundaryTurnInstalled = true;

      const threshold = 28;
      let startY = null;
      let startAtTop = false;
      let startAtBottom = false;
      let lastPostAt = 0;

      function metrics() {
        const doc = document.scrollingElement || document.documentElement || document.body;
        const y = window.scrollY || doc.scrollTop || 0;
        const maxY = Math.max((doc.scrollHeight || 0) - window.innerHeight, 0);
        return {
          atTop: y <= threshold,
          atBottom: y >= maxY - threshold
        };
      }

      function post(direction) {
        const now = Date.now();
        if (now - lastPostAt < 700) {
          return;
        }
        lastPostAt = now;
        const handler = window.webkit &&
          window.webkit.messageHandlers &&
          window.webkit.messageHandlers.offlineReaderBoundaryTurn;
        if (handler) {
          handler.postMessage({ direction });
        }
      }

      window.addEventListener("touchstart", event => {
        if (!event.touches || event.touches.length === 0) {
          return;
        }
        startY = event.touches[0].clientY;
        const state = metrics();
        startAtTop = state.atTop;
        startAtBottom = state.atBottom;
      }, { passive: true });

      window.addEventListener("touchend", event => {
        if (startY === null) {
          return;
        }
        const touch = event.changedTouches && event.changedTouches[0];
        const endY = touch ? touch.clientY : startY;
        const deltaY = endY - startY;
        const state = metrics();
        if (deltaY < -36 && (startAtBottom || state.atBottom)) {
          post("forward");
        } else if (deltaY > 36 && (startAtTop || state.atTop)) {
          post("backward");
        }
        startY = null;
      }, { passive: true });

      window.addEventListener("wheel", event => {
        const state = metrics();
        if (event.deltaY > 18 && state.atBottom) {
          post("forward");
        } else if (event.deltaY < -18 && state.atTop) {
          post("backward");
        }
      }, { passive: true });
    })();
    """
}

@MainActor
private final class ChapterBoundaryPageTurner: NSObject {
    private weak var navigator: EPUBNavigatorViewController?
    private var pendingTurnTask: Task<Void, Never>?
    private var isTurning = false

    init(navigator: EPUBNavigatorViewController) {
        self.navigator = navigator
        super.init()
    }

    func invalidate() {
        pendingTurnTask?.cancel()
    }

    func requestTurn(_ direction: ReaderBoundaryDirection, options: NavigatorGoOptions) {
        pendingTurnTask?.cancel()
        pendingTurnTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            await self?.turn(direction, options: options)
        }
    }

    private func turn(_ direction: ReaderBoundaryDirection, options: NavigatorGoOptions) async {
        guard !isTurning,
              let navigator
        else {
            return
        }

        isTurning = true
        let moved = switch direction {
        case .forward:
            await navigator.goForward(options: options)
        case .backward:
            await navigator.goBackward(options: options)
        }
        try? await Task.sleep(for: .milliseconds(moved ? 180 : 120))
        isTurning = false
    }
}

private final class ReaderBoundaryScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: ReaderSession?

    init(session: ReaderSession) {
        self.session = session
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor [weak session] in
            session?.handleBoundaryTurnMessage(body)
        }
    }
}

private enum ReaderBoundaryDirection: String {
    case forward
    case backward
}

enum ReaderChapterBoundaryNavigationPolicy {
    static func navigationOptions(for pageTurnMode: ReaderPreferencesSnapshot.PageTurnMode) -> NavigatorGoOptions? {
        guard pageTurnMode == .verticalScroll else {
            return nil
        }
        return NavigatorGoOptions.none
    }
}

@MainActor
private final class ReaderHorizontalPagePanController: NSObject, UIGestureRecognizerDelegate {
    private weak var navigator: EPUBNavigatorViewController?
    private weak var attachedView: UIView?
    private let isPagingEnabled: () -> Bool
    private let onNavigation: () -> Void
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private var isTurning = false

    var isEnabled = false {
        didSet {
            panGestureRecognizer?.isEnabled = isEnabled
        }
    }

    init(
        navigator: EPUBNavigatorViewController,
        isPagingEnabled: @escaping () -> Bool,
        onNavigation: @escaping () -> Void
    ) {
        self.navigator = navigator
        self.isPagingEnabled = isPagingEnabled
        self.onNavigation = onNavigation
        super.init()
    }

    func attach(to view: UIView) {
        detach()
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.isEnabled = isEnabled
        view.addGestureRecognizer(recognizer)
        panGestureRecognizer = recognizer
        attachedView = view
    }

    func detach() {
        if let panGestureRecognizer {
            attachedView?.removeGestureRecognizer(panGestureRecognizer)
        }
        panGestureRecognizer = nil
        attachedView = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled,
              isPagingEnabled(),
              let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
              let view = recognizer.view
        else {
            return false
        }
        let velocity = recognizer.velocity(in: view)
        return abs(velocity.x) > max(120, abs(velocity.y) * 1.25)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended,
              !isTurning,
              isPagingEnabled(),
              let navigator,
              let view = recognizer.view
        else {
            return
        }

        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        guard abs(translation.x) > max(44, abs(translation.y) * 1.35)
                || abs(velocity.x) > max(520, abs(velocity.y) * 1.5)
        else {
            return
        }

        isTurning = true
        let goRight = translation.x < 0 || velocity.x < -520
        Task { @MainActor [weak self, weak navigator] in
            guard let self, let navigator else { return }
            if goRight {
                await navigator.goRight(options: .animated)
            } else {
                await navigator.goLeft(options: .animated)
            }
            self.onNavigation()
            try? await Task.sleep(for: .milliseconds(260))
            self.isTurning = false
        }
    }
}

private extension UIView {
    func disableReadiumResourcePagingScroll() {
        if String(describing: type(of: self)).contains("PaginationView") {
            subviews
                .compactMap { $0 as? UIScrollView }
                .forEach { $0.isScrollEnabled = false }
        }

        subviews.forEach { $0.disableReadiumResourcePagingScroll() }
    }
}

private extension ReaderPreferencesSnapshot.PageTurnMode {
    var usesPagedNavigation: Bool {
        self != .verticalScroll
    }
}

@MainActor
final class PDFReaderSession: NSObject, ReaderSessionProtocol {
    let bookID: UUID
    let publicationHandle: PublicationHandle
    let navigator: PDFNavigatorViewController
    var onLocationChanged: ((Data, Double) -> Void)?
    var onChromeToggleRequested: (() -> Void)?

    private var tocLinksByID: [String: Link] = [:]
    private var chromeToggleInputToken: InputObservableToken?

    var navigatorViewController: UIViewController {
        navigator
    }

    var currentLocatorData: Data? {
        guard let locator = navigator.currentLocation else {
            return nil
        }
        return try? LocatorCoding.encode(locator)
    }

    init(
        publicationHandle: PublicationHandle,
        initialLocatorData: Data?,
        preferences: ReaderPreferencesSnapshot
    ) throws {
        self.bookID = publicationHandle.bookID
        self.publicationHandle = publicationHandle
        let locator = try initialLocatorData.map { try LocatorCoding.decode($0) }
        navigator = try PDFNavigatorViewController(
            publication: publicationHandle.publication,
            initialLocation: locator,
            config: PDFNavigatorViewController.Configuration(
                preferences: preferences.makePDFPreferences()
            )
        )
        super.init()
        navigator.delegate = self
        chromeToggleInputToken = navigator.addObserver(.activate { [weak self] _ in
            self?.onChromeToggleRequested?()
            return true
        })
    }

    func start() async throws {
        if let current = navigator.currentLocation {
            onLocationChanged?(try LocatorCoding.encode(current), current.locations.totalProgression ?? 0)
        }
    }

    func tableOfContents() async -> [TableOfContentsItem] {
        let links: [Link]
        switch await publicationHandle.publication.tableOfContents() {
        case .success(let toc):
            links = toc.isEmpty ? publicationHandle.publication.readingOrder : toc
        case .failure:
            links = publicationHandle.publication.readingOrder
        }
        tocLinksByID = [:]
        return flatten(links: links, depth: 0)
    }

    func totalPageCount() async -> Int? {
        switch await publicationHandle.publication.positions() {
        case .success(let positions):
            return positions.isEmpty ? nil : positions.count
        case .failure:
            return nil
        }
    }

    func search(_ query: String) async -> [ReaderSearchResultItem] {
        await publicationHandle.publication.readerSearchResults(for: query, fallbackTitle: publicationHandle.title)
    }

    func go(to locatorData: Data) async throws {
        let locator = try LocatorCoding.decode(locatorData)
        let didMove = await navigator.go(to: locator, options: .animated)
        if !didMove {
            throw ReaderAppError.unknown
        }
    }

    func goToTableOfContentsItem(_ itemID: String) async throws {
        guard let link = tocLinksByID[itemID] else {
            throw ReaderAppError.unknown
        }
        let didMove = await navigator.go(to: link, options: .animated)
        if !didMove {
            throw ReaderAppError.unknown
        }
    }

    func applyPreferences(_ snapshot: ReaderPreferencesSnapshot) async {
        navigator.submitPreferences(snapshot.makePDFPreferences())
    }

    func close() async {
        if let chromeToggleInputToken {
            navigator.removeObserver(chromeToggleInputToken)
        }
        chromeToggleInputToken = nil
        publicationHandle.publication.close()
    }

    private func flatten(links: [Link], depth: Int) -> [TableOfContentsItem] {
        links.enumerated().flatMap { index, link -> [TableOfContentsItem] in
            let id = "\(depth)-\(index)-\(link.href)"
            tocLinksByID[id] = link
            let title = link.title?.nilIfEmpty ?? "第 \(index + 1) 项"
            return [TableOfContentsItem(id: id, title: title, depth: depth, hasChildren: !link.children.isEmpty)]
                + flatten(links: link.children, depth: depth + 1)
        }
    }
}

extension PDFReaderSession: PDFNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard let data = try? LocatorCoding.encode(locator) else {
            return
        }
        onLocationChanged?(data, locator.locations.totalProgression ?? 0)
    }

    func navigator(_ navigator: any Navigator, presentError error: NavigatorError) {
        AppLog.reader.error("PDF navigator error: \(String(describing: error), privacy: .public)")
    }
}

@MainActor
private extension Publication {
    func readerSearchResults(for query: String, fallbackTitle: String, limit: Int = 80) async -> [ReaderSearchResultItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let options = SearchOptions(caseSensitive: false, diacriticSensitive: false)
        switch await search(query: trimmedQuery, options: options) {
        case .success(let iterator):
            defer { iterator.close() }
            var items: [ReaderSearchResultItem] = []
            while !Task.isCancelled, items.count < limit {
                switch await iterator.next() {
                case .success(.some(let collection)):
                    for locator in collection.locators {
                        guard let item = locator.readerSearchResult(fallbackTitle: fallbackTitle) else {
                            continue
                        }
                        items.append(item)
                        if items.count >= limit {
                            break
                        }
                    }
                case .success(nil), .failure:
                    return items
                }
            }
            return items
        case .failure:
            return []
        }
    }
}

private extension Locator {
    func readerSearchResult(fallbackTitle: String) -> ReaderSearchResultItem? {
        guard let locatorData = try? LocatorCoding.encode(self) else {
            return nil
        }

        let sanitizedText = text.sanitized()
        let snippet = [
            sanitizedText.before,
            sanitizedText.highlight,
            sanitizedText.after
        ]
        .compactMap { $0 }
        .joined()
        .readerCollapsedWhitespace

        return ReaderSearchResultItem(
            title: title?.nilIfEmpty ?? fallbackTitle.nilIfEmpty ?? "搜索结果",
            snippet: snippet.nilIfEmpty ?? title?.nilIfEmpty ?? fallbackTitle.nilIfEmpty ?? "搜索结果",
            locatorData: locatorData
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var readerCollapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
