import Foundation
import HermesCaptureProtocol
import Testing
@testable import HermesCaptureMac

/// The Mac's side of voice input as a state machine: the model's phases, one utterance per session, the limits, and
/// that no audio outlives its utterance. A fake model stands in for Whisper.
struct SpeechServiceTests {
    static let utterance = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    @Test func aSubscriberHearsTheModelIsMissingAndItsSize() async throws {
        let backend = FakeBackend(installed: false)
        let service = makeService(backend)
        let phone = Inbox()
        await service.handle(.subscribe, session: "s", reply: phone.receive)
        #expect(phone.statuses.last?.state == .notInstalled)
        #expect(phone.statuses.last?.downloadBytes == 3_000)
        #expect(phone.statuses.last?.modelName == "Fake Whisper")
    }

    @Test func speakingBeforeTheModelIsThereFailsPolitely() async throws {
        let service = makeService(FakeBackend(installed: false))
        let phone = Inbox()
        await service.handle(.begin(utteranceID: Self.utterance), session: "s", reply: phone.receive)
        #expect(phone.failures.map(\.reason) == [.modelNotReady])
        #expect(await service.bufferedAudioBytes == 0)
    }

    @Test func prepareDownloadsThenLoadsAndTheSubscriberSeesEachStep() async throws {
        let backend = FakeBackend(installed: false)
        let service = makeService(backend)
        let phone = Inbox()
        await service.handle(.subscribe, session: "s", reply: phone.receive)
        await service.handle(.prepare, session: "s", reply: phone.receive)
        try await waitUntil { await service.phase == .ready }
        try await waitUntil { phone.statuses.last?.state == .ready }
        let states = phone.statuses.map(\.state)
        #expect(states.first == .notInstalled)
        #expect(states.contains(.downloading))
        #expect(states.contains(.loading))
        #expect(phone.statuses.contains { $0.state == .downloading && $0.progress == 0.5 })
        #expect(backend.loads == 1)
    }

