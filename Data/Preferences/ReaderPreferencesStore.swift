import Foundation

struct ReaderPreferencesSnapshot: Codable, Equatable, Sendable {
    enum Theme: String, Codable, Sendable, CaseIterable, Identifiable {
        case day
        case sepia
        case eyeCare
        case night

        var id: String { rawValue }
    }

    enum FontChoice: String, Codable, Sendable, CaseIterable, Identifiable {
        case publisher
        case serif
        case sansSerif

        var id: String { rawValue }
    }

    enum Level: Int, Codable, Sendable, CaseIterable, Identifiable {
        case one = 1
        case two
        case three
        case four
        case five

        var id: Int { rawValue }
    }

    enum PageTurnMode: String, Codable, Sendable, CaseIterable, Identifiable {
        case horizontal
        case verticalScroll
        case curl

        var id: String { rawValue }
    }

    enum SpeechEngine: String, Codable, Sendable, CaseIterable, Identifiable {
        case system
        case edgeReadAloud

        var id: String { rawValue }
    }

    var version: Int = 1
    var theme: Theme = .day
    var font: FontChoice = .publisher
    var fontSizeLevel: Level = .three
    var lineHeightLevel: Level = .three
    var marginLevel: Level = .three
    var pageTurnMode: PageTurnMode = .verticalScroll
    var speechEngine: SpeechEngine = .system
    var speechVoiceIdentifier: String = "zh-CN-XiaoxiaoNeural"
    var speechRate: Double = 1.0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version
        case theme
        case font
        case fontSizeLevel
        case lineHeightLevel
        case marginLevel
        case pageTurnMode
        case speechEngine
        case speechVoiceIdentifier
        case speechRate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        theme = try values.decodeIfPresent(Theme.self, forKey: .theme) ?? .day
        font = try values.decodeIfPresent(FontChoice.self, forKey: .font) ?? .publisher
        fontSizeLevel = try values.decodeIfPresent(Level.self, forKey: .fontSizeLevel) ?? .three
        lineHeightLevel = try values.decodeIfPresent(Level.self, forKey: .lineHeightLevel) ?? .three
        marginLevel = try values.decodeIfPresent(Level.self, forKey: .marginLevel) ?? .three
        pageTurnMode = try values.decodeIfPresent(PageTurnMode.self, forKey: .pageTurnMode) ?? .verticalScroll
        speechEngine = try values.decodeIfPresent(SpeechEngine.self, forKey: .speechEngine) ?? .system
        speechVoiceIdentifier = try values.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier) ?? "zh-CN-XiaoxiaoNeural"
        speechRate = Self.normalizedSpeechRate(try values.decodeIfPresent(Double.self, forKey: .speechRate) ?? 1.0)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(theme, forKey: .theme)
        try values.encode(font, forKey: .font)
        try values.encode(fontSizeLevel, forKey: .fontSizeLevel)
        try values.encode(lineHeightLevel, forKey: .lineHeightLevel)
        try values.encode(marginLevel, forKey: .marginLevel)
        try values.encode(pageTurnMode, forKey: .pageTurnMode)
        try values.encode(speechEngine, forKey: .speechEngine)
        try values.encode(speechVoiceIdentifier, forKey: .speechVoiceIdentifier)
        try values.encode(Self.normalizedSpeechRate(speechRate), forKey: .speechRate)
    }

    static func normalizedSpeechRate(_ value: Double) -> Double {
        min(max(value, 0.7), 3.0)
    }
}

@MainActor
final class ReaderPreferencesStore {
    private let defaults: UserDefaults
    private let key = "reader.preferences.snapshot.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ReaderPreferencesSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(ReaderPreferencesSnapshot.self, from: data),
              snapshot.version == 1
        else {
            return ReaderPreferencesSnapshot()
        }
        return snapshot
    }

    func save(_ snapshot: ReaderPreferencesSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
    }
}
