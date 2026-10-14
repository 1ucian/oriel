import Foundation

/// Whisper large-v3 on MLX (Whisper/), the model Hermes uses, as voice input's backend.
struct WhisperBackend: SpeechBackend {
    var modelName: String { WhisperModelStore.displayName }
    /// What the download would fetch now: about 1 MB of tokenizer when Hermes already left the weights in the
    /// shared Hugging Face cache, the whole 3.1 GB otherwise.
    var downloadBytes: Int64 { WhisperModelStore.missingBytes }

    func installedModel() -> URL? {
        WhisperModelStore.installedDirectory()
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await WhisperModelStore.download(progress: progress)
    }

    func load(_ directory: URL) async throws -> any SpeechRecognizer {
        // Reading three gigabytes of weights takes seconds: off the service's executor, so status keeps flowing.
        // The warm-up compiles the GPU kernels now (seconds after an install or OS update), not on the first words.
        try await Task.detached(priority: .userInitiated) {
            let engine = try WhisperEngine(directory: directory)
            engine.warmUp()
            return WhisperRecognizer(engine: engine)
        }.value
    }

    func removeDownloaded() throws {
        try WhisperModelStore.removeDownloaded()
    }
}

final class WhisperRecognizer: SpeechRecognizer {
    private let engine: WhisperEngine

    init(engine: WhisperEngine) {
        self.engine = engine
    }

    func transcribe(_ samples: [Float], language: String?, prompt: String) throws -> String {
        try engine.transcribe(samples, language: language, initialPrompt: prompt).text
    }
}