    @Test func anUtteranceComesBackAsTextAndLeavesNoAudioBehind() async throws {
        let backend = FakeBackend(installed: true, text: "  Open Safari and search for the weather in Lisbon.  ")
        let service = makeService(backend, preferences: SpeechPreferences(isEnabled: true, language: "en", prompt: "Lisbon, Safari"))
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        // The model loads while the person speaks.
        try await waitUntil { await service.phase == .ready }
        let pcm = Data([0xFF, 0x7F, 0x00, 0x80, 0x00, 0x00, 0x00, 0x40])
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: pcm)), session: "s", reply: phone.receive)
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 1, samples: pcm)), session: "s", reply: phone.receive)
        #expect(await service.bufferedAudioBytes == 16)
        await service.handle(.end(utteranceID: id), session: "s", reply: phone.receive)

        #expect(phone.transcripts.map(\.text) == ["Open Safari and search for the weather in Lisbon."])
        #expect(phone.transcripts.first?.utteranceID == id)
        #expect(phone.transcripts.first?.audioSeconds == 8.0 / 16_000)
        #expect(await service.bufferedAudioBytes == 0)
        let heard = try #require(backend.recognizer.calls.first)
        #expect(heard.samples.count == 8)
        #expect(heard.samples[0] == Float(Int16.max) / 32_768 && heard.samples[1] == -1 && heard.samples[3] == 0.5)
        #expect(heard.language == "en" && heard.prompt == "Lisbon, Safari")
    }

    @Test func audioOutOfOrderOrForAnotherUtteranceIsDropped() async throws {
        let service = makeService(FakeBackend(installed: true))
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 1, samples: Data([0, 0]))), session: "s", reply: phone.receive)
        #expect(phone.failures.map(\.reason) == [.unexpectedAudio])
        #expect(await service.bufferedAudioBytes == 0)
        await service.handle(.end(utteranceID: id), session: "s", reply: phone.receive)
        #expect(phone.transcripts.isEmpty)
    }

    @Test func moreThanAMinuteIsRefusedAndDropped() async throws {
        let service = makeService(FakeBackend(installed: true))
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        let chunk = Data(count: SpeechProtocol.maximumChunkBytes)
        var sequence = 0
        while phone.failures.isEmpty, sequence < 40 {
            await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: sequence, samples: chunk)), session: "s", reply: phone.receive)
            sequence += 1
        }
        #expect(phone.failures.map(\.reason) == [.tooLong])
        #expect(sequence == SpeechProtocol.maximumUtteranceBytes / SpeechProtocol.maximumChunkBytes + 1)
        #expect(await service.bufferedAudioBytes == 0)
    }

    @Test func cancelAndTheSessionEndingDropTheAudio() async throws {
        let backend = FakeBackend(installed: true)
        let service = makeService(backend)
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data([1, 0]))), session: "s", reply: phone.receive)
        await service.handle(.cancel(utteranceID: id), session: "s", reply: phone.receive)
        #expect(await service.bufferedAudioBytes == 0)
        await service.handle(.end(utteranceID: id), session: "s", reply: phone.receive)
        #expect(phone.transcripts.isEmpty)

        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data([1, 0]))), session: "s", reply: phone.receive)
        await service.endSession("s")
        #expect(await service.bufferedAudioBytes == 0)
        #expect(backend.recognizer.calls.isEmpty)
    }

    @Test func aCancelledDownloadLeavesTheModelMissingAndAFailedOneCanBeRetried() async throws {
        let backend = FakeBackend(installed: false, holdDownload: true)
        let service = makeService(backend)
        await service.prepare()
        try await waitUntil { await service.phase == .downloading(0.5) }
        await service.cancelDownload()
        try await waitUntil { await service.phase == .notInstalled }

        let failing = FakeBackend(installed: false, downloadError: URLError(.notConnectedToInternet))
        let retrying = makeService(failing)
        await retrying.prepare()
        try await waitUntil { if case .failed = await retrying.phase { true } else { false } }
        failing.downloadError = nil
        await retrying.prepare()
        try await waitUntil { await retrying.phase == .ready }
    }

    @Test func theModelLeavesMemoryAfterItsIdleTime() async throws {
        let service = makeService(FakeBackend(installed: true), idle: 50_000_000)
        await service.prepare()
        try await waitUntil { await service.phase == .ready }
        try await waitUntil { await service.phase == .installed }
    }

    @Test func aModelThatFailsItsCheckSaysSoAndCanBeTriedAgain() async throws {
        let backend = FakeBackend(installed: true)
        backend.loadError = WhisperModelStore.Failure.failedCheck(file: "weights.npz", ownCopyRemoved: true)
        let service = makeService(backend)
        let phone = Inbox()
        await service.handle(.subscribe, session: "s", reply: phone.receive)
        await service.prepare()
        try await waitUntil { phone.statuses.last?.state == .failed }
        #expect(phone.statuses.last?.message?.contains("The voice model didn't pass its check") == true)

        backend.loadError = nil
        await service.prepare()
        try await waitUntil { await service.phase == .ready }
    }

    @Test func voiceInputOffOnTheMacSaysSoAndTakesNoAudio() async throws {
        let service = makeService(FakeBackend(installed: true), preferences: SpeechPreferences(isEnabled: false, language: nil, prompt: ""))
        let phone = Inbox()
        await service.handle(.subscribe, session: "s", reply: phone.receive)
        #expect(phone.statuses.last?.state == .unavailable)
        await service.handle(.begin(utteranceID: Self.utterance), session: "s", reply: phone.receive)
        #expect(phone.failures.map(\.reason) == [.unavailable])
    }

    @Test func aRequestFromANewerPhoneIsAnsweredNotFatal() async throws {
        let service = makeService(FakeBackend(installed: true))
        let phone = Inbox()
        await service.handle(.unsupported(version: 2, kind: "stream"), session: "s", reply: phone.receive)
        #expect(phone.failures.map(\.reason) == [.unsupported])
    }

    @Test func requestsStillQueuedForAnEndedSessionAreDropped() async throws {
        let service = makeService(FakeBackend(installed: true))
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.subscribe, session: "s", reply: phone.receive)
        await service.endSession("s")
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data([1, 0]))), session: "s", reply: phone.receive)
        #expect(await service.bufferedAudioBytes == 0, "an ended session must not come back to life")
        #expect(phone.failures.isEmpty && phone.transcripts.isEmpty)
    }

    @Test func anyFirstRequestBringsTheStatus() async throws {
        let service = makeService(FakeBackend(installed: false))
        let phone = Inbox()
        // The subscribe got lost on its way (the Mac's handler was not in place yet): the begin still tells the phone
        // what the model is doing, so it can offer the download.
        await service.handle(.begin(utteranceID: Self.utterance), session: "s", reply: phone.receive)
        #expect(phone.statuses.map(\.state) == [.notInstalled])
        #expect(phone.failures.map(\.reason) == [.modelNotReady])
    }

    @Test func theModelLeavesMemoryAfterACancelledUtteranceToo() async throws {
        let service = makeService(FakeBackend(installed: true), idle: 80_000_000)
        let phone = Inbox()
        await service.handle(.begin(utteranceID: Self.utterance), session: "s", reply: phone.receive)
        try await waitUntil { await service.phase == .ready }
        await service.handle(.cancel(utteranceID: Self.utterance), session: "s", reply: phone.receive)
        try await waitUntil { await service.phase == .installed }
    }

    @Test func someoneSpeakingKeepsTheModelLoaded() async throws {
        let service = makeService(FakeBackend(installed: true), idle: 80_000_000)
        let phone = Inbox()
        await service.handle(.begin(utteranceID: Self.utterance), session: "s", reply: phone.receive)
        try await waitUntil { await service.phase == .ready }
        try await Task.sleep(for: .milliseconds(250))
        #expect(await service.phase == .ready)
    }

    // MARK: The model in memory

    @Test func theModelStaysOnDiskUntilSomeonePreparesIt() async throws {
        let backend = FakeBackend(installed: true)
        let service = makeService(backend)
        try await Task.sleep(for: .milliseconds(100))
        #expect(backend.loads == 0)
        #expect(await service.phase == .installed)
        await service.prepare()
        try await waitUntil { await service.phase == .ready }
        #expect(backend.loads == 1)
    }

    @Test func theModelLeavesMemoryTenMinutesAfterItsLastTranscription() async throws {
        let timer = ManualTimer()
        let service = SpeechService(backend: FakeBackend(installed: true), preferences: { .on }, supported: true, sleep: timer.sleep)
        #expect(await service.idleUnloadNanoseconds == 600_000_000_000, "ten minutes is the default")
        await service.prepare()
        try await waitUntil { await service.phase == .ready }
        try await waitUntil { timer.requested.count == 1 }
        #expect(timer.requested == [600_000_000_000])

        // A transcription starts the ten minutes over.
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data(count: 3_200))), session: "s", reply: phone.receive)
        await service.handle(.end(utteranceID: id), session: "s", reply: phone.receive)
        #expect(phone.transcripts.count == 1)
        try await waitUntil { timer.requested.count == 2 }
        #expect(timer.waiting == 1, "the first ten minutes were cancelled, not left running")

        timer.fire()
        try await waitUntil { await service.phase == .installed }
    }

    @Test func aTimerThatFiresDuringATranscriptionLeavesTheModelAlone() async throws {
        let timer = ManualTimer()
        let backend = FakeBackend(installed: true, transcribeSeconds: 0.5)
        let service = SpeechService(backend: backend, preferences: { .on }, supported: true, sleep: timer.sleep)
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        try await waitUntil { await service.phase == .ready }
        try await waitUntil { timer.waiting == 1 }
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data(count: 3_200))), session: "s", reply: phone.receive)
        let transcribing = Task { await service.handle(.end(utteranceID: id), session: "s", reply: phone.receive) }
        try await waitUntil { backend.recognizer.calls.count == 1 }
        timer.fire()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await service.phase == .ready, "the model is in use")
        await transcribing.value
        #expect(phone.transcripts.count == 1)
        #expect(await service.phase == .ready)
    }

    @Test func memoryPressureUnloadsTheModelAtOnce() async throws {
        let (pressure, signal) = AsyncStream.makeStream(of: MemoryPressure.Level.self)
        let backend = FakeBackend(installed: true)
        let service = makeService(backend, memoryPressure: pressure)
        await service.prepare()
        try await waitUntil { await service.phase == .ready }

        signal.yield(.normal)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await service.phase == .ready, "pressure easing is no reason to unload")

        signal.yield(.warning)
        try await waitUntil { await service.phase == .installed }

        await service.prepare()
        try await waitUntil { await service.phase == .ready }
        signal.yield(.critical)
        try await waitUntil { await service.phase == .installed }
        #expect(backend.loads == 2, "the next use loads it again")
    }

    @Test func memoryPressureDuringATranscriptionLeavesTheModelAlone() async throws {
        let (pressure, signal) = AsyncStream.makeStream(of: MemoryPressure.Level.self)
        let backend = FakeBackend(installed: true, transcribeSeconds: 0.5)
        let service = makeService(backend, memoryPressure: pressure)
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        try await waitUntil { await service.phase == .ready }
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data(count: 3_200))), session: "s", reply: phone.receive)
        let transcribing = Task { await service.handle(.end(utteranceID: id), session: "s", reply: phone.receive) }
        try await waitUntil { backend.recognizer.calls.count == 1 }
        signal.yield(.critical)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await service.phase == .ready, "the model is in use")
        await transcribing.value
        #expect(phone.transcripts.count == 1)
        #expect(await service.phase == .ready)
    }

    @Test func theSystemSourceListensForWarningsAndCriticalEvents() {
        #expect(MemoryPressure.eventMask == [.warning, .critical])
        #expect(MemoryPressure.level(of: .warning) == .warning)
        #expect(MemoryPressure.level(of: .critical) == .critical)
        #expect(MemoryPressure.level(of: [.warning, .critical]) == .critical)
        #expect(MemoryPressure.level(of: .normal) == .normal)
    }

    @Test func endingASessionDoesNotWaitForATranscription() async throws {
        let backend = FakeBackend(installed: true, transcribeSeconds: 0.6)
        let service = makeService(backend)
        let phone = Inbox()
        let id = Self.utterance
        await service.handle(.begin(utteranceID: id), session: "s", reply: phone.receive)
        await service.handle(.audio(try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data(count: 3_200))), session: "s", reply: phone.receive)
        let transcribing = Task { await service.handle(.end(utteranceID: id), session: "s", reply: phone.receive) }
        try await waitUntil { backend.recognizer.calls.count == 1 }
        let started = Date()
        await service.endSession("s")
        #expect(Date().timeIntervalSince(started) < 0.3, "the actor stays free while Whisper works")
        await transcribing.value
        #expect(phone.transcripts.isEmpty, "the text of an ended session goes nowhere")
    }

    @Test func aMacThatCannotRunTheModelSaysSo() async throws {
        let service = SpeechService(backend: FakeBackend(installed: true), preferences: { .on }, supported: false)
        #expect(await service.phase == .unsupported)
        #expect(await service.status().state == .unavailable)
    }

    @Test func theOfferGoesOnlyToSessionsThatCanTypeOrInstruct() async throws {
        await MainActor.run {
            let defaults = UserDefaults(suiteName: "oriel.speech-settings-test-\(UUID().uuidString)")!
            let settings = SpeechSettings(defaults: defaults)
            #expect(settings.isEnabled)
            #expect(settings.language == "en")
            #expect(settings.vocabulary.isEmpty)
            #expect(settings.offer(for: [.viewScreen]) == nil)
            let expected: SpeechTranscriptionOffer? = SpeechService.isSupportedHere ? .current : nil
            #expect(settings.offer(for: SessionCapability.phaseOneDefaults) == expected)
            settings.isEnabled = false
            #expect(settings.offer(for: SessionCapability.assistantDefaults) == nil)
            settings.language = ""
            #expect(settings.whisperLanguage == nil)
        }
    }

    // MARK: Helpers

    private func makeService(
        _ backend: FakeBackend,
        preferences: SpeechPreferences = .on,
        idle: UInt64 = 60_000_000_000,
        memoryPressure: AsyncStream<MemoryPressure.Level>? = nil
    ) -> SpeechService {
        SpeechService(backend: backend, preferences: { preferences }, supported: true, idleUnloadNanoseconds: idle,
                      memoryPressure: memoryPressure)
    }
}

