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
    private var preferences: ReaderPreferencesSnapshot
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var edgeSpeechEngine: EdgeReadAloudTTSEngine?
    private var edgeSpeechTask: Task<Void, Never>?
    private var prefetchedEdgeUtteranceIndexes: Set<Int> = []
    private lazy var utterances: [PlainTextUtterance] = makeUtterances()
    private var currentUtteranceIndex: Int?
    private var currentUtteranceStartLocation: Int?
    private var activePlaybackUtterance: PlainTextUtterance?
    private var currentSpokenPhraseRange: NSRange?
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
        self.preferences = preferences
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
        viewController.onListeningStartRequestedAtLocation = { [weak self] location in
            guard let self else { return }
            self.beginListening(startingAt: location)
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
        let didChangeSpeechEngine = preferences.speechEngine != snapshot.speechEngine
            || preferences.speechVoiceIdentifier != snapshot.speechVoiceIdentifier
        preferences = snapshot
        if didChangeSpeechEngine {
            prefetchedEdgeUtteranceIndexes.removeAll()
        }
        if didChangeSpeechEngine, isListeningActive {
            stopListening()
        }
        viewController.apply(preferences: snapshot)
    }

    func startListening() async {
        guard isListeningAvailable else {
            onListeningStateChanged?(.inactive)
            return
        }
        if let location = viewController.visibleTextLocationNearReadingCenter() {
            beginListening(startingAt: location)
        } else {
            beginListening(startIndex: utteranceIndex(near: viewController.currentProgress))
        }
    }

    func pauseOrResumeListening() {
        if preferences.speechEngine == .edgeReadAloud {
            edgeSpeechEngine?.pauseOrResume()
            notifyCurrentUtterance(isPlaying: edgeSpeechEngine?.isSpeaking == true)
            return
        }

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
        viewController.scrollRangeToVisible(
            currentSpokenPhraseRange
                ?? activePlaybackUtterance?.nsRange
                ?? utterances[index].nsRange
        )
    }

    func stopListening() {
        isStoppingSpeech = true
        isListeningActive = false
        edgeSpeechTask?.cancel()
        edgeSpeechTask = nil
        edgeSpeechEngine?.stopPlayback()
        edgeSpeechEngine = nil
        prefetchedEdgeUtteranceIndexes.removeAll()
        speechSynthesizer.stopSpeaking(at: .immediate)
        currentUtteranceIndex = nil
        currentUtteranceStartLocation = nil
        activePlaybackUtterance = nil
        currentSpokenPhraseRange = nil
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
            let sentenceRange = self.text[range].plainTextTrimmingRange(in: self.text)
            let sentence = String(self.text[sentenceRange])
            guard sentence.contains(where: { $0.isLetter || $0.isNumber }) else {
                return
            }
            let sentenceNSRange = NSRange(sentenceRange, in: self.text)
            items.append(self.plainTextUtterance(text: sentence, nsRange: sentenceNSRange))
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

    private func plainTextUtterance(text: String, nsRange: NSRange) -> PlainTextUtterance {
        let progress = Double(nsRange.location) / Double(max((self.text as NSString).length, 1))
        return PlainTextUtterance(
            text: text,
            nsRange: nsRange,
            progress: progress.clamped(to: 0 ... 1)
        )
    }

    private func utteranceIndex(near progress: Double) -> Int {
        let textLength = max((text as NSString).length, 1)
        let location = Int((progress.clamped(to: 0 ... 1) * Double(textLength)).rounded(.down))
        return utteranceIndex(startingAt: location)
    }

    private func utteranceIndex(startingAt location: Int) -> Int {
        return utterances.firstIndex { NSMaxRange($0.nsRange) > location } ?? max(utterances.count - 1, 0)
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
        let utterance = playbackUtterance(for: utterances[index])
        activePlaybackUtterance = utterance
        currentSpokenPhraseRange = nil
        updateCurrentSpokenPhrase(for: utterance, localSpokenRange: nil, isPlaying: true)

        if preferences.speechEngine == .edgeReadAloud {
            playCurrentUtteranceWithEdge(utterance)
            return
        }

        let speechUtterance = AVSpeechUtterance(string: utterance.text)
        NarrationSpeechConfiguration.configure(speechUtterance, text: utterance.text)
        if preferences.speechEngine == .system,
           let selectedVoice = AVSpeechSynthesisVoice(identifier: preferences.speechVoiceIdentifier) {
            speechUtterance.voice = selectedVoice
        }
        speechSynthesizer.speak(speechUtterance)
    }

    private func playbackUtterance(for source: PlainTextUtterance) -> PlainTextUtterance {
        guard let startLocation = currentUtteranceStartLocation,
              startLocation > source.nsRange.location,
              startLocation < NSMaxRange(source.nsRange)
        else {
            return source
        }

        let nsRange = NSRange(
            location: startLocation,
            length: NSMaxRange(source.nsRange) - startLocation
        )
        guard let range = Range(nsRange, in: text) else {
            return source
        }

        let trimmedRange = text[range].plainTextTrimmingRange(in: text)
        guard trimmedRange.lowerBound < trimmedRange.upperBound else {
            return source
        }

        return plainTextUtterance(
            text: String(text[trimmedRange]),
            nsRange: NSRange(trimmedRange, in: text)
        )
    }

    private func beginListening(startingAt location: Int) {
        beginListening(
            startIndex: utteranceIndex(startingAt: location),
            startLocation: location
        )
    }

    private func beginListening(startIndex: Int) {
        beginListening(startIndex: startIndex, startLocation: nil)
    }

    private func beginListening(startIndex: Int, startLocation: Int?) {
        guard isListeningAvailable else {
            onListeningStateChanged?(.inactive)
            return
        }

        configureAudioSession()
        if speechSynthesizer.isSpeaking || speechSynthesizer.isPaused {
            isStoppingSpeech = true
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        edgeSpeechTask?.cancel()
        edgeSpeechTask = nil
        edgeSpeechEngine?.stopPlayback()
        edgeSpeechEngine = nil
        currentUtteranceIndex = startIndex.clamped(to: 0 ... max(utterances.count - 1, 0))
        currentUtteranceStartLocation = startLocation
        activePlaybackUtterance = nil
        prefetchUpcomingEdgeUtterances(startingAt: (currentUtteranceIndex ?? 0) + 1)
        playCurrentUtterance()
    }

    private func playCurrentUtteranceWithEdge(_ utterance: PlainTextUtterance) {
        let engine = EdgeReadAloudTTSEngine(voiceIdentifier: preferences.speechVoiceIdentifier)
        edgeSpeechEngine = engine
        edgeSpeechTask?.cancel()
        edgeSpeechTask = Task { @MainActor [weak self, engine, utterance] in
            let languageIdentifier = NarrationSpeechConfiguration.preferredLanguageIdentifier(for: utterance.text)
            let result = await engine.speakText(
                utterance.text,
                language: Language(code: .bcp47(languageIdentifier)),
                onSpeakRange: { [weak self] range in
                    guard let self,
                          self.isListeningActive,
                          self.edgeSpeechEngine === engine
                    else {
                        return
                    }
                    self.updateCurrentSpokenPhrase(
                        for: utterance,
                        localSpokenRange: NSRange(range, in: utterance.text),
                        isPlaying: true
                    )
                }
            )

            guard let self,
                  self.isListeningActive,
                  !self.isStoppingSpeech,
                  self.edgeSpeechEngine === engine
            else {
                self?.isStoppingSpeech = false
                return
            }

            switch result {
            case .success:
                self.edgeSpeechEngine = nil
                self.edgeSpeechTask = nil
                self.advanceToNextUtterance()
            case .failure(let error):
                AppLog.reader.error("Plain text Edge TTS error: \(String(describing: error), privacy: .public)")
                self.notifyCurrentUtterance(isPlaying: false)
            }
        }
    }

    private func prefetchUpcomingEdgeUtterances(startingAt index: Int) {
        guard preferences.speechEngine == .edgeReadAloud else {
            prefetchedEdgeUtteranceIndexes.removeAll()
            return
        }

        let range = index ..< min(index + 6, utterances.count)
        let indexes = range.filter { !prefetchedEdgeUtteranceIndexes.contains($0) }
        guard !indexes.isEmpty else {
            return
        }

        indexes.forEach { prefetchedEdgeUtteranceIndexes.insert($0) }
        EdgeReadAloudTTSEngine.prefetch(
            texts: indexes.map { utterances[$0].text },
            preferredVoiceIdentifier: preferences.speechVoiceIdentifier
        )
    }

    private func updateCurrentSpokenPhrase(
        for utterance: PlainTextUtterance,
        localSpokenRange: NSRange?,
        isPlaying: Bool
    ) {
        let phraseRange = spokenPhraseRange(for: utterance, localSpokenRange: localSpokenRange)
        if currentSpokenPhraseRange.map({ NSEqualRanges($0, phraseRange) }) != true {
            currentSpokenPhraseRange = phraseRange
            viewController.highlightSpokenSentence(phraseRange)
            viewController.scrollRangeToVisibleIfNeeded(phraseRange)
        }
        let phraseText = (text as NSString).substring(with: phraseRange)
        notifyCurrentUtterance(isPlaying: isPlaying, spokenText: phraseText)
    }

    private func spokenPhraseRange(
        for utterance: PlainTextUtterance,
        localSpokenRange: NSRange?
    ) -> NSRange {
        utterance.nsRange
    }

    private func notifyCurrentUtterance(isPlaying: Bool, spokenText: String? = nil) {
        guard let index = currentUtteranceIndex,
              utterances.indices.contains(index)
        else {
            return
        }
        let utterance = activePlaybackUtterance ?? utterances[index]
        onListeningStateChanged?(
            ReaderListeningState(
                isActive: true,
                isPlaying: isPlaying,
                isLoading: false,
                chapterTitle: title,
                utteranceText: (spokenText ?? utterance.text).readerCollapsedWhitespace,
                locatorData: makeLocatorData(progress: utterance.progress),
                remainingSeconds: max(60, (utterances.count - index) * 8)
            )
        )
    }

    private func finishListening() {
        isListeningActive = false
        currentUtteranceIndex = nil
        currentUtteranceStartLocation = nil
        activePlaybackUtterance = nil
        currentSpokenPhraseRange = nil
        edgeSpeechTask?.cancel()
        edgeSpeechTask = nil
        edgeSpeechEngine?.stopPlayback()
        edgeSpeechEngine = nil
        viewController.highlightSpokenSentence(nil)
        onListeningStateChanged?(.inactive)
    }

    private func advanceToNextUtterance() {
        guard let index = currentUtteranceIndex else {
            finishListening()
            return
        }
        currentSpokenPhraseRange = nil
        currentUtteranceStartLocation = nil
        activePlaybackUtterance = nil
        currentUtteranceIndex = index + 1
        prefetchUpcomingEdgeUtterances(startingAt: currentUtteranceIndex ?? index + 1)
        playCurrentUtterance()
    }

    private func configureAudioSession() {
        NarrationSpeechConfiguration.configureAudioSession()
    }
}

private struct PlainTextUtterance {
    let text: String
    let nsRange: NSRange
    let progress: Double
}

extension PlainTextReaderSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  isListeningActive,
                  let index = currentUtteranceIndex,
                  utterances.indices.contains(index)
            else {
                return
            }
            updateCurrentSpokenPhrase(
                for: activePlaybackUtterance ?? utterances[index],
                localSpokenRange: characterRange,
                isPlaying: true
            )
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard isListeningActive, !isStoppingSpeech else {
                isStoppingSpeech = false
                return
            }
            guard currentUtteranceIndex != nil else {
                finishListening()
                return
            }
            advanceToNextUtterance()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isStoppingSpeech = false
        }
    }
}

