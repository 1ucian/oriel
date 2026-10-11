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

/// Ready-made model sets, downloaded on demand through Ollama. Both navigate with the same
/// small, fast models (Apple's on-device model when this Mac has it, otherwise Qwen3.5 4B,
/// with Qwen3.5 4B as the eyes), so clicks and typing feel the same; Standard spends its
/// memory on a bigger planner, which plans and reads the answers.
enum AssistantProfile: String, CaseIterable, Identifiable, Codable {
    case lite
    case standard
    case custom

    var id: Self { self }

    static let navigationModel = "qwen3.5:4b"

    var title: String {
        switch self {
        case .lite: "Lite"
        case .standard: "Standard"
        case .custom: "Custom"
        }
    }

    var minimumMemoryGigabytes: Int? {
        switch self {
        case .lite: 16
        case .standard: 32
        case .custom: nil
        }
    }

    var plannerModel: String? {
        switch self {
        case .lite: "qwen3.5:4b"
        case .standard: "qwen3.5:9b"
        case .custom: nil
        }
    }

    /// What Ollama has to hold for this profile.
    var models: [String] {
        guard let plannerModel else { return [] }
        return Array(Set([plannerModel, Self.navigationModel])).sorted()
    }

    var downloadGigabytes: Double {
        switch self {
        case .lite: 3.3
        case .standard: 9.9
        case .custom: 0
        }
    }

    var summary: String {
        switch self {
        case .lite: "Fast navigation with a 4B planner. Needs 16 GB of memory and a 3.3 GB download."
        case .standard: "The same fast navigation with a 9B planner that plans and reads answers more reliably. Needs 32 GB of memory and a 9.9 GB download."
        case .custom: "Choose each model and where it runs."
        }
    }

    static var memoryGigabytes: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    static func recommended(memoryGigabytes: Int) -> AssistantProfile {
        memoryGigabytes >= 32 ? .standard : .lite
    }

    func fits(memoryGigabytes: Int) -> Bool {
        memoryGigabytes >= (minimumMemoryGigabytes ?? 0)
    }

    /// The planner, executor and eyes this profile uses on a Mac with or without Apple's model.
    func endpoints(appleModelAvailable: Bool) -> (planner: AssistantEndpointSettings, executor: AssistantEndpointSettings, vision: String)? {
        guard let plannerModel else { return nil }
        let url = AssistantSettings.defaultOllamaURL
        let executor = appleModelAvailable
            ? AssistantEndpointSettings(kind: .appleOnDevice, baseURL: url, model: AppleModelProvider.modelID)
            : AssistantEndpointSettings(kind: .ollama, baseURL: url, model: Self.navigationModel)
        return (AssistantEndpointSettings(kind: .ollama, baseURL: url, model: plannerModel), executor, Self.navigationModel)
    }

    /// The profile a set of settings amounts to, or custom.
    static func matching(planner: AssistantEndpointSettings, executor: AssistantEndpointSettings, vision: String) -> AssistantProfile {
        for profile in [AssistantProfile.lite, .standard] {
            for apple in [true, false] {
                if let set = profile.endpoints(appleModelAvailable: apple),
                   set.planner.kind == planner.kind, set.planner.resolvedModel == planner.resolvedModel,
                   set.executor.kind == executor.kind, set.executor.resolvedModel == executor.resolvedModel,
                   set.vision == vision {
                    return profile
                }
            }
        }
        return .custom
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

/// The downloads a profile needs, as the settings screen shows them.
@MainActor
@Observable
final class AssistantProfileDownloads {
    static let shared = AssistantProfileDownloads()

    private(set) var installed: Set<String> = []
    private(set) var progress: [String: Double] = [:]
    /// Nil until checked.
    private(set) var ollamaRunning: Bool?
    private(set) var lastError: String?

    private var baseURL: URL { URL(string: AssistantSettings.defaultOllamaURL)! }

    func refresh() async {
        do {
            installed = try await OllamaModelLibrary.installed(at: baseURL)
            ollamaRunning = true
        } catch {
            ollamaRunning = false
        }
    }

    func isInstalled(_ model: String) -> Bool {
        installed.contains(model) || installed.contains(model + ":latest")
    }

    /// Downloads what is missing, one model at a time.
    func download(_ models: [String]) async {
        await refresh()
        guard ollamaRunning == true else { return }
        lastError = nil
        for model in models where !isInstalled(model) && progress[model] == nil {
            progress[model] = 0
            do {
                try await OllamaModelLibrary.pull(model, at: baseURL) { fraction in
                    Task { @MainActor in AssistantProfileDownloads.shared.progress[model] = fraction }
                }
                installed.insert(model)
            } catch {
                lastError = "\(model): \(error)"
            }
            progress[model] = nil
        }
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

    var profile: AssistantProfile { didSet { save() } }
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
        let storedPlanner = Self.endpoint(defaults, Keys.planner) ?? .plannerDefault
        let storedExecutor = Self.endpoint(defaults, Keys.executor) ?? .executorDefault
        let storedVision = defaults.string(forKey: Keys.visionModel) ?? EmbeddedModelCatalog.vision.id
        profile = AssistantProfile(rawValue: defaults.string(forKey: Keys.profile) ?? "")
            ?? AssistantProfile.matching(planner: storedPlanner, executor: storedExecutor, vision: storedVision)
        planner = storedPlanner
        executor = storedExecutor
        visionModel = storedVision
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

    /// Switches to a profile's models; the downloads it needs are started by the caller.
    func use(_ chosen: AssistantProfile, appleModelAvailable: Bool = AppleModelProvider.availability == .available) {
        if let set = chosen.endpoints(appleModelAvailable: appleModelAvailable) {
            planner = set.planner
            executor = set.executor
            visionModel = set.vision
            visionPolicy = .auto
        }
        profile = chosen
    }

    private enum Keys {
        static let profile = "assistant.profile"
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
        defaults.set(profile.rawValue, forKey: Keys.profile)
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
