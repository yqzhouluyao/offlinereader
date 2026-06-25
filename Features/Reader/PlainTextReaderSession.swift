import AVFoundation
import Foundation
@preconcurrency import ReadiumShared
import UIKit

@MainActor
final class PlainTextReaderSession: NSObject, ReaderSessionProtocol {
    let bookID: UUID
    private let title: String
    private let text: String
    private let estimatedPageCount: Int
    private let viewController: PlainTextReaderViewController
    private let speechSynthesizer = AVSpeechSynthesizer()
    private lazy var utterances: [PlainTextUtterance] = makeUtterances()
    private var currentUtteranceIndex: Int?
    private var isStoppingSpeech = false
    private var isListeningActive = false
    var onLocationChanged: ((Data, Double) -> Void)?
    var onChromeToggleRequested: (() -> Void)?
    var onListeningStateChanged: ((ReaderListeningState) -> Void)?

    var navigatorViewController: UIViewController {
        viewController
    }

    var isListeningAvailable: Bool {
        !utterances.isEmpty
    }

    var currentLocatorData: Data? {
        makeLocatorData(progress: viewController.currentProgress)
    }

    init(
        bookID: UUID,
        title: String,
        text: String,
        initialLocatorData: Data?,
        preferences: ReaderPreferencesSnapshot
    ) {
        self.bookID = bookID
        self.title = title
        self.text = text
        self.estimatedPageCount = max(1, Int(ceil(Double(text.count) / 900.0)))
        let initialProgress = initialLocatorData
            .flatMap { try? LocatorCoding.decode($0) }
            .flatMap { $0.locations.totalProgression ?? $0.locations.progression } ?? 0
        viewController = PlainTextReaderViewController(
            text: text,
            title: title,
            initialProgress: initialProgress,
            preferences: preferences
        )
        super.init()
        speechSynthesizer.delegate = self
        viewController.onProgressChanged = { [weak self] progress in
            guard let self,
                  let data = self.makeLocatorData(progress: progress)
            else {
                return
            }
            self.onLocationChanged?(data, progress)
        }
        viewController.onChromeToggleRequested = { [weak self] in
            self?.onChromeToggleRequested?()
        }
    }

    func start() async throws {
        if let data = currentLocatorData {
            onLocationChanged?(data, viewController.currentProgress)
        }
    }

    func tableOfContents() async -> [TableOfContentsItem] {
        []
    }

    func totalPageCount() async -> Int? {
        estimatedPageCount
    }

    func search(_ query: String) async -> [ReaderSearchResultItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let href = RelativeURL(path: "publication.txt")
        else {
            return []
        }

        var results: [ReaderSearchResultItem] = []
        var searchRange = text.startIndex ..< text.endIndex
        let characterCount = max(text.count, 1)

        while !Task.isCancelled,
              results.count < 80,
              let range = text.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
              ) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let progress = (Double(offset) / Double(characterCount)).clamped(to: 0 ... 1)
            let locator = Locator(
                href: href,
                mediaType: .text,
                title: title,
                locations: Locator.Locations(
                    progression: progress,
                    totalProgression: progress,
                    position: max(1, Int((progress * Double(estimatedPageCount)).rounded(.down)) + 1)
                ),
                text: Locator.Text(
                    after: text.readerSearchContext(after: range.upperBound, limit: 34),
                    before: text.readerSearchContext(before: range.lowerBound, limit: 24),
                    highlight: String(text[range])
                )
            )

            if let locatorData = try? LocatorCoding.encode(locator) {
                results.append(
                    ReaderSearchResultItem(
                        title: title,
                        snippet: locator.readerSearchSnippet(fallbackTitle: title),
                        locatorData: locatorData
                    )
                )
            }