private extension Substring {
    func plainTextTrimmingRange(in source: String) -> Range<String.Index> {
        var lower = startIndex
        var upper = endIndex

        while lower < upper, source[lower].isPlainTextNarrationWhitespace {
            lower = source.index(after: lower)
        }

        while lower < upper {
            let previous = source.index(before: upper)
            guard source[previous].isPlainTextNarrationWhitespace else {
                break
            }
            upper = previous
        }

        return lower ..< upper
    }
}

private extension Character {
    var isPlainTextNarrationWhitespace: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

@MainActor
private final class PlainTextReaderViewController: UIViewController, UITextViewDelegate {
    private let text: String
    private let initialProgress: Double
    private let textView = UITextView()
    private let spokenHighlightLayer = CAShapeLayer()
    private var didApplyInitialProgress = false
    private var preferences: ReaderPreferencesSnapshot
    private var spokenSentenceRange: NSRange?

    var onProgressChanged: ((Double) -> Void)?
    var onChromeToggleRequested: (() -> Void)?
    var onListeningStartRequestedAtLocation: ((Int) -> Void)?

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
        spokenHighlightLayer.fillColor = ReaderSession.ttsHighlightOverlayFill.cgColor
        spokenHighlightLayer.isHidden = true
        spokenHighlightLayer.allowsEdgeAntialiasing = true
        textView.layer.addSublayer(spokenHighlightLayer)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleListeningDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        tap.cancelsTouchesInView = false
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        apply(preferences: preferences)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSpokenHighlightLayer()
        guard !didApplyInitialProgress else {
            return
        }
        didApplyInitialProgress = true
        scrollToProgress(initialProgress, animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateSpokenHighlightLayer()
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
        updateSpokenHighlightLayer()
    }

