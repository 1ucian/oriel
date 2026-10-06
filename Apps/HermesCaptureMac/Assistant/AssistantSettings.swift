import Foundation
import HermesCaptureCore
import HermesCaptureProtocol
import Observation

/// Where a model runs. The default is the built-in engine on this Mac with open, permissively
/// licensed models; Ollama, any OpenAI-compatible server, or Anthropic with the user's own
/// key are the alternatives.
enum AssistantProviderKind: String, CaseIterable, Identifiable, Codable {
    case appleOnDevice
    case builtIn
    case ollama
    case openAICompatible
    case anthropic

    var id: Self { self }

    var title: String {
        switch self {
        case .appleOnDevice: "Apple on-device (macOS 26)"
        case .builtIn: "Built in, on this Mac"
        case .ollama: "Ollama on this Mac or my network"
        case .openAICompatible: "OpenAI-compatible endpoint"
        case .anthropic: "Anthropic"
        }
    }
}

enum AssistantVisionPolicy: String, CaseIterable, Identifiable, Codable {
    case auto
    case always
    case never

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "When the text picture isn't enough"
        case .always: "Every step"
        case .never: "Never"
        }
    }
}

/// One role's endpoint: the planner (big brain) or the executor (fast brain).
struct AssistantEndpointSettings: Equatable, Codable {
    var kind: AssistantProviderKind
    var baseURL: String
    var model: String

    /// Apple's model when this Mac has it: nothing to download, so the assistant works at once.
    static var plannerDefault: AssistantEndpointSettings {
        AppleModelProvider.availability == .available
            ? AssistantEndpointSettings(kind: .appleOnDevice, baseURL: AssistantSettings.defaultOllamaURL, model: AppleModelProvider.modelID)
            : AssistantEndpointSettings(kind: .builtIn, baseURL: AssistantSettings.defaultOllamaURL, model: EmbeddedModelCatalog.planner.id)
    }
    static var executorDefault: AssistantEndpointSettings {
        AppleModelProvider.availability == .available
            ? AssistantEndpointSettings(kind: .appleOnDevice, baseURL: AssistantSettings.defaultOllamaURL, model: AppleModelProvider.modelID)
            : AssistantEndpointSettings(kind: .builtIn, baseURL: AssistantSettings.defaultOllamaURL, model: EmbeddedModelCatalog.fast.id)
    }

    var resolvedBaseURL: URL? {
        switch kind {
        case .builtIn, .appleOnDevice:
            return nil
        case .anthropic:
            return AnthropicProvider.defaultBaseURL
        case .ollama, .openAICompatible:
            let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil else { return nil }
            return url
        }
    }

    var locality: ModelLocality {
        switch kind {
        case .builtIn, .appleOnDevice: .onThisMac
        case .anthropic: .internet
        case .ollama, .openAICompatible: ScreenshotSharingPolicy.locality(ofHost: resolvedBaseURL?.host ?? "")
        }
    }

    var resolvedModel: String {
        if kind == .appleOnDevice { return AppleModelProvider.modelID }
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, kind == .anthropic { return AnthropicProvider.defaultModel }
        return trimmed
    }

    func isConfigured(apiKey: String) -> Bool {
        switch kind {
        case .appleOnDevice: AppleModelProvider.availability == .available
        case .builtIn: EmbeddedModelCatalog.supportedHere && !resolvedModel.isEmpty
        case .anthropic: !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .ollama, .openAICompatible: resolvedBaseURL != nil && !resolvedModel.isEmpty
        }
    }

    func makeProvider(apiKey: String) -> (any AssistantModelProvider)? {
        switch kind {
        case .appleOnDevice:
            guard AppleModelProvider.availability == .available else { return nil }
            return AppleModelProvider()
        case .builtIn:
            guard EmbeddedModelCatalog.supportedHere else { return nil }
            return EmbeddedModelProvider()
        case .anthropic:
            guard isConfigured(apiKey: apiKey) else { return nil }
            return AnthropicProvider(apiKey: apiKey)
        case .ollama:
            guard let url = resolvedBaseURL else { return nil }
            return OllamaProvider(baseURL: url)
        case .openAICompatible:
            guard let url = resolvedBaseURL else { return nil }
            let key = apiKey.trimmingCharacters(in: .whitespaces)
            return OpenAICompatibleProvider(baseURL: url, apiKey: key.isEmpty ? nil : key, label: url.host ?? "endpoint")
        }
    }

