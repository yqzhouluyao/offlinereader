//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
import ReadiumShared

public protocol PublicationSpeechSynthesizerDelegate: AnyObject {
    /// Called when the synthesizer's state is updated.
    @MainActor
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, stateDidChange state: PublicationSpeechSynthesizer.State)

    /// Called when an `error` occurs while speaking `utterance`.
    @MainActor
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, utterance: PublicationSpeechSynthesizer.Utterance, didFailWithError error: PublicationSpeechSynthesizer.Error)
}

/// `PublicationSpeechSynthesizer` orchestrates the rendition of a `Publication` by iterating through its content,
/// splitting it into individual utterances using a `ContentTokenizer`, then using a `TTSEngine` to read them aloud.
public class PublicationSpeechSynthesizer: Loggable {
    public typealias EngineFactory = () -> TTSEngine
    public typealias TokenizerFactory = (_ defaultLanguage: Language?) -> ContentTokenizer

    /// Returns whether the `publication` can be played with a `PublicationSpeechSynthesizer`.
    public static func canSpeak(publication: Publication) -> Bool {
        publication.content() != nil
    }

    public enum Error: Swift.Error {
        /// Underlying `TTSEngine` error.
        case engine(TTSError)
    }

    /// User configuration for the text-to-speech engine.
    public struct Configuration: Equatable {
        /// Language overriding the publication one.
        public var defaultLanguage: Language?

        /// Identifier for the voice used to speak the utterances.
        public var voiceIdentifier: String?

        /// Playback speed multiplier.
        public var rateMultiplier: Double

        public init(
            defaultLanguage: Language? = nil,
            voiceIdentifier: String? = nil,
            rateMultiplier: Double = 1.0
        ) {
            self.defaultLanguage = defaultLanguage
            self.voiceIdentifier = voiceIdentifier
            self.rateMultiplier = min(max(rateMultiplier, 0.7), 3.0)
        }
    }

    /// An utterance is an arbitrary text (e.g. sentence) extracted from the publication, that can be synthesized by
    /// the TTS engine.
    public struct Utterance: Equatable {
        /// Text to be spoken.
        public let text: String
        /// Locator to the utterance in the publication.
        public let locator: Locator
        /// Language of this utterance, if it dffers from the default publication language.
        public let language: Language?
    }

    /// Represents a state of the `PublicationSpeechSynthesizer`.
    public enum State: Equatable {
        /// The synthesizer is completely stopped and must be (re)started from a given locator.
        case stopped

        /// The synthesizer is paused at the given utterance.
        case paused(Utterance)

        /// The TTS engine is synthesizing the associated utterance.
        /// `range` will be regularly updated while the utterance is being played.
        case playing(Utterance, range: Locator?)

        var isPlaying: Bool {
            switch self {
            case .stopped, .paused:
                return false
            case .playing:
                return true
            }
        }
    }

    /// Current state of the `PublicationSpeechSynthesizer`.
    public private(set) var state: State = .stopped {
        didSet {
            if oldValue.isPlaying != state.isPlaying {
                AudioSession.shared.user(audioSessionUser, didChangePlaying: state.isPlaying)
            }

            Task {
                await delegate?.publicationSpeechSynthesizer(self, stateDidChange: state)
            }
        }
    }

    /// Current configuration of the `PublicationSpeechSynthesizer`.
    ///
    /// Changes are not immediate, they will be applied for the next utterance.
    public var config: Configuration

    public weak var delegate: PublicationSpeechSynthesizerDelegate?

    private let publication: Publication
    private let engineFactory: EngineFactory
    private let tokenizerFactory: TokenizerFactory

