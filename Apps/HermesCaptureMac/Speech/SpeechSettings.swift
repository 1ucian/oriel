import Foundation
import HermesCaptureProtocol
import Observation

/// Settings, Assistant, Voice input: whether a phone may talk to this Mac, in which language, and the words Whisper
/// should expect.
@MainActor
@Observable
final class SpeechSettings {
    static let shared = SpeechSettings(
        defaults: ProcessInfo.processInfo.environment["ORIEL_SETTINGS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    )

    /// Whisper's language codes as Settings offers them; an empty code lets Whisper detect the language.
    static let languages: [(code: String, name: String)] = [
        ("", "Detect automatically"),
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("nl", "Dutch"), ("ro", "Romanian"), ("pl", "Polish"), ("ru", "Russian"),
        ("uk", "Ukrainian"), ("tr", "Turkish"), ("ar", "Arabic"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("vi", "Vietnamese"), ("sv", "Swedish"),
    ]
    static let defaultLanguage = "en"
    /// Whisper reads at most 223 tokens of prompt; this keeps the text near that.
    static let maximumVocabularyCharacters = 800

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            Task { await SpeechService.shared.preferencesChanged() }
        }
    }

    /// A code from `languages`; empty to detect.
    var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    /// Names and terms to expect, given to Whisper as its initial prompt. Empty means no prompt.
    var vocabulary: String {
        didSet {
            if vocabulary.count > Self.maximumVocabularyCharacters {
                vocabulary = String(vocabulary.prefix(Self.maximumVocabularyCharacters))
                return
            }
            defaults.set(vocabulary, forKey: Keys.vocabulary)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        language = defaults.string(forKey: Keys.language) ?? Self.defaultLanguage
        vocabulary = defaults.string(forKey: Keys.vocabulary) ?? ""
    }

    /// The language Whisper is told, nil to detect.
    var whisperLanguage: String? { language.isEmpty ? nil : language }

    /// The offer a phone approved for `capabilities` gets. Voice input fills the assistant's instruction and the
    /// keyboard, so a session with neither gets none, and neither does a Mac that cannot run the model.
    func offer(for capabilities: Set<SessionCapability>) -> SpeechTranscriptionOffer? {
        guard isEnabled, SpeechService.isSupportedHere,
              !capabilities.isDisjoint(with: [.typeText, .runAgentActions]) else { return nil }
        return .current
    }

    private enum Keys {
        static let enabled = "speech.enabled"
        static let language = "speech.language"
        static let vocabulary = "speech.vocabulary"
    }
}
