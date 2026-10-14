import Foundation
import HermesCaptureProtocol
import Observation

/// What voice input needs from a speech model: Whisper in the app (WhisperBackend.swift), fakes in tests.
protocol SpeechBackend: Sendable {
    var modelName: String { get }
    var downloadBytes: Int64 { get }
    /// A complete copy on this Mac, or nil.
    func installedModel() -> URL?
    /// Fetches the model; progress 0...1. Cancelling the task stops it and removes the partial files.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func load(_ directory: URL) async throws -> any SpeechRecognizer
    /// Deletes Oriel's own copy.
    func removeDownloaded() throws
}

/// A loaded model. One call at a time; the service serializes them.
protocol SpeechRecognizer: AnyObject, Sendable {
    /// 16 kHz mono samples in -1...1. A nil language lets the model detect it; an empty prompt is no prompt.
    func transcribe(_ samples: [Float], language: String?, prompt: String) throws -> String
}

/// The speech model, as the Assistant tab and the phone show it.
enum SpeechModelPhase: Equatable, Sendable {
    /// This Mac cannot run the model.
    case unsupported
    case notInstalled
    case downloading(Double)
    /// On disk; loaded when an utterance arrives.
    case installed
    case loading
    /// In memory.
    case ready
    case failed(String)
}