    func displayName(role: String) -> String {
        let model: String
        switch kind {
        case .appleOnDevice: model = AppleModelProvider.title
        case .builtIn: model = EmbeddedModelCatalog.model(id: resolvedModel)?.title ?? resolvedModel
        default: model = resolvedModel
        }
        let place: String
        switch kind {
        case .appleOnDevice: place = "on this Mac"
        case .builtIn: place = "built in"
        case .ollama: place = "Ollama"
        case .openAICompatible: place = resolvedBaseURL?.host ?? "endpoint"
        case .anthropic: place = "Anthropic"
        }
        return "\(role) \(model) · \(place)"
    }

    /// Eyes for an executor that cannot see pixels: the built-in engine for a catalog id,
    /// otherwise Ollama on this Mac.
    static func visionProvider(for model: String?) -> (any AssistantModelProvider)? {
        guard let model, !model.isEmpty else { return nil }
        if model.contains("/") { return EmbeddedModelCatalog.supportedHere ? EmbeddedModelProvider() : nil }
        guard let url = URL(string: AssistantSettings.defaultOllamaURL) else { return nil }
        return OllamaProvider(baseURL: url)
    }
}

@MainActor
@Observable
final class AssistantSettings {
    /// ORIEL_SETTINGS_SUITE gives a development copy its own settings, so trying a model on
    /// it never changes the companion the owner uses.
    static let shared = AssistantSettings(
        defaults: ProcessInfo.processInfo.environment["ORIEL_SETTINGS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    )

    nonisolated static let defaultOllamaURL = "http://127.0.0.1:11434"
    nonisolated static let defaultOllamaVisionModel = "qwen3.5:9b"
    nonisolated static let defaultStepsPerSubtask = 8

    enum Role: String {
        case planner
        case executor
    }

    var planner: AssistantEndpointSettings { didSet { save() } }
    var executor: AssistantEndpointSettings { didSet { save() } }
    var visionModel: String { didSet { save() } }
    var visionPolicy: AssistantVisionPolicy { didSet { save() } }
    var screenshotsAllowedToRemote: Bool { didSet { save() } }
    var maximumSteps: Int { didSet { save() } }
    var stepsPerSubtask: Int { didSet { save() } }
    /// Keys live in the keychain only.
    var plannerAPIKey: String { didSet { try? plannerSecrets.save(plannerAPIKey) } }
    var executorAPIKey: String { didSet { try? executorSecrets.save(executorAPIKey) } }

    private let defaults: UserDefaults
    private let plannerSecrets: AssistantSecretStore
    private let executorSecrets: AssistantSecretStore
    private var loading = true

    init(defaults: UserDefaults = .standard,
         plannerSecrets: AssistantSecretStore = AssistantSecretStore(account: "planner-api-key"),
         executorSecrets: AssistantSecretStore = AssistantSecretStore(account: "api-key")) {
        self.defaults = defaults
        self.plannerSecrets = plannerSecrets
        self.executorSecrets = executorSecrets
        planner = Self.endpoint(defaults, Keys.planner) ?? .plannerDefault
        executor = Self.endpoint(defaults, Keys.executor) ?? .executorDefault
        visionModel = defaults.string(forKey: Keys.visionModel) ?? EmbeddedModelCatalog.vision.id
        visionPolicy = AssistantVisionPolicy(rawValue: defaults.string(forKey: Keys.visionPolicy) ?? "") ?? .auto
        screenshotsAllowedToRemote = defaults.bool(forKey: Keys.screenshotsAllowedToRemote)
        let steps = defaults.integer(forKey: Keys.maximumSteps)
        maximumSteps = AgentInstruction.stepLimits.contains(steps) ? steps : AgentInstruction.defaultStepLimit
        let perSubtask = defaults.integer(forKey: Keys.stepsPerSubtask)
        stepsPerSubtask = (2...20).contains(perSubtask) ? perSubtask : Self.defaultStepsPerSubtask
        plannerAPIKey = plannerSecrets.load() ?? ""
        executorAPIKey = executorSecrets.load() ?? ""
        loading = false
    }

    private enum Keys {
        static let planner = "assistant.planner"
        static let executor = "assistant.executor"
        static let visionModel = "assistant.visionModel"
        static let visionPolicy = "assistant.visionPolicy"
        static let screenshotsAllowedToRemote = "assistant.screenshotsAllowedToRemote"
        static let maximumSteps = "assistant.maximumSteps"
        static let stepsPerSubtask = "assistant.stepsPerSubtask"
    }

    private static func endpoint(_ defaults: UserDefaults, _ key: String) -> AssistantEndpointSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AssistantEndpointSettings.self, from: data)
    }

