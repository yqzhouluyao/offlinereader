import Foundation
import AVFoundation
import CryptoKit
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
    var isLoading: Bool
    var chapterTitle: String
    var utteranceText: String
    var locatorData: Data?
    var remainingSeconds: Int

    static let inactive = ReaderListeningState(
        isActive: false,
        isPlaying: false,
        isLoading: false,
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

private struct EPUBVisualSpeechPoint: Sendable {
    let selector: String
    let textNodeIndex: Int
    let offset: Int
}

private struct EPUBVisualSpeechChunk: Sendable {
    let text: String
    let start: EPUBVisualSpeechPoint
    let end: EPUBVisualSpeechPoint
}

private enum SpokenHighlightScrollPolicy: String {
    case none
    case threshold
    case center
}

@MainActor
private enum EPUBVisualSpeechEngine {
    case system(NarrationExpressiveAVTTSEngine)
    case edge(EdgeReadAloudTTSEngine)

    var ttsEngine: TTSEngine {
        switch self {
        case .system(let engine):
            return engine
        case .edge(let engine):
            return engine
        }
    }

    var isPlaying: Bool {
        switch self {
        case .system(let engine):
            return engine.isPlaying
        case .edge(let engine):
            return engine.isSpeaking
        }
    }

    func pauseOrResume() {
        switch self {
        case .system(let engine):
            engine.pauseOrResume()
        case .edge(let engine):
            engine.pauseOrResume()
        }
    }

    func stopPlayback() {
        switch self {
        case .system(let engine):
            engine.stopPlayback()
        case .edge(let engine):
            engine.stopPlayback()
        }
    }

    func updatePlaybackRate(_ rateMultiplier: Double) {
        ttsEngine.updatePlaybackRate(rateMultiplier)
    }
}

enum NarrationSpeechConfiguration {
    static let defaultChineseLanguage = "zh-CN"

    static func publicationConfiguration(
        publicationLanguage: Language?,
        voiceIdentifier: String? = nil,
        rateMultiplier: Double = 1.0
    ) -> PublicationSpeechSynthesizer.Configuration {
        let defaultLanguage = publicationLanguage ?? Language(code: .bcp47(preferredLanguageIdentifier(for: nil)))
        return PublicationSpeechSynthesizer.Configuration(
            defaultLanguage: defaultLanguage,
            voiceIdentifier: voiceIdentifier,
            rateMultiplier: rateMultiplier
        )
    }

    static func configure(
        _ utterance: AVSpeechUtterance,
        text: String? = nil,
        languageHint: String? = nil,
        rateMultiplier: Double = 1.0
    ) {
        let spokenText = text ?? utterance.speechString
        let languageIdentifier = preferredLanguageIdentifier(for: spokenText, languageHint: languageHint)
        utterance.voice = preferredVoice(for: languageIdentifier)
        utterance.rate = preferredRate(for: spokenText, rateMultiplier: rateMultiplier)
        utterance.pitchMultiplier = preferredPitch
        utterance.volume = 1
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = postUtteranceDelay(for: spokenText)
    }

    static func voice(
        _ voice: AVSpeechSynthesisVoice,
        isCompatibleWithText text: String,
        languageHint: String?
    ) -> Bool {
        let preferredLanguage = preferredLanguageIdentifier(for: text, languageHint: languageHint)
        return matchesLanguage(voice.language, preferred: preferredLanguage)
    }

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 11.0, *) {
            try? session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: [.interruptSpokenAudioAndMixWithOthers]
            )
        } else {
            try? session.setCategory(.playback, mode: .spokenAudio)
        }
        try? session.setActive(true)
    }

    static func preferredLanguageIdentifier(for text: String?, languageHint: String? = nil) -> String {
        if text?.containsCJKText == true {
            if let languageHint,
               isChineseLanguageIdentifier(languageHint) {
                return languageHint
            }
            return defaultChineseLanguage
        }

        if let languageHint,
           !languageHint.isEmpty,
           languageHint != "und" {
            return languageHint
        }

        if let preferred = Locale.preferredLanguages.first(where: { !$0.isEmpty }) {
            if isChineseLanguageIdentifier(preferred) {
                return defaultChineseLanguage
            }
            return preferred
        }

        return defaultChineseLanguage
    }

    private static let preferredPitch: Float = 1.03

    private static func preferredRate(for text: String, rateMultiplier: Double = 1.0) -> Float {
        let containsCJK = text.containsCJKText
        let base = containsCJK
            ? AVSpeechUtteranceDefaultSpeechRate * 0.86
            : AVSpeechUtteranceDefaultSpeechRate * 0.90
        return (base * Float(ReaderPreferencesSnapshot.normalizedSpeechRate(rateMultiplier)))
            .clamped(to: AVSpeechUtteranceMinimumSpeechRate ... AVSpeechUtteranceMaximumSpeechRate)
    }

    private static func postUtteranceDelay(for text: String) -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return 0.02
        }

        if "。！？!?".contains(last) {
            return 0.08
        }
        if "；;：:".contains(last) {
            return 0.05
        }
        if "，、,".contains(last) {
            return 0.03
        }
        return 0.02
    }

    private static func preferredVoice(for languageIdentifier: String) -> AVSpeechSynthesisVoice? {
        let voices = availableSystemVoices()

        let preferredLanguages = candidateLanguageIdentifiers(for: languageIdentifier)
        return voices
            .filter { voice in preferredLanguages.contains { matchesLanguage(voice.language, preferred: $0) } }
            .max { lhs, rhs in
                voiceScore(lhs, preferredLanguages: preferredLanguages) < voiceScore(rhs, preferredLanguages: preferredLanguages)
            }
            ?? AVSpeechSynthesisVoice(language: languageIdentifier)
            ?? AVSpeechSynthesisVoice(language: defaultChineseLanguage)
    }

    static func availableSystemVoices() -> [AVSpeechSynthesisVoice] {
        let preferredLanguages = candidateLanguageIdentifiers(for: defaultChineseLanguage)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter(isUsableSystemVoice(_:))
            .sorted { lhs, rhs in
                voiceScore(lhs, preferredLanguages: preferredLanguages) > voiceScore(rhs, preferredLanguages: preferredLanguages)
            }
    }

    private static func isUsableSystemVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        guard !voice.identifier.contains(".eloquence."),
              !voice.identifier.starts(with: "com.apple.speech.synthesis.voice.")
        else {
            return false
        }
        if #available(iOS 17.0, *),
           voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice) {
            return false
        }
        return true
    }

    private static func candidateLanguageIdentifiers(for languageIdentifier: String) -> [String] {
        let normalized = languageIdentifier.replacingOccurrences(of: "_", with: "-")
        if normalized.hasPrefix("zh") || normalized.hasPrefix("cmn") || normalized.hasPrefix("yue") {
            return [normalized, defaultChineseLanguage, "zh-Hans-CN", "cmn-CN", "zh-TW", "zh-HK"]
                .narrationRemovingDuplicates()
        }
        return [normalized] + Locale.preferredLanguages + ["en-US", defaultChineseLanguage]
    }

    private static func matchesLanguage(_ voiceLanguage: String, preferred: String) -> Bool {
        let voice = voiceLanguage.lowercased()
        let target = preferred.lowercased()
        if voice == target {
            return true
        }
        if target.hasPrefix("zh") || target.hasPrefix("cmn") || target.hasPrefix("yue") {
            return voice.hasPrefix("zh") || voice.hasPrefix("cmn") || voice.hasPrefix("yue")
        }
        return voice.split(separator: "-").first == target.split(separator: "-").first
    }

    private static func voiceScore(
        _ voice: AVSpeechSynthesisVoice,
        preferredLanguages: [String]
    ) -> Int {
        let languageScore = preferredLanguages.enumerated().compactMap { index, language in
            matchesLanguage(voice.language, preferred: language) ? max(0, 240 - index * 24) : nil
        }.max() ?? 0

        let qualityScore: Int
        switch voice.quality {
        #if swift(>=5.7)
        case .premium:
            qualityScore = 500
        #endif
        case .enhanced:
            qualityScore = 360
        case .default:
            qualityScore = voice.identifier.contains(".compact.") ? 80 : 160
        @unknown default:
            qualityScore = 100
        }

        let genderScore: Int
        if #available(iOS 13.0, *) {
            switch voice.gender {
            case .female:
                genderScore = 18
            case .male:
                genderScore = 8
            case .unspecified:
                genderScore = 0
            @unknown default:
                genderScore = 0
            }
        } else {
            genderScore = 0
        }

        return languageScore + qualityScore + genderScore
    }

    private static func isChineseLanguageIdentifier(_ languageIdentifier: String) -> Bool {
        let normalized = languageIdentifier.lowercased()
        return normalized.hasPrefix("zh")
            || normalized.hasPrefix("cmn")
            || normalized.hasPrefix("yue")
    }
}

final class NarrationExpressiveAVTTSEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Result<Void, TTSError>, Never>?
    private var activeRequest: NarrationSpeechRequest?
    private var onSpeakRange: NarrationSpeakRangeHandler?
    private var lastSpokenRange: Range<String.Index>?
    private var activeGeneration = UUID()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var availableVoices: [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter(Self.isUsableVoice(_:))
            .map { voice in
                TTSVoice(
                    identifier: voice.identifier,
                    language: Language(code: .bcp47(voice.language)),
                    name: voice.name,
                    gender: Self.ttsGender(for: voice),
                    quality: Self.ttsQuality(for: voice)
            )
        }
    }

    @MainActor
    var isPlaying: Bool {
        synthesizer.isSpeaking && !synthesizer.isPaused
    }

    @MainActor
    func pauseOrResume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        }
    }

    @MainActor
    func stopPlayback() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(.success(()))
    }

    func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        AVSpeechSynthesisVoice(identifier: identifier).map { voice in
            TTSVoice(
                identifier: voice.identifier,
                language: Language(code: .bcp47(voice.language)),
                name: voice.name,
                gender: Self.ttsGender(for: voice),
                quality: Self.ttsQuality(for: voice)
            )
        }
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @Sendable @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        await speak(
            request: NarrationSpeechRequest(utterance),
            onSpeakRange: NarrationSpeakRangeHandler(onSpeakRange)
        )
    }

    @MainActor
    private func speak(
        request: NarrationSpeechRequest,
        onSpeakRange: NarrationSpeakRangeHandler
    ) async -> Result<Void, TTSError> {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish(.success(()))

        activeGeneration = UUID()
        activeRequest = request
        lastSpokenRange = nil
        self.onSpeakRange = onSpeakRange

        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success(())
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.speakActiveRequest()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSpeech()
            }
        }
    }

    @MainActor
    private func speakActiveRequest() {
        guard let activeRequest else {
            finish(.success(()))
            return
        }

        let speech = NarrationSpeechUtterance(string: activeRequest.text, generation: activeGeneration)
        let explicitVoice = preferredVoice(for: activeRequest)
        NarrationSpeechConfiguration.configure(
            speech,
            text: activeRequest.text,
            languageHint: activeRequest.languageIdentifier,
            rateMultiplier: activeRequest.rateMultiplier
        )
        if let explicitVoice,
           NarrationSpeechConfiguration.voice(
               explicitVoice,
               isCompatibleWithText: activeRequest.text,
               languageHint: activeRequest.languageIdentifier
           ) {
            speech.voice = explicitVoice
        }
        speech.preUtteranceDelay = activeRequest.delay
        synthesizer.speak(speech)
    }

    @MainActor
    private func cancelSpeech() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(.success(()))
    }

    @MainActor
    private func finish(_ result: Result<Void, TTSError>) {
        activeGeneration = UUID()
        activeRequest = nil
        lastSpokenRange = nil
        onSpeakRange = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    private func preferredVoice(for request: NarrationSpeechRequest) -> AVSpeechSynthesisVoice? {
        request.voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let generation = (utterance as? NarrationSpeechUtterance)?.generation
        Task { @MainActor [weak self, generation] in
            guard let self,
                  generation == self.activeGeneration,
                  let activeRequest = self.activeRequest
            else {
                return
            }
            self.publishSpokenRange(
                NarrationTextChunker.firstChunkRange(in: activeRequest.text)
                    ?? activeRequest.text.startIndex ..< activeRequest.text.endIndex
            )
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let generation = (utterance as? NarrationSpeechUtterance)?.generation
        let spokenText = utterance.speechString
        Task { @MainActor [weak self, generation, spokenText] in
            guard let self,
                  generation == self.activeGeneration,
                  let wordRange = Range(characterRange, in: spokenText)
            else {
                return
            }
            self.publishSpokenRange(
                NarrationTextChunker.chunkRange(containing: wordRange, in: spokenText) ?? wordRange
            )
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let generation = (utterance as? NarrationSpeechUtterance)?.generation
        Task { @MainActor [weak self, generation] in
            guard let self,
                  generation == self.activeGeneration
            else {
                return
            }
            self.finish(.success(()))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let generation = (utterance as? NarrationSpeechUtterance)?.generation
        Task { @MainActor [weak self, generation] in
            guard generation == self?.activeGeneration else {
                return
            }
            self?.finish(.success(()))
        }
    }

    private static func isUsableVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        guard !voice.identifier.contains(".eloquence."),
              !voice.identifier.starts(with: "com.apple.speech.synthesis.voice.")
        else {
            return false
        }
        if #available(iOS 17.0, *),
           voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice) {
            return false
        }
        return true
    }

    private static func ttsGender(for voice: AVSpeechSynthesisVoice) -> TTSVoice.Gender {
        if #available(iOS 13.0, *) {
            switch voice.gender {
            case .female:
                return .female
            case .male:
                return .male
            case .unspecified:
                return .unspecified
            @unknown default:
                return .unspecified
            }
        }
        return .unspecified
    }

    private static func ttsQuality(for voice: AVSpeechSynthesisVoice) -> TTSVoice.Quality? {
        switch voice.quality {
        case .default:
            if voice.identifier.contains(".super-compact.") {
                return .lower
            }
            if voice.identifier.contains(".compact.") {
                return .low
            }
            return .medium
        case .enhanced:
            return .high
        #if swift(>=5.7)
        case .premium:
            return .higher
        #endif
        @unknown default:
            return nil
        }
    }

    @MainActor
    private func publishSpokenRange(_ range: Range<String.Index>) {
        guard range != lastSpokenRange else {
            return
        }
        lastSpokenRange = range
        onSpeakRange?.callAsFunction(range)
    }
}

private struct NarrationSpeechRequest: Sendable {
    let text: String
    let delay: TimeInterval
    let voiceIdentifier: String?
    let languageIdentifier: String?
    let rateMultiplier: Double

    init(_ utterance: TTSUtterance) {
        text = utterance.text
        delay = utterance.delay
        rateMultiplier = utterance.rateMultiplier
        switch utterance.voiceOrLanguage {
        case .left(let voice):
            voiceIdentifier = voice.identifier
            languageIdentifier = voice.language.code.bcp47
        case .right(let language):
            voiceIdentifier = nil
            languageIdentifier = language.code.bcp47
        }
    }
}

private final class NarrationSpeakRangeHandler: @unchecked Sendable {
    private let onSpeakRange: (Range<String.Index>) -> Void

    init(_ onSpeakRange: @escaping (Range<String.Index>) -> Void) {
        self.onSpeakRange = onSpeakRange
    }

    func callAsFunction(_ range: Range<String.Index>) {
        onSpeakRange(range)
    }
}

private final class NarrationSpeechUtterance: AVSpeechUtterance {
    let generation: UUID