    func visibleTextLocationNearReadingCenter() -> Int? {
        guard textView.attributedText.length > 0 else {
            return nil
        }
        textView.layoutIfNeeded()
        let point = CGPoint(
            x: max(textView.bounds.midX - textView.textContainerInset.left, 1),
            y: max(textView.contentOffset.y + readingCenterY - textView.textContainerInset.top, 0)
        )
        let location = textView.layoutManager.characterIndex(
            for: point,
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return min(location, textView.attributedText.length - 1)
    }

    func scrollRangeToVisible(_ range: NSRange) {
        scrollRangeToReadingCenter(range, animated: false)
    }

    func scrollRangeToVisibleIfNeeded(_ range: NSRange) {
        scrollRangeToReadingCenter(range, animated: true)
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
                value: ReaderSession.ttsHighlightFill.withAlphaComponent(0.28),
                range: spokenSentenceRange
            )
        }
        textView.attributedText = attributedText
        if preservingOffset {
            textView.setContentOffset(offset, animated: false)
        }
        updateSpokenHighlightLayer()
    }

    private func updateSpokenHighlightLayer() {
        spokenHighlightLayer.frame = textView.bounds
        guard let spokenSentenceRange,
              spokenSentenceRange.location != NSNotFound,
              spokenSentenceRange.length > 0,
              NSMaxRange(spokenSentenceRange) <= textView.attributedText.length
        else {
            spokenHighlightLayer.isHidden = true
            spokenHighlightLayer.path = nil
            return
        }

        textView.layoutIfNeeded()
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let glyphRange = textView.layoutManager.glyphRange(
            forCharacterRange: spokenSentenceRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else {
            spokenHighlightLayer.isHidden = true
            spokenHighlightLayer.path = nil
            return
        }

        let path = UIBezierPath()
        let visibleBounds = textView.bounds.insetBy(dx: -8, dy: -12)
        textView.layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: glyphRange,
            in: textView.textContainer
        ) { [weak self] rect, _ in
            guard let self else { return }
            var highlightRect = rect
            highlightRect.origin.x += self.textView.textContainerInset.left - 4
            highlightRect.origin.y += self.textView.textContainerInset.top - self.textView.contentOffset.y - 2
            highlightRect.size.width += 8
            highlightRect.size.height += 4
            guard highlightRect.intersects(visibleBounds) else {
                return
            }
            path.append(
                UIBezierPath(
                    roundedRect: highlightRect,
                    cornerRadius: min(5, highlightRect.height / 2)
                )
            )
        }

        spokenHighlightLayer.path = path.cgPath
        spokenHighlightLayer.isHidden = path.isEmpty
    }

