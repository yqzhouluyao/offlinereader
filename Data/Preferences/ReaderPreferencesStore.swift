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