extension SpeechPreferences {
    static let on = SpeechPreferences(isEnabled: true, language: "en", prompt: "")
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition timed out")
}

/// A stand-in for the idle timer: each sleep waits until `fire` ends the newest one, or its task is cancelled.
private final class ManualTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [UInt64] = []
    private var sleepers: [(id: Int, wake: AsyncStream<Void>.Continuation)] = []

    /// The durations asked for, oldest first.
    var requested: [UInt64] { lock.withLock { asked } }
    /// Sleeps still waiting.
    var waiting: Int { lock.withLock { sleepers.count } }

    func sleep(_ nanoseconds: UInt64) async throws {
        let (stream, wake) = AsyncStream.makeStream(of: Void.self)
        let id = lock.withLock { () -> Int in
            asked.append(nanoseconds)
            let id = asked.count
            sleepers.append((id, wake))
            return id
        }
        defer { lock.withLock { sleepers.removeAll { $0.id == id } } }
        for await _ in stream { break }
        try Task.checkCancellation()
    }

    func fire() {
        lock.withLock { sleepers.last?.wake }?.yield()
    }
}

private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpeechEvent] = []

    var receive: @Sendable (SpeechEvent) -> Void { { [self] event in lock.withLock { events.append(event) } } }

    var statuses: [SpeechModelStatus] {
        lock.withLock { events.compactMap { if case let .status(status) = $0 { status } else { nil } } }
    }

    var transcripts: [SpeechTranscript] {
        lock.withLock { events.compactMap { if case let .transcript(transcript) = $0 { transcript } else { nil } } }
    }

    var failures: [SpeechFailure] {
        lock.withLock { events.compactMap { if case let .failure(failure) = $0 { failure } else { nil } } }
    }
}