            guard range.upperBound < text.endIndex else {
                break
            }
            searchRange = range.upperBound ..< text.endIndex
        }

        return results
    }

    func go(to locatorData: Data) async throws {
        let locator = try LocatorCoding.decode(locatorData)
        let progress = (locator.locations.totalProgression ?? locator.locations.progression ?? 0).clamped(to: 0 ... 1)
        viewController.scrollToProgress(progress, animated: true)
    }

    func goToTableOfContentsItem(_ itemID: String) async throws {
        throw ReaderAppError.unknown
    }

    func applyPreferences(_ snapshot: ReaderPreferencesSnapshot) async {
        viewController.apply(preferences: snapshot)
    }

    func startListening() async {
        guard isListeningAvailable else {
            onListeningStateChanged?(.inactive)
            return
        }
        configureAudioSession()
        let startIndex = viewController.visibleTextLocationNearReadingTop()
            .map { utteranceIndex(startingAt: $0) }
            ?? utteranceIndex(near: viewController.currentProgress)
        currentUtteranceIndex = startIndex
        playCurrentUtterance()
    }

    func pauseOrResumeListening() {
        if speechSynthesizer.isPaused {
            speechSynthesizer.continueSpeaking()
            notifyCurrentUtterance(isPlaying: true)
        } else if speechSynthesizer.isSpeaking {
            speechSynthesizer.pauseSpeaking(at: .word)
            notifyCurrentUtterance(isPlaying: false)
        }
    }

    func focusListeningPosition() async {
        guard let index = currentUtteranceIndex,
              utterances.indices.contains(index)
        else {
            return
        }
        viewController.scrollRangeToVisible(utterances[index].nsRange)
    }

    func stopListening() {
        isStoppingSpeech = true
        isListeningActive = false
        speechSynthesizer.stopSpeaking(at: .immediate)
        currentUtteranceIndex = nil
        viewController.highlightSpokenSentence(nil)
        onListeningStateChanged?(.inactive)
    }

    func close() async {
        stopListening()
    }

    private func makeLocatorData(progress: Double) -> Data? {
        guard let href = RelativeURL(path: "publication.txt") else {
            return nil
        }
        let locator = Locator(
            href: href,
            mediaType: .text,
            title: title,
            locations: Locator.Locations(
                progression: progress.clamped(to: 0 ... 1),
                totalProgression: progress.clamped(to: 0 ... 1)
            )
        )
        return try? LocatorCoding.encode(locator)
    }

    private func makeUtterances() -> [PlainTextUtterance] {
        var items: [PlainTextUtterance] = []
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: [.bySentences, .localized]) { _, range, _, _ in
            let sentence = String(self.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.contains(where: { $0.isLetter || $0.isNumber }) else {
                return
            }
            let nsRange = NSRange(range, in: self.text)
            let progress = Double(nsRange.location) / Double(max((self.text as NSString).length, 1))
            items.append(
                PlainTextUtterance(
                    text: sentence,
                    nsRange: nsRange,
                    progress: progress.clamped(to: 0 ... 1)
                )
            )
        }

        if items.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
                items.append(
                    PlainTextUtterance(
                        text: trimmed,
                        nsRange: NSRange(location: 0, length: (text as NSString).length),
                        progress: 0
                    )
                )
            }
        }
        return items
    }

    private func utteranceIndex(near progress: Double) -> Int {
        let textLength = max((text as NSString).length, 1)
        let location = Int((progress.clamped(to: 0 ... 1) * Double(textLength)).rounded(.down))
        return utteranceIndex(startingAt: location)
    }

    private func utteranceIndex(startingAt location: Int) -> Int {
        return utterances.firstIndex { NSMaxRange($0.nsRange) >= location } ?? max(utterances.count - 1, 0)
    }

    private func playCurrentUtterance() {
        guard let index = currentUtteranceIndex,
              utterances.indices.contains(index)
        else {
            finishListening()
            return
        }

        isStoppingSpeech = false
        isListeningActive = true
        let utterance = utterances[index]
        viewController.highlightSpokenSentence(utterance.nsRange)
        viewController.scrollRangeToVisibleIfNeeded(utterance.nsRange)
        notifyCurrentUtterance(isPlaying: true)

        let speechUtterance = AVSpeechUtterance(string: utterance.text)
        speechUtterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "zh-CN")
        speechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(speechUtterance)
    }

    private func notifyCurrentUtterance(isPlaying: Bool) {
        guard let index = currentUtteranceIndex,
              utterances.indices.contains(index)
        else {
            return
        }
        let utterance = utterances[index]
        onListeningStateChanged?(
            ReaderListeningState(
                isActive: true,
                isPlaying: isPlaying,
                chapterTitle: title,
                utteranceText: utterance.text.readerCollapsedWhitespace,
                locatorData: makeLocatorData(progress: utterance.progress),
                remainingSeconds: max(60, (utterances.count - index) * 8)
            )
        )
    }

    private func finishListening() {
        isListeningActive = false
        currentUtteranceIndex = nil
        viewController.highlightSpokenSentence(nil)
        onListeningStateChanged?(.inactive)
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

private struct PlainTextUtterance {
    let text: String
    let nsRange: NSRange
    let progress: Double
}

extension PlainTextReaderSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard isListeningActive, !isStoppingSpeech else {
                isStoppingSpeech = false
                return
            }
            guard let index = currentUtteranceIndex else {
                finishListening()
                return
            }
            currentUtteranceIndex = index + 1
            playCurrentUtterance()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isStoppingSpeech = false
        }
    }
}