/// Voice input on the Mac: keeps the model (download, load when it is first prepared or spoken to, unload after ten
/// idle minutes or at once under memory pressure) and turns each phone's utterances into text. Audio lives only in
/// memory, one utterance per session, at most a minute of it, and is gone once it is transcribed or cancelled, or the
/// session ends. Nothing is written to disk but the model.
actor SpeechService {
    static let shared = SpeechService(
        backend: WhisperBackend(),
        preferences: {
            await MainActor.run {
                let settings = SpeechSettings.shared
                return SpeechPreferences(isEnabled: settings.isEnabled, language: settings.whisperLanguage,
                                         prompt: settings.vocabulary)
            }
        },
        observer: { phase in Task { @MainActor in SpeechStatus.shared.phase = phase } },
        memoryPressure: MemoryPressure.system()
    )

    static var isSupportedHere: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// The model stays loaded this long after its last use.
    let idleUnloadNanoseconds: UInt64

    private let backend: any SpeechBackend
    private let preferences: @Sendable () async -> SpeechPreferences
    private let observer: @Sendable (SpeechModelPhase) -> Void
    /// Waits out the idle time; tests stand in for the clock.
    private let sleep: @Sendable (UInt64) async throws -> Void
    private(set) var phase: SpeechModelPhase
    private var recognizer: (any SpeechRecognizer)?
    private var download: Task<Void, Never>?
    private var loading: Task<(any SpeechRecognizer)?, Never>?
    private var idleUnload: Task<Void, Never>?
    /// Transcriptions in progress: the model is in use, whatever the clock or the system says.
    private var activeTranscriptions = 0
    private var sessions: [String: Session] = [:]
    /// Sessions that ended, newest last: a request still queued for one is dropped, never revived.
    private var endedSessions: [String] = []
    private var lastPublishedPercent: Int?
    /// One transcription at a time, off the actor, so ending a session or cancelling a download never waits for one.
    private let transcriptionQueue = DispatchQueue(label: "com.67enterprise.oriel.speech-transcription", qos: .userInitiated)

    private struct Session {
        let reply: @Sendable (SpeechEvent) -> Void
        var subscribed = false
        var utterance: Utterance?
    }

    private struct Utterance {
        let id: String
        var samples = Data()
        var nextSequence = 0
    }

    init(
        backend: any SpeechBackend,
        preferences: @escaping @Sendable () async -> SpeechPreferences,
        observer: @escaping @Sendable (SpeechModelPhase) -> Void = { _ in },
        supported: Bool = SpeechService.isSupportedHere,
        idleUnloadNanoseconds: UInt64 = 10 * 60 * 1_000_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        memoryPressure: AsyncStream<MemoryPressure.Level>? = nil
    ) {
        self.backend = backend
        self.preferences = preferences
        self.observer = observer
        self.idleUnloadNanoseconds = idleUnloadNanoseconds
        self.sleep = sleep
        let phase: SpeechModelPhase = supported ? (backend.installedModel() == nil ? .notInstalled : .installed) : .unsupported
        self.phase = phase
        observer(phase)
        if let memoryPressure {
            Task { [weak self] in
                for await level in memoryPressure {
                    guard let self else { return }
                    await self.memoryPressured(level)
                }
            }
        }
    }

    // MARK: Sessions

    /// A request from the phone of `session`; `reply` sends an event back over that session.
    func handle(_ request: SpeechRequest, session id: String, reply: @escaping @Sendable (SpeechEvent) -> Void) async {
        guard !endedSessions.contains(id) else { return }
        if sessions[id] == nil { sessions[id] = Session(reply: reply) }
        // Any request subscribes: the phone's first one can arrive before this session's packet handler is in place,
        // and a phone that never hears a status would not know to offer the download.
        if request != .subscribe, sessions[id]?.subscribed == false {
            sessions[id]?.subscribed = true
            reply(.status(await status()))
        }
        switch request {
        case .subscribe:
            sessions[id]?.subscribed = true
            reply(.status(await status()))
        case .prepare:
            guard await preferences().isEnabled else {
                reply(.status(await status()))
                return
            }
            prepare()
        case let .begin(utteranceID):
            await begin(utteranceID, in: id)
        case let .audio(chunk):
            append(chunk, in: id)
        case let .end(utteranceID):
            await transcribe(utteranceID, in: id)
        case let .cancel(utteranceID):
            if sessions[id]?.utterance?.id == utteranceID { sessions[id]?.utterance = nil }
        case let .unsupported(version, kind):
            fail(nil, .unsupported, "This Mac does not know \(kind) (speech version \(version)). Update Oriel on the Mac.", in: id)
        }
    }

    /// The session ended: whatever it was saying is dropped, and so is anything it still had queued.
    func endSession(_ id: String) {
        sessions[id] = nil
        endedSessions.append(id)
        if endedSessions.count > 64 { endedSessions.removeFirst(endedSessions.count - 64) }
        SpeechRelay.finish(session: id)
    }

    /// Hands a request from the session's channel to the shared service, in the order the requests arrived (audio
    /// chunks must not overtake each other), with the way back over the same channel.
    nonisolated static func relay(_ request: SpeechRequest, session: String, over channel: PeerSessionChannel) {
        SpeechRelay.send(request, session: session) { [weak channel] event in
            try? channel?.send(.speechEvent(event))
        }
    }

    /// Bytes of audio held for every session, for tests and the privacy contract: zero whenever nobody is speaking.
    var bufferedAudioBytes: Int {
        sessions.values.reduce(0) { $0 + ($1.utterance?.samples.count ?? 0) }
    }

    private func begin(_ utteranceID: String, in id: String) async {
        let enabled = await preferences().isEnabled
        guard enabled, [.installed, .loading, .ready].contains(phase) else {
            sessions[id]?.utterance = nil
            let message = enabled
                ? "Whisper is not on this Mac yet. Download it first."
                : "Voice input is turned off on this Mac."
            fail(utteranceID, enabled ? .modelNotReady : .unavailable, message, in: id)
            return
        }
        sessions[id]?.utterance = Utterance(id: utteranceID)
        // Load while the person speaks, so the text comes back quickly.
        if phase == .installed { _ = startLoading() }
    }

    private func append(_ chunk: SpeechAudioChunk, in id: String) {
        guard var utterance = sessions[id]?.utterance, utterance.id == chunk.utteranceID,
              chunk.sequence == utterance.nextSequence else {
            sessions[id]?.utterance = nil
            fail(chunk.utteranceID, .unexpectedAudio, "The audio arrived out of order. Try again.", in: id)
            return
        }
        guard utterance.samples.count + chunk.samples.count <= SpeechProtocol.maximumUtteranceBytes else {
            sessions[id]?.utterance = nil
            fail(chunk.utteranceID, .tooLong, "Keep it under \(SpeechProtocol.maximumSeconds) seconds.", in: id)
            return
        }
        utterance.samples.append(chunk.samples)
        utterance.nextSequence += 1
        sessions[id]?.utterance = utterance
    }

    private func transcribe(_ utteranceID: String, in id: String) async {
        guard let utterance = sessions[id]?.utterance, utterance.id == utteranceID else {
            fail(utteranceID, .unexpectedAudio, "That recording did not reach the Mac. Try again.", in: id)
            return
        }
        // The audio leaves the session's state now; the samples below are the only copy, gone when this returns.
        sessions[id]?.utterance = nil
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        let samples = Self.floatSamples(utterance.samples)
        let audioSeconds = Double(samples.count) / Double(SpeechProtocol.sampleRate)
        guard let recognizer = await readyRecognizer() else {
            fail(utteranceID, .modelNotReady, failureMessage ?? "Whisper could not start on this Mac.", in: id)
            return
        }
        let preferences = await preferences()
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let raw = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                transcriptionQueue.async {
                    continuation.resume(with: Result {
                        try recognizer.transcribe(samples, language: preferences.language, prompt: preferences.prompt)
                    })
                }
            }
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.utf8.count > SpeechProtocol.maximumTextBytes { text.removeLast() }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            let transcript = try SpeechTranscript(
                utteranceID: utteranceID,
                text: text,
                audioSeconds: audioSeconds,
                elapsedSeconds: elapsed
            )
            sessions[id]?.reply(.transcript(transcript))
            SpeechActivity.record(audioSeconds: audioSeconds, elapsedSeconds: elapsed)
        } catch {
            fail(utteranceID, .transcriptionFailed, "Whisper could not transcribe that. Try again.", in: id)
        }
        scheduleIdleUnload()
    }

    private func fail(_ utteranceID: String?, _ reason: SpeechFailure.Reason, _ message: String, in id: String) {
        guard let failure = try? SpeechFailure(utteranceID: utteranceID, reason: reason, message: String(message.prefix(200))) else { return }
        sessions[id]?.reply(.failure(failure))
    }

    // MARK: The model

    /// Downloads the model if this Mac lacks it, then loads it.
    func prepare() {
        switch phase {
        case .notInstalled, .failed:
            startDownload()
        case .installed:
            _ = startLoading()
        case .unsupported, .downloading, .loading, .ready:
            break
        }
    }

    func cancelDownload() {
        download?.cancel()
    }

    /// Unloads and deletes Oriel's copy of the model.
    func removeModel() {
        guard download == nil, loading == nil else { return }
        recognizer = nil
        try? backend.removeDownloaded()
        set(backend.installedModel() == nil ? .notInstalled : .installed)
    }

    /// Drops the model from memory; it stays on disk.
    func unload() {
        idleUnload?.cancel()
        guard loading == nil, recognizer != nil else { return }
        recognizer = nil
        set(.installed)
    }

    /// Voice input was switched on or off on the Mac: the phones listening hear about it.
    func preferencesChanged() async {
        await publish()
    }

    /// Looks at the disk again, for the Assistant tab: a model can appear or go between sessions.
    func refresh() {
        switch phase {
        case .notInstalled, .installed:
            set(backend.installedModel() == nil ? .notInstalled : .installed)
        default:
            observer(phase)
        }
    }

    private func startDownload() {
        guard download == nil else { return }
        lastPublishedPercent = nil
        SpeechActivity.note("Voice input: downloading \(backend.modelName) from Hugging Face")
        set(.downloading(0))
        let backend = backend
        // The service outlives its download, so the task may hold it.
        download = Task {
            do {
                _ = try await backend.download { fraction in
                    Task { await self.downloadProgressed(fraction) }
                }
                downloadFinished(nil)
            } catch {
                downloadFinished(error)
            }
        }
    }

    private func downloadProgressed(_ fraction: Double) {
        guard case .downloading = phase else { return }
        let clamped = min(max(fraction, 0), 1)
        let percent = Int(clamped * 100)
        // The phone hears each whole percent, not every network read.
        guard percent != lastPublishedPercent else { return }
        lastPublishedPercent = percent
        set(.downloading(clamped))
    }

    private func downloadFinished(_ error: (any Error)?) {
        download = nil
        if let error {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                SpeechActivity.note("Voice input: the model download was cancelled")
                set(backend.installedModel() == nil ? .notInstalled : .installed)
            } else {
                SpeechActivity.note("Voice input: the model download failed: \(Self.describe(error))")
                set(.failed("The download stopped: \(Self.describe(error))"))
            }
            return
        }
        guard backend.installedModel() != nil else {
            set(.failed("The download finished but the model is incomplete. Try again."))
            return
        }
        SpeechActivity.note("Voice input: \(backend.modelName) is downloaded")
        set(.installed)
        _ = startLoading()
    }

    @discardableResult
    private func startLoading() -> Task<(any SpeechRecognizer)?, Never>? {
        if let loading { return loading }
        guard recognizer == nil, let directory = backend.installedModel() else { return nil }
        set(.loading)
        let backend = backend
        let task = Task<(any SpeechRecognizer)?, Never> { [weak self] in
            do {
                let loaded = try await backend.load(directory)
                await self?.loadFinished(loaded, nil)
                return loaded
            } catch {
                await self?.loadFinished(nil, error)
                return nil
            }
        }
        loading = task
        return task
    }

    private func loadFinished(_ loaded: (any SpeechRecognizer)?, _ error: (any Error)?) {
        loading = nil
        if let loaded {
            recognizer = loaded
            set(.ready)
            scheduleIdleUnload()
        } else {
            set(.failed("Whisper could not load: \(Self.describe(error))"))
        }
    }

    private func readyRecognizer() async -> (any SpeechRecognizer)? {
        if let recognizer { return recognizer }
        guard let task = startLoading() else { return nil }
        return await task.value
    }

    private var failureMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    /// The model leaves memory once nobody has used it for the idle time; someone mid-utterance or a transcription
    /// keeps it.
    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let delay = idleUnloadNanoseconds
        let sleep = sleep
        idleUnload = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        if activeTranscriptions > 0 || sessions.values.contains(where: { $0.utterance != nil }) {
            scheduleIdleUnload()
        } else {
            unload()
        }
    }

    /// The Mac is short of memory and the model is its largest tenant: it goes now unless a transcription is using
    /// it, and loads again with the next use.
    private func memoryPressured(_ level: MemoryPressure.Level) {
        guard level != .normal, activeTranscriptions == 0 else { return }
        unload()
    }

    private func set(_ new: SpeechModelPhase) {
        guard new != phase else { return }
        phase = new
        observer(new)
        Task { await publish() }
    }

    private func publish() async {
        let subscribers = sessions.values.filter(\.subscribed).map(\.reply)
        guard !subscribers.isEmpty else { return }
        let status = await status()
        for reply in subscribers { reply(.status(status)) }
    }

    /// The status the phone shows.
    func status() async -> SpeechModelStatus {
        let enabled = await preferences().isEnabled
        let name = backend.modelName
        let state: SpeechModelStatus.State
        var progress: Double?
        var bytes: Int64?
        var message: String?
        switch phase {
        case _ where !enabled:
            state = .unavailable
            message = "Voice input is turned off on this Mac."
        case .unsupported:
            state = .unavailable
            message = "This Mac cannot run Whisper. It needs Apple silicon."
        case .notInstalled:
            state = .notInstalled
            bytes = backend.downloadBytes
        case let .downloading(fraction):
            state = .downloading
            progress = fraction
            bytes = backend.downloadBytes
        case .installed:
            state = .installed
        case .loading:
            state = .loading
        case .ready:
            state = .ready
        case let .failed(reason):
            state = .failed
            message = reason
        }
        return (try? SpeechModelStatus(
            state: state,
            progress: progress,
            modelName: name,
            downloadBytes: bytes,
            message: message.map { String($0.prefix(200)) }
        )) ?? (try! SpeechModelStatus(state: .failed, modelName: "Whisper"))
    }

    /// 16-bit little-endian PCM to floats in -1...1.
    static func floatSamples(_ pcm: Data) -> [Float] {
        let count = pcm.count / 2
        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let value = Int16(bitPattern: UInt16(raw[2 * index]) | UInt16(raw[2 * index + 1]) << 8)
                samples[index] = Float(value) / 32_768
            }
        }
        return samples
    }

    private static func describe(_ error: (any Error)?) -> String {
        guard let error else { return "unknown error" }
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return String(describing: error).prefix(160).description
    }
}