    /// Creates a `PublicationSpeechSynthesizer` using the given `TTSEngine` factory.
    ///
    /// Returns null if the publication cannot be synthesized.
    ///
    /// - Parameters:
    ///   - publication: Publication which will be iterated through and synthesized.
    ///   - config: Initial TTS configuration.
    ///   - audioSessionConfig: Configuration of the audio session used to play
    ///     the utterances.
    ///   - engineFactory: Factory to create an instance of `TtsEngine`. Defaults to `AVTTSEngine`.
    ///   - tokenizerFactory: Factory to create a `ContentTokenizer` which will be used to
    ///     split each `ContentElement` item into smaller chunks. Splits by sentences by default.
    ///   - delegate: Optional delegate.
    public init?(
        publication: Publication,
        config: Configuration = Configuration(),
        audioSessionConfig: AudioSession.Configuration = .init(
            category: .playback,
            mode: .spokenAudio,
            routeSharingPolicy: .longFormAudio
        ),
        engineFactory: @escaping EngineFactory = { AVTTSEngine() },
        tokenizerFactory: @escaping TokenizerFactory = defaultTokenizerFactory,
        delegate: PublicationSpeechSynthesizerDelegate? = nil
    ) {
        guard Self.canSpeak(publication: publication) else {
            return nil
        }

        self.publication = publication
        self.config = config
        audioSessionUser = AudioSessionUser(config: audioSessionConfig)
        self.engineFactory = engineFactory
        self.tokenizerFactory = tokenizerFactory
        self.delegate = delegate
    }

    /// The default content tokenizer will split the `Content.Element` items into individual sentences.
    public static let defaultTokenizerFactory: TokenizerFactory = { defaultLanguage in
        makeTextContentTokenizer(
            defaultLanguage: defaultLanguage,
            contextSnippetLength: 50,
            textTokenizerFactory: { language in
                makeDefaultTextTokenizer(unit: .sentence, language: language)
            }
        )
    }

    private var currentTask: Task<Void, Never>?

    private lazy var engine: TTSEngine = engineFactory()

    /// List of synthesizer voices supported by the TTS engine.
    public var availableVoices: [TTSVoice] {
        engine.availableVoices
    }

    /// Returns the first voice with the given `identifier` supported by the TTS `engine`.
    ///
    /// This can be used to restore the user selected voice after storing it in the user defaults.
    public func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        let voice = lastUsedVoice.takeIf { $0.identifier == identifier }
            ?? engine.voiceWithIdentifier(identifier)