    private func save() {
        guard !loading else { return }
        defaults.set(try? JSONEncoder().encode(planner), forKey: Keys.planner)
        defaults.set(try? JSONEncoder().encode(executor), forKey: Keys.executor)
        defaults.set(visionModel, forKey: Keys.visionModel)
        defaults.set(visionPolicy.rawValue, forKey: Keys.visionPolicy)
        defaults.set(screenshotsAllowedToRemote, forKey: Keys.screenshotsAllowedToRemote)
        defaults.set(maximumSteps, forKey: Keys.maximumSteps)
        defaults.set(stepsPerSubtask, forKey: Keys.stepsPerSubtask)
    }

    func apiKey(for role: Role) -> String {
        role == .planner ? plannerAPIKey : executorAPIKey
    }

    func endpoint(for role: Role) -> AssistantEndpointSettings {
        role == .planner ? planner : executor
    }

    /// The sensible model names for a freshly chosen provider kind.
    func applyDefaults(for role: Role) {
        switch role {
        case .planner:
            switch planner.kind {
            case .appleOnDevice: planner.model = AppleModelProvider.modelID
            case .builtIn: planner.model = EmbeddedModelCatalog.planner.id
            case .ollama: planner.baseURL = Self.defaultOllamaURL; planner.model = "qwen3.5:9b"
            case .anthropic: planner.model = AnthropicProvider.defaultModel
            case .openAICompatible: break
            }
        case .executor:
            switch executor.kind {
            case .appleOnDevice:
                executor.model = AppleModelProvider.modelID
                if visionModel.trimmingCharacters(in: .whitespaces).isEmpty { visionModel = Self.defaultOllamaVisionModel }
            case .builtIn:
                executor.model = EmbeddedModelCatalog.fast.id
                visionModel = EmbeddedModelCatalog.vision.id
            case .ollama:
                executor.baseURL = Self.defaultOllamaURL
                executor.model = "qwen3.5:4b"
                visionModel = Self.defaultOllamaVisionModel
            case .anthropic:
                executor.model = AnthropicProvider.defaultModel
            case .openAICompatible:
                break
            }
        }
    }

    var isConfigured: Bool {
        planner.isConfigured(apiKey: plannerAPIKey) && executor.isConfigured(apiKey: executorAPIKey)
    }

    func makeProvider(for role: Role) -> (any AssistantModelProvider)? {
        endpoint(for: role).makeProvider(apiKey: apiKey(for: role))
    }

    /// Nil until both roles have an endpoint and a model.
    func runConfiguration() -> AssistantRunConfiguration? {
        guard let plannerProvider = makeProvider(for: .planner),
              let executorProvider = makeProvider(for: .executor),
              !planner.resolvedModel.isEmpty, !executor.resolvedModel.isEmpty else { return nil }
        let vision = visionModel.trimmingCharacters(in: .whitespaces)
        let executorVision: String?
        switch executor.kind {
        case .anthropic: executorVision = executor.resolvedModel
        case .builtIn: executorVision = vision.isEmpty ? EmbeddedModelCatalog.vision.id : vision
        case .ollama, .openAICompatible, .appleOnDevice: executorVision = vision.isEmpty ? nil : vision
        }
        let eyes = executor.kind == .appleOnDevice ? AssistantEndpointSettings.visionProvider(for: executorVision) : nil
        return AssistantRunConfiguration(
            planner: AssistantModelRole(provider: plannerProvider, model: planner.resolvedModel, visionModel: nil,
                                        locality: planner.locality, displayName: planner.displayName(role: "Planner")),
            executor: AssistantModelRole(provider: executorProvider, model: executor.resolvedModel, visionModel: executorVision,
                                         visionProvider: eyes, locality: executor.locality,
                                         displayName: executor.displayName(role: "Executor")),
            visionPolicy: visionPolicy,
            screenshotsAllowedToRemote: screenshotsAllowedToRemote,
            maximumSteps: maximumSteps,
            stepsPerSubtask: stepsPerSubtask
        )
    }

    /// What the phone shows: the executor is what sees the screen, so its locality rules.
    func providerSummary(isRunning: Bool) -> AgentProviderSummary {
        let locality: AgentProviderSummary.Locality
        switch executor.locality {
        case .onThisMac: locality = .onThisMac
        case .localNetwork: locality = .localNetwork
        case .internet: locality = .internet
        }
        let shares = ScreenshotSharingPolicy.mayShareScreenshots(
            locality: executor.locality, remoteSharingEnabled: screenshotsAllowedToRemote, instructionAllows: true
        )
        let name = isConfigured
            ? "\(planner.displayName(role: "Planner")) · \(executor.displayName(role: "Executor"))"
            : (EmbeddedModelCatalog.supportedHere ? "No model configured on the Mac" : "Built-in models need Apple silicon; pick another provider on the Mac")
        return AgentProviderSummary(displayName: name, locality: locality, screenshotsShared: shares,
                                    isConfigured: isConfigured, isRunning: isRunning)
    }
}