    init(string: String, generation: UUID) {
        self.generation = generation
        super.init(string: string)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct NarrationTextChunk: Equatable {
    let range: Range<String.Index>
    let terminal: Character?
}

enum NarrationTextChunker {
    static func chunks(in text: String) -> [NarrationTextChunk] {
        var chunks: [NarrationTextChunk] = []
        var start = text.startIndex
        var current = start

        func appendChunk(end: String.Index, terminal: Character?) {
            let trimmedRange = text[start ..< end].trimmingRange(in: text)
            guard trimmedRange.lowerBound < trimmedRange.upperBound else {
                start = end
                current = end
                return
            }
            chunks.append(NarrationTextChunk(range: trimmedRange, terminal: terminal))
            start = end
            current = end
        }

        while current < text.endIndex {
            let char = text[current]
            let next = text.index(after: current)
            let length = text.distance(from: start, to: next)
            if strongBoundaryCharacters.contains(char)
                || length >= maximumChunkCharacters {
                appendChunk(end: next, terminal: char)
            } else {
                current = next
            }
        }

        if start < text.endIndex {
            appendChunk(end: text.endIndex, terminal: nil)
        }

        return chunks
    }

    static func firstChunkRange(in text: String) -> Range<String.Index>? {
        chunks(in: text).first?.range
    }

    static func chunkRange(
        containing range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        chunks(in: text).first { chunk in
            chunk.range.lowerBound <= range.lowerBound && range.lowerBound < chunk.range.upperBound
        }?.range
    }

    private static let maximumChunkCharacters = 96
    private static let strongBoundaryCharacters = Set("。！？!?；;：:\n")
}

final class EdgeReadAloudTTSEngine: NSObject, TTSEngine, AVAudioPlayerDelegate, @unchecked Sendable {
    private let voiceIdentifier: String
    private var audioPlayer: AVAudioPlayer?
    private var continuation: CheckedContinuation<Result<Void, TTSError>, Never>?
    private var rangeTask: Task<Void, Never>?

    init(voiceIdentifier: String = EdgeReadAloudVoice.defaultIdentifier) {
        self.voiceIdentifier = voiceIdentifier
        super.init()
    }

    var availableVoices: [TTSVoice] {
        EdgeReadAloudVoice.available.map(\.ttsVoice)
    }

    func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        EdgeReadAloudVoice.available.first { $0.identifier == identifier }?.ttsVoice
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @Sendable @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        let speakRangeHandler = NarrationSpeakRangeHandler(onSpeakRange)
        return await speakText(
            utterance.text,
            language: utterance.language,
            rateMultiplier: utterance.rateMultiplier,
            speakRangeHandler: speakRangeHandler
        )
    }

    func prefetch(_ utterances: [TTSUtterance]) {
        let entries = utterances.map { utterance in
            (
                text: utterance.text,
                voiceIdentifier: Self.effectiveVoiceIdentifier(
                    preferredVoiceIdentifier: voiceIdentifier,
                    text: utterance.text,
                    language: utterance.language
                )
            )
        }
        EdgeReadAloudClient.prefetch(entries: entries)
    }

    @MainActor
    func speakText(
        _ text: String,
        language: Language? = nil,
        rateMultiplier: Double = 1.0,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        await speakText(
            text,
            language: language,
            rateMultiplier: rateMultiplier,
            speakRangeHandler: NarrationSpeakRangeHandler(onSpeakRange)
        )
    }

    @MainActor
    private func speakText(
        _ text: String,
        language: Language?,
        rateMultiplier: Double = 1.0,
        speakRangeHandler: NarrationSpeakRangeHandler
    ) async -> Result<Void, TTSError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success(())
        }

        do {
            let voice = voiceIdentifier(for: text, language: language)
            let languageCode = language?.code.bcp47 ?? "nil"
            AppLog.reader.error(
                "Edge Read Aloud trace: engine speak start voice=\(voice, privacy: .public) language=\(languageCode, privacy: .public) chars=\(trimmed.count, privacy: .public) utf8=\(trimmed.utf8.count, privacy: .public) fp=\(EdgeReadAloudClient.fingerprint(for: trimmed), privacy: .public)"
            )
            let audio = try await EdgeReadAloudClient.synthesize(text: text, voiceIdentifier: voice)
            return await play(
                audio: audio,
                text: text,
                rateMultiplier: rateMultiplier,
                speakRangeHandler: speakRangeHandler
            )
        } catch is CancellationError {
            stopPlayback()
            return .success(())
        } catch {
            AppLog.reader.error("Edge Read Aloud TTS failed: \(String(describing: error), privacy: .public)")
            return .failure(.other(error))
        }
    }

    @MainActor
    var isSpeaking: Bool {
        audioPlayer?.isPlaying == true
    }

    @MainActor
    var isPaused: Bool {
        guard let audioPlayer else {
            return false
        }
        return !audioPlayer.isPlaying && continuation != nil
    }

    @MainActor
    func updatePlaybackRate(_ rateMultiplier: Double) {
        guard let audioPlayer else {
            return
        }
        audioPlayer.enableRate = true
        audioPlayer.rate = Float(ReaderPreferencesSnapshot.normalizedSpeechRate(rateMultiplier))
    }

    @MainActor
    func pauseOrResume() {
        guard let audioPlayer else {
            return
        }
        if audioPlayer.isPlaying {
            audioPlayer.pause()
            rangeTask?.cancel()
        } else {
            audioPlayer.play()
        }
    }

    @MainActor
    func stopPlayback() {
        rangeTask?.cancel()
        rangeTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        finish(.success(()))
    }

    private func voiceIdentifier(for text: String, language: Language?) -> String {
        Self.effectiveVoiceIdentifier(
            preferredVoiceIdentifier: voiceIdentifier,
            text: text,
            language: language,
            shouldLogOverride: true
        )
    }

    static func prefetch(texts: [String], preferredVoiceIdentifier: String) {
        let entries = texts.map { text in
            (
                text: text,
                voiceIdentifier: effectiveVoiceIdentifier(
                    preferredVoiceIdentifier: preferredVoiceIdentifier,
                    text: text,
                    language: nil
                )
            )
        }
        EdgeReadAloudClient.prefetch(entries: entries)
    }

    static func effectiveVoiceIdentifier(
        preferredVoiceIdentifier: String,
        text: String,
        language: Language?,
        shouldLogOverride: Bool = false
    ) -> String {
        let preferred = EdgeReadAloudVoice.available.first { $0.identifier == preferredVoiceIdentifier }
        if text.containsCJKText {
            if let preferred, preferred.supportsChineseText {
                return preferred.identifier
            }
            if shouldLogOverride {
                AppLog.reader.error(
                    "Edge Read Aloud trace: overriding incompatible voice selected=\(preferredVoiceIdentifier, privacy: .public) textLanguage=zh fallback=\(EdgeReadAloudVoice.defaultIdentifier, privacy: .public)"
                )
            }
            return EdgeReadAloudVoice.defaultIdentifier
        }

        if let language,
           let voice = EdgeReadAloudVoice.available.first(where: { $0.language == language.code.bcp47 }) {
            return voice.identifier
        }

        return preferred?.identifier ?? EdgeReadAloudVoice.englishFallbackIdentifier
    }

    @MainActor
    private func play(
        audio: Data,
        text: String,
        rateMultiplier: Double,
        speakRangeHandler: NarrationSpeakRangeHandler
    ) async -> Result<Void, TTSError> {
        stopPlayback()

        do {
            AppLog.reader.error(
                "Edge Read Aloud trace: player prepare bytes=\(audio.count, privacy: .public) textChars=\(text.count, privacy: .public) fp=\(EdgeReadAloudClient.fingerprint(for: text), privacy: .public)"
            )
            let player = try AVAudioPlayer(data: audio)
            audioPlayer = player
            player.delegate = self
            player.enableRate = true
            player.rate = Float(ReaderPreferencesSnapshot.normalizedSpeechRate(rateMultiplier))
            player.prepareToPlay()
            AppLog.reader.error(
                "Edge Read Aloud trace: player ready duration=\(player.duration, privacy: .public) channels=\(player.numberOfChannels, privacy: .public) deviceTime=\(player.deviceCurrentTime, privacy: .public)"
            )
            scheduleRangeUpdates(
                for: text,
                player: player,
                speakRangeHandler: speakRangeHandler
            )

            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    if !player.play() {
                        AppLog.reader.error("Edge Read Aloud trace: player play returned false")
                        self.finish(.failure(.other(EdgeReadAloudError.audioPlaybackFailed)))
                    } else {
                        AppLog.reader.error("Edge Read Aloud trace: player play started")
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.stopPlayback()
                }
            }
        } catch {
            return .failure(.other(error))
        }
    }

    @MainActor
    private func scheduleRangeUpdates(
        for text: String,
        player: AVAudioPlayer,
        speakRangeHandler: NarrationSpeakRangeHandler
    ) {
        let chunks = NarrationTextChunker.chunks(in: text)
        let ranges = chunks.isEmpty ? [text.startIndex ..< text.endIndex] : chunks.map(\.range)
        let totalCharacters = max(text.count, 1)
        let duration = max(player.duration, 0.6)

        rangeTask?.cancel()
        rangeTask = Task { @MainActor in
            for range in ranges {
                guard !Task.isCancelled else {
                    return
                }

                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                let targetSeconds = duration * Double(offset) / Double(totalCharacters)
                while !Task.isCancelled, player.currentTime + 0.02 < targetSeconds {
                    try? await Task.sleep(for: .milliseconds(80))
                }

                guard !Task.isCancelled else {
                    return
                }
                speakRangeHandler(range)
            }
        }
    }

    @MainActor
    private func finish(_ result: Result<Void, TTSError>) {
        rangeTask?.cancel()
        rangeTask = nil
        audioPlayer = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            AppLog.reader.error("Edge Read Aloud trace: player finished successfully=\(flag, privacy: .public)")
            self?.finish(.success(()))
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            AppLog.reader.error(
                "Edge Read Aloud trace: player decode error=\(String(describing: error), privacy: .public)"
            )
            self?.finish(.failure(.other(error ?? EdgeReadAloudError.audioPlaybackFailed)))
        }
    }
}

struct EdgeReadAloudVoice: Sendable {
    let identifier: String
    let name: String
    let language: String
    let gender: TTSVoice.Gender

    var ttsVoice: TTSVoice {
        TTSVoice(
            identifier: identifier,
            language: Language(code: .bcp47(language)),
            name: name,
            gender: gender,
            quality: .higher
        )
    }

    static let defaultIdentifier = "zh-CN-XiaoxiaoNeural"
    static let englishFallbackIdentifier = "en-US-AriaNeural"

    static let available: [EdgeReadAloudVoice] = [
        EdgeReadAloudVoice(identifier: "zh-CN-XiaoxiaoNeural", name: "Xiaoxiao", language: "zh-CN", gender: .female),
        EdgeReadAloudVoice(identifier: "zh-CN-XiaoyiNeural", name: "Xiaoyi", language: "zh-CN", gender: .female),
        EdgeReadAloudVoice(identifier: "zh-CN-YunjianNeural", name: "Yunjian", language: "zh-CN", gender: .male),
        EdgeReadAloudVoice(identifier: "zh-CN-YunxiNeural", name: "Yunxi", language: "zh-CN", gender: .male),
        EdgeReadAloudVoice(identifier: "zh-CN-YunxiaNeural", name: "Yunxia", language: "zh-CN", gender: .male),
        EdgeReadAloudVoice(identifier: "zh-CN-YunyangNeural", name: "Yunyang", language: "zh-CN", gender: .male),
        EdgeReadAloudVoice(identifier: "zh-CN-liaoning-XiaobeiNeural", name: "Xiaobei", language: "zh-CN", gender: .female),
        EdgeReadAloudVoice(identifier: "zh-CN-shaanxi-XiaoniNeural", name: "Xiaoni", language: "zh-CN", gender: .female),
        EdgeReadAloudVoice(identifier: "zh-HK-HiuGaaiNeural", name: "HiuGaai", language: "zh-HK", gender: .female),
        EdgeReadAloudVoice(identifier: "zh-HK-HiuMaanNeural", name: "HiuMaan", language: "zh-HK", gender: .female),
        EdgeReadAloudVoice(identifier: "zh-HK-WanLungNeural", name: "WanLung", language: "zh-HK", gender: .male),
        EdgeReadAloudVoice(identifier: "zh-TW-HsiaoChenNeural", name: "HsiaoChen", language: "zh-TW", gender: .female),
        EdgeReadAloudVoice(identifier: "en-US-AriaNeural", name: "Aria", language: "en-US", gender: .female)
    ]
}

struct ReaderSpeechVoiceOption: Identifiable, Hashable, Sendable {
    let engine: ReaderPreferencesSnapshot.SpeechEngine
    let identifier: String
    let title: String
    let subtitle: String
    let badge: String?

    var id: String {
        "\(engine.rawValue):\(identifier)"
    }
}

struct ReaderSpeechVoiceSection: Identifiable, Sendable {
    let id: String
    let title: String
    let options: [ReaderSpeechVoiceOption]
}

enum ReaderSpeechVoiceCatalog {
    static func sections() -> [ReaderSpeechVoiceSection] {
        let edgeOptions = EdgeReadAloudVoice.available.map { voice in
            ReaderSpeechVoiceOption(
                engine: .edgeReadAloud,
                identifier: voice.identifier,
                title: voice.localizedTitle,
                subtitle: "Microsoft \(voice.language)",
                badge: "云端"
            )
        }

        let systemOptions = NarrationSpeechConfiguration.availableSystemVoices().map { voice in
            ReaderSpeechVoiceOption(
                engine: .system,
                identifier: voice.identifier,
                title: voice.name,
                subtitle: systemVoiceSubtitle(for: voice),
                badge: systemVoiceBadge(for: voice)
            )
        }

        return [
            ReaderSpeechVoiceSection(id: "edge", title: "微软 Edge", options: edgeOptions),
            ReaderSpeechVoiceSection(id: "system", title: "系统声音", options: systemOptions)
        ]
    }

    static func option(
        engine: ReaderPreferencesSnapshot.SpeechEngine,
        identifier: String
    ) -> ReaderSpeechVoiceOption? {
        sections()
            .flatMap(\.options)
            .first { $0.engine == engine && $0.identifier == identifier }
    }

    static func defaultIdentifier(for engine: ReaderPreferencesSnapshot.SpeechEngine) -> String {
        switch engine {
        case .system:
            return NarrationSpeechConfiguration.availableSystemVoices().first?.identifier
                ?? AVSpeechSynthesisVoice(language: NarrationSpeechConfiguration.defaultChineseLanguage)?.identifier
                ?? EdgeReadAloudVoice.defaultIdentifier
        case .edgeReadAloud:
            return EdgeReadAloudVoice.defaultIdentifier
        }
    }

    private static func systemVoiceSubtitle(for voice: AVSpeechSynthesisVoice) -> String {
        let languageName = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        let quality: String
        switch voice.quality {
        #if swift(>=5.7)
        case .premium:
            quality = "高级"
        #endif
        case .enhanced:
            quality = "增强"
        case .default:
            quality = voice.identifier.contains(".compact.") ? "紧凑" : "标准"
        @unknown default:
            quality = "系统"
        }
        return "\(languageName) · \(quality)"
    }

    private static func systemVoiceBadge(for voice: AVSpeechSynthesisVoice) -> String? {
        switch voice.quality {
        #if swift(>=5.7)
        case .premium:
            return "高级"
        #endif
        case .enhanced:
            return "增强"
        default:
            return nil
        }
    }
}

private extension EdgeReadAloudVoice {
    var supportsChineseText: Bool {
        language.hasPrefix("zh")
    }

    var localizedTitle: String {
        switch identifier {
        case "zh-CN-XiaoxiaoNeural":
            return "晓晓"
        case "zh-CN-XiaoyiNeural":
            return "晓伊"
        case "zh-CN-YunjianNeural":
            return "云健"
        case "zh-CN-YunxiNeural":
            return "云希"
        case "zh-CN-YunxiaNeural":
            return "云夏"
        case "zh-CN-YunyangNeural":
            return "云扬"
        case "zh-CN-liaoning-XiaobeiNeural":
            return "晓北"
        case "zh-CN-shaanxi-XiaoniNeural":
            return "晓妮"
        case "zh-HK-HiuGaaiNeural":
            return "晓佳"
        case "zh-HK-HiuMaanNeural":
            return "晓曼"
        case "zh-HK-WanLungNeural":
            return "云龙"
        case "zh-TW-HsiaoChenNeural":
            return "晓臻"
        case "en-US-AriaNeural":
            return "Aria"
        default:
            return name
        }
    }
}

private enum EdgeReadAloudClient {
    static func synthesize(text: String, voiceIdentifier: String) async throws -> Data {
        try await EdgeReadAloudAudioCache.shared.audio(text: text, voiceIdentifier: voiceIdentifier)
    }

    static func fingerprint(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(5).map { String(format: "%02X", $0) }.joined()
    }