    private var readingTopY: CGFloat {
        min(
            ReaderChromeLayoutMetrics.topReadingInset(for: view),
            max(textView.bounds.height * 0.35, 0)
        )
    }

    private var readingBottomY: CGFloat {
        let bottomInset = ReaderChromeLayoutMetrics.listeningAutoAdvanceBottomInset(for: view)
        return max(readingTopY + 120, textView.bounds.height - bottomInset)
    }

    private var readingCenterY: CGFloat {
        (readingTopY + readingBottomY) / 2
    }

    private func scrollRangeToReadingCenter(_ range: NSRange, animated: Bool) {
        guard let rect = textContentRect(for: range) else {
            return
        }
        let maxOffset = max(textView.contentSize.height - textView.bounds.height, 0)
        let targetY = (rect.midY - readingCenterY).clamped(to: 0 ... maxOffset)
        textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
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

    private func textLocation(at point: CGPoint) -> Int? {
        guard textView.attributedText.length > 0 else {
            return nil
        }

        textView.layoutIfNeeded()
        let pointInTextView = view.convert(point, to: textView)
        guard textView.bounds.insetBy(dx: -24, dy: -24).contains(pointInTextView) else {
            return nil
        }

        let containerPoint = CGPoint(
            x: pointInTextView.x - textView.textContainerInset.left,
            y: pointInTextView.y + textView.contentOffset.y - textView.textContainerInset.top
        )
        let location = textView.layoutManager.characterIndex(
            for: containerPoint,
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return location.clamped(to: 0 ... max(textView.attributedText.length - 1, 0))
    }

    @objc private func handleListeningDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let location = textLocation(at: recognizer.location(in: view))
        else {
            return
        }
        onListeningStartRequestedAtLocation?(location)
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
