import Foundation

/// One model call. Text in, text out; an optional JPEG rides along only when the sharing
/// policy let the runtime attach it.
struct AssistantModelMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

struct AssistantModelRequest: Sendable {
    let model: String
    let system: String
    let messages: [AssistantModelMessage]
    /// Attached to the last user message.
    let imageJPEG: Data?
    let maxTokens: Int
    let temperature: Double

    init(
        model: String,
        system: String,
        messages: [AssistantModelMessage],
        imageJPEG: Data? = nil,
        maxTokens: Int = 600,
        temperature: Double = 0.1
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.imageJPEG = imageJPEG
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

struct AssistantModelReply: Equatable, Sendable {
    let text: String
    let model: String
    let latencyMilliseconds: Int
}

enum AssistantModelProviderError: Error, Equatable, Sendable {
    case invalidEndpoint
    case missingAPIKey
    case httpStatus(Int, String)
    case emptyReply
    case transport(String)
}

protocol AssistantModelProvider: Sendable {
    var displayName: String { get }
    func complete(_ request: AssistantModelRequest) async throws -> AssistantModelReply
    func listModels() async throws -> [String]
    /// Models are loaded on demand; a run that is over gives the memory back.
    func release(models: [String]) async
}

extension AssistantModelProvider {
    func release(models: [String]) async {}
}

/// Ollama's own API: `keep_alive` on every call so a model stays warm only during a run and
/// is unloaded when the run ends, images as base64 on the message, `/api/tags` for the list.
struct OllamaProvider: AssistantModelProvider {
    static let keepAliveDuringRun = "10m"

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .assistantSession) {
        self.baseURL = baseURL
        self.session = session
    }

    var displayName: String { "Ollama" }

    func complete(_ request: AssistantModelRequest) async throws -> AssistantModelReply {
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        for (index, message) in request.messages.enumerated() {
            var entry: [String: Any] = ["role": message.role.rawValue, "content": message.text]
            if index == request.messages.count - 1, message.role == .user, let jpeg = request.imageJPEG {
                entry["images"] = [jpeg.base64EncodedString()]
            }
            messages.append(entry)
        }
        let body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": false,
            "keep_alive": Self.keepAliveDuringRun,
            // Thinking models (Qwen3.5) would spend the whole answer budget thinking, and
            // Ollama's default window silently drops the start of a long screen description.
            "think": false,
            "options": ["temperature": request.temperature, "num_predict": request.maxTokens, "num_ctx": 8_192],
        ]
        let started = DispatchTime.now().uptimeNanoseconds
        let json = try await post(path: "api/chat", body: body)
        let text = ((json["message"] as? [String: Any])?["content"] as? String) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantModelProviderError.emptyReply
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return AssistantModelReply(text: text, model: (json["model"] as? String) ?? request.model, latencyMilliseconds: elapsed)
    }

    func listModels() async throws -> [String] {
        let json = try await get(path: "api/tags")
        return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
    }

    /// What Ollama holds in memory right now.
    func loadedModels() async throws -> [String] {
        let json = try await get(path: "api/ps")
        return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
    }

    func release(models: [String]) async {
        for model in Set(models) where !model.isEmpty {
            _ = try? await post(path: "api/generate", body: ["model": model, "keep_alive": 0])
        }
    }

    private func get(path: String) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AssistantModelProviderError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AssistantModelProviderError.httpStatus(status, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantModelProviderError.emptyReply
        }
        return json
    }
}

/// Ollama, LM Studio, llama.cpp's server, vLLM, OpenRouter, OpenAI itself: anything that
/// speaks `/v1/chat/completions`. Images go as data URLs in content parts.
struct OpenAICompatibleProvider: AssistantModelProvider {
    let baseURL: URL
    let apiKey: String?
    let label: String
    let session: URLSession

    init(baseURL: URL, apiKey: String?, label: String, session: URLSession = .assistantSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.label = label
        self.session = session
    }

    var displayName: String { label }

    func complete(_ request: AssistantModelRequest) async throws -> AssistantModelReply {
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        for (index, message) in request.messages.enumerated() {
            let isLastUser = index == request.messages.count - 1 && message.role == .user
            if isLastUser, let jpeg = request.imageJPEG {
                messages.append([
                    "role": "user",
                    "content": [
                        ["type": "text", "text": message.text],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                    ],
                ])
            } else {
                messages.append(["role": message.role.rawValue, "content": message.text])
            }
        }
        let body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "stream": false,
        ]
        let started = DispatchTime.now().uptimeNanoseconds
        let json = try await post(path: "chat/completions", body: body)
        let choices = json["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        var text = (message?["content"] as? String) ?? ""
        if text.isEmpty, let parts = message?["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantModelProviderError.emptyReply
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return AssistantModelReply(text: text, model: (json["model"] as? String) ?? request.model, latencyMilliseconds: elapsed)
    }

    func listModels() async throws -> [String] {
        let json = try await get(path: "models")
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }.sorted()
    }

    private func get(path: String) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "GET"
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return try await send(request)
    }

    private func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func endpoint(_ path: String) -> URL {
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        if !base.hasSuffix("/v1/") { base += "v1/" }
        return URL(string: base + path) ?? baseURL
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AssistantModelProviderError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AssistantModelProviderError.httpStatus(status, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantModelProviderError.emptyReply
        }
        return json
    }
}

/// Anthropic's Messages API with the user's own key. Images go as base64 blocks.
struct AnthropicProvider: AssistantModelProvider {
    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    static let defaultModel = "claude-sonnet-5"

    let baseURL: URL
    let apiKey: String
    let session: URLSession

    init(baseURL: URL = AnthropicProvider.defaultBaseURL, apiKey: String, session: URLSession = .assistantSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    var displayName: String { "Anthropic" }

    func complete(_ request: AssistantModelRequest) async throws -> AssistantModelReply {
        guard !apiKey.isEmpty else { throw AssistantModelProviderError.missingAPIKey }
        var messages: [[String: Any]] = []
        for (index, message) in request.messages.enumerated() {
            let isLastUser = index == request.messages.count - 1 && message.role == .user
            if isLastUser, let jpeg = request.imageJPEG {
                messages.append([
                    "role": "user",
                    "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                        ["type": "text", "text": message.text],
                    ],
                ])
            } else {
                messages.append(["role": message.role.rawValue, "content": message.text])
            }
        }
        let body: [String: Any] = [
            "model": request.model,
            "system": request.system,
            "messages": messages,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
        ]
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = DispatchTime.now().uptimeNanoseconds
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AssistantModelProviderError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AssistantModelProviderError.httpStatus(status, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantModelProviderError.emptyReply
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantModelProviderError.emptyReply
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return AssistantModelReply(text: text, model: (json["model"] as? String) ?? request.model, latencyMilliseconds: elapsed)
    }

    func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw AssistantModelProviderError.missingAPIKey }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantModelProviderError.httpStatus(status, "")
        }
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}

extension URLSession {
    /// Model calls can take a while on a small machine; local servers never answer in 10 s.
    static let assistantSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