/// One ordered pipe per session from the channel's callbacks into the service: a stream drained by a single task.
/// When the session ends, whatever is still queued is dropped, not handled.
final class SpeechRelay: @unchecked Sendable {
    /// Two minutes of half-second chunks and then some; a phone that floods past it loses audio, which the sequence
    /// check then refuses.
    static let queueLimit = 512

    private let continuation: AsyncStream<SpeechRequest>.Continuation
    private let lock = NSLock()
    private var closed = false

    private init(session: String, service: SpeechService, reply: @escaping @Sendable (SpeechEvent) -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SpeechRequest.self,
            bufferingPolicy: .bufferingOldest(Self.queueLimit)
        )
        self.continuation = continuation
        Task { [self] in
            for await request in stream {
                guard !isClosed else { break }
                await service.handle(request, session: session, reply: reply)
            }
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    private func close() {
        lock.withLock { closed = true }
        continuation.finish()
    }

    private static let registry = SpeechRelayRegistry()

    static func send(
        _ request: SpeechRequest,
        session: String,
        service: SpeechService = .shared,
        reply: @escaping @Sendable (SpeechEvent) -> Void
    ) {
        registry.relay(for: session) { SpeechRelay(session: session, service: service, reply: reply) }?
            .continuation.yield(request)
    }

    static func finish(session: String) {
        registry.remove(session)?.close()
    }
}

private final class SpeechRelayRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var relays: [String: SpeechRelay] = [:]
    /// Ended sessions, newest last: a packet that arrives after the end gets no new relay.
    private var finished: [String] = []

