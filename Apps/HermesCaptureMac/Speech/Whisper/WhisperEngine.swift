import Foundation
import MLX

/// What one clip turned into.
struct WhisperTranscription: Sendable, Equatable {
    let text: String
    /// The language the text is in: the one asked for, or the one detected.
    let language: String?
    let elapsedSeconds: Double
}

/// One loaded Whisper model, the transcriber Hermes runs (mlx_whisper with large-v3) ported to
/// mlx-swift. The caller serializes use; the weights stay loaded until the engine is released.
final class WhisperEngine: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case missingFile(String)
        case unsupportedModel
        case unsupportedLanguage(String)

        var description: String {
            switch self {
            case let .missingFile(name): "The Whisper model is missing \(name). Download it again."
            case .unsupportedModel: "This Whisper model is not supported; Oriel uses large-v3."
            case let .unsupportedLanguage(language): "Whisper does not know the language \(language)."
            }
        }
    }

    /// Below this peak (about −50 dBFS) a clip is treated as silence and not decoded: Whisper,
    /// Hermes's included, reads pure silence as "Thank you."
    static let silencePeak: Float = 0.003_16

    let dimensions: WhisperDimensions
    private let model: WhisperModel
    private let tokenizer: WhisperTokenizer

    /// Loads `config.json` and the weights from `directory`, and the tokenizer vocabulary from
    /// there or from wherever the model store keeps it. Nothing is read until all three match
    /// the SHA-256 pinned in the model store, so these are the only files that are ever loaded.
    init(directory: URL) throws {
        let configURL = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { throw Failure.missingFile("config.json") }
        let vocabularyURL = [directory.appendingPathComponent("vocab.json")]
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? WhisperModelStore.vocabularyURL()
        guard let vocabularyURL else { throw Failure.missingFile("vocab.json") }
        let weightsURL = directory.appendingPathComponent("weights.npz")
        guard FileManager.default.fileExists(atPath: weightsURL.path) else { throw Failure.missingFile("weights.npz") }
        try WhisperModelStore.verify(config: configURL, vocabulary: vocabularyURL, weights: weightsURL)

        let dimensions = try JSONDecoder().decode(WhisperDimensions.self, from: Data(contentsOf: configURL))
        guard dimensions.isMultilingual else { throw Failure.unsupportedModel }
        let tokenizer = try WhisperTokenizer(vocabularyURL: vocabularyURL, languageCount: dimensions.languageCount)
        let weights = try WhisperNPZ.load(weightsURL)
        let model = try WhisperModel(dimensions: dimensions, weights: weights)
        eval(model.parameters)

        self.dimensions = dimensions
        self.model = model
        self.tokenizer = tokenizer
    }

    /// 16 kHz mono samples in −1…1. `language` nil detects it; an empty `initialPrompt` is none.
    func transcribe(_ samples: [Float], language: String?, initialPrompt: String) throws -> WhisperTranscription {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 }

        var code: String?
        if let language, !language.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let resolved = WhisperTokenizer.languageCode(for: language),
                  tokenizer.languageToken(resolved) != nil else {
                throw Failure.unsupportedLanguage(language)
            }
            code = resolved
        }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak >= Self.silencePeak else {
            return WhisperTranscription(text: "", language: code, elapsedSeconds: elapsed())
        }

        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Its own GPU stream, so a clip and an assistant model working at the same time do not
        // share a command queue.
        let result = Stream.withNewDefaultStream {
            WhisperTranscriber(model: model, tokenizer: tokenizer)
                .transcribe(samples, language: code, initialPrompt: prompt.isEmpty ? nil : prompt)
        }
        // The weights stay; the working buffers go back (about 0.9 GB, some 15 ms to rebuild).
        Memory.clearCache()
        return WhisperTranscription(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: result.language,
            elapsedSeconds: elapsed()
        )
    }

    /// Runs one window of silence through the model so the GPU kernels exist before the first
    /// real clip. The first run after an install or an OS update compiles them, a few seconds;
    /// after that it costs about as much as a short clip.
    func warmUp() {
        Stream.withNewDefaultStream {
            _ = WhisperTranscriber(model: model, tokenizer: tokenizer)
                .transcribe([Float](repeating: 0, count: WhisperAudio.sampleRate), language: "en", initialPrompt: nil)
        }
        Memory.clearCache()
    }
}
