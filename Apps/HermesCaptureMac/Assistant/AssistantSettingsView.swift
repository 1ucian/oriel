import AppKit
import HermesCaptureCore
import SwiftUI

/// Settings, Assistant: the two brains, where they run, and what they may see.
struct AssistantSettingsView: View {
    @Bindable var settings: AssistantSettings
    @State private var loadedOllamaModels: [String] = []
    private var embedded: EmbeddedModelStatus { EmbeddedModelStatus.shared }

    var body: some View {
        Form {
            ProfileSection(settings: settings)
            if settings.profile == .custom {
                customSections
            }

            Section {
                LabeledContent("The executor runs", value: localityLine(settings.executor))
                LabeledContent("The planner runs", value: localityLine(settings.planner))
                Toggle("Share screenshots with an executor on the internet", isOn: $settings.screenshotsAllowedToRemote)
                    .accessibilityIdentifier("assistant.remoteScreenshots")
                Stepper("Steps per instruction: \(settings.maximumSteps)", value: $settings.maximumSteps, in: 1...60)
                Stepper("Steps per sub-task before re-planning: \(settings.stepsPerSubtask)", value: $settings.stepsPerSubtask, in: 2...20)
            } header: {
                Text("Privacy and limits")
            } footer: {
                Text("The screen is read on this Mac: accessibility controls and on-device text recognition, with secure fields and anything that looks like a secret left out. An executor on this Mac or on your network may also get a downscaled screenshot. On the internet it gets text only unless you switch screenshots on here and allow them on the phone for a run. The planner never gets pixels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.planner.kind == .ollama || settings.executor.kind == .ollama {
                Section("Ollama memory") {
                    LabeledContent("Loaded now", value: loadedOllamaModels.isEmpty ? "nothing" : loadedOllamaModels.joined(separator: ", "))
                    HStack {
                        Button("Refresh") { refreshLoaded() }
                        Button("Unload all") { unloadAll() }
                            .disabled(loadedOllamaModels.isEmpty)
                    }
                    Text("Models load when the phone connects and stay loaded while it is connected, so each step is quick; they are unloaded when it disconnects or after ten idle minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VoiceInputSettingsSection(settings: SpeechSettings.shared)
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLoaded)
    }

    @ViewBuilder
    private var customSections: some View {
            EndpointSection(
                title: "Planner",
                subtitle: "The big brain. Breaks your instruction into small sub-tasks and revises when the executor is stuck. Sees text only, never pixels. Worth a larger model, or your own frontier key.",
                role: .planner,
                endpoint: $settings.planner,
                apiKey: $settings.plannerAPIKey,
                settings: settings
            )
            EndpointSection(
                title: "Executor",
                subtitle: "The fast brain. Reads the screen on this Mac and carries out each sub-task click by click. A small local model keeps it quick.",
                role: .executor,
                endpoint: $settings.executor,
                apiKey: $settings.executorAPIKey,
                settings: settings
            ) {
                if settings.executor.kind == .builtIn {
                    LabeledContent("Vision model", value: EmbeddedModelCatalog.model(id: settings.visionModel)?.title ?? settings.visionModel)
                } else if settings.executor.kind != .anthropic {
                    TextField("Vision model (when the text picture isn't enough)", text: $settings.visionModel)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("assistant.visionModel")
                }
                Picker("Use the vision model", selection: $settings.visionPolicy) {
                    ForEach(AssistantVisionPolicy.allCases) { Text($0.title).tag($0) }
                }
            }

            if settings.planner.kind == .builtIn || settings.executor.kind == .builtIn {
                builtInModels
            }
    }

    private var builtInModels: some View {
        Section {
            ForEach(EmbeddedModelCatalog.all) { model in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title).font(.body)
                        Text("\(model.id) · \(String(format: "%.1f", model.approximateGigabytes)) GB · \(model.license)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let progress = embedded.downloadProgress[model.id] {
                        ProgressView(value: progress)
                            .frame(width: 90)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    } else if embedded.loaded.contains(model.id) {
                        Text("Loaded").font(.caption).foregroundStyle(.green)
                    } else if EmbeddedModelEngine.isDownloaded(model.id) {
                        Text("Downloaded").font(.caption).foregroundStyle(.secondary)
                        Button("Remove") { EmbeddedModelEngine.removeDownloaded(model.id) }
                            .controlSize(.small)
                    } else {
                        Button("Download now") { prefetch(model.id) }
                            .controlSize(.small)
                    }
                }
            }
            HStack {
                Button("Show models folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([EmbeddedModelEngine.modelsDirectory])
                }
                .controlSize(.small)
                if let error = embedded.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                }
            }
        } header: {
            Text("Built-in models")
        } footer: {
            Text(EmbeddedModelCatalog.supportedHere
                 ? "Open models, fetched from Hugging Face on first use into Oriel's own folder, loaded when a run starts and dropped when it ends. Nothing else is installed."
                 : "Built-in models need a Mac with Apple silicon. On this Mac choose Ollama or an endpoint.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func prefetch(_ id: String) {
        Task {
            _ = try? await EmbeddedModelEngine.shared.container(for: id)
            await EmbeddedModelEngine.shared.release([id])
        }
    }

    private func localityLine(_ endpoint: AssistantEndpointSettings) -> String {
        switch endpoint.locality {
        case .onThisMac: "on this Mac"
        case .localNetwork: "on your network (\(endpoint.resolvedBaseURL?.host ?? ""))"
        case .internet: "on the internet"
        }
    }

    private var ollamaProviders: [OllamaProvider] {
        var out: [OllamaProvider] = []
        for role in [AssistantSettings.Role.planner, .executor] {
            if let provider = settings.makeProvider(for: role) as? OllamaProvider,
               !out.contains(where: { $0.baseURL == provider.baseURL }) {
                out.append(provider)
            }
        }
        return out
    }

    private func refreshLoaded() {
        let providers = ollamaProviders
        guard !providers.isEmpty else { return }
        Task {
            var names: [String] = []
            for provider in providers { names += (try? await provider.loadedModels()) ?? [] }
            loadedOllamaModels = Array(Set(names)).sorted()
        }
    }

    private func unloadAll() {
        let providers = ollamaProviders
        let names = loadedOllamaModels
        Task {
            for provider in providers { await provider.release(models: names) }
            refreshLoaded()
        }
    }
}

/// Lite, Standard or Custom: picking Lite or Standard switches to its models and downloads
/// the ones Ollama does not have yet.
private struct ProfileSection: View {
    @Bindable var settings: AssistantSettings
    private var downloads: AssistantProfileDownloads { AssistantProfileDownloads.shared }
    private let memory = AssistantProfile.memoryGigabytes

    var body: some View {
        Section {
            Picker("Profile", selection: Binding(get: { settings.profile }, set: { choose($0) })) {
                ForEach(AssistantProfile.allCases) { profile in
                    Text(profile == AssistantProfile.recommended(memoryGigabytes: memory) ? "\(profile.title) (recommended)" : profile.title)
                        .tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("assistant.profile")
            Text(settings.profile.summary)
                .font(.callout)
            if settings.profile != .custom {
                if !settings.profile.fits(memoryGigabytes: memory) {
                    Label("This Mac has \(memory) GB of memory; \(settings.profile.title) needs \(settings.profile.minimumMemoryGigabytes ?? 0) GB. Choose Lite.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Navigates with", value: settings.executor.kind == .appleOnDevice
                               ? "Apple on-device, with \(AssistantProfile.navigationModel) as eyes"
                               : AssistantProfile.navigationModel)
                LabeledContent("Plans and reads answers with", value: settings.planner.resolvedModel)
                ForEach(settings.profile.models, id: \.self) { model in
                    modelRow(model)
                }
                if downloads.ollamaRunning == false {
                    Label("Lite and Standard run their models in Ollama. Install it, open it, then choose the profile again.", systemImage: "arrow.down.circle")
                        .font(.caption)
                    Button("Get Ollama") {
                        if let url = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
                if let error = downloads.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        } header: {
            Text("Models")
        } footer: {
            Text("This Mac has \(memory) GB of memory. Lite needs 16 GB, Standard 32 GB. Both navigate with the same small, fast models; Standard plans and reads answers with a bigger one. Models download only when you choose a profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await downloads.refresh() }
    }

    @ViewBuilder
    private func modelRow(_ model: String) -> some View {
        HStack {
            Text(model)
            Spacer()
            if let fraction = downloads.progress[model] {
                ProgressView(value: fraction).frame(width: 110)
                Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
            } else if downloads.isInstalled(model) {
                Label("Downloaded", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else {
                Button("Download") { Task { await downloads.download([model]) } }
                    .controlSize(.small)
                    .disabled(downloads.ollamaRunning != true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.profile.model.\(model)")
    }

    private func choose(_ profile: AssistantProfile) {
        settings.use(profile)
        let models = profile.models
        guard !models.isEmpty else { return }
        Task { await downloads.download(models) }
    }
}

private struct EndpointSection<Extra: View>: View {
    let title: String
    let subtitle: String
    let role: AssistantSettings.Role
    @Binding var endpoint: AssistantEndpointSettings
    @Binding var apiKey: String
    let settings: AssistantSettings
    @ViewBuilder var extra: () -> Extra
    @State private var models: [String] = []
    @State private var checkResult: String?
    @State private var checking = false

    init(
        title: String,
        subtitle: String,
        role: AssistantSettings.Role,
        endpoint: Binding<AssistantEndpointSettings>,
        apiKey: Binding<String>,
        settings: AssistantSettings,
        @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.role = role
        _endpoint = endpoint
        _apiKey = apiKey
        self.settings = settings
        self.extra = extra
    }

    var body: some View {
        Section {
            Picker("Runs with", selection: $endpoint.kind) {
                ForEach(AssistantProviderKind.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: endpoint.kind) { _, _ in
                settings.applyDefaults(for: role)
                models = []
                checkResult = nil
            }
            if endpoint.kind == .builtIn {
                Picker("Model", selection: $endpoint.model) {
                    ForEach(EmbeddedModelCatalog.all.filter { !$0.isVision }) { model in
                        Text("\(model.title) · \(String(format: "%.1f", model.approximateGigabytes)) GB").tag(model.id)
                    }
                }
                .accessibilityIdentifier("assistant.\(role.rawValue).model")
            } else if endpoint.kind == .appleOnDevice {
                Label(appleAvailabilityText, systemImage: AppleModelProvider.availability == .available ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .accessibilityIdentifier("assistant.\(role.rawValue).model")
            } else {
                if endpoint.kind != .anthropic {
                    TextField("Endpoint", text: $endpoint.baseURL, prompt: Text(AssistantSettings.defaultOllamaURL))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("assistant.\(role.rawValue).endpoint")
                }
                HStack {
                    TextField("Model", text: $endpoint.model)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("assistant.\(role.rawValue).model")
                    if !models.isEmpty {
                        Menu {
                            ForEach(models, id: \.self) { model in
                                Button(model) { endpoint.model = model }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .accessibilityLabel("Choose a model")
                    }
                }
                if endpoint.kind != .ollama {
                    SecureField("API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("assistant.\(role.rawValue).apiKey")
                }
            }
            extra()
            if endpoint.kind != .builtIn, endpoint.kind != .appleOnDevice {
                HStack {
                    Button(checking ? "Checking…" : "Check connection") { check() }
                        .disabled(checking)
                        .accessibilityIdentifier("assistant.\(role.rawValue).check")
                    if let checkResult {
                        Text(checkResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(subtitle + " " + kindFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appleAvailabilityText: String {
        switch AppleModelProvider.availability {
        case .available: "Apple's on-device model is ready."
        case let .unavailable(reason): "Apple's on-device model is unavailable: \(reason)."
        }
    }

    private var kindFooter: String {
        switch endpoint.kind {
        case .appleOnDevice:
            "Apple's on-device model (Apple Intelligence). Nothing to download; macOS loads and unloads it. Text only with a 4,096-token window, so the executor's eyes stay the vision model below."
        case .builtIn:
            "Runs with MLX on this Mac. The weights download once, on first use."
        case .ollama:
            "Open models with permissive licenses (Apache-2.0): qwen3.5:9b or larger for the planner and as the eyes, qwen3.5:4b for the executor. Install with “ollama pull”."
        case .openAICompatible:
            "Any server with a /v1/chat/completions endpoint: LM Studio or llama.cpp on your network, or a hosted service with your own key."
        case .anthropic:
            "Your own Anthropic key. Pixels are never sent unless Privacy below allows it."
        }
    }

    private func check() {
        checking = true
        checkResult = nil
        let provider = endpoint.makeProvider(apiKey: apiKey)
        let wanted = [endpoint.resolvedModel] + (role == .executor && endpoint.kind == .ollama ? [settings.visionModel] : [])
        let isOllama = endpoint.kind == .ollama
        Task {
            defer { checking = false }
            guard let provider else {
                checkResult = "Endpoint or key missing."
                return
            }
            do {
                let names = try await provider.listModels()
                models = names
                let missing = isOllama ? wanted.filter { !$0.isEmpty && !names.contains($0) } : []
                checkResult = missing.isEmpty
                    ? "Reachable, \(names.count) models."
                    : "Reachable, but not installed: \(missing.joined(separator: ", ")). Run: ollama pull \(missing.joined(separator: " && ollama pull "))"
            } catch {
                checkResult = AssistantRuntime.describe(error)
            }
        }
    }
}
