import CoreImage
import Foundation
import HermesCaptureCore
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Observation
import Tokenizers

/// An open model Oriel can run by itself, with MLX on Apple silicon. Weights are fetched
/// on first use into Oriel's own folder, loaded when a run starts, and dropped when it ends.
struct EmbeddedModel: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isVision: Bool
    let approximateGigabytes: Double
    let license: String
}

enum EmbeddedModelCatalog {
    static let fast = EmbeddedModel(id: "mlx-community/Qwen3-4B-4bit", title: "Qwen3 4B", isVision: false, approximateGigabytes: 2.3, license: "Apache-2.0")
    static let planner = EmbeddedModel(id: "mlx-community/Qwen3-8B-4bit", title: "Qwen3 8B", isVision: false, approximateGigabytes: 4.6, license: "Apache-2.0")
    static let vision = EmbeddedModel(id: "mlx-community/Qwen3-VL-4B-Instruct-4bit", title: "Qwen3-VL 4B", isVision: true, approximateGigabytes: 3.1, license: "Apache-2.0")
    static let all = [fast, planner, vision]

    static func model(id: String) -> EmbeddedModel? {
        all.first { $0.id == id }
    }

    static func isVision(_ id: String) -> Bool {
        model(id: id)?.isVision ?? id.lowercased().contains("-vl")
    }

    static var supportedHere: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}

/// What the settings screen shows: downloads in flight, what is loaded, the folder.
@MainActor
@Observable
final class EmbeddedModelStatus {
    static let shared = EmbeddedModelStatus()

    private(set) var downloadProgress: [String: Double] = [:]
    private(set) var loaded: Set<String> = []
    var lastError: String?

    func downloading(_ id: String, fraction: Double) { downloadProgress[id] = fraction }
    func finishedLoading(_ id: String) { downloadProgress[id] = nil; loaded.insert(id) }
    func released(_ ids: [String]) { for id in ids { loaded.remove(id); downloadProgress[id] = nil } }
    func failed(_ id: String, _ error: String) { downloadProgress[id] = nil; lastError = error }
}

enum EmbeddedModelError: Error, CustomStringConvertible {
    case unsupportedMachine

    var description: String {
        switch self {
        case .unsupportedMachine: "Built-in models need a Mac with Apple silicon. Choose Ollama or an endpoint instead."
        }
    }
}

/// Owns the loaded weights. One copy per model id, loaded on demand, shared by the planner
/// and executor when they name the same model.
actor EmbeddedModelEngine {
    static let shared = EmbeddedModelEngine()

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Oriel/Models", isDirectory: true)
    }

    private var containers: [String: ModelContainer] = [:]
    private var loading: [String: Task<ModelContainer, any Error>] = [:]

    init() {
        // The Hugging Face client reads its cache location from the environment at first use.
        let directory = Self.modelsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("HF_HUB_CACHE", directory.path, 1)
        setenv("HF_HOME", directory.deletingLastPathComponent().path, 0)
    }

    /// True when the weights are already on disk (the hub cache keeps one folder per repo).
    nonisolated static func isDownloaded(_ id: String) -> Bool {
        let folder = "models--" + id.replacingOccurrences(of: "/", with: "--")
        let url = modelsDirectory.appendingPathComponent(folder).appendingPathComponent("snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return !entries.isEmpty
    }

    nonisolated static func removeDownloaded(_ id: String) {
        let folder = "models--" + id.replacingOccurrences(of: "/", with: "--")
        try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(folder))
    }

    func container(for id: String) async throws -> ModelContainer {
        guard EmbeddedModelCatalog.supportedHere else { throw EmbeddedModelError.unsupportedMachine }
        if let container = containers[id] { return container }
        if let task = loading[id] { return try await task.value }
        let vision = EmbeddedModelCatalog.isVision(id)
        let task = Task { () -> ModelContainer in
            let configuration = ModelConfiguration(id: id)
            let progress: @Sendable (Progress) -> Void = { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in EmbeddedModelStatus.shared.downloading(id, fraction: fraction) }
            }
            if vision {
                return try await VLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                    configuration: configuration, progressHandler: progress
                )
            }
            return try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration, progressHandler: progress
            )
        }
        loading[id] = task
        defer { loading[id] = nil }
        do {
            let container = try await task.value
            containers[id] = container
            await MainActor.run { EmbeddedModelStatus.shared.finishedLoading(id) }
            return container
        } catch {
            let message = String(describing: error)
            await MainActor.run { EmbeddedModelStatus.shared.failed(id, message) }
            throw error
        }
    }

    func release(_ ids: [String]) async {
        for id in ids { containers[id] = nil }
        if containers.isEmpty { MLX.Memory.clearCache() }
        await MainActor.run { EmbeddedModelStatus.shared.released(ids) }
    }

    var loadedModels: [String] { containers.keys.sorted() }
}

/// The built-in engine as a provider: same contract as Ollama or a frontier endpoint,
/// nothing leaves the Mac.
struct EmbeddedModelProvider: AssistantModelProvider {
    var displayName: String { "Built in" }

    func complete(_ request: AssistantModelRequest) async throws -> AssistantModelReply {
        let container = try await EmbeddedModelEngine.shared.container(for: request.model)
        var parameters = GenerateParameters()
        parameters.maxTokens = request.maxTokens
        parameters.temperature = Float(request.temperature)
        let session = ChatSession(container, instructions: request.system, generateParameters: parameters)
        // Runs carry one user message with their own history inside it.
        let prompt = request.messages.map { $0.role == .user ? $0.text : "Assistant: \($0.text)" }.joined(separator: "\n\n")
        let started = DispatchTime.now().uptimeNanoseconds
        let text: String
        if EmbeddedModelCatalog.isVision(request.model), let jpeg = request.imageJPEG, let image = CIImage(data: jpeg) {
            text = try await session.respond(to: prompt, image: .ciImage(image))
        } else {
            text = try await session.respond(to: prompt)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantModelProviderError.emptyReply
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return AssistantModelReply(text: text, model: request.model, latencyMilliseconds: elapsed)
    }

    func listModels() async throws -> [String] {
        EmbeddedModelCatalog.all.map(\.id)
    }

    func release(models: [String]) async {
        await EmbeddedModelEngine.shared.release(models)
    }
}