private final class FakeRecognizer: SpeechRecognizer, @unchecked Sendable {
    struct Call { let samples: [Float]; let language: String?; let prompt: String }
    private let lock = NSLock()
    private var stored: [Call] = []
    let text: String
    let seconds: Double

    init(text: String, seconds: Double = 0) {
        self.text = text
        self.seconds = seconds
    }

    var calls: [Call] { lock.withLock { stored } }

    func transcribe(_ samples: [Float], language: String?, prompt: String) throws -> String {
        lock.withLock { stored.append(Call(samples: samples, language: language, prompt: prompt)) }
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        return text
    }
}

private final class FakeBackend: SpeechBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var isInstalled: Bool
    private var storedError: URLError?
    private var loadCount = 0
    private let holdDownload: Bool
    private var storedLoadError: (any Error)?
    let recognizer: FakeRecognizer

    init(installed: Bool, text: String = "hello", holdDownload: Bool = false, downloadError: URLError? = nil,
         transcribeSeconds: Double = 0) {
        isInstalled = installed
        self.holdDownload = holdDownload
        storedError = downloadError
        recognizer = FakeRecognizer(text: text, seconds: transcribeSeconds)
    }

    var downloadError: URLError? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }

    var loadError: (any Error)? {
        get { lock.withLock { storedLoadError } }
        set { lock.withLock { storedLoadError = newValue } }
    }

    var loads: Int { lock.withLock { loadCount } }
    var modelName: String { "Fake Whisper" }
    var downloadBytes: Int64 { 3_000 }

    func installedModel() -> URL? {
        lock.withLock { isInstalled ? URL(fileURLWithPath: "/tmp/fake-whisper") : nil }
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let error = downloadError { throw error }
        progress(0.5)
        // The service takes progress on a task of its own: give it time to arrive before the download is over.
        try await Task.sleep(for: .milliseconds(20))
        if holdDownload {
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        progress(1)
        lock.withLock { isInstalled = true }
        return URL(fileURLWithPath: "/tmp/fake-whisper")
    }

    func load(_ directory: URL) async throws -> any SpeechRecognizer {
        lock.withLock { loadCount += 1 }
        if let error = loadError { throw error }
        return recognizer
    }

    func removeDownloaded() throws {
        lock.withLock { isInstalled = false }
    }
}