@MainActor
private final class PlainTextReaderViewController: UIViewController, UITextViewDelegate {
    private let text: String
    private let initialProgress: Double
    private let textView = UITextView()
    private var didApplyInitialProgress = false
    private var preferences: ReaderPreferencesSnapshot
    private var spokenSentenceRange: NSRange?

    var onProgressChanged: ((Double) -> Void)?
    var onChromeToggleRequested: (() -> Void)?

    var currentProgress: Double {
        let maxOffset = max(textView.contentSize.height - textView.bounds.height, 1)
        guard maxOffset > 1 else {
            return 0
        }
        return (textView.contentOffset.y / maxOffset).clamped(to: 0 ... 1)
    }

    init(text: String, title: String, initialProgress: Double, preferences: ReaderPreferencesSnapshot) {
        self.text = text
        self.initialProgress = initialProgress.clamped(to: 0 ... 1)
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.delegate = self
        textView.text = text
        textView.textContainer.lineFragmentPadding = 0
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        apply(preferences: preferences)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didApplyInitialProgress else {
            return
        }
        didApplyInitialProgress = true
        scrollToProgress(initialProgress, animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onProgressChanged?(currentProgress)
    }

    func scrollToProgress(_ progress: Double, animated: Bool) {
        view.layoutIfNeeded()
        let maxOffset = max(textView.contentSize.height - textView.bounds.height, 0)
        textView.setContentOffset(
            CGPoint(x: 0, y: maxOffset * progress.clamped(to: 0 ... 1)),
            animated: animated
        )
    }

    func apply(preferences: ReaderPreferencesSnapshot) {
        self.preferences = preferences
        renderText(preservingOffset: true)
    }

    func highlightSpokenSentence(_ range: NSRange?) {
        spokenSentenceRange = range
        renderText(preservingOffset: true)
    }

    func visibleTextLocationNearReadingTop() -> Int? {
        guard textView.attributedText.length > 0 else {
            return nil
        }
        textView.layoutIfNeeded()
        let point = CGPoint(
            x: 1,
            y: max(textView.contentOffset.y + readingTopY - textView.textContainerInset.top, 0)
        )
        let location = textView.layoutManager.characterIndex(
            for: point,
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return min(location, textView.attributedText.length - 1)
    }

    func scrollRangeToVisible(_ range: NSRange) {
        scrollRangeToReadingTop(range, animated: false)
    }

    func scrollRangeToVisibleIfNeeded(_ range: NSRange) {
        guard let rect = textViewportRect(for: range) else {
            return
        }
        if rect.maxY > readingBottomY {
            scrollRangeToReadingTop(range, animated: false)
        }
    }

    private func renderText(preservingOffset: Bool) {
        let offset = textView.contentOffset
        textView.backgroundColor = preferences.textBackgroundColor
        textView.textColor = preferences.textForegroundColor
        textView.font = preferences.textFont
        textView.textContainerInset = preferences.textInsets
        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: preferences.textFont,
                .foregroundColor: preferences.textForegroundColor,
                .paragraphStyle: preferences.paragraphStyle
            ]
        )
        if let spokenSentenceRange,
           NSMaxRange(spokenSentenceRange) <= attributedText.length {
            attributedText.addAttribute(
                .backgroundColor,
                value: UIColor(red: 0.63, green: 0.84, blue: 0.94, alpha: 0.56),
                range: spokenSentenceRange
            )
        }
        textView.attributedText = attributedText
        if preservingOffset {
            textView.setContentOffset(offset, animated: false)
        }
    }

