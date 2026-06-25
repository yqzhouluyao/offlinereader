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

struct ReaderListeningState: Equatable, Sendable {
    var isActive: Bool
    var isPlaying: Bool
    var chapterTitle: String
    var utteranceText: String
    var locatorData: Data?
    var remainingSeconds: Int

    static let inactive = ReaderListeningState(
        isActive: false,
        isPlaying: false,
        chapterTitle: "",
        utteranceText: "",
        locatorData: nil,
        remainingSeconds: 0
    )

    var remainingTimeText: String {
        let seconds = max(remainingSeconds, 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
enum ReaderChromeLayoutMetrics {
    static let topBarHeight: CGFloat = 56
    static let bottomSummaryPanelHeight: CGFloat = 126
    static let readingPadding: CGFloat = 8

    static func topReadingInset(for view: UIView?) -> CGFloat {
        safeInsets(for: view).top + topBarHeight + readingPadding
    }

    static func bottomReadingInset(for view: UIView?) -> CGFloat {
        safeInsets(for: view).bottom + bottomSummaryPanelHeight + readingPadding
    }

    private static func safeInsets(for view: UIView?) -> UIEdgeInsets {
        view?.window?.safeAreaInsets ?? view?.safeAreaInsets ?? .zero
    }
}

@MainActor
protocol ReaderSessionProtocol: AnyObject {
    var bookID: UUID { get }
    var navigatorViewController: UIViewController { get }
    var currentLocatorData: Data? { get }
    var isListeningAvailable: Bool { get }
    var onLocationChanged: ((Data, Double) -> Void)? { get set }
    var onChromeToggleRequested: (() -> Void)? { get set }
    var onListeningStateChanged: ((ReaderListeningState) -> Void)? { get set }

    func start() async throws
    func tableOfContents() async -> [TableOfContentsItem]
    func totalPageCount() async -> Int?
    func search(_ query: String) async -> [ReaderSearchResultItem]
    func go(to locatorData: Data) async throws
    func goToTableOfContentsItem(_ itemID: String) async throws
    func applyPreferences(_ snapshot: ReaderPreferencesSnapshot) async
    func startListening() async
    func pauseOrResumeListening()
    func focusListeningPosition() async
    func stopListening()
    func close() async
}

@MainActor
final class ReaderSession: NSObject, ReaderSessionProtocol {
    let bookID: UUID
    let publicationHandle: PublicationHandle
    let navigator: EPUBNavigatorViewController
    var onLocationChanged: ((Data, Double) -> Void)?
    var onChromeToggleRequested: (() -> Void)?
    var onListeningStateChanged: ((ReaderListeningState) -> Void)?

    private var tocLinksByID: [String: Link] = [:]
    private var boundaryPageTurner: ChapterBoundaryPageTurner?
    private var directionalNavigationAdapter: DirectionalNavigationAdapter?
    private var horizontalPagePanController: ReaderHorizontalPagePanController?
    private var chromeToggleInputToken: InputObservableToken?
    private var configuredUserContentControllerIDs: Set<ObjectIdentifier> = []
    private var pageTurnMode: ReaderPreferencesSnapshot.PageTurnMode
    private var speechSynthesizer: PublicationSpeechSynthesizer?
    private var currentSpokenLocatorData: Data?

    var navigatorViewController: UIViewController {
        navigator
    }

    var isListeningAvailable: Bool {
        PublicationSpeechSynthesizer.canSpeak(publication: publicationHandle.publication)
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

    func startListening() async {
        guard let synthesizer = makeSpeechSynthesizer() else {
            onListeningStateChanged?(.inactive)
            return
        }

        if let locator = await navigator.firstVisibleElementLocator() {
            synthesizer.start(from: locator)
        } else {
            synthesizer.start(from: navigator.currentLocation)
        }
    }

    func pauseOrResumeListening() {
        speechSynthesizer?.pauseOrResume()
    }

    func focusListeningPosition() async {
        guard let currentSpokenLocatorData,
              let locator = try? LocatorCoding.decode(currentSpokenLocatorData)
        else {
            return
        }
        _ = await navigator.go(to: locator, options: .none)
    }

    func stopListening() {
        speechSynthesizer?.stop()
        clearSpokenDecoration()
        currentSpokenLocatorData = nil
        onListeningStateChanged?(.inactive)
    }

    func close() async {
        stopListening()
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

    private func makeSpeechSynthesizer() -> PublicationSpeechSynthesizer? {
        if let speechSynthesizer {
            return speechSynthesizer
        }
        guard let speechSynthesizer = PublicationSpeechSynthesizer(publication: publicationHandle.publication) else {
            return nil
        }
        speechSynthesizer.delegate = self
        self.speechSynthesizer = speechSynthesizer
        return speechSynthesizer
    }

    private func updateSpokenUtterance(_ utterance: PublicationSpeechSynthesizer.Utterance, isPlaying: Bool) {
        let locatorData = try? LocatorCoding.encode(utterance.locator)
        if locatorData != currentSpokenLocatorData {
            currentSpokenLocatorData = locatorData
            navigator.apply(
                decorations: [
                    Decoration(
                        id: Self.ttsDecorationID,
                        locator: utterance.locator,
                        style: .highlight(tint: Self.ttsHighlightTint)
                    )
                ],
                in: Self.ttsDecorationGroup
            )
            autoAdvanceViewportIfNeeded(to: utterance.locator)
        }

        onListeningStateChanged?(
            ReaderListeningState(
                isActive: true,
                isPlaying: isPlaying,
                chapterTitle: utterance.locator.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? publicationHandle.title,
                utteranceText: utterance.text.readerCollapsedWhitespace,
                locatorData: locatorData,
                remainingSeconds: Self.estimatedRemainingSeconds(for: utterance.locator)
            )
        )
    }

    private func clearSpokenDecoration() {
        navigator.apply(decorations: [], in: Self.ttsDecorationGroup)
    }

    private func autoAdvanceViewportIfNeeded(to locator: Locator) {
        guard shouldAutoAdvanceViewport(to: locator) else {
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.navigator.go(to: locator, options: .none)
        }
    }

    private func shouldAutoAdvanceViewport(to locator: Locator) -> Bool {
        guard let viewport = navigator.viewport else {
            return false
        }

        if let spokenPosition = locator.locations.position,
           let visiblePositions = viewport.positions {
            return spokenPosition > visiblePositions.upperBound
        }

        if let spokenTotalProgression = locator.locations.totalProgression {
            return spokenTotalProgression > viewport.progression.upperBound
        }

        guard let spokenProgression = locator.locations.progression else {
            return false
        }

        let spokenHREF = locator.href.string.removingFragment
        guard let resource = viewport.resources.first(where: { $0.href.string.removingFragment == spokenHREF }) else {
            return true
        }
        return spokenProgression > resource.progression.upperBound
    }

    private static func estimatedRemainingSeconds(for locator: Locator) -> Int {
        let progression = (locator.locations.progression
            ?? locator.locations.totalProgression
            ?? 0
        )
        .clamped(to: 0 ... 1)
        let estimatedChapterSeconds = 12 * 60
        return max(60, Int((1 - progression) * Double(estimatedChapterSeconds)))
    }

    private static let ttsDecorationGroup: DecorationGroup = "offline-reader-tts"
    private static let ttsDecorationID = "offline-reader-current-utterance"
    private static let ttsHighlightTint = UIColor(red: 0.63, green: 0.84, blue: 0.94, alpha: 1)

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

    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        UIEdgeInsets(
            top: ReaderChromeLayoutMetrics.topReadingInset(for: navigator.view),
            left: 0,
            bottom: ReaderChromeLayoutMetrics.bottomReadingInset(for: navigator.view),
            right: 0
        )
    }

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

extension ReaderSession: PublicationSpeechSynthesizerDelegate {
    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        switch state {
        case .stopped:
            currentSpokenLocatorData = nil
            clearSpokenDecoration()
            onListeningStateChanged?(.inactive)
        case .paused(let utterance):
            updateSpokenUtterance(utterance, isPlaying: false)
        case .playing(let utterance, range: _):
            updateSpokenUtterance(utterance, isPlaying: true)
        }
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        AppLog.reader.error("EPUB TTS error: \(String(describing: error), privacy: .public)")
        updateSpokenUtterance(utterance, isPlaying: false)
    }
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
    var onListeningStateChanged: ((ReaderListeningState) -> Void)?

    private var tocLinksByID: [String: Link] = [:]
    private var chromeToggleInputToken: InputObservableToken?
    private var speechSynthesizer: PublicationSpeechSynthesizer?
    private var currentListeningState: ReaderListeningState?

    var navigatorViewController: UIViewController {
        navigator
    }

    var isListeningAvailable: Bool {
        PublicationSpeechSynthesizer.canSpeak(publication: publicationHandle.publication)
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

    func startListening() async {
        guard let synthesizer = makeSpeechSynthesizer() else {
            onListeningStateChanged?(.inactive)
            return
        }
        synthesizer.start(from: navigator.currentLocation)
    }

    func pauseOrResumeListening() {
        speechSynthesizer?.pauseOrResume()
    }

    func focusListeningPosition() async {
        guard let locatorData = currentListeningState?.locatorData,
              let locator = try? LocatorCoding.decode(locatorData)
        else {
            return
        }
        _ = await navigator.go(to: locator, options: .animated)
    }

    func stopListening() {
        speechSynthesizer?.stop()
        currentListeningState = nil
        onListeningStateChanged?(.inactive)
    }

    func close() async {
        stopListening()
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

    private func makeSpeechSynthesizer() -> PublicationSpeechSynthesizer? {
        if let speechSynthesizer {
            return speechSynthesizer
        }
        guard let speechSynthesizer = PublicationSpeechSynthesizer(publication: publicationHandle.publication) else {
            return nil
        }
        speechSynthesizer.delegate = self
        self.speechSynthesizer = speechSynthesizer
        return speechSynthesizer
    }

    private func listeningState(for utterance: PublicationSpeechSynthesizer.Utterance, isPlaying: Bool) -> ReaderListeningState {
        let locatorData = try? LocatorCoding.encode(utterance.locator)
        let state = ReaderListeningState(
            isActive: true,
            isPlaying: isPlaying,
            chapterTitle: utterance.locator.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? publicationHandle.title,
            utteranceText: utterance.text.readerCollapsedWhitespace,
            locatorData: locatorData,
            remainingSeconds: Self.estimatedRemainingSeconds(for: utterance.locator)
        )
        currentListeningState = state
        return state
    }

    private static func estimatedRemainingSeconds(for locator: Locator) -> Int {
        let progression = (locator.locations.progression
            ?? locator.locations.totalProgression
            ?? 0
        )
        .clamped(to: 0 ... 1)
        return max(60, Int((1 - progression) * Double(12 * 60)))
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

extension PDFReaderSession: PublicationSpeechSynthesizerDelegate {
    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        switch state {
        case .stopped:
            onListeningStateChanged?(.inactive)
        case .paused(let utterance):
            onListeningStateChanged?(listeningState(for: utterance, isPlaying: false))
        case .playing(let utterance, range: _):
            onListeningStateChanged?(listeningState(for: utterance, isPlaying: true))
        }
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        AppLog.reader.error("PDF TTS error: \(String(describing: error), privacy: .public)")
        onListeningStateChanged?(listeningState(for: utterance, isPlaying: false))
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

    var removingFragment: String {
        split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? self
    }

    var readerCollapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