    static func prefetch(entries: [(text: String, voiceIdentifier: String)]) {
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            await EdgeReadAloudAudioCache.shared.prefetch(entries: entries)
        }
    }

    fileprivate static func synthesizeWithRetry(text: String, voiceIdentifier: String) async throws -> Data {
        let chunks = text.edgeReadAloudPreparedChunks(maximumUTF8Bytes: maximumTextBytesPerRequest)
        AppLog.reader.error(
            "Edge Read Aloud trace: synthesize start voice=\(voiceIdentifier, privacy: .public) chars=\(text.count, privacy: .public) utf8=\(text.utf8.count, privacy: .public) fp=\(fingerprint(for: text), privacy: .public) chunks=\(chunks.count, privacy: .public) chunkSizes=\(chunkSizeSummary(chunks), privacy: .public)"
        )
        guard !chunks.isEmpty else {
            AppLog.reader.error("Edge Read Aloud trace: synthesize aborted empty prepared text")
            throw EdgeReadAloudError.emptyAudio
        }

        var audio = Data()
        for (index, chunk) in chunks.enumerated() {
            AppLog.reader.error(
                "Edge Read Aloud trace: synthesize chunk start index=\(index + 1, privacy: .public)/\(chunks.count, privacy: .public) chars=\(chunk.count, privacy: .public) utf8=\(chunk.utf8.count, privacy: .public) fp=\(fingerprint(for: chunk), privacy: .public)"
            )
            let chunkAudio = try await synthesizeRecoveringFromEmptyAudio(
                text: chunk,
                voiceIdentifier: voiceIdentifier
            )
            audio.append(chunkAudio)
            AppLog.reader.error(
                "Edge Read Aloud trace: synthesize chunk success index=\(index + 1, privacy: .public)/\(chunks.count, privacy: .public) bytes=\(chunkAudio.count, privacy: .public) totalBytes=\(audio.count, privacy: .public)"
            )
        }

        guard !audio.isEmpty else {
            AppLog.reader.error("Edge Read Aloud trace: synthesize finished with zero audio fp=\(fingerprint(for: text), privacy: .public)")
            throw EdgeReadAloudError.emptyAudio
        }
        AppLog.reader.error(
            "Edge Read Aloud trace: synthesize success fp=\(fingerprint(for: text), privacy: .public) totalBytes=\(audio.count, privacy: .public)"
        )
        return audio
    }

    private static func synthesizeRecoveringFromEmptyAudio(
        text: String,
        voiceIdentifier: String,
        splitDepth: Int = 0
    ) async throws -> Data {
        do {
            return try await synthesizeChunkWithRetry(text: text, voiceIdentifier: voiceIdentifier)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard error.isEdgeReadAloudEmptyAudio, splitDepth < maximumEmptyAudioSplitDepth else {
                throw error
            }

            let maximumCharacters = splitDepth == 0 ? 36 : 14
            let segments = text.edgeReadAloudRecoverySegments(maximumCharacters: maximumCharacters)
            guard segments.count > 1 else {
                AppLog.reader.error(
                    "Edge Read Aloud trace: empty audio recovery unavailable depth=\(splitDepth, privacy: .public) chars=\(text.count, privacy: .public) fp=\(fingerprint(for: text), privacy: .public)"
                )
                throw error
            }

            AppLog.reader.error(
                "Edge Read Aloud trace: empty audio; retrying \(segments.count, privacy: .public) shorter segments depth=\(splitDepth, privacy: .public) fp=\(fingerprint(for: text), privacy: .public) segmentSizes=\(chunkSizeSummary(segments), privacy: .public)"
            )

            var recoveredAudio = Data()
            var lastError: Error?
            for (index, segment) in segments.enumerated() {
                do {
                    AppLog.reader.error(
                        "Edge Read Aloud trace: recovery segment start depth=\(splitDepth + 1, privacy: .public) index=\(index + 1, privacy: .public)/\(segments.count, privacy: .public) chars=\(segment.count, privacy: .public) fp=\(fingerprint(for: segment), privacy: .public)"
                    )
                    let audio = try await synthesizeRecoveringFromEmptyAudio(
                        text: segment,
                        voiceIdentifier: voiceIdentifier,
                        splitDepth: splitDepth + 1
                    )
                    recoveredAudio.append(audio)
                    AppLog.reader.error(
                        "Edge Read Aloud trace: recovery segment success depth=\(splitDepth + 1, privacy: .public) index=\(index + 1, privacy: .public)/\(segments.count, privacy: .public) bytes=\(audio.count, privacy: .public)"
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    AppLog.reader.error(
                        "Edge Read Aloud trace: recovery segment failed depth=\(splitDepth + 1, privacy: .public) index=\(index + 1, privacy: .public)/\(segments.count, privacy: .public) fp=\(fingerprint(for: segment), privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
            }

            guard !recoveredAudio.isEmpty else {
                AppLog.reader.error(
                    "Edge Read Aloud trace: recovery produced zero audio depth=\(splitDepth, privacy: .public) fp=\(fingerprint(for: text), privacy: .public)"
                )
                throw lastError ?? error
            }
            AppLog.reader.error(
                "Edge Read Aloud trace: recovery success depth=\(splitDepth, privacy: .public) fp=\(fingerprint(for: text), privacy: .public) bytes=\(recoveredAudio.count, privacy: .public)"
            )
            return recoveredAudio
        }
    }

    private static func synthesizeChunkWithRetry(text: String, voiceIdentifier: String) async throws -> Data {
        var lastError: Error?
        for attempt in 0 ..< maximumSynthesisAttempts {
            do {
                AppLog.reader.error(
                    "Edge Read Aloud trace: attempt start attempt=\(attempt + 1, privacy: .public)/\(maximumSynthesisAttempts, privacy: .public) fp=\(fingerprint(for: text), privacy: .public)"
                )
                return try await synthesizeUncached(text: text, voiceIdentifier: voiceIdentifier)
            } catch is CancellationError {
                AppLog.reader.error(
                    "Edge Read Aloud trace: attempt cancelled attempt=\(attempt + 1, privacy: .public)/\(maximumSynthesisAttempts, privacy: .public) fp=\(fingerprint(for: text), privacy: .public)"
                )
                throw CancellationError()
            } catch {
                lastError = error
                AppLog.reader.error(
                    "Edge Read Aloud trace: attempt failed attempt=\(attempt + 1, privacy: .public)/\(maximumSynthesisAttempts, privacy: .public) fp=\(fingerprint(for: text), privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                guard attempt < maximumSynthesisAttempts - 1 else {
                    break
                }
                let delay = UInt64(180_000_000 * UInt64(attempt + 1))
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? EdgeReadAloudError.emptyAudio
    }

    fileprivate static func synthesizeUncached(text: String, voiceIdentifier: String) async throws -> Data {
        let connectionID = makeConnectionID()
        let requestID = makeConnectionID()
        var request = URLRequest(url: try websocketURL(connectionID: connectionID))
        request.addEdgeReadAloudHeaders()
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        let timestamp = edgeTimestamp()
        let traceID = requestID.prefix(8)
        let textFingerprint = fingerprint(for: text)
        AppLog.reader.error(
            "Edge Read Aloud trace: websocket start trace=\(traceID, privacy: .public) connection=\(connectionID.prefix(8), privacy: .public) request=\(requestID.prefix(8), privacy: .public) voice=\(voiceIdentifier, privacy: .public) chars=\(text.count, privacy: .public) utf8=\(text.utf8.count, privacy: .public) fp=\(textFingerprint, privacy: .public)"
        )

        var stringFrames = 0
        var binaryFrames = 0
        var audioFrames = 0
        var audioBytes = 0
        var metadataFrames = 0
        var responseFrames = 0
        var turnStartFrames = 0
        var nonAudioBinaryFrames = 0
        var emptyAudioBinaryFrames = 0
        var malformedBinaryFrames = 0
        var lastStringPath = "none"
        var lastBinaryPath = "none"
        var lastBinaryContentType = "none"
        var audio = Data()

        func statsSummary() -> String {
            "trace=\(traceID) fp=\(textFingerprint) strings=\(stringFrames) binaries=\(binaryFrames) audioFrames=\(audioFrames) audioBytes=\(audioBytes) metadata=\(metadataFrames) response=\(responseFrames) turnStart=\(turnStartFrames) nonAudioBinary=\(nonAudioBinaryFrames) emptyAudioBinary=\(emptyAudioBinaryFrames) malformedBinary=\(malformedBinaryFrames) lastStringPath=\(lastStringPath) lastBinaryPath=\(lastBinaryPath) lastBinaryContentType=\(lastBinaryContentType)"
        }

        do {
            try await task.sendAsync(.string(speechConfigMessage(timestamp: timestamp)))
            try await task.sendAsync(.string(ssmlMessage(
                requestID: requestID,
                timestamp: timestamp,
                text: text,
                voiceIdentifier: voiceIdentifier
            )))
            AppLog.reader.error(
                "Edge Read Aloud trace: websocket sent trace=\(traceID, privacy: .public) fp=\(textFingerprint, privacy: .public) timestamp=\(timestamp, privacy: .public)"
            )

            while !Task.isCancelled {
                switch try await task.receiveAsync() {
                case .data(let data):
                    binaryFrames += 1
                    let parsed = parseBinaryMessage(data)
                    lastBinaryPath = parsed.path ?? "none"
                    lastBinaryContentType = parsed.contentType ?? "none"
                    if parsed.isMalformed {
                        malformedBinaryFrames += 1
                        AppLog.reader.error(
                            "Edge Read Aloud trace: malformed binary frame \(statsSummary(), privacy: .public) rawBytes=\(data.count, privacy: .public)"
                        )
                    }
                    if parsed.path != "audio" {
                        nonAudioBinaryFrames += 1
                    }
                    if let chunk = parsed.audio {
                        if chunk.isEmpty {
                            emptyAudioBinaryFrames += 1
                        } else {
                            audioFrames += 1
                            audioBytes += chunk.count
                            if audioFrames == 1 {
                                AppLog.reader.error(
                                    "Edge Read Aloud trace: first audio frame \(statsSummary(), privacy: .public) payloadBytes=\(chunk.count, privacy: .public)"
                                )
                            }
                            audio.append(chunk)
                        }
                    }
                    if parsed.isTurnEnd {
                        guard !audio.isEmpty else {
                            AppLog.reader.error(
                                "Edge Read Aloud trace: empty audio at binary turn.end \(statsSummary(), privacy: .public)"
                            )
                            throw EdgeReadAloudError.emptyAudio
                        }
                        AppLog.reader.error(
                            "Edge Read Aloud trace: websocket success binary turn.end \(statsSummary(), privacy: .public)"
                        )
                        return audio
                    }
                case .string(let string):
                    stringFrames += 1
                    let path = parseStringPath(string)
                    lastStringPath = path ?? "none"
                    switch path {
                    case "audio.metadata":
                        metadataFrames += 1
                    case "response":
                        responseFrames += 1
                    case "turn.start":
                        turnStartFrames += 1
                    default:
                        break
                    }
                    if string.localizedCaseInsensitiveContains("error") {
                        AppLog.reader.error(
                            "Edge Read Aloud trace: websocket text contains error trace=\(traceID, privacy: .public) path=\(lastStringPath, privacy: .public) prefix=\(string.edgeReadAloudLogPrefix, privacy: .public)"
                        )
                    }
                    if string.contains("Path:turn.end") {
                        guard !audio.isEmpty else {
                            AppLog.reader.error(
                                "Edge Read Aloud trace: empty audio at text turn.end \(statsSummary(), privacy: .public)"
                            )
                            throw EdgeReadAloudError.emptyAudio
                        }
                        AppLog.reader.error(
                            "Edge Read Aloud trace: websocket success text turn.end \(statsSummary(), privacy: .public)"
                        )
                        return audio
                    }
                @unknown default:
                    AppLog.reader.error(
                        "Edge Read Aloud trace: websocket unknown frame \(statsSummary(), privacy: .public)"
                    )
                }
            }
            AppLog.reader.error(
                "Edge Read Aloud trace: websocket cancelled loop \(statsSummary(), privacy: .public)"
            )
            throw CancellationError()
        } catch is CancellationError {
            AppLog.reader.error(
                "Edge Read Aloud trace: websocket cancelled \(statsSummary(), privacy: .public)"
            )
            throw CancellationError()
        } catch {
            AppLog.reader.error(
                "Edge Read Aloud trace: websocket failed \(statsSummary(), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let edgeVersion = "143.0.3650.75"
    private static let secMSGECVersion = "1-143.0.3650.75"
    private static let maximumSynthesisAttempts = 3
    private static let maximumEmptyAudioSplitDepth = 2
    private static let maximumTextBytesPerRequest = 4096
    static let chromiumMajorVersion = edgeVersion.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "143"

    private static func websocketURL(connectionID: String) throws -> URL {
        let secMSGEC = makeSecMSGEC()
        let value = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedClientToken)&Sec-MS-GEC=\(secMSGEC)&Sec-MS-GEC-Version=\(secMSGECVersion)&ConnectionId=\(connectionID)"
        guard let url = URL(string: value) else {
            throw EdgeReadAloudError.invalidURL
        }
        return url
    }

    private static func speechConfigMessage(timestamp: String) -> String {
        [
            "X-Timestamp:\(timestamp)",
            "Content-Type:application/json; charset=utf-8",
            "Path:speech.config",
            "",
            #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#,
            ""
        ].joined(separator: "\r\n")
    }

    private static func ssmlMessage(
        requestID: String,
        timestamp: String,
        text: String,
        voiceIdentifier: String
    ) -> String {
        let escapedText = text.edgeReadAloudXMLEscaped
        let voiceLanguage = EdgeReadAloudVoice.available.first { $0.identifier == voiceIdentifier }?.language
            ?? NarrationSpeechConfiguration.defaultChineseLanguage
        let ssml = """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="\(voiceLanguage)"><voice name="\(voiceIdentifier)"><prosody pitch="+0Hz" rate="+0%" volume="+0%">\(escapedText)</prosody></voice></speak>
        """
        return [
            "X-RequestId:\(requestID)",
            "Content-Type:application/ssml+xml",
            "X-Timestamp:\(timestamp)Z",
            "Path:ssml",
            "",
            ssml
        ].joined(separator: "\r\n")
    }

    private static func parseBinaryMessage(_ data: Data) -> EdgeReadAloudBinaryMessage {
        guard data.count >= 2 else {
            return EdgeReadAloudBinaryMessage(
                audio: nil,
                isTurnEnd: false,
                path: nil,
                contentType: nil,
                isMalformed: true
            )
        }

        let headerLength = (Int(data[data.startIndex]) << 8) + Int(data[data.index(after: data.startIndex)])
        guard data.count >= headerLength + 2 else {
            return EdgeReadAloudBinaryMessage(
                audio: nil,
                isTurnEnd: false,
                path: nil,
                contentType: nil,
                isMalformed: true
            )
        }

        let headerStart = data.index(data.startIndex, offsetBy: 2)
        let headerEnd = data.index(headerStart, offsetBy: headerLength)
        let header = String(data: data[headerStart ..< headerEnd], encoding: .utf8) ?? ""
        let path = parseHeaderValue("Path", in: header)
        let contentType = parseHeaderValue("Content-Type", in: header)
        let isTurnEnd = path == "turn.end"
        guard path == "audio", headerEnd < data.endIndex else {
            return EdgeReadAloudBinaryMessage(
                audio: nil,
                isTurnEnd: isTurnEnd,
                path: path,
                contentType: contentType,
                isMalformed: false
            )
        }

        return EdgeReadAloudBinaryMessage(
            audio: Data(data[headerEnd ..< data.endIndex]),
            isTurnEnd: isTurnEnd,
            path: path,
            contentType: contentType,
            isMalformed: false
        )
    }

    private static func parseStringPath(_ string: String) -> String? {
        parseHeaderValue("Path", in: string)
    }

    private static func parseHeaderValue(_ name: String, in headers: String) -> String? {
        let prefix = "\(name):"
        return headers
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix(prefix) }
            .map { line in
                String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private static func chunkSizeSummary(_ chunks: [String]) -> String {
        let sizes = chunks.prefix(8).map { "\($0.count)/\($0.utf8.count)" }.joined(separator: ",")
        if chunks.count > 8 {
            return "\(sizes),..."
        }
        return sizes
    }

    private static func makeConnectionID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }

    private static func makeSecMSGEC(date: Date = Date()) -> String {
        let ticks = roundedWindowsTicks(date: date)
        let input = "\(ticks)\(trustedClientToken)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func roundedWindowsTicks(date: Date) -> UInt64 {
        let windowsEpochOffset: TimeInterval = 11_644_473_600
        let ticksPerSecond: TimeInterval = 10_000_000
        var ticks = UInt64((date.timeIntervalSince1970 + windowsEpochOffset) * ticksPerSecond)
        let fiveMinutesInTicks: UInt64 = 3_000_000_000
        ticks -= ticks % fiveMinutesInTicks
        return ticks
    }

    private static func edgeTimestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT'Z '(Coordinated Universal Time)'"
        return formatter.string(from: date)
    }
}

private enum EdgeReadAloudError: Error {
    case invalidURL
    case emptyAudio
    case audioPlaybackFailed
}

private struct EdgeReadAloudBinaryMessage {
    let audio: Data?
    let isTurnEnd: Bool
    let path: String?
    let contentType: String?
    let isMalformed: Bool
}

private extension Error {
    var isEdgeReadAloudEmptyAudio: Bool {
        if let edgeError = self as? EdgeReadAloudError,
           case .emptyAudio = edgeError {
            return true
        }
        return false
    }
}

private struct EdgeReadAloudAudioCacheKey: Hashable {
    let voiceIdentifier: String
    let text: String

    init(text: String, voiceIdentifier: String) {
        self.voiceIdentifier = voiceIdentifier
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private actor EdgeReadAloudAudioCache {
    static let shared = EdgeReadAloudAudioCache()

    private var audioByKey: [EdgeReadAloudAudioCacheKey: Data] = [:]
    private var inFlightByKey: [EdgeReadAloudAudioCacheKey: Task<Data, Error>] = [:]
    private var keyOrder: [EdgeReadAloudAudioCacheKey] = []
    private var queuedPrefetchKeys: [EdgeReadAloudAudioCacheKey] = []
    private var queuedPrefetchEntries: [EdgeReadAloudAudioCacheKey: (text: String, voiceIdentifier: String)] = [:]
    private var isPrefetchWorkerRunning = false
    private var activeForegroundSynthesisCount = 0
    private let maximumCachedItems = 96

    func audio(text: String, voiceIdentifier: String) async throws -> Data {
        let key = EdgeReadAloudAudioCacheKey(text: text, voiceIdentifier: voiceIdentifier)
        if let cached = audioByKey[key] {
            touch(key)
            AppLog.reader.error(
                "Edge Read Aloud trace: cache hit voice=\(voiceIdentifier, privacy: .public) fp=\(EdgeReadAloudClient.fingerprint(for: text), privacy: .public) bytes=\(cached.count, privacy: .public)"
            )
            return cached
        }

        if let task = inFlightByKey[key] {
            AppLog.reader.error(
                "Edge Read Aloud trace: cache waiting in-flight voice=\(voiceIdentifier, privacy: .public) fp=\(EdgeReadAloudClient.fingerprint(for: text), privacy: .public)"
            )
            return try await task.value
        }

        queuedPrefetchKeys.removeAll { $0 == key }
        queuedPrefetchEntries[key] = nil

        AppLog.reader.error(
            "Edge Read Aloud trace: cache miss voice=\(voiceIdentifier, privacy: .public) fp=\(EdgeReadAloudClient.fingerprint(for: text), privacy: .public)"
        )
        activeForegroundSynthesisCount += 1
        defer {
            activeForegroundSynthesisCount = max(0, activeForegroundSynthesisCount - 1)
            startPrefetchWorkerIfNeeded()
        }
        let task = Task<Data, Error> {
            try await EdgeReadAloudClient.synthesizeWithRetry(text: text, voiceIdentifier: voiceIdentifier)
        }
        inFlightByKey[key] = task

        do {
            let audio = try await task.value
            store(audio, for: key)
            inFlightByKey[key] = nil
            AppLog.reader.error(
                "Edge Read Aloud trace: cache store voice=\(voiceIdentifier, privacy: .public) fp=\(EdgeReadAloudClient.fingerprint(for: text), privacy: .public) bytes=\(audio.count, privacy: .public)"
            )
            return audio
        } catch {
            inFlightByKey[key] = nil
            AppLog.reader.error(
                "Edge Read Aloud trace: cache synthesis failed voice=\(voiceIdentifier, privacy: .public) fp=\(EdgeReadAloudClient.fingerprint(for: text), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    func prefetch(entries: [(text: String, voiceIdentifier: String)]) {
        for entry in entries {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let key = EdgeReadAloudAudioCacheKey(text: trimmed, voiceIdentifier: entry.voiceIdentifier)
            guard audioByKey[key] == nil,
                  inFlightByKey[key] == nil,
                  queuedPrefetchEntries[key] == nil
            else {
                continue
            }

            queuedPrefetchEntries[key] = (trimmed, entry.voiceIdentifier)
            queuedPrefetchKeys.append(key)
        }
        let queuedCount = queuedPrefetchKeys.count
        let foregroundCount = activeForegroundSynthesisCount
        AppLog.reader.error(
            "Edge Read Aloud trace: prefetch queued count=\(queuedCount, privacy: .public) activeForeground=\(foregroundCount, privacy: .public)"
        )
        startPrefetchWorkerIfNeeded()
    }

    private func finishPrefetch(audio: Data, for key: EdgeReadAloudAudioCacheKey) {
        store(audio, for: key)
        inFlightByKey[key] = nil
    }

    private func clearPrefetch(for key: EdgeReadAloudAudioCacheKey) {
        inFlightByKey[key] = nil
    }

    private func startPrefetchWorkerIfNeeded() {
        guard !isPrefetchWorkerRunning else {
            return
        }
        guard activeForegroundSynthesisCount == 0 else {
            return
        }
        isPrefetchWorkerRunning = true
        Task { [weak self] in
            while let next = await self?.nextPrefetchTask() {
                do {
                    let audio = try await next.task.value
                    await self?.finishPrefetch(audio: audio, for: next.key)
                } catch {
                    await self?.clearPrefetch(for: next.key)
                }
            }
            await self?.finishPrefetchWorker()
        }
    }

    private func nextPrefetchTask() -> (key: EdgeReadAloudAudioCacheKey, task: Task<Data, Error>)? {
        while !queuedPrefetchKeys.isEmpty {
            let key = queuedPrefetchKeys.removeFirst()
            guard audioByKey[key] == nil,
                  inFlightByKey[key] == nil,
                  let entry = queuedPrefetchEntries.removeValue(forKey: key)
            else {
                queuedPrefetchEntries[key] = nil
                continue
            }

            let task = Task<Data, Error> {
                try await EdgeReadAloudClient.synthesizeWithRetry(
                    text: entry.text,
                    voiceIdentifier: entry.voiceIdentifier
                )
            }
            inFlightByKey[key] = task
            return (key, task)
        }
        return nil
    }

    private func finishPrefetchWorker() {
        isPrefetchWorkerRunning = false
        if !queuedPrefetchKeys.isEmpty {
            startPrefetchWorkerIfNeeded()
        }
    }

    private func store(_ audio: Data, for key: EdgeReadAloudAudioCacheKey) {
        audioByKey[key] = audio
        touch(key)
        while keyOrder.count > maximumCachedItems {
            let removed = keyOrder.removeFirst()
            audioByKey[removed] = nil
        }
    }

    private func touch(_ key: EdgeReadAloudAudioCacheKey) {
        keyOrder.removeAll { $0 == key }
        keyOrder.append(key)
    }
}

private extension URLRequest {
    mutating func addEdgeReadAloudHeaders() {
        let chromiumMajorVersion = EdgeReadAloudClient.chromiumMajorVersion
        setValue("no-cache", forHTTPHeaderField: "Pragma")
        setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/\(chromiumMajorVersion).0.0.0 Safari/537.36 " +
                "Edg/\(chromiumMajorVersion).0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        setValue("muid=\(Self.edgeReadAloudMUID());", forHTTPHeaderField: "Cookie")
    }

    private static func edgeReadAloudMUID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }
}

private extension URLSessionWebSocketTask {
    func sendAsync(_ message: URLSessionWebSocketTask.Message) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(message) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func receiveAsync() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            receive { result in
                continuation.resume(with: result)
            }
        }
    }
}

private extension String {
    var edgeReadAloudLogPrefix: String {
        let collapsed = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(220))
    }

    func edgeReadAloudRecoverySegments(maximumCharacters: Int) -> [String] {
        guard maximumCharacters > 0 else {
            return [self]
        }

        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var segments: [String] = []
        var start = trimmed.startIndex
        var current = start
        let preferredBoundaries = Set<Character>("。！？!?；;：:\n，、,")

        func appendSegment(upTo end: String.Index) {
            let segment = String(trimmed[start ..< end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(segment)
            }
            start = end
            current = end
        }

        while current < trimmed.endIndex {
            let character = trimmed[current]
            let next = trimmed.index(after: current)
            let length = trimmed.distance(from: start, to: next)
            if preferredBoundaries.contains(character) || length >= maximumCharacters {
                appendSegment(upTo: next)
            } else {
                current = next
            }
        }

        if start < trimmed.endIndex {
            appendSegment(upTo: trimmed.endIndex)
        }

        return segments
    }

    func edgeReadAloudPreparedChunks(maximumUTF8Bytes: Int) -> [String] {
        let sanitized = edgeReadAloudRemovingIncompatibleCharacters
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return []
        }
        guard sanitized.utf8.count > maximumUTF8Bytes else {
            return [sanitized]
        }

        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        var lastPreferredSplit: String.Index?

        func flush(upTo splitIndex: String.Index? = nil) {
            let flushed: String
            if let splitIndex {
                flushed = String(current[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                current = String(current[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                currentBytes = current.utf8.count
                lastPreferredSplit = current.firstIndex(where: { $0.isWhitespace || $0.isNewline })
            } else {
                flushed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                current = ""
                currentBytes = 0
                lastPreferredSplit = nil
            }

            if !flushed.isEmpty {
                chunks.append(flushed)
            }
        }

        for character in sanitized {
            let characterBytes = String(character).utf8.count
            if currentBytes + characterBytes > maximumUTF8Bytes {
                if let split = lastPreferredSplit, split > current.startIndex {
                    flush(upTo: split)
                } else {
                    flush()
                }
            }

            current.append(character)
            currentBytes += characterBytes
            if character.isWhitespace || character.isNewline {
                lastPreferredSplit = current.index(before: current.endIndex)
            }
        }

        flush()
        return chunks
    }

    var edgeReadAloudRemovingIncompatibleCharacters: String {
        var scalars = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0 ... 8, 11 ... 12, 14 ... 31:
                scalars.append(UnicodeScalar(32)!)
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    var edgeReadAloudXMLEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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

    static func listeningAutoAdvanceBottomInset(for view: UIView?) -> CGFloat {
        safeInsets(for: view).bottom + 88
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
    func showSearchHighlight(locatorData: Data, query: String) async
    func goToTableOfContentsItem(_ itemID: String) async throws
    func applyPreferences(_ snapshot: ReaderPreferencesSnapshot) async
    func startListening() async
    func pauseOrResumeListening()
    func skipToPreviousListening()
    func skipToNextListening()
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
    private var listeningDoubleTapRecognizer: UITapGestureRecognizer?
    private var configuredUserContentControllerIDs: Set<ObjectIdentifier> = []
    private var pageTurnMode: ReaderPreferencesSnapshot.PageTurnMode
    private var speechEngine: ReaderPreferencesSnapshot.SpeechEngine
    private var speechVoiceIdentifier: String
    private var speechRate: Double
    private var speechSynthesizer: PublicationSpeechSynthesizer?
    private var currentSpokenLocatorData: Data?
    private var currentSpokenDecorationLocatorData: Data?
    private var spokenDOMHighlightGeneration = 0
    private var searchHighlightVisibleSince: Date?
    private var visualSpeechTask: Task<Void, Never>?
    private var visualSpeechEngine: EPUBVisualSpeechEngine?
    private var visualSpeechCurrentChunk: EPUBVisualSpeechChunk?
    private var visualSpeechCurrentTitle: String?
    private var visualSpeechGeneration = UUID()
    private var visualSpeechRemainingChunkCount = 0

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
        self.speechEngine = preferences.speechEngine
        self.speechVoiceIdentifier = preferences.speechVoiceIdentifier
        self.speechRate = preferences.speechRate
        let locator = try initialLocatorData.map { try LocatorCoding.decode($0) }
        navigator = try EPUBNavigatorViewController(
            publication: publicationHandle.publication,
            initialLocation: locator,
            config: EPUBNavigatorViewController.Configuration(
                preferences: preferences.makeEPUBPreferences(),
                disablePageTurnsWhileScrolling: true,
                decorationTemplates: Self.ttsDecorationTemplates()
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

    func showSearchHighlight(locatorData: Data, query: String) async {
        guard let locator = try? LocatorCoding.decode(locatorData) else {
            return
        }
        try? await Task.sleep(for: .milliseconds(220))
        applySearchDOMHighlight(to: locator, query: query)
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
        let didChangeSpeechEngine = speechEngine != snapshot.speechEngine
            || speechVoiceIdentifier != snapshot.speechVoiceIdentifier
        pageTurnMode = snapshot.pageTurnMode
        speechEngine = snapshot.speechEngine
        speechVoiceIdentifier = snapshot.speechVoiceIdentifier
        speechRate = snapshot.speechRate
        speechSynthesizer?.config = NarrationSpeechConfiguration.publicationConfiguration(
            publicationLanguage: publicationHandle.publication.metadata.language,
            voiceIdentifier: speechVoiceIdentifier,
            rateMultiplier: speechRate
        )
        speechSynthesizer?.updateRateMultiplier(speechRate)
        visualSpeechEngine?.updatePlaybackRate(speechRate)
        if didChangeSpeechEngine {
            stopVisualSpeech()
            speechSynthesizer?.stop()
            speechSynthesizer = nil
        }
        navigator.submitPreferences(snapshot.makeEPUBPreferences())
        updateControlledPagingGestures()
    }

    func startListening() async {
        guard let synthesizer = makeSpeechSynthesizer() else {
            onListeningStateChanged?(.inactive)
            return
        }

        clearSearchHighlight()
        clearSpokenDecoration()
        await startListening(from: nil, using: synthesizer)
    }

    func pauseOrResumeListening() {
        if let visualSpeechEngine {
            visualSpeechEngine.pauseOrResume()
            notifyVisualSpeechState(isPlaying: visualSpeechEngine.isPlaying)
        } else {
            speechSynthesizer?.pauseOrResume()
        }
    }

    func skipToPreviousListening() {
        guard visualSpeechEngine == nil else {
            return
        }
        speechSynthesizer?.previous()
    }

    func skipToNextListening() {
        guard visualSpeechEngine == nil else {
            return
        }
        speechSynthesizer?.next()
    }

    func focusListeningPosition() async {
        if let visualSpeechCurrentChunk {
            await applyVisualSpeechHighlight(visualSpeechCurrentChunk, center: true)
            return
        }

        guard let currentSpokenLocatorData,
              let locator = try? LocatorCoding.decode(currentSpokenLocatorData)
        else {
            return
        }
        await navigateToSpokenLocator(locator)
    }

    func stopListening() {
        stopVisualSpeech()
        speechSynthesizer?.stop()
        clearSpokenDecoration()
        currentSpokenLocatorData = nil
        currentSpokenDecorationLocatorData = nil
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
        if let listeningDoubleTapRecognizer {
            navigator.view.removeGestureRecognizer(listeningDoubleTapRecognizer)
        }
        listeningDoubleTapRecognizer = nil
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
        guard let speechSynthesizer = PublicationSpeechSynthesizer(
            publication: publicationHandle.publication,
            config: NarrationSpeechConfiguration.publicationConfiguration(
                publicationLanguage: publicationHandle.publication.metadata.language,
                voiceIdentifier: speechVoiceIdentifier,
                rateMultiplier: speechRate
            ),
            engineFactory: { [speechEngine, speechVoiceIdentifier] in
                switch speechEngine {
                case .system:
                    return NarrationExpressiveAVTTSEngine()
                case .edgeReadAloud:
                    return EdgeReadAloudTTSEngine(voiceIdentifier: speechVoiceIdentifier)
                }
            },
            tokenizerFactory: Self.speechTokenizerFactory(for: speechEngine)
        ) else {
            return nil
        }
        warmUpSpeechSynthesizerEngine(speechSynthesizer)
        speechSynthesizer.delegate = self
        self.speechSynthesizer = speechSynthesizer
        return speechSynthesizer
    }

    private func startVisualListening(from point: CGPoint?) async -> Bool {
        guard let chunks = await visualSpeechChunks(at: point),
              !chunks.isEmpty
        else {
            return false
        }

        NarrationSpeechConfiguration.configureAudioSession()
        speechSynthesizer?.stop()
        speechSynthesizer = nil
        currentSpokenLocatorData = nil
        currentSpokenDecorationLocatorData = nil
        clearSearchHighlight()
        clearSpokenDecoration()
        stopVisualSpeech(clearHighlight: false)

        let engine = makeVisualSpeechEngine()
        visualSpeechEngine = engine
        visualSpeechCurrentTitle = navigator.currentLocation?.title?.nilIfEmpty ?? publicationHandle.title
        visualSpeechRemainingChunkCount = chunks.count
        let generation = UUID()
        visualSpeechGeneration = generation
        visualSpeechTask = Task { @MainActor [weak self] in
            await self?.playVisualSpeechChunks(chunks, generation: generation)
        }
        return true
    }

    private func makeVisualSpeechEngine() -> EPUBVisualSpeechEngine {
        switch speechEngine {
        case .system:
            return .system(NarrationExpressiveAVTTSEngine())
        case .edgeReadAloud:
            return .edge(EdgeReadAloudTTSEngine(voiceIdentifier: speechVoiceIdentifier))
        }
    }

    private func playVisualSpeechChunks(_ chunks: [EPUBVisualSpeechChunk], generation: UUID) async {
        for (index, chunk) in chunks.enumerated() {
            guard !Task.isCancelled,
                  generation == visualSpeechGeneration
            else {
                return
            }

            visualSpeechCurrentChunk = chunk
            visualSpeechRemainingChunkCount = chunks.count - index
            await applyVisualSpeechHighlight(chunk, center: true)
            notifyVisualSpeechState(isPlaying: true)

            guard let visualSpeechEngine else {
                return
            }

            let utterance = visualSpeechUtterance(for: chunk, engine: visualSpeechEngine.ttsEngine)
            let result = await visualSpeechEngine.ttsEngine.speak(utterance) { _ in }

            guard !Task.isCancelled,
                  generation == visualSpeechGeneration
            else {
                return
            }

            if case .failure(let error) = result {
                AppLog.reader.error("EPUB visual TTS error: \(String(describing: error), privacy: .public)")
                notifyVisualSpeechState(isPlaying: false)
                return
            }
        }

        guard generation == visualSpeechGeneration else {
            return
        }
        visualSpeechTask = nil
        visualSpeechEngine = nil
        visualSpeechCurrentChunk = nil
        visualSpeechRemainingChunkCount = 0
        clearVisualSpeechHighlight()
        onListeningStateChanged?(.inactive)
    }

    private func visualSpeechUtterance(for chunk: EPUBVisualSpeechChunk, engine: TTSEngine) -> TTSUtterance {
        let languageIdentifier = NarrationSpeechConfiguration.preferredLanguageIdentifier(
            for: chunk.text,
            languageHint: publicationHandle.publication.metadata.language?.code.bcp47
        )
        let language = Language(code: .bcp47(languageIdentifier))
        let voiceOrLanguage: Either<TTSVoice, Language>
        if let voice = engine.voiceWithIdentifier(speechVoiceIdentifier) {
            voiceOrLanguage = .left(voice)
        } else {
            voiceOrLanguage = .right(language)
        }
        return TTSUtterance(
            text: chunk.text,
            delay: 0.02,
            voiceOrLanguage: voiceOrLanguage,
            rateMultiplier: speechRate
        )
    }

    private func notifyVisualSpeechState(isPlaying: Bool) {
        guard let chunk = visualSpeechCurrentChunk else {
            return
        }
        onListeningStateChanged?(
            ReaderListeningState(
                isActive: true,
                isPlaying: isPlaying,
                isLoading: false,
                chapterTitle: visualSpeechCurrentTitle ?? publicationHandle.title,
                utteranceText: chunk.text.readerCollapsedWhitespace,
                locatorData: currentLocatorData,
                remainingSeconds: max(4, visualSpeechRemainingChunkCount * 4)
            )
        )
    }

    private func stopVisualSpeech(clearHighlight: Bool = true) {
        visualSpeechGeneration = UUID()
        visualSpeechTask?.cancel()
        visualSpeechTask = nil
        visualSpeechEngine?.stopPlayback()
        visualSpeechEngine = nil
        visualSpeechCurrentChunk = nil
        visualSpeechCurrentTitle = nil
        visualSpeechRemainingChunkCount = 0
        if clearHighlight {
            clearVisualSpeechHighlight()
        }
    }

    private func visualSpeechChunks(at point: CGPoint?) async -> [EPUBVisualSpeechChunk]? {
        let topInset = ReaderChromeLayoutMetrics.topReadingInset(for: navigator.view)
        let bottomInset = ReaderChromeLayoutMetrics.bottomReadingInset(for: navigator.view)
        let readableBottom = max(topInset + 80, navigator.view.bounds.height - bottomInset)
        let targetY: CGFloat
        if let point {
            targetY = point.y.clamped(to: topInset ... readableBottom)
        } else {
            targetY = (topInset + readableBottom) / 2
        }
        let maxX = max(navigator.view.bounds.width, 1)
        let targetX = (point?.x ?? navigator.view.bounds.midX).clamped(to: 0 ... maxX)
        let script = Self.visualSpeechExtractionScript(
            topInset: topInset,
            bottomInset: bottomInset,
            targetX: targetX,
            targetY: targetY
        )

        switch await navigator.evaluateJavaScript(script) {
        case .success(let value):
            return Self.visualSpeechChunks(from: value)
        case .failure(let error):
            AppLog.reader.error("EPUB visual TTS extraction failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func applyVisualSpeechHighlight(_ chunk: EPUBVisualSpeechChunk, center: Bool) async {
        let topInset = ReaderChromeLayoutMetrics.topReadingInset(for: navigator.view)
        let bottomInset = ReaderChromeLayoutMetrics.bottomReadingInset(for: navigator.view)
        let script = Self.visualSpeechHighlightScript(
            chunk: chunk,
            topInset: topInset,
            bottomInset: bottomInset,
            center: center
        )

        switch await navigator.evaluateJavaScript(script) {
        case .success:
            break
        case .failure(let error):
            AppLog.reader.error("EPUB visual TTS highlight failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func clearVisualSpeechHighlight() {
        spokenDOMHighlightGeneration += 1
        let generation = spokenDOMHighlightGeneration
        let script = Self.clearVisualSpeechHighlightScript(generation: generation)
        Task { @MainActor [weak self] in
            _ = await self?.navigator.evaluateJavaScript(script)
        }
    }

    private func startListening(from point: CGPoint?, using synthesizer: PublicationSpeechSynthesizer) async {
        if let locator = await readableLocator(at: point) {
            synthesizer.start(from: locator)
        } else if let locator = await navigator.firstVisibleElementLocator() {
            synthesizer.start(from: locator)
        } else {
            synthesizer.start(from: navigator.currentLocation)
        }
    }

    private func readableLocator(at point: CGPoint?) async -> Locator? {
        let topInset = ReaderChromeLayoutMetrics.topReadingInset(for: navigator.view)
        let bottomInset = ReaderChromeLayoutMetrics.bottomReadingInset(for: navigator.view)
        let readableBottom = max(topInset + 80, navigator.view.bounds.height - bottomInset)
        let targetY: CGFloat
        if let point {
            targetY = point.y.clamped(to: topInset ... readableBottom)
        } else {
            targetY = (topInset + readableBottom) / 2
        }
        let maxX = max(navigator.view.bounds.width, 1)
        let targetX = (point?.x ?? navigator.view.bounds.midX).clamped(to: 0 ... maxX)
        let script = Self.readableLocatorScript(
            topInset: topInset,
            bottomInset: bottomInset,
            targetX: targetX,
            targetY: targetY
        )

        let rawLocator: Locator?
        switch await navigator.evaluateJavaScript(script) {
        case .success(let value):
            rawLocator = Self.locator(fromJavaScriptValue: value)
        case .failure(let error):
            AppLog.reader.error("EPUB TTS readable locator lookup failed: \(String(describing: error), privacy: .public)")
            rawLocator = nil
        }

        guard let rawLocator else {
            return nil
        }

        let baseLocator: Locator?
        if let currentLocation = navigator.currentLocation {
            baseLocator = currentLocation
        } else {
            baseLocator = await navigator.firstVisibleElementLocator()
        }
        guard let baseLocator else {
            return rawLocator
        }

        return rawLocator.copy(
            href: baseLocator.href,
            mediaType: baseLocator.mediaType,
            locations: { locations in
                locations.progression = baseLocator.locations.progression
                locations.totalProgression = baseLocator.locations.totalProgression
                locations.position = baseLocator.locations.position
            }
        )
    }

    private func updateSpokenUtterance(
        _ utterance: PublicationSpeechSynthesizer.Utterance,
        rangeLocator: Locator? = nil,
        isPlaying: Bool
    ) {
        let spokenLocator = rangeLocator ?? utterance.locator
        let locatorData = try? LocatorCoding.encode(spokenLocator)
        let shouldApplyReadiumDecoration = rangeLocator != nil || !isPlaying
        if shouldApplyReadiumDecoration {
            currentSpokenLocatorData = locatorData
        }
        if shouldApplyReadiumDecoration, locatorData != currentSpokenDecorationLocatorData {
            clearVisualSpeechHighlight()
            currentSpokenDecorationLocatorData = locatorData
            navigator.apply(
                decorations: [
                    Decoration(
                        id: Self.ttsDecorationID,
                        locator: spokenLocator,
                        style: .highlight(tint: Self.ttsHighlightTint)
                    )
                ],
                in: Self.ttsDecorationGroup
            )
        }
        if isPlaying, rangeLocator != nil {
            applySpokenDecorationViewportAdjustment(scrollPolicy: .threshold)
        }

        onListeningStateChanged?(
            ReaderListeningState(
                isActive: true,
                isPlaying: isPlaying,
                isLoading: isPlaying && rangeLocator == nil,
                chapterTitle: spokenLocator.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? utterance.locator.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? publicationHandle.title,
                utteranceText: spokenLocator.text.highlight?.readerCollapsedWhitespace.nilIfEmpty
                    ?? utterance.text.readerCollapsedWhitespace,
                locatorData: locatorData,
                remainingSeconds: Self.estimatedRemainingSeconds(for: spokenLocator)
            )
        )
    }

    private func clearSpokenDecoration() {
        navigator.apply(decorations: [], in: Self.ttsDecorationGroup)
        currentSpokenDecorationLocatorData = nil
        clearVisualSpeechHighlight()
    }

    private func clearSearchHighlight() {
        searchHighlightVisibleSince = nil
        navigator.apply(decorations: [], in: Self.searchDecorationGroup)
        Task { @MainActor [weak self] in
            _ = await self?.navigator.evaluateJavaScript(Self.clearSearchHighlightScript)
        }
    }

    private func clearSearchHighlightFromUserActivation() {
        if let searchHighlightVisibleSince,
           Date().timeIntervalSince(searchHighlightVisibleSince) < 0.8 {
            return
        }
        clearSearchHighlight()
    }

    private func navigateToSpokenLocator(_ locator: Locator) async {
        _ = await navigator.go(to: locator, options: .none)
        applySpokenDOMHighlight(to: locator, scrollPolicy: .center, drawsHighlight: true)
    }

    private func applySearchDOMHighlight(to locator: Locator, query: String) {
        let highlight = locator.text.highlight?.readerCollapsedWhitespace.nilIfEmpty
        let selector = locator.locations.cssSelector
        let topInset = ReaderChromeLayoutMetrics.topReadingInset(for: navigator.view)
        let bottomInset = ReaderChromeLayoutMetrics.bottomReadingInset(for: navigator.view)
        let script = Self.searchDOMHighlightScript(
            text: highlight ?? query,
            fallbackQuery: query,
            selector: selector,
            topInset: topInset,
            bottomInset: bottomInset
        )
        searchHighlightVisibleSince = Date()
        navigator.apply(
            decorations: [
                Decoration(
                    id: Self.searchDecorationID,
                    locator: locator,
                    style: .highlight(tint: Self.searchHighlightTint)
                )
            ],
            in: Self.searchDecorationGroup
        )
        Task { @MainActor [weak self] in
            switch await self?.navigator.evaluateJavaScript(script) {
            case .success:
                break
            case .failure(let error):
                AppLog.reader.error("EPUB search DOM highlight failed: \(String(describing: error), privacy: .public)")
            case nil:
                break
            }
        }
    }

    private func applySpokenDOMHighlight(
        to locator: Locator,
        scrollPolicy: SpokenHighlightScrollPolicy,
        drawsHighlight: Bool
    ) {
        let text = locator.text.highlight?.readerCollapsedWhitespace.nilIfEmpty
        let selector = locator.locations.cssSelector
        guard text != nil || selector != nil else {
            return
        }
        let topInset = ReaderChromeLayoutMetrics.topReadingInset(for: navigator.view)
        let bottomInset = ReaderChromeLayoutMetrics.bottomReadingInset(for: navigator.view)
        spokenDOMHighlightGeneration += 1
        let generation = spokenDOMHighlightGeneration
        let script = Self.spokenDOMHighlightScript(
            text: text,
            selector: selector,
            topInset: topInset,
            bottomInset: bottomInset,
            scrollPolicy: scrollPolicy,
            drawsHighlight: drawsHighlight,
            generation: generation
        )
        Task { @MainActor [weak self] in
            switch await self?.navigator.evaluateJavaScript(script) {
            case .success:
                break
            case .failure(let error):
                AppLog.reader.error("EPUB spoken DOM highlight failed: \(String(describing: error), privacy: .public)")
            case nil:
                break
            }
        }
    }

    private func applySpokenDecorationViewportAdjustment(scrollPolicy: SpokenHighlightScrollPolicy) {
        let topInset = ReaderChromeLayoutMetrics.topReadingInset(for: navigator.view)
        let bottomInset = ReaderChromeLayoutMetrics.bottomReadingInset(for: navigator.view)
        spokenDOMHighlightGeneration += 1
        let generation = spokenDOMHighlightGeneration
        let script = Self.spokenDecorationViewportScript(
            topInset: topInset,
            bottomInset: bottomInset,
            scrollPolicy: scrollPolicy,
            generation: generation
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, self.spokenDOMHighlightGeneration == generation else {
                return
            }
            switch await self.navigator.evaluateJavaScript(script) {
            case .success:
                break
            case .failure(let error):
                AppLog.reader.error("EPUB spoken decoration scroll failed: \(String(describing: error), privacy: .public)")
            }
        }
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

    nonisolated fileprivate static func speechTokenizerFactory(
        for engine: ReaderPreferencesSnapshot.SpeechEngine
    ) -> PublicationSpeechSynthesizer.TokenizerFactory {
        switch engine {
        case .system:
            return PublicationSpeechSynthesizer.defaultTokenizerFactory
        case .edgeReadAloud:
            return { defaultLanguage in
                makeTextContentTokenizer(
                    defaultLanguage: defaultLanguage,
                    contextSnippetLength: 50,
                    textTokenizerFactory: { language in
                        Self.edgeReadAloudTextTokenizer(language: language)
                    }
                )
            }
        }
    }

    nonisolated private static func edgeReadAloudTextTokenizer(language: Language?) -> TextTokenizer {
        let paragraphTokenizer = makeDefaultTextTokenizer(unit: .paragraph, language: language)

        return { text in
            let paragraphRanges = try paragraphTokenizer(text)
            return paragraphRanges.flatMap { paragraphRange in
                Self.edgeReadAloudChunkRanges(in: text, paragraphRange: paragraphRange)
            }
        }
    }

    nonisolated private static func edgeReadAloudChunkRanges(
        in text: String,
        paragraphRange: Range<String.Index>
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = paragraphRange.lowerBound
        var current = start
        var lastSoftBoundary = start

        func appendRange(endingAt end: String.Index) {
            let trimmedRange = text[start ..< end].trimmingRange(in: text)
            if trimmedRange.lowerBound < trimmedRange.upperBound {
                ranges.append(trimmedRange)
            }
            start = end
            current = end
            lastSoftBoundary = end
        }

        while current < paragraphRange.upperBound {
            let character = text[current]
            let next = text.index(after: current)
            let length = text.distance(from: start, to: next)

            if edgeReadAloudSoftBoundaries.contains(character) {
                lastSoftBoundary = next
            }

            if edgeReadAloudStrongBoundaries.contains(character),
               length >= edgeReadAloudMinimumStrongBoundaryCharacters {
                appendRange(endingAt: next)
                continue
            }

            if length >= edgeReadAloudMaximumChunkCharacters {
                let end = lastSoftBoundary > start ? lastSoftBoundary : next
                appendRange(endingAt: end)
                continue
            }

            current = next
        }

        if start < paragraphRange.upperBound {
            appendRange(endingAt: paragraphRange.upperBound)
        }

        return ranges
    }

    nonisolated private static let edgeReadAloudMaximumChunkCharacters = 280
    nonisolated private static let edgeReadAloudMinimumStrongBoundaryCharacters = 120
    nonisolated private static let edgeReadAloudStrongBoundaries = Set("。！？!?；;\n")
    nonisolated private static let edgeReadAloudSoftBoundaries = Set("，、,。：: 　")

    private static let ttsDecorationGroup: DecorationGroup = "offline-reader-tts"
    private static let ttsDecorationID = "offline-reader-current-utterance"
    private static let searchDecorationGroup: DecorationGroup = "offline-reader-search"
    private static let searchDecorationID = "offline-reader-search-result"
    static let ttsHighlightTint = UIColor(red: 0.55, green: 0.78, blue: 0.96, alpha: 1)
    static let searchHighlightTint = UIColor(red: 0.55, green: 0.78, blue: 0.96, alpha: 1)
    static let ttsHighlightFill = UIColor(red: 0.55, green: 0.78, blue: 0.96, alpha: 0.46)
    static let ttsHighlightOverlayFill = UIColor(red: 0.48, green: 0.76, blue: 0.98, alpha: 0.38)

    private static func ttsDecorationTemplates() -> [Decoration.Style.Id: HTMLDecorationTemplate] {
        HTMLDecorationTemplate.defaultTemplates(
            defaultTint: ttsHighlightTint,
            lineWeight: 0,
            cornerRadius: 1,
            alpha: 0.50
        )
    }

    private static func locator(fromJavaScriptValue value: Any) -> Locator? {
        guard
            let json = JSONValue(value),
            let locator = try? Locator(json: json, warnings: nil)
        else {
            return nil
        }
        return locator
    }

    private static func visualSpeechChunks(from value: Any) -> [EPUBVisualSpeechChunk]? {
        guard let payload = value as? [String: Any],
              let rawChunks = payload["chunks"] as? [[String: Any]]
        else {
            return nil
        }

        return rawChunks.compactMap { chunk in
            guard let text = chunk["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let startPayload = chunk["start"] as? [String: Any],
                  let endPayload = chunk["end"] as? [String: Any],
                  let start = visualSpeechPoint(from: startPayload),
                  let end = visualSpeechPoint(from: endPayload)
            else {
                return nil
            }
            return EPUBVisualSpeechChunk(text: text, start: start, end: end)
        }
    }

    private static func visualSpeechPoint(from value: [String: Any]) -> EPUBVisualSpeechPoint? {
        guard let selector = value["selector"] as? String,
              let textNodeIndex = value["textNodeIndex"] as? Int,
              let offset = value["offset"] as? Int
        else {
            return nil
        }
        return EPUBVisualSpeechPoint(
            selector: selector,
            textNodeIndex: textNodeIndex,
            offset: offset
        )
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2
        else {
            return "\"\""
        }
        return String(arrayLiteral.dropFirst().dropLast())
    }

    private static func visualSpeechExtractionScript(
        topInset: CGFloat,
        bottomInset: CGFloat,
        targetX: CGFloat,
        targetY: CGFloat
    ) -> String {
        let topInsetValue = String(format: "%.3f", Double(topInset))
        let bottomInsetValue = String(format: "%.3f", Double(bottomInset))
        let targetXValue = String(format: "%.3f", Double(targetX))
        let targetYValue = String(format: "%.3f", Double(targetY))
        return """
        (() => {
          const readableTop = \(topInsetValue);
          const readableBottom = Math.max(readableTop + 80, window.innerHeight - \(bottomInsetValue));
          const targetX = Math.max(0, Math.min(window.innerWidth, \(targetXValue)));
          const targetY = Math.max(readableTop, Math.min(readableBottom, \(targetYValue)));
          const maxCharacters = 14000;
          const maxChunks = 180;
          const maxChunkCharacters = 54;
          const boundaryCharacters = new Set(Array.from("，、,。！？!?；;：:\\n"));
          const ignoredTags = new Set(["script", "style", "svg", "head", "meta", "link", "noscript"]);
          const blockDisplays = new Set(["block", "list-item", "table", "flex", "grid"]);

          function cssEscapeIdentifier(value) {
            const string = String(value || "");
            if (window.CSS && typeof window.CSS.escape === "function") {
              return window.CSS.escape(string);
            }
            return Array.from(string).map((character, index) => {
              const code = character.codePointAt(0) || 0;
              const isLetter = (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
              const isDigit = code >= 48 && code <= 57;
              const isSafe = character === "_" || character === "-" || isLetter || (isDigit && index > 0);
              return isSafe ? character : "\\\\" + code.toString(16).toUpperCase() + " ";
            }).join("");
          }

          function selectorFor(element) {
            if (!element || element.nodeType !== Node.ELEMENT_NODE) {
              return null;
            }
            if (element.id) {
              return "#" + cssEscapeIdentifier(element.id);
            }

            const segments = [];
            let current = element;
            while (current && current.nodeType === Node.ELEMENT_NODE && current !== document) {
              const tagName = (current.localName || current.tagName || "").toLowerCase();
              if (!tagName) {
                break;
              }
              let segment = tagName;
              const parent = current.parentElement;
              if (parent) {
                const sameTagCount = Array.from(parent.children).filter(child =>
                  (child.localName || child.tagName || "").toLowerCase() === tagName
                ).length;
                if (sameTagCount > 1 || !current.id) {
                  segment += ":nth-child(" + (Array.prototype.indexOf.call(parent.children, current) + 1) + ")";
                }
              }
              segments.unshift(segment);
              current = parent;
            }
            return segments.join(" > ");
          }

          function isIgnoredNode(node) {
            const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
            if (!element) {
              return true;
            }
            let current = element;
            while (current && current !== document.body) {
              const tagName = (current.localName || current.tagName || "").toLowerCase();
              if (ignoredTags.has(tagName)) {
                return true;
              }
              current = current.parentElement;
            }
            return false;
          }

          function isVisibleElement(element) {
            if (!element) {
              return false;
            }
            const style = getComputedStyle(element);
            if (!style || style.display === "none" || style.opacity === "0" || style.visibility === "hidden") {
              return false;
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0
              && rect.height > 0
              && rect.bottom > readableTop
              && rect.top < readableBottom
              && rect.right > 0
              && rect.left < window.innerWidth;
          }

          function isVisibleTextNode(node) {
            if (!node || node.nodeType !== Node.TEXT_NODE || isIgnoredNode(node)) {
              return false;
            }
            if (!String(node.nodeValue || "").trim()) {
              return false;
            }
            const range = document.createRange();
            range.selectNodeContents(node);
            const rects = Array.from(range.getClientRects());
            range.detach && range.detach();
            return rects.some(rect =>
              rect.width > 0
                && rect.height > 0
                && rect.bottom > readableTop
                && rect.top < readableBottom
                && rect.right > 0
                && rect.left < window.innerWidth
            );
          }

          function textNodes(root) {
            const nodes = [];
            const walker = document.createTreeWalker(
              root || document.body,
              NodeFilter.SHOW_TEXT,
              {
                acceptNode(node) {
                  if (!node.nodeValue || !node.nodeValue.trim() || isIgnoredNode(node)) {
                    return NodeFilter.FILTER_REJECT;
                  }
                  return NodeFilter.FILTER_ACCEPT;
                }
              }
            );
            while (walker.nextNode()) {
              nodes.push(walker.currentNode);
            }
            return nodes;
          }

          function stableRootFor(node) {
            let current = node && node.parentElement;
            let fallback = current || document.body;
            while (current && current !== document.body) {
              const style = getComputedStyle(current);
              const display = style && style.display;
              if (blockDisplays.has(display) && selectorFor(current)) {
                return current;
              }
              fallback = current;
              current = current.parentElement;
            }
            return fallback || document.body;
          }

          function pointFor(node, offset) {
            const root = stableRootFor(node);
            const selector = selectorFor(root);
            const index = textNodes(root).indexOf(node);
            if (!selector || index < 0) {
              return null;
            }
            return { selector, textNodeIndex: index, offset };
          }

          function caretTextPositionAtPoint(x, y) {
            if (document.caretRangeFromPoint) {
              const range = document.caretRangeFromPoint(x, y);
              if (range && range.startContainer && range.startContainer.nodeType === Node.TEXT_NODE) {
                return { node: range.startContainer, offset: range.startOffset };
              }
            }
            if (document.caretPositionFromPoint) {
              const position = document.caretPositionFromPoint(x, y);
              if (position && position.offsetNode && position.offsetNode.nodeType === Node.TEXT_NODE) {
                return { node: position.offsetNode, offset: position.offset };
              }
            }
            return null;
          }

          function nearestVisibleTextPosition() {
            const nodes = textNodes(document.body).filter(isVisibleTextNode);
            let best = null;
            let bestScore = Infinity;
            for (const node of nodes) {
              const range = document.createRange();
              range.selectNodeContents(node);
              const rects = Array.from(range.getClientRects());
              range.detach && range.detach();
              for (const rect of rects) {
                const centerX = (rect.left + rect.right) / 2;
                const centerY = (rect.top + rect.bottom) / 2;
                const score = Math.abs(centerY - targetY) * 4 + Math.abs(centerX - targetX);
                if (score < bestScore) {
                  bestScore = score;
                  best = { node, offset: 0 };
                }
              }
            }
            return best;
          }

          function streamFrom(startNode, startOffset) {
            const stream = [];
            const nodes = textNodes(document.body);
            let started = false;
            for (const node of nodes) {
              if (node === startNode) {
                started = true;
              }
              if (!started) {
                continue;
              }
              const value = String(node.nodeValue || "");
              const offset = node === startNode ? Math.max(0, Math.min(value.length, startOffset)) : 0;
              for (let index = offset; index < value.length && stream.length < maxCharacters; index += 1) {
                stream.push({ character: value[index], node, offset: index });
              }
              if (stream.length >= maxCharacters) {
                break;
              }
            }
            return stream;
          }

          function isWhitespace(character) {
            return /\\s/.test(character || "");
          }

          function makeChunks(stream) {
            const chunks = [];
            let index = 0;
            while (index < stream.length && chunks.length < maxChunks) {
              while (index < stream.length && isWhitespace(stream[index].character)) {
                index += 1;
              }
              if (index >= stream.length) {
                break;
              }

              const start = index;
              let end = index;
              while (end < stream.length) {
                const length = end - start + 1;
                const character = stream[end].character;
                end += 1;
                if (boundaryCharacters.has(character) || length >= maxChunkCharacters) {
                  break;
                }
              }

              let trimmedEnd = end;
              while (trimmedEnd > start && isWhitespace(stream[trimmedEnd - 1].character)) {
                trimmedEnd -= 1;
              }
              if (trimmedEnd <= start) {
                index = end;
                continue;
              }

              const first = stream[start];
              const last = stream[trimmedEnd - 1];
              const startPoint = pointFor(first.node, first.offset);
              const endPoint = pointFor(last.node, last.offset + 1);
              const text = stream.slice(start, trimmedEnd).map(item => item.character).join("").replace(/\\s+/g, " ").trim();
              if (text && startPoint && endPoint) {
                chunks.push({ text, start: startPoint, end: endPoint });
              }
              index = end;
            }
            return chunks;
          }

          const caret = caretTextPositionAtPoint(targetX, targetY);
          const start = (caret && isVisibleTextNode(caret.node)) ? caret : nearestVisibleTextPosition();
          if (!start) {
            return { chunks: [] };
          }
          return { chunks: makeChunks(streamFrom(start.node, start.offset)) };
        })();
        """
    }

    private static func visualSpeechHighlightScript(
        chunk: EPUBVisualSpeechChunk,
        topInset: CGFloat,
        bottomInset: CGFloat,
        center: Bool
    ) -> String {
        let topInsetValue = String(format: "%.3f", Double(topInset))
        let bottomInsetValue = String(format: "%.3f", Double(bottomInset))
        let centerValue = center ? "true" : "false"
        return """
        (() => {
          const layerID = "offline-reader-tts-dom-highlight-layer";
          const start = {
            selector: \(javaScriptLiteral(chunk.start.selector)),
            textNodeIndex: \(chunk.start.textNodeIndex),
            offset: \(chunk.start.offset)
          };
          const end = {
            selector: \(javaScriptLiteral(chunk.end.selector)),
            textNodeIndex: \(chunk.end.textNodeIndex),
            offset: \(chunk.end.offset)
          };

          function clearHighlight() {
            const existing = document.getElementById(layerID);
            if (existing && existing.parentNode) {
              existing.parentNode.removeChild(existing);
            }
          }

          function textNodes(root) {
            const nodes = [];
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
              acceptNode(node) {
                return node.nodeValue ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
              }
            });
            while (walker.nextNode()) {
              nodes.push(walker.currentNode);
            }
            return nodes;
          }

          function resolve(point) {
            const root = document.querySelector(point.selector);
            if (!root) {
              return null;
            }
            const node = textNodes(root)[point.textNodeIndex];
            if (!node) {
              return null;
            }
            return {
              node,
              offset: Math.max(0, Math.min(String(node.nodeValue || "").length, point.offset))
            };
          }

          clearHighlight();
          const startPoint = resolve(start);
          const endPoint = resolve(end);
          if (!startPoint || !endPoint) {
            return false;
          }

          const range = document.createRange();
          range.setStart(startPoint.node, startPoint.offset);
          range.setEnd(endPoint.node, endPoint.offset);
          if (range.collapsed) {
            return false;
          }

          if (\(centerValue)) {
            const rects = Array.from(range.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0);
            if (rects.length) {
              const top = rects.reduce((value, rect) => Math.min(value, rect.top), Infinity);
              const bottom = rects.reduce((value, rect) => Math.max(value, rect.bottom), -Infinity);
              const highlightCenter = (top + bottom) / 2;
              const readableTop = \(topInsetValue);
              const readableBottom = Math.max(readableTop + 80, window.innerHeight - \(bottomInsetValue));
              const targetCenter = (readableTop + readableBottom) / 2;
              const delta = highlightCenter - targetCenter;
              if (Math.abs(delta) > 2) {
                window.scrollBy(0, delta);
              }
            }
          }

          const rects = Array.from(range.getClientRects()).filter(rect =>
            rect.width > 0
              && rect.height > 0
              && rect.bottom > 0
              && rect.top < window.innerHeight
              && rect.right > 0
              && rect.left < window.innerWidth
          );
          if (!rects.length) {
            return false;
          }

          const layer = document.createElement("div");
          layer.id = layerID;
          layer.setAttribute("aria-hidden", "true");
          layer.style.position = "fixed";
          layer.style.left = "0";
          layer.style.top = "0";
          layer.style.width = "100vw";
          layer.style.height = "100vh";
          layer.style.pointerEvents = "none";
          layer.style.zIndex = "2147483647";
          layer.style.mixBlendMode = "normal";
          for (const rect of rects) {
            const item = document.createElement("div");
            item.style.position = "absolute";
            item.style.left = Math.max(0, rect.left - 3) + "px";
            item.style.top = Math.max(0, rect.top - 2) + "px";
            item.style.width = Math.min(window.innerWidth, rect.width + 6) + "px";
            item.style.height = (rect.height + 4) + "px";
            item.style.background = "rgba(122, 194, 250, 0.42)";
            item.style.borderRadius = "4px";
            layer.appendChild(item);
          }
          document.documentElement.appendChild(layer);
          return true;
        })();
        """
    }

    private static func clearVisualSpeechHighlightScript(generation: Int) -> String {
        """
        (() => {
          const generation = \(generation);
          const generationKey = "__offlineReaderTTSHighlightGeneration";
          const currentGeneration = Number(window[generationKey] || 0);
          if (generation >= currentGeneration) {
            window[generationKey] = generation;
            const existing = document.getElementById("offline-reader-tts-dom-highlight-layer");
            if (existing && existing.parentNode) {
              existing.parentNode.removeChild(existing);
            }
          }
          return true;
        })();
        """
    }

    private static let clearSearchHighlightScript = """
    (() => {
      const existing = document.getElementById("offline-reader-search-highlight-layer");
      if (existing && existing.parentNode) {
        existing.parentNode.removeChild(existing);
      }
      return true;
    })();
    """

    private static func searchDOMHighlightScript(
        text: String,
        fallbackQuery: String,
        selector: String?,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> String {
        let textLiteral = javaScriptLiteral(text)
        let queryLiteral = javaScriptLiteral(fallbackQuery)
        let selectorLiteral = selector.map(javaScriptLiteral) ?? "null"
        let topInsetValue = String(format: "%.3f", Double(topInset))
        let bottomInsetValue = String(format: "%.3f", Double(bottomInset))
        return """
        (() => {
          const layerID = "offline-reader-search-highlight-layer";
          const selector = \(selectorLiteral);
          const needles = [\(textLiteral), \(queryLiteral)]
            .map(value => String(value || "").replace(/\\s+/g, " ").trim())
            .filter(Boolean);
          const existing = document.getElementById(layerID);
          if (existing && existing.parentNode) {
            existing.parentNode.removeChild(existing);
          }
          if (!needles.length) {
            return false;
          }

          function safeQuerySelector(value) {
            if (!value) {
              return null;
            }
            try {
              return document.querySelector(value);
            } catch (_) {
              return null;
            }
          }

          function textNodes(root) {
            const nodes = [];
            const walker = document.createTreeWalker(root || document.body, NodeFilter.SHOW_TEXT, {
              acceptNode(node) {
                return node.nodeValue && node.nodeValue.trim()
                  ? NodeFilter.FILTER_ACCEPT
                  : NodeFilter.FILTER_REJECT;
              }
            });
            while (walker.nextNode()) {
              nodes.push(walker.currentNode);
            }
            return nodes;
          }

          function buildIndex(root) {
            let value = "";
            const map = [];
            for (const node of textNodes(root)) {
              const text = String(node.nodeValue || "");
              for (let index = 0; index < text.length; index += 1) {
                const character = text[index];
                if (/\\s/.test(character)) {
                  if (value.length > 0 && value[value.length - 1] !== " ") {
                    value += " ";
                    map.push({ node, offset: index });
                  }
                } else {
                  value += character;
                  map.push({ node, offset: index });
                }
              }
            }
            return { value: value.trim().toLowerCase(), map };
          }

          function rangeFromIndexedValue(indexed, start, length) {
            const startPoint = indexed.map[start];
            const endPoint = indexed.map[Math.min(start + length - 1, indexed.map.length - 1)];
            if (!startPoint || !endPoint) {
              return null;
            }
            const range = document.createRange();
            range.setStart(startPoint.node, startPoint.offset);
            range.setEnd(endPoint.node, endPoint.offset + 1);
            return range.collapsed ? null : range;
          }

          function rangesFor(root) {
            const indexed = buildIndex(root);
            const ranges = [];
            for (const needle of needles) {
              let query = needle.toLowerCase();
              let start = indexed.value.indexOf(query);
              if (start < 0 && query.length > 18) {
                query = query.slice(0, Math.min(42, query.length));
                start = indexed.value.indexOf(query);
              }
              const length = query.length;
              while (start >= 0) {
                const range = rangeFromIndexedValue(indexed, start, length);
                if (range) {
                  ranges.push(range);
                }
                start = indexed.value.indexOf(query, start + Math.max(1, length));
              }
            }
            return ranges;
          }

          function scrollByDelta(delta) {
            if (Math.abs(delta) <= 2) {
              return;
            }
            const scroller = document.scrollingElement || document.documentElement || document.body;
            const before = scroller ? scroller.scrollTop : window.scrollY || 0;
            window.scrollBy(0, delta);
            if (scroller && typeof scroller.scrollTop === "number") {
              scroller.scrollTop = before + delta;
            }
          }

          function visibleRectsFor(range) {
            return Array.from(range.getClientRects()).filter(rect =>
              rect.width > 0
                && rect.height > 0
                && rect.bottom > 0
                && rect.top < window.innerHeight
                && rect.right > 0
                && rect.left < window.innerWidth
            );
          }

          function visibleScore(range) {
            const rects = visibleRectsFor(range);
            if (!rects.length) {
              return null;
            }
            const top = rects.reduce((value, rect) => Math.min(value, rect.top), Infinity);
            const bottom = rects.reduce((value, rect) => Math.max(value, rect.bottom), -Infinity);
            const center = (top + bottom) / 2;
            const readableTop = \(topInsetValue);
            const readableBottom = Math.max(readableTop + 80, window.innerHeight - \(bottomInsetValue));
            const targetCenter = readableTop + (readableBottom - readableTop) * 0.50;
            return Math.abs(center - targetCenter);
          }

          function bestRangeFor(root) {
            const ranges = rangesFor(root);
            let best = null;
            let bestScore = Infinity;
            for (const range of ranges) {
              const score = visibleScore(range);
              if (score !== null && score < bestScore) {
                best = range;
                bestScore = score;
              }
            }
            return best || ranges[0] || null;
          }

          function draw(range) {
            if (!range) {
              return false;
            }
            const rectsForScroll = Array.from(range.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0);
            if (!rectsForScroll.length) {
              return false;
            }
            const top = rectsForScroll.reduce((value, rect) => Math.min(value, rect.top), Infinity);
            const bottom = rectsForScroll.reduce((value, rect) => Math.max(value, rect.bottom), -Infinity);
            const readableTop = \(topInsetValue);
            const readableBottom = Math.max(readableTop + 80, window.innerHeight - \(bottomInsetValue));
            const targetCenter = readableTop + (readableBottom - readableTop) * 0.50;
            scrollByDelta(((top + bottom) / 2) - targetCenter);

            const rects = visibleRectsFor(range);
            if (!rects.length) {
              return false;
            }

            const layer = document.createElement("div");
            layer.id = layerID;
            layer.setAttribute("aria-hidden", "true");
            layer.style.position = "fixed";
            layer.style.left = "0";
            layer.style.top = "0";
            layer.style.width = "100vw";
            layer.style.height = "100vh";
            layer.style.pointerEvents = "none";
            layer.style.zIndex = "2147483646";
            for (const rect of rects) {
              const item = document.createElement("div");
              item.style.position = "absolute";
              item.style.left = Math.max(0, rect.left - 3) + "px";
              item.style.top = Math.max(0, rect.top - 2) + "px";
              item.style.width = Math.min(window.innerWidth, rect.width + 6) + "px";
              item.style.height = (rect.height + 4) + "px";
              item.style.background = "rgba(144, 211, 255, 0.46)";
              item.style.borderRadius = "3px";
              layer.appendChild(item);
            }
            document.documentElement.appendChild(layer);
            return true;
          }

          const roots = [];
          const selected = safeQuerySelector(selector);
          if (selected) {
            roots.push(selected);
          }
          roots.push(document.body);
          for (const root of roots) {
            if (draw(bestRangeFor(root))) {
              return true;
            }
          }
          return false;
        })();
        """
    }

    private static func spokenDecorationViewportScript(
        topInset: CGFloat,
        bottomInset: CGFloat,
        scrollPolicy: SpokenHighlightScrollPolicy,
        generation: Int
    ) -> String {
        let topInsetValue = String(format: "%.3f", Double(topInset))
        let bottomInsetValue = String(format: "%.3f", Double(bottomInset))
        let scrollPolicyLiteral = javaScriptLiteral(scrollPolicy.rawValue)
        let decorationGroupLiteral = javaScriptLiteral(String(Self.ttsDecorationGroup))
        return """
        (() => {
          const decorationGroup = \(decorationGroupLiteral);
          const scrollPolicy = \(scrollPolicyLiteral);
          const generation = \(generation);
          const generationKey = "__offlineReaderTTSViewportGeneration";
          const currentGeneration = Number(window[generationKey] || 0);
          if (generation < currentGeneration) {
            return false;
          }
          window[generationKey] = generation;

          function isCurrentGeneration() {
            return Number(window[generationKey] || 0) === generation;
          }

          function scrollByDelta(delta) {
            if (Math.abs(delta) <= 2) {
              return;
            }
            const scroller = document.scrollingElement || document.documentElement || document.body;
            const before = scroller ? scroller.scrollTop : window.scrollY || 0;
            window.scrollBy(0, delta);
            if (scroller && typeof scroller.scrollTop === "number") {
              scroller.scrollTop = before + delta;
            }
          }

          function decorationRects() {
            const containers = Array.from(document.querySelectorAll("[data-group]"))
              .filter(element => element.getAttribute("data-group") === decorationGroup);
            const container = containers[containers.length - 1];
            if (!container) {
              return [];
            }

            return Array.from(container.querySelectorAll("div"))
              .map(element => element.getBoundingClientRect())
              .filter(rect => rect.width > 0 && rect.height > 0);
          }

          function adjustViewport(rects) {
            if (scrollPolicy === "none" || !rects.length) {
              return false;
            }

            const top = rects.reduce((value, rect) => Math.min(value, rect.top), Infinity);
            const bottom = rects.reduce((value, rect) => Math.max(value, rect.bottom), -Infinity);
            const highlightCenter = (top + bottom) / 2;
            const readableTop = \(topInsetValue);
            const readableBottom = Math.max(readableTop + 80, window.innerHeight - \(bottomInsetValue));
            const readableHeight = Math.max(1, readableBottom - readableTop);

            if (scrollPolicy === "center") {
              scrollByDelta(highlightCenter - (readableTop + readableHeight * 0.50));
              return true;
            }

            const lowerTrigger = readableTop + readableHeight * 0.75;
            const upperTarget = readableTop + readableHeight * 0.25;
            if (highlightCenter > lowerTrigger) {
              scrollByDelta(highlightCenter - upperTarget);
            }
            return true;
          }

          function attempt(remainingFrames) {
            if (!isCurrentGeneration()) {
              return;
            }
            if (adjustViewport(decorationRects())) {
              return;
            }
            if (remainingFrames > 0) {
              window.requestAnimationFrame(() => attempt(remainingFrames - 1));
            }
          }

          window.requestAnimationFrame(() => attempt(12));
          return true;
        })();
        """
    }

    private static func spokenDOMHighlightScript(
        text: String?,
        selector: String?,
        topInset: CGFloat,
        bottomInset: CGFloat,
        scrollPolicy: SpokenHighlightScrollPolicy,
        drawsHighlight: Bool,
        generation: Int
    ) -> String {
        let textLiteral = javaScriptLiteral(text ?? "")
        let selectorLiteral = selector.map(javaScriptLiteral) ?? "null"
        let topInsetValue = String(format: "%.3f", Double(topInset))
        let bottomInsetValue = String(format: "%.3f", Double(bottomInset))
        let scrollPolicyLiteral = javaScriptLiteral(scrollPolicy.rawValue)
        let drawsHighlightLiteral = drawsHighlight ? "true" : "false"
        return """
        (() => {
          const layerID = "offline-reader-tts-dom-highlight-layer";
          const rawNeedle = \(textLiteral);
          const selector = \(selectorLiteral);
          const scrollPolicy = \(scrollPolicyLiteral);
          const drawsHighlight = \(drawsHighlightLiteral);
          const generation = \(generation);
          const generationKey = "__offlineReaderTTSHighlightGeneration";
          const currentGeneration = Number(window[generationKey] || 0);
          if (generation < currentGeneration) {
            return false;
          }
          window[generationKey] = generation;

          function isCurrentGeneration() {
            return Number(window[generationKey] || 0) === generation;
          }

          function clearHighlight() {
            const existing = document.getElementById(layerID);
            if (existing && existing.parentNode) {
              existing.parentNode.removeChild(existing);
            }
          }

          function collapsed(value) {
            return String(value || "").replace(/\\s+/g, " ").trim();
          }

          function isSkippableCharacter(character) {
            const code = character.codePointAt(0) || 0;
            const asciiPunctuation = ".,!?;:()[]{}<>\\\"'“”‘’-—_+=/@#$%^&*~`·";
            return /\\s/.test(character)
              || asciiPunctuation.includes(character)
              || (code >= 0x2000 && code <= 0x206F)
              || (code >= 0x3000 && code <= 0x303F)
              || (code >= 0xFF00 && code <= 0xFFEF && !/[A-Za-z0-9]/.test(character));
          }

          function compact(value) {
            let output = "";
            const source = String(value || "");
            for (let index = 0; index < source.length; index += 1) {
              const character = source[index];
              if (!isSkippableCharacter(character)) {
                output += character.toLowerCase();
              }
            }
            return output;
          }

          function textNodes(root) {
            const nodes = [];
            const walker = document.createTreeWalker(root || document.body, NodeFilter.SHOW_TEXT, {
              acceptNode(node) {
                return node.nodeValue && node.nodeValue.trim()
                  ? NodeFilter.FILTER_ACCEPT
                  : NodeFilter.FILTER_REJECT;
              }
            });
            while (walker.nextNode()) {
              nodes.push(walker.currentNode);
            }
            return nodes;
          }

          function safeQuerySelector(value) {
            if (!value) {
              return null;
            }
            try {
              return document.querySelector(value);
            } catch (_) {
              return null;
            }
          }

          function buildIndex(root, mode) {
            let value = "";
            const map = [];
            for (const node of textNodes(root)) {
              const text = String(node.nodeValue || "");
              for (let index = 0; index < text.length; index += 1) {
                const character = text[index];
                if (mode === "compact") {
                  if (!isSkippableCharacter(character)) {
                    value += character.toLowerCase();
                    map.push({ node, offset: index });
                  }
                } else if (/\\s/.test(character)) {
                  if (value.length > 0 && value[value.length - 1] !== " ") {
                    value += " ";
                    map.push({ node, offset: index });
                  }
                } else {
                  value += character;
                  map.push({ node, offset: index });
                }
              }
            }
            return { value: value.trim(), map };
          }

          function rangeFromIndexedValue(indexed, start, length) {
            const startPoint = indexed.map[start];
            const endPoint = indexed.map[Math.min(start + length - 1, indexed.map.length - 1)];
            if (!startPoint || !endPoint) {
              return null;
            }

            const range = document.createRange();
            range.setStart(startPoint.node, startPoint.offset);
            range.setEnd(endPoint.node, endPoint.offset + 1);
            return range.collapsed ? null : range;
          }

          function rangeForMode(root, needle, mode) {
            const indexed = buildIndex(root, mode);
            const query = mode === "compact" ? compact(needle) : collapsed(needle);
            if (!query || !indexed.value || !indexed.map.length) {
              return null;
            }

            let start = indexed.value.indexOf(query);
            let length = query.length;
            if (start < 0 && query.length > 18) {
              const shorter = query.slice(0, Math.min(42, query.length));
              start = indexed.value.indexOf(shorter);
              length = shorter.length;
            }
            if (start < 0) {
              return null;
            }

            return rangeFromIndexedValue(indexed, start, length);
          }

          function rangeFor(root, needle) {
            return rangeForMode(root, needle, "collapsed")
              || rangeForMode(root, needle, "compact");
          }

          function nearestVisibleTextRange() {
            const readableTop = \(topInsetValue);
            const readableBottom = Math.max(readableTop + 80, window.innerHeight - \(bottomInsetValue));
            let best = null;
            let bestScore = Infinity;
            for (const node of textNodes(document.body)) {
              const value = String(node.nodeValue || "");
              if (!value.trim()) {
                continue;
              }
              const range = document.createRange();
              range.selectNodeContents(node);
              const rects = Array.from(range.getClientRects()).filter(rect =>
                rect.width > 0
                  && rect.height > 0
                  && rect.bottom > readableTop
                  && rect.top < readableBottom
              );
              if (!rects.length) {
                continue;
              }
              for (const rect of rects) {
                const centerY = (rect.top + rect.bottom) / 2;
                const targetY = (readableTop + readableBottom) / 2;
                const score = Math.abs(centerY - targetY);
                if (score < bestScore) {
                  bestScore = score;
                  best = range.cloneRange();
                }
              }
            }
            return best;
          }

          function scrollByDelta(delta) {
            if (Math.abs(delta) <= 2) {
              return;
            }
            const scroller = document.scrollingElement || document.documentElement || document.body;
            const before = scroller ? scroller.scrollTop : window.scrollY || 0;
            window.scrollBy(0, delta);
            if (scroller && typeof scroller.scrollTop === "number") {
              scroller.scrollTop = before + delta;
            }
          }

          function adjustViewport(range) {
            if (scrollPolicy === "none") {
              return;
            }
            const rectsForScroll = Array.from(range.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0);
            if (!rectsForScroll.length) {
              return;
            }

            const top = rectsForScroll.reduce((value, rect) => Math.min(value, rect.top), Infinity);
            const bottom = rectsForScroll.reduce((value, rect) => Math.max(value, rect.bottom), -Infinity);
            const highlightCenter = (top + bottom) / 2;
            const readableTop = \(topInsetValue);
            const readableBottom = Math.max(readableTop + 80, window.innerHeight - \(bottomInsetValue));
            const readableHeight = Math.max(1, readableBottom - readableTop);

            if (scrollPolicy === "center") {
              scrollByDelta(highlightCenter - (readableTop + readableHeight * 0.50));
              return;
            }

            const lowerTrigger = readableTop + readableHeight * 0.75;
            const upperTarget = readableTop + readableHeight * 0.25;
            if (highlightCenter > lowerTrigger) {
              scrollByDelta(highlightCenter - upperTarget);
            }
          }

          function draw(range) {
            if (!range || !isCurrentGeneration()) {
              return false;
            }

            adjustViewport(range);
            if (!isCurrentGeneration()) {
              return false;
            }
            if (!drawsHighlight) {
              return true;
            }

            const rects = Array.from(range.getClientRects()).filter(rect =>
              rect.width > 0
                && rect.height > 0
                && rect.bottom > 0
                && rect.top < window.innerHeight
                && rect.right > 0
                && rect.left < window.innerWidth
            );
            if (!rects.length) {
              return false;
            }

            const layer = document.createElement("div");
            layer.id = layerID;
            layer.setAttribute("aria-hidden", "true");
            layer.style.position = "fixed";
            layer.style.left = "0";
            layer.style.top = "0";
            layer.style.width = "100vw";
            layer.style.height = "100vh";
            layer.style.pointerEvents = "none";
            layer.style.zIndex = "2147483647";
            for (const rect of rects) {
              const item = document.createElement("div");
              item.style.position = "absolute";
              item.style.left = Math.max(0, rect.left - 3) + "px";
              item.style.top = Math.max(0, rect.top - 2) + "px";
              item.style.width = Math.min(window.innerWidth, rect.width + 6) + "px";
              item.style.height = (rect.height + 4) + "px";
              item.style.background = "rgba(122, 194, 250, 0.42)";
              item.style.borderRadius = "4px";
              layer.appendChild(item);
            }
            document.documentElement.appendChild(layer);
            return true;
          }

          if (drawsHighlight) {
            clearHighlight();
          }
          const roots = [];
          if (selector) {
            const selected = safeQuerySelector(selector);
            if (selected) {
              roots.push(selected);
            }
          }
          roots.push(document.body);

          for (const root of roots) {
            const range = rangeFor(root, rawNeedle);
            if (draw(range)) {
              return true;
            }
          }
          return false;
        })();
        """
    }

    private static func readableLocatorScript(
        topInset: CGFloat,
        bottomInset: CGFloat,
        targetX: CGFloat,
        targetY: CGFloat
    ) -> String {
        let topInsetValue = String(format: "%.3f", Double(topInset))
        let bottomInsetValue = String(format: "%.3f", Double(bottomInset))
        let targetXValue = String(format: "%.3f", Double(targetX))
        let targetYValue = String(format: "%.3f", Double(targetY))
        return """
        (() => {
          const readableTop = \(topInsetValue);
          const readableBottom = Math.max(readableTop + 80, window.innerHeight - \(bottomInsetValue));
          const targetX = Math.max(0, Math.min(window.innerWidth, \(targetXValue)));
          const targetY = Math.max(readableTop, Math.min(readableBottom, \(targetYValue)));
          const blockDisplays = new Set(["block", "list-item", "table", "flex", "grid"]);
          const ignoredTags = new Set(["script", "style", "svg", "head", "meta", "link"]);

          function normalizedText(element) {
            return (element.textContent || "").replace(/\\s+/g, " ").trim();
          }

          function caretTextPositionAtPoint(x, y) {
            if (document.caretRangeFromPoint) {
              const range = document.caretRangeFromPoint(x, y);
              if (range && range.startContainer && range.startContainer.nodeType === Node.TEXT_NODE) {
                return { node: range.startContainer, offset: range.startOffset };
              }
            }
            if (document.caretPositionFromPoint) {
              const position = document.caretPositionFromPoint(x, y);
              if (position && position.offsetNode && position.offsetNode.nodeType === Node.TEXT_NODE) {
                return { node: position.offsetNode, offset: position.offset };
              }
            }
            return null;
          }

          function normalizedLength(value) {
            return String(value || "").replace(/\\s+/g, " ").length;
          }

          function focusedText(element, caret) {
            const fullText = normalizedText(element);
            if (!fullText) {
              return null;
            }

            function payload(start, length) {
              const clampedStart = Math.max(0, Math.min(fullText.length - 1, start));
              const highlight = fullText.slice(clampedStart, clampedStart + length).trim()
                || fullText.slice(0, Math.min(240, fullText.length)).trim();
              if (!highlight) {
                return null;
              }
              const before = fullText.slice(Math.max(0, clampedStart - 90), clampedStart).trim();
              const after = fullText.slice(
                Math.min(fullText.length, clampedStart + highlight.length),
                Math.min(fullText.length, clampedStart + highlight.length + 90)
              ).trim();
              return {
                highlight,
                before: before || undefined,
                after: after || undefined
              };
            }

            if (!caret || !element.contains(caret.node)) {
              return payload(0, 240);
            }

            const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
            let offset = 0;
            while (walker.nextNode()) {
              const node = walker.currentNode;
              if (node === caret.node) {
                offset += normalizedLength(node.nodeValue.slice(0, caret.offset));
                break;
              }
              offset += normalizedLength(node.nodeValue);
            }

            const start = Math.max(0, Math.min(fullText.length - 1, offset));
            return payload(start, 160);
          }

          function cssEscapeIdentifier(value) {
            const string = String(value || "");
            if (window.CSS && typeof window.CSS.escape === "function") {
              return window.CSS.escape(string);
            }
            return Array.from(string).map((character, index) => {
              const code = character.codePointAt(0) || 0;
              const isLetter = (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
              const isDigit = code >= 48 && code <= 57;
              const isSafe = character === "_" || character === "-" || isLetter || (isDigit && index > 0);
              return isSafe ? character : "\\\\" + code.toString(16).toUpperCase() + " ";
            }).join("");
          }

          function selectorFor(element) {
            if (!element || element.nodeType !== Node.ELEMENT_NODE) {
              return null;
            }
            if (element.id) {
              return "#" + cssEscapeIdentifier(element.id);
            }

            const segments = [];
            let current = element;
            while (current && current.nodeType === Node.ELEMENT_NODE && current !== document) {
              const tagName = (current.localName || current.tagName || "").toLowerCase();
              if (!tagName) {
                break;
              }

              let segment = tagName;
              if (current.classList && current.classList.length) {
                segment += "." + Array.from(current.classList).sort().map(cssEscapeIdentifier).join(".");
              }

              const parent = current.parentElement;
              if (parent) {
                const sameTagCount = Array.from(parent.children).filter(child =>
                  (child.localName || child.tagName || "").toLowerCase() === tagName
                ).length;
                if (sameTagCount > 1) {
                  segment += ":nth-child(" + (Array.prototype.indexOf.call(parent.children, current) + 1) + ")";
                }
              }

              segments.unshift(segment);
              current = parent;
            }
            return segments.join(" > ");
          }

          function isVisible(element) {
            const style = getComputedStyle(element);
            if (!style || style.opacity === "0" || style.visibility === "hidden") {
              return false;
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0
              && rect.height > 0
              && rect.bottom > readableTop + 2
              && rect.top < readableBottom
              && rect.right > 0
              && rect.left < window.innerWidth;
          }

          function isReadableBlock(element) {
            const tagName = (element.localName || element.tagName || "").toLowerCase();
            if (ignoredTags.has(tagName) || !normalizedText(element)) {
              return false;
            }
            const display = getComputedStyle(element).display;
            if (!blockDisplays.has(display)) {
              return false;
            }
            if (!isVisible(element)) {
              return false;
            }
            return true;
          }

          function collectReadableBlocks(root, output) {
            for (const child of Array.from(root.children || [])) {
              if (!isVisible(child)) {
                continue;
              }
              collectReadableBlocks(child, output);
              if (isReadableBlock(child)) {
                output.push(child);
              }
            }
          }

          function ancestorReadableBlock(element) {
            let current = element;
            while (current && current !== document && current !== document.body) {
              if (current.nodeType === Node.ELEMENT_NODE && isReadableBlock(current)) {
                return current;
              }
              current = current.parentElement;
            }
            return null;
          }

          function readableElementForCaret(caret) {
            if (!caret || !caret.node || !caret.node.parentElement) {
              return null;
            }
            return ancestorReadableBlock(caret.node.parentElement);
          }

          function score(element) {
            const rect = element.getBoundingClientRect();
            const verticalDistance = targetY < rect.top
              ? rect.top - targetY
              : (targetY > rect.bottom ? targetY - rect.bottom : 0);
            const horizontalDistance = targetX < rect.left
              ? rect.left - targetX
              : (targetX > rect.right ? targetX - rect.right : 0);
            return verticalDistance * 4 + horizontalDistance * 0.25 + Math.min(rect.height, 1000) * 0.002;
          }

          const blocks = [];
          collectReadableBlocks(document.body, blocks);
          const caret = caretTextPositionAtPoint(targetX, targetY);
          const caretBlock = readableElementForCaret(caret);
          const tappedElement = document.elementFromPoint(targetX, targetY);
          const tappedBlock = tappedElement ? ancestorReadableBlock(tappedElement) : null;
          const element = caretBlock
            || tappedBlock
            || blocks.sort((left, right) => score(left) - score(right))[0]
            || document.body;
          const selector = selectorFor(element);
          const text = focusedText(element, caret);
          if (!selector || !text || !text.highlight) {
            return null;
          }
          return {
            href: "#",
            type: "application/xhtml+xml",
            locations: { cssSelector: selector },
            text
          };
        })();
        """
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

        let doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleListeningDoubleTap(_:)))
        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.cancelsTouchesInView = false
        navigator.view.addGestureRecognizer(doubleTapRecognizer)
        listeningDoubleTapRecognizer = doubleTapRecognizer

        chromeToggleInputToken = navigator.addObserver(.activate { [weak self] _ in
            self?.clearSearchHighlightFromUserActivation()
            self?.onChromeToggleRequested?()
            return true
        })
    }

    @objc private func handleListeningDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }
        let point = recognizer.location(in: navigator.view)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard let synthesizer = self.makeSpeechSynthesizer() else {
                self.onListeningStateChanged?(.inactive)
                return
            }
            self.clearSearchHighlight()
            self.clearSpokenDecoration()
            await self.startListening(from: point, using: synthesizer)
        }
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
            currentSpokenDecorationLocatorData = nil
            clearSpokenDecoration()
            onListeningStateChanged?(.inactive)
        case .paused(let utterance):
            updateSpokenUtterance(utterance, isPlaying: false)
        case .playing(let utterance, range: let rangeLocator):
            updateSpokenUtterance(utterance, rangeLocator: rangeLocator, isPlaying: true)
        }
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        AppLog.reader.error("EPUB TTS error: \(String(describing: error), privacy: .public)")
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
    private var speechEngine: ReaderPreferencesSnapshot.SpeechEngine
    private var speechVoiceIdentifier: String
    private var speechRate: Double

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
        self.speechEngine = preferences.speechEngine
        self.speechVoiceIdentifier = preferences.speechVoiceIdentifier
        self.speechRate = preferences.speechRate
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

    func showSearchHighlight(locatorData: Data, query: String) async {}

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
        let didChangeSpeechEngine = speechEngine != snapshot.speechEngine
            || speechVoiceIdentifier != snapshot.speechVoiceIdentifier
        speechEngine = snapshot.speechEngine
        speechVoiceIdentifier = snapshot.speechVoiceIdentifier
        speechRate = snapshot.speechRate
        speechSynthesizer?.config = NarrationSpeechConfiguration.publicationConfiguration(
            publicationLanguage: publicationHandle.publication.metadata.language,
            voiceIdentifier: speechVoiceIdentifier,
            rateMultiplier: speechRate
        )
        speechSynthesizer?.updateRateMultiplier(speechRate)
        if didChangeSpeechEngine {
            speechSynthesizer?.stop()
            speechSynthesizer = nil
            currentListeningState = nil
        }
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

    func skipToPreviousListening() {
        speechSynthesizer?.previous()
    }

    func skipToNextListening() {
        speechSynthesizer?.next()
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
        guard let speechSynthesizer = PublicationSpeechSynthesizer(
            publication: publicationHandle.publication,
            config: NarrationSpeechConfiguration.publicationConfiguration(
                publicationLanguage: publicationHandle.publication.metadata.language,
                voiceIdentifier: speechVoiceIdentifier,
                rateMultiplier: speechRate
            ),
            engineFactory: { [speechEngine, speechVoiceIdentifier] in
                switch speechEngine {
                case .system:
                    return NarrationExpressiveAVTTSEngine()
                case .edgeReadAloud:
                    return EdgeReadAloudTTSEngine(voiceIdentifier: speechVoiceIdentifier)
                }
            },
            tokenizerFactory: ReaderSession.speechTokenizerFactory(for: speechEngine)
        ) else {
            return nil
        }
        warmUpSpeechSynthesizerEngine(speechSynthesizer)
        speechSynthesizer.delegate = self
        self.speechSynthesizer = speechSynthesizer
        return speechSynthesizer
    }

    private func listeningState(for utterance: PublicationSpeechSynthesizer.Utterance, isPlaying: Bool) -> ReaderListeningState {
        let locatorData = try? LocatorCoding.encode(utterance.locator)
        let state = ReaderListeningState(
            isActive: true,
            isPlaying: isPlaying,
            isLoading: false,
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

@MainActor
private func warmUpSpeechSynthesizerEngine(_ speechSynthesizer: PublicationSpeechSynthesizer) {
    // Readium creates the TTS engine lazily. Warm it up on the main actor so
    // AVSpeechSynthesizer is not first initialized from PublicationSpeechSynthesizer's playback Task.
    _ = speechSynthesizer.availableVoices
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

    var containsCJKText: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400 ... 0x4DBF,
                 0x4E00 ... 0x9FFF,
                 0xF900 ... 0xFAFF,
                 0x20000 ... 0x2A6DF,
                 0x2A700 ... 0x2B73F,
                 0x2B740 ... 0x2B81F,
                 0x2B820 ... 0x2CEAF,
                 0x3000 ... 0x303F,
                 0xFF00 ... 0xFFEF:
                return true
            default:
                return false
            }
        }
    }
}

private extension Substring {
    func trimmingRange(in source: String) -> Range<String.Index> {
        var lower = startIndex
        var upper = endIndex

        while lower < upper, source[lower].isNarrationWhitespace {
            lower = source.index(after: lower)
        }

        while lower < upper {
            let previous = source.index(before: upper)
            guard source[previous].isNarrationWhitespace else {
                break
            }
            upper = previous
        }

        return lower ..< upper
    }
}

private extension Character {
    var isNarrationWhitespace: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

private extension Array where Element: Hashable {
    func narrationRemovingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