    private var readingTopY: CGFloat {
        min(
            ReaderChromeLayoutMetrics.topReadingInset(for: view),
            max(textView.bounds.height * 0.35, 0)
        )
    }

    private var readingBottomY: CGFloat {
        let bottomInset = min(
            ReaderChromeLayoutMetrics.bottomReadingInset(for: view),
            max(textView.bounds.height * 0.35, 0)
        )
        return max(readingTopY + 120, textView.bounds.height - bottomInset)
    }

    private func scrollRangeToReadingTop(_ range: NSRange, animated: Bool) {
        guard let rect = textContentRect(for: range) else {
            return
        }
        let maxOffset = max(textView.contentSize.height - textView.bounds.height, 0)
        let targetY = (rect.minY - readingTopY).clamped(to: 0 ... maxOffset)
        textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
    }

    private func textViewportRect(for range: NSRange) -> CGRect? {
        guard var rect = textContentRect(for: range) else {
            return nil
        }
        rect.origin.y -= textView.contentOffset.y
        return rect
    }

    private func textContentRect(for range: NSRange) -> CGRect? {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textView.attributedText.length
        else {
            return nil
        }

        let glyphRange = textView.layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        var rect = textView.layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textView.textContainer
        )
        rect.origin.x += textView.textContainerInset.left
        rect.origin.y += textView.textContainerInset.top
        return rect
    }

    @objc private func toggleChrome() {
        onChromeToggleRequested?()
    }
}

private extension ReaderPreferencesSnapshot {
    var textFont: UIFont {
        let baseSize: CGFloat
        switch fontSizeLevel {
        case .one: baseSize = 17
        case .two: baseSize = 20
        case .three: baseSize = 23
        case .four: baseSize = 28
        case .five: baseSize = 34
        }
        switch font {
        case .publisher, .serif:
            return UIFont.systemFont(ofSize: baseSize, weight: .regular)
        case .sansSerif:
            return UIFont.preferredFont(forTextStyle: .body).withSize(baseSize)
        }
    }

    var textBackgroundColor: UIColor {
        switch theme {
        case .day: .systemBackground
        case .sepia: UIColor(red: 0.92, green: 0.88, blue: 0.78, alpha: 1)
        case .eyeCare: UIColor(red: 0.87, green: 0.93, blue: 0.87, alpha: 1)
        case .night: .black
        }
    }

    var textForegroundColor: UIColor {
        switch theme {
        case .day, .sepia, .eyeCare: .label
        case .night: UIColor(white: 0.88, alpha: 1)
        }
    }

    var textInsets: UIEdgeInsets {
        let horizontal: CGFloat
        switch marginLevel {
        case .one: horizontal = 18
        case .two: horizontal = 22
        case .three: horizontal = 28
        case .four: horizontal = 36
        case .five: horizontal = 44
        }
        return UIEdgeInsets(top: 28, left: horizontal, bottom: 40, right: horizontal)
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch lineHeightLevel {
        case .one: style.lineSpacing = 3
        case .two: style.lineSpacing = 5
        case .three: style.lineSpacing = 7
        case .four: style.lineSpacing = 10
        case .five: style.lineSpacing = 13
        }
        style.paragraphSpacing = 8
        return style
    }
}

private extension Locator {
    func readerSearchSnippet(fallbackTitle: String) -> String {
        let sanitizedText = text.sanitized()
        let snippet = [
            sanitizedText.before,
            sanitizedText.highlight,
            sanitizedText.after
        ]
        .compactMap { $0 }
        .joined()
        .readerCollapsedWhitespace
        return snippet.isEmpty ? fallbackTitle : snippet
    }
}

private extension String {
    func readerSearchContext(before index: String.Index, limit: Int) -> String? {
        let lowerBound = self.index(index, offsetBy: -limit, limitedBy: startIndex) ?? startIndex
        let context = String(self[lowerBound ..< index]).readerCollapsedWhitespace
        return context.isEmpty ? nil : context
    }

    func readerSearchContext(after index: String.Index, limit: Int) -> String? {
        let upperBound = self.index(index, offsetBy: limit, limitedBy: endIndex) ?? endIndex
        let context = String(self[index ..< upperBound]).readerCollapsedWhitespace
        return context.isEmpty ? nil : context
    }

    var readerCollapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