        lastUsedVoice = voice
        return voice
    }

    /// Cache for the last requested voice, for performance.
    private var lastUsedVoice: TTSVoice?

    /// (Re)starts the synthesizer from the given locator or the beginning of the publication.
    public func start(from startLocator: Locator? = nil) {
        AudioSession.shared.start(with: audioSessionUser, isPlaying: false)

        currentTask?.cancel()
        lastPrefetchedUtteranceKey = nil
        pendingStartLocator = startLocator
        publicationIterator = publication.content(from: startLocator)?.iterator()
        currentTask = Task {
            await playNextUtterance(.forward)
        }
    }

    /// Stops the synthesizer.
    ///
    /// Use `start()` to restart it.
    public func stop() {
        currentTask?.cancel()
        lastPrefetchedUtteranceKey = nil
        state = .stopped
        publicationIterator = nil
    }

    /// Interrupts a played utterance.
    ///
    /// Use `resume()` to restart the playback from the same utterance.
    public func pause() {
        currentTask?.cancel()
        if case let .playing(utterance, range: _) = state {
            state = .paused(utterance)
        }
    }

    /// Resumes an utterance interrupted with `pause()`.
    public func resume() {
        currentTask?.cancel()
        if case let .paused(utterance) = state {
            currentTask = Task {
                await play(utterance)
            }
        }
    }

    /// Pauses or resumes the playback of the current utterance.
    public func pauseOrResume() {
        switch state {
        case .stopped: return
        case .playing: pause()
        case .paused: resume()
        }
    }

    /// Updates the playback speed. Engines backed by audio players apply it to the current utterance immediately.
    @MainActor
    public func updateRateMultiplier(_ rateMultiplier: Double) {
        config.rateMultiplier = min(max(rateMultiplier, 0.7), 3.0)
        engine.updatePlaybackRate(config.rateMultiplier)
    }

    /// Skips to the previous utterance.
    public func previous() {
        currentTask?.cancel()
        currentTask = Task {
            await playNextUtterance(.backward)
        }
    }

    /// Skips to the next utterance.
    public func next() {
        currentTask?.cancel()
        currentTask = Task {
            await playNextUtterance(.forward)
        }
    }

    /// `Content.Iterator` used to iterate through the `publication`.
    private var publicationIterator: ContentIterator? {
        didSet {
            utterances = CursorList()
            queuedUtteranceBatches.removeAll()
            lastPrefetchedUtteranceKey = nil
        }
    }

    private var pendingStartLocator: Locator?
    private var queuedUtteranceBatches: [[Utterance]] = []

    /// Utterances for the current publication `ContentElement` item.
    private var utterances: CursorList<Utterance> = CursorList()
    private var lastPrefetchedUtteranceKey: String?
    private var consecutivePlaybackFailures = 0
    private static let maximumConsecutivePlaybackFailures = 3

    /// Plays the next utterance in the given `direction`.
    private func playNextUtterance(_ direction: Direction) async {
        guard let utterance = await nextUtterance(direction) else {
            state = .stopped
            return
        }
        await play(utterance)
    }

    /// Plays the given `utterance` with the TTS `engine`.
    private func play(_ utterance: Utterance) async {
        await preloadForwardUtteranceBatches(minimumUpcomingUtteranceCount: Self.prefetchUtteranceLimit)
        guard !Task.isCancelled else {
            return
        }

        prefetchUpcomingUtterances(afterStarting: utterance)
        state = .playing(utterance, range: nil)

        let result = await engine.speak(
            TTSUtterance(
                text: utterance.text,
                delay: 0,
                voiceOrLanguage: voiceOrLanguage(for: utterance),
                rateMultiplier: config.rateMultiplier
            ),
            onSpeakRange: { [weak self] range in
                guard let self = self else {
                    return
                }

                self.state = .playing(
                    utterance,
                    range: utterance.locator.copy(
                        text: { text in
                            guard
                                let highlight = text.highlight,
                                highlight.startIndex <= range.lowerBound, highlight.endIndex >= range.upperBound
                            else {
                                return
                            }
                            text = text[range]
                        }
                    )
                )
            }
        )

        guard !Task.isCancelled else {
            return
        }

        switch result {
        case .success:
            consecutivePlaybackFailures = 0
            await playNextUtterance(.forward)
        case let .failure(error):
            consecutivePlaybackFailures += 1
            await delegate?.publicationSpeechSynthesizer(self, utterance: utterance, didFailWithError: .engine(error))
            guard consecutivePlaybackFailures < Self.maximumConsecutivePlaybackFailures else {
                state = .paused(utterance)
                return
            }
            try? await Task.sleep(nanoseconds: 280_000_000)
            await playNextUtterance(.forward)
        }
    }

    private func prefetchUpcomingUtterances(afterStarting utterance: Utterance) {
        let key = "\(utterance.locator.href)#\(utterance.text)"
        guard lastPrefetchedUtteranceKey != key else {
            return
        }
        lastPrefetchedUtteranceKey = key

        let upcoming = upcomingUtterances(limit: Self.prefetchUtteranceLimit)
        guard !upcoming.isEmpty else {
            return
        }

        engine.prefetch(
            upcoming.map { utterance in
                TTSUtterance(
                    text: utterance.text,
                    delay: 0,
                    voiceOrLanguage: voiceOrLanguage(for: utterance),
                    rateMultiplier: config.rateMultiplier
                )
            }
        )
    }

    private func upcomingUtterances(limit: Int) -> [Utterance] {
        guard limit > 0 else {
            return []
        }

        var upcoming = utterances.nextItems(limit: limit)
        guard upcoming.count < limit else {
            return upcoming
        }

        for batch in queuedUtteranceBatches {
            let remaining = limit - upcoming.count
            guard remaining > 0 else {
                break
            }
            upcoming.append(contentsOf: batch.prefix(remaining))
        }
        return upcoming
    }

    private static let prefetchUtteranceLimit = 3

    /// Returns the user selected voice if it's compatible with the utterance language. Otherwise, falls back on
    /// the languages.
    private func voiceOrLanguage(for utterance: Utterance) -> Either<TTSVoice, Language> {
        if let voice = config.voiceIdentifier
            .flatMap({ id in self.voiceWithIdentifier(id) })
            .takeIf({ voice in utterance.language == nil || utterance.language?.removingRegion() == voice.language.removingRegion() })
        {
            return .left(voice)
        } else {
            return .right(utterance.language
                ?? config.defaultLanguage
                ?? publication.metadata.language
                ?? Language.current)
        }
    }

    /// Gets the next utterance in the given `direction`, or null when reaching the beginning or the end.
    private func nextUtterance(_ direction: Direction) async -> Utterance? {
        guard let utterance = utterances.next(direction) else {
            if await loadNextUtterances(direction) {
                return await nextUtterance(direction)
            }
            return nil
        }
        return utterance
    }

    /// Loads the utterances for the next publication `ContentElement` item in the given `direction`.
    private func loadNextUtterances(_ direction: Direction) async -> Bool {
        if direction == .forward, !queuedUtteranceBatches.isEmpty {
            utterances = CursorList(list: queuedUtteranceBatches.removeFirst(), startIndex: 0)
            await preloadForwardUtteranceBatches(minimumUpcomingUtteranceCount: Self.prefetchUtteranceLimit)
            return true
        }

        do {
            var nextUtterances: [Utterance] = []
            var resolvedStartIndex: Int?
            var bufferedUtteranceBatches: [[Utterance]] = []
            var searchedStartElements = 0
            while nextUtterances.isEmpty {
                guard let content = try await publicationIterator?.next(direction) else {
                    if !bufferedUtteranceBatches.isEmpty {
                        nextUtterances = bufferedUtteranceBatches.removeFirst()
                        queuedUtteranceBatches = bufferedUtteranceBatches + queuedUtteranceBatches
                        utterances = CursorList(list: nextUtterances, startIndex: 0)
                        pendingStartLocator = nil
                        return true
                    }
                    return false
                }

                let contentUtterances = try tokenize(content)
                    .flatMap { utterances(for: $0) }

                guard !contentUtterances.isEmpty else {
                    continue
                }

                switch direction {
                case .forward:
                    if let pendingStartLocator {
                        if let startIndex = preferredStartIndex(in: contentUtterances, for: pendingStartLocator) {
                            nextUtterances = contentUtterances
                            resolvedStartIndex = startIndex
                            self.pendingStartLocator = nil
                        } else {
                            bufferedUtteranceBatches.append(contentUtterances)
                            searchedStartElements += 1
                            if searchedStartElements >= Self.maximumStartLocatorSearchElements {
                                nextUtterances = bufferedUtteranceBatches.removeFirst()
                                queuedUtteranceBatches = bufferedUtteranceBatches + queuedUtteranceBatches
                                resolvedStartIndex = 0
                                self.pendingStartLocator = nil
                            }
                        }
                    } else {
                        nextUtterances = contentUtterances
                    }
                case .backward:
                    nextUtterances = contentUtterances
                }
            }

            let startIndex: Int
            switch direction {
            case .forward:
                startIndex = resolvedStartIndex ?? 0
                pendingStartLocator = nil
            case .backward:
                startIndex = nextUtterances.count - 1
            }

            utterances = CursorList(list: nextUtterances, startIndex: startIndex)
            if direction == .forward {
                await preloadForwardUtteranceBatches(minimumUpcomingUtteranceCount: Self.prefetchUtteranceLimit)
            }

            return true

        } catch {
            log(.error, error)
            return false
        }
    }

    private static let maximumStartLocatorSearchElements = 80

    private func preloadForwardUtteranceBatches(minimumUpcomingUtteranceCount: Int) async {
        var searchedElements = 0

        while upcomingUtterances(limit: minimumUpcomingUtteranceCount).count < minimumUpcomingUtteranceCount,
              searchedElements < Self.maximumPrefetchContentElements {
            searchedElements += 1
            do {
                guard let content = try await publicationIterator?.next(.forward) else {
                    return
                }
                let contentUtterances = try tokenize(content)
                    .flatMap { utterances(for: $0) }
                guard !contentUtterances.isEmpty else {
                    continue
                }
                queuedUtteranceBatches.append(contentUtterances)
            } catch {
                log(.error, error)
                return
            }
        }
    }

    private static let maximumPrefetchContentElements = 4

    /// Splits a publication `ContentElement` item into smaller chunks using the provided tokenizer.
    ///
    /// This is used to split a paragraph into sentences, for example.
    func tokenize(_ element: ContentElement) throws -> [ContentElement] {
        let tokenizer = tokenizerFactory(config.defaultLanguage ?? publication.metadata.language)
        return try tokenizer(element)
    }

    /// Splits a publication `ContentElement` item into the utterances to be spoken.
    private func utterances(for element: ContentElement) -> [Utterance] {
        func utterance(text: String, locator: Locator, language: Language? = nil) -> Utterance? {
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                return nil
            }

            return Utterance(
                text: text,
                locator: locator,
                language: language
                    // If the language is the same as the one declared globally in the publication,
                    // we omit it. This way, the app can customize the default language used in the
                    // configuration.
                    .takeIf { $0 != publication.metadata.language }
            )
        }

        switch element {
        case let element as TextContentElement:
            return element.segments
                .compactMap { segment in
                    utterance(text: segment.text, locator: segment.locator, language: segment.language)
                }

        case let element as TextualContentElement:
            guard let text = element.text.takeIf({ !$0.isEmpty }) else {
                return []
            }
            return Array(ofNotNil: utterance(text: text, locator: element.locator))

        default:
            return []
        }
    }

    private func preferredStartIndex(in utterances: [Utterance], for locator: Locator) -> Int? {
        let hints = [
            locator.text.highlight,
            locator.text.after,
            locator.text.before,
        ]
        .compactMap { $0.map(Self.normalizedSpeechText(_:)) }
        .filter { !$0.isEmpty }

        guard !hints.isEmpty else {
            return nil
        }

        let scored = utterances.enumerated().compactMap { index, utterance -> (index: Int, score: Int)? in
            let text = Self.normalizedSpeechText(utterance.text)
            guard !text.isEmpty else {
                return nil
            }
            let score = hints.map { Self.speechStartMatchScore(utterance: text, hint: $0) }.max() ?? 0
            return score > 0 ? (index, score) : nil
        }

        return scored.max { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.index > rhs.index
            }
            return lhs.score < rhs.score
        }?.index
    }

    private static func normalizedSpeechText(_ text: String) -> String {
        let skippedCharacters = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !skippedCharacters.contains($0) }
        ))
        .lowercased()
    }

    private static func speechStartMatchScore(utterance: String, hint: String) -> Int {
        if utterance.contains(hint) {
            return hint.count + 200
        }
        if hint.contains(utterance) {
            return utterance.count + 160
        }

        let maxLength = min(utterance.count, hint.count)
        guard maxLength >= 2 else {
            return 0
        }

        for length in stride(from: maxLength, through: 2, by: -1) {
            let prefixEnd = hint.index(hint.startIndex, offsetBy: length)
            let prefix = String(hint[..<prefixEnd])
            if utterance.contains(prefix) {
                return length + 120
            }
        }

        if maxLength >= 4 {
            var start = hint.startIndex
            while start < hint.endIndex {
                guard let end = hint.index(start, offsetBy: min(12, hint.distance(from: start, to: hint.endIndex)), limitedBy: hint.endIndex) else {
                    break
                }
                let candidate = String(hint[start ..< end])
                if candidate.count >= 4, utterance.contains(candidate) {
                    return candidate.count + 40
                }
                start = hint.index(after: start)
            }
        }

        return 0
    }

    // MARK: - Audio session

    private let audioSessionUser: AudioSessionUser

    private final class AudioSessionUser: ReadiumShared.AudioSessionUser {
        let audioConfiguration: AudioSession.Configuration

        init(config: AudioSession.Configuration) {
            audioConfiguration = config
        }

        deinit {
            AudioSession.shared.end(for: self)
        }

        func play() {}
    }
}

private enum Direction {
    case forward, backward
}

private extension CursorList {
    mutating func next(_ direction: Direction) -> Element? {
        switch direction {
        case .forward:
            return next()
        case .backward:
            return previous()
        }
    }
}

private extension ContentIterator {
    func next(_ direction: Direction) async throws -> ContentElement? {
        switch direction {
        case .forward:
            return try await next()
        case .backward:
            return try await previous()
        }
    }
}
