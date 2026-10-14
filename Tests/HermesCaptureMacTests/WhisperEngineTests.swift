import Foundation
import Testing
@testable import HermesCaptureMac

/// The Mac's Whisper engine against Hermes's transcriber (Python mlx_whisper 0.4.3 with
/// mlx-community/whisper-large-v3-mlx): mel filters, token ids and compression ratios taken from
/// it, and a 5-second synthetic-speech clip (macOS `say`, Samantha) transcribed by the real model.
/// The model tests run when the model is on this Mac and skip otherwise; ORIEL_REQUIRE_WHISPER=1
/// makes a missing model a failure.
struct WhisperEngineTests {
    static var requireModel: Bool { ProcessInfo.processInfo.environment["ORIEL_REQUIRE_WHISPER"] == "1" }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/voice-command.wav")
    }

    /// What Hermes's transcriber returns for the fixture, in English, with or without a prompt.
    static let fixtureText = "Open Safari, search for the weather in Lisbon, and show me the forecast for this weekend."

    @Test func melFiltersMatchLibrosa() {
        let filters = WhisperAudio.melFilterValues(128)
        #expect(filters.count == 128 * 201)
        // mlx_whisper's mel_filters.npz (librosa, Slaney): a few values and the total.
        #expect(filters[0 * 201 + 1] == Float(0.012373987))
        #expect(filters[0 * 201 + 2] == 0)
        #expect(filters[127 * 201 + 195] == Float(0.0050416016))
        #expect(filters[127 * 201 + 199] == Float(0.0011142802))
        #expect(filters[0 ..< 201].filter { $0 != 0 }.count == 1)
        #expect(filters[(64 * 201) ..< (65 * 201)].filter { $0 != 0 }.count == 2)
        #expect(filters[(127 * 201) ..< (128 * 201)].filter { $0 != 0 }.count == 9)
        let total = filters.reduce(0.0) { $0 + Double($1) }
        #expect(abs(total - 3.1909855409403463) < 1e-9)
    }

    @Test func compressionRatioMatchesZlib() {
        #expect(WhisperTranscriber.compressionRatio("hello hello hello hello") == 23.0 / 16)
        #expect(WhisperTranscriber.compressionRatio("Thank you.") == 10.0 / 18)
        #expect(WhisperTranscriber.compressionRatio(Self.fixtureText) == 89.0 / 82)
        #expect(WhisperTranscriber.compressionRatio("") == 0)
    }

    @Test func storeSizesAddUp() {
        #expect(WhisperModelStore.weightBytes == 3_083_520_685)
        #expect(WhisperModelStore.approximateBytes == WhisperModelStore.weightBytes + WhisperModelStore.tokenizerBytes)
        let missing = WhisperModelStore.missingBytes
        #expect((missing == 0) == (WhisperModelStore.installedDirectory() != nil))
        #expect([0, WhisperModelStore.tokenizerBytes, WhisperModelStore.weightBytes, WhisperModelStore.approximateBytes]
            .contains(missing))
    }

    @Test func languagesResolveLikeMlxWhisper() {
        #expect(WhisperTokenizer.languageCodes.count == 100)
        #expect(WhisperTokenizer.languageCode(for: "en") == "en")
        #expect(WhisperTokenizer.languageCode(for: "English") == "en")
        #expect(WhisperTokenizer.languageCode(for: "castilian") == "es")
        #expect(WhisperTokenizer.languageCode(for: "yue") == "yue")
        #expect(WhisperTokenizer.languageCode(for: "klingon") == nil)
    }

    /// Token ids from tiktoken with mlx_whisper's multilingual.tiktoken.
    @Test func tokenizerMatchesTiktoken() throws {
        guard let vocabulary = WhisperModelStore.vocabularyURL() else {
            #expect(!Self.requireModel, "The Whisper tokenizer vocabulary is not on this Mac")
            return
        }
        let tokenizer = try WhisperTokenizer(vocabularyURL: vocabulary, languageCount: 100)
        let cases: [(String, [Int])] = [
            (" Oriel, Safari, Lisbon, TextEdit, Finder.", [422, 16721, 11, 43820, 11, 30812, 4351, 11, 18643, 36, 17975, 11, 479, 5669, 13]),
            ("Hello, world! It's 3.14 o'clock — café naïve 日本語 🎉",
             [15947, 11, 1002, 0, 467, 311, 805, 13, 7271, 277, 6, 9023, 3466, 25118, 1667, 15487, 303, 220, 27311, 31348, 19034, 231]),
            ("  leading spaces\nand\ttabs   trailing  ", [220, 5775, 7673, 198, 474, 197, 83, 17243, 220, 220, 944, 4883, 220, 220]),
            (" -", [359]),
            (" '", [922]),
            (" ", [220]),
        ]
        for (text, ids) in cases {
            #expect(tokenizer.encode(text) == ids, "\(text)")
            #expect(tokenizer.decode(ids) == text, "\(text)")
        }
        #expect(tokenizer.endOfText == 50_257)
        #expect(tokenizer.transcribe == 50_360)
        #expect(tokenizer.startOfPrevious == 50_362)
        #expect(tokenizer.noSpeech == 50_363)
        #expect(tokenizer.timestampBegin == 50_365)
        #expect(tokenizer.languageToken("en") == 50_259)
        let nonSpeech = tokenizer.nonSpeechTokens
        #expect(nonSpeech.count == 82)
        #expect(Array(nonSpeech.prefix(10)) == [1, 2, 7, 8, 9, 10, 14, 25, 26, 27])
        #expect(Array(nonSpeech.suffix(5)) == [36_865, 42_863, 47_425, 49_870, 50_254])
    }

    /// The real model: the fixture as Hermes transcribes it, detected as English, and silence as nothing.
    @Test func realModelTranscribesLikeHermes() throws {
        guard let directory = WhisperModelStore.installedDirectory() else {
            #expect(!Self.requireModel, "Whisper large-v3 is not on this Mac; download it from Settings, Assistant")
            return
        }
        let samples = try Self.readWAV(Self.fixtureURL)
        #expect(abs(Double(samples.count) / 16_000 - 5.06) < 0.05)
        let engine = try WhisperEngine(directory: directory)
        engine.warmUp()

        let english = try engine.transcribe(samples, language: "en", initialPrompt: "")
        #expect(english.text == Self.fixtureText)
        #expect(english.language == "en")

        let prompted = try engine.transcribe(samples, language: "en", initialPrompt: "Oriel, Safari, Lisbon, TextEdit, Finder.")
        #expect(prompted.text == Self.fixtureText)

        let detected = try engine.transcribe(samples, language: nil, initialPrompt: "")
        #expect(detected.language == "en")
        #expect(detected.text == Self.fixtureText)

        let silence = try engine.transcribe([Float](repeating: 0, count: 32_000), language: "en", initialPrompt: "")
        #expect(silence.text.isEmpty)

        #expect(throws: WhisperEngine.Failure.unsupportedLanguage("klingon")) {
            try engine.transcribe(samples, language: "klingon", initialPrompt: "")
        }
        print("Whisper large-v3, 5 s clip after warm-up: \(String(format: "%.2f", english.elapsedSeconds)) s")
    }

    /// 16-bit PCM WAV to samples in −1…1.
    static func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset ..< (offset + 4)], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" {
                let body = data[(offset + 8) ..< min(data.count, offset + 8 + size)]
                return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { index in
                    Float(Int16(bitPattern: UInt16(body[index]) | UInt16(body[index + 1]) << 8)) / 32_768
                }
            }
            offset += 8 + size + (size & 1)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