    func relay(for session: String, make: () -> SpeechRelay) -> SpeechRelay? {
        lock.withLock {
            if let relay = relays[session] { return relay }
            guard !finished.contains(session) else { return nil }
            let relay = make()
            relays[session] = relay
            return relay
        }
    }

    func remove(_ session: String) -> SpeechRelay? {
        lock.withLock {
            finished.append(session)
            if finished.count > 64 { finished.removeFirst(finished.count - 64) }
            return relays.removeValue(forKey: session)
        }
    }
}

/// What the person chose in Settings, read at the moment it is used.
struct SpeechPreferences: Sendable, Equatable {
    var isEnabled: Bool
    /// Whisper's language code, nil to detect.
    var language: String?
    var prompt: String
}

/// The model's phase for the Assistant tab.
@MainActor
@Observable
final class SpeechStatus {
    static let shared = SpeechStatus()
    var phase: SpeechModelPhase = .notInstalled
    /// The last utterance: its length and how long Whisper took.
    var lastTranscription: (audioSeconds: Double, elapsedSeconds: Double)?
}

/// Writes one line per utterance to the activity log, and the timing for the Assistant tab. Never the words.
enum SpeechActivity {
    static func record(audioSeconds: Double, elapsedSeconds: Double) {
        Task { @MainActor in
            SpeechStatus.shared.lastTranscription = (audioSeconds, elapsedSeconds)
        }
        note(String(format: "Voice input: %.1f s of speech transcribed in %.2f s", audioSeconds, elapsedSeconds))
    }

    static func note(_ line: String) {
        ActivityLog.shared.write(.assistant, line)
    }
}
