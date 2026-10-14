import Foundation

/// Voice input, version 1: the phone records, the Mac turns the speech into text.
///
/// The Mac offers it in its approval (`SessionApproval.speech`), a key that older phones skip. A phone that reads the
/// offer subscribes, then sends one utterance at a time as 16 kHz, 16-bit mono PCM in numbered chunks; the Mac answers
/// with the text, or says why not, and keeps the phone told about its speech model. Neither side sends these packets
/// to a peer that has not shown it speaks them, because a peer ends the session on a packet kind it does not know:
/// Oriel 1.0 and 1.0.1 for Mac, the Windows companion and older phones never see anything new. Every payload carries
/// its version; a request or event from a newer version decodes as `unsupported` instead of ending the session.
/// Audio stays in memory on both devices and is dropped once it is transcribed or cancelled, or the session ends.
public enum SpeechProtocol {
    public static let version = 1
    public static let sampleRate = 16_000
    public static let maximumSeconds = 60
    /// One chunk: two seconds of audio at most.
    public static let maximumChunkBytes = 64 * 1_024
    /// A whole utterance: 60 seconds of 16-bit samples at 16 kHz.
    public static let maximumUtteranceBytes = sampleRate * 2 * maximumSeconds
    public static let maximumChunks = maximumUtteranceBytes / 1_024
    public static let maximumTextBytes = 8 * 1_024
    public static let maximumMessageBytes = 256
    static let maximumIdentifierBytes = 64
}

public enum SpeechProtocolError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidChunk
    case invalidText
    case invalidProgress
    case invalidOffer
    case missingVersion
    /// `unsupported` is what a peer sent; it is never sent back.
    case notSendable
}

/// What the Mac says in its approval when it can turn speech into text this session.
public struct SpeechTranscriptionOffer: Codable, Equatable, Sendable {
    /// The newest speech protocol version the Mac speaks. A phone talks the lower of this and its own.
    public let version: Int
    /// Version 1 audio is 16-bit mono PCM at this rate.
    public let sampleRate: Int
    /// The longest utterance the Mac takes, in seconds.
    public let maximumSeconds: Int

    public init(
        version: Int = SpeechProtocol.version,
        sampleRate: Int = SpeechProtocol.sampleRate,
        maximumSeconds: Int = SpeechProtocol.maximumSeconds
    ) throws {
        guard version >= 1, sampleRate > 0, (1...600).contains(maximumSeconds) else {
            throw SpeechProtocolError.invalidOffer
        }
        self.version = version
        self.sampleRate = sampleRate
        self.maximumSeconds = maximumSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            sampleRate: container.decode(Int.self, forKey: .sampleRate),
            maximumSeconds: container.decode(Int.self, forKey: .maximumSeconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sampleRate
        case maximumSeconds
    }

    /// This build's offer.
    public static let current = try! SpeechTranscriptionOffer()

    /// The version both sides speak, or nil when this phone cannot use the offer (its audio format is not the one
    /// version 1 sends).
    public var negotiatedVersion: Int? {
        guard sampleRate == SpeechProtocol.sampleRate else { return nil }
        return min(version, SpeechProtocol.version)
    }

    /// The longest utterance both sides take.
    public var negotiatedMaximumSeconds: Int { min(maximumSeconds, SpeechProtocol.maximumSeconds) }
}

/// One stretch of an utterance, in order.
public struct SpeechAudioChunk: Codable, Equatable, Sendable {
    public let utteranceID: String
    /// 0 for the first chunk of an utterance, then 1, 2, 3...
    public let sequence: Int
    /// 16-bit little-endian mono PCM at 16 kHz.
    public let samples: Data

    public init(utteranceID: String, sequence: Int, samples: Data) throws {
        self.utteranceID = try SpeechIdentifier.validated(utteranceID)
        guard (0..<SpeechProtocol.maximumChunks).contains(sequence),
              !samples.isEmpty,
              samples.count.isMultiple(of: 2),
              samples.count <= SpeechProtocol.maximumChunkBytes else {
            throw SpeechProtocolError.invalidChunk
        }
        self.sequence = sequence
        self.samples = samples
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            utteranceID: container.decode(String.self, forKey: .utteranceID),
            sequence: container.decode(Int.self, forKey: .sequence),
            samples: container.decode(Data.self, forKey: .samples)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case utteranceID
        case sequence
        case samples
    }

    /// Seconds of audio in this chunk.
    public var seconds: Double { Double(samples.count / 2) / Double(SpeechProtocol.sampleRate) }
}

/// Phone to Mac.
public enum SpeechRequest: Equatable, Sendable {
    /// Start getting the Mac's speech model status; sent once a session, after the offer.
    case subscribe
    /// Get the model ready: download it if this Mac does not have it, then load it.
    case prepare
    /// A new utterance; its audio follows in order. Any utterance still open on the Mac is dropped.
    case begin(utteranceID: String)
    case audio(SpeechAudioChunk)
    /// Transcribe what arrived.
    case end(utteranceID: String)
    /// Drop it unheard.
    case cancel(utteranceID: String)
    /// From a newer phone: a version or kind this side does not know. Decoded, never sent.
    case unsupported(version: Int, kind: String)
}

/// Mac to phone.
public enum SpeechEvent: Equatable, Sendable {
    case status(SpeechModelStatus)
    case transcript(SpeechTranscript)
    case failure(SpeechFailure)
    /// From a newer Mac: a version or kind this side does not know. Decoded, never sent.
    case unsupported(version: Int, kind: String)
}

/// Where the Mac's speech model stands.
public struct SpeechModelStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case notInstalled
        case downloading
        /// On the Mac's disk, loaded when an utterance arrives.
        case installed
        case loading
        case ready
        case failed
        /// Voice input is off on the Mac, or the Mac cannot run the model.
        case unavailable

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // A state from a newer Mac reads as one this phone can show.
            self = State(rawValue: raw) ?? .unavailable
        }

        /// The phone can record now: the Mac loads an installed model while the person speaks.
        public var acceptsAudio: Bool {
            switch self {
            case .installed, .loading, .ready: true
            default: false
            }
        }
    }

    public let state: State
    /// 0...1 while downloading.
    public let progress: Double?
    /// The model, for the person: "Whisper large-v3".
    public let modelName: String
    /// The size of the one-time download, while the model is not on the Mac.
    public let downloadBytes: Int64?
    /// Why the model failed or is unavailable, in a sentence.
    public let message: String?

    public init(
        state: State,
        progress: Double? = nil,
        modelName: String,
        downloadBytes: Int64? = nil,
        message: String? = nil
    ) throws {
        if let progress {
            guard progress.isFinite, (0...1).contains(progress) else { throw SpeechProtocolError.invalidProgress }
        }
        if let downloadBytes {
            guard downloadBytes >= 0 else { throw SpeechProtocolError.invalidProgress }
        }
        self.state = state
        self.progress = progress
        self.modelName = try SpeechText.short(modelName)
        self.downloadBytes = downloadBytes
        self.message = try message.map(SpeechText.short)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            state: container.decode(State.self, forKey: .state),
            progress: container.decodeIfPresent(Double.self, forKey: .progress),
            modelName: container.decode(String.self, forKey: .modelName),
            downloadBytes: container.decodeIfPresent(Int64.self, forKey: .downloadBytes),
            message: container.decodeIfPresent(String.self, forKey: .message)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case progress
        case modelName
        case downloadBytes
        case message
    }
}

/// The text of one utterance.
public struct SpeechTranscript: Codable, Equatable, Sendable {
    public let utteranceID: String
    /// Empty when nothing was said.
    public let text: String
    public let audioSeconds: Double
    /// How long the Mac took to transcribe it.
    public let elapsedSeconds: Double

    public init(utteranceID: String, text: String, audioSeconds: Double, elapsedSeconds: Double) throws {
        self.utteranceID = try SpeechIdentifier.validated(utteranceID)
        guard text.utf8.count <= SpeechProtocol.maximumTextBytes,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SpeechProtocolError.invalidText
        }
        guard audioSeconds.isFinite, audioSeconds >= 0, elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
            throw SpeechProtocolError.invalidProgress
        }
        self.text = text
        self.audioSeconds = audioSeconds
        self.elapsedSeconds = elapsedSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            utteranceID: container.decode(String.self, forKey: .utteranceID),
            text: container.decode(String.self, forKey: .text),
            audioSeconds: container.decode(Double.self, forKey: .audioSeconds),
            elapsedSeconds: container.decode(Double.self, forKey: .elapsedSeconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case utteranceID
        case text
        case audioSeconds
        case elapsedSeconds
    }
}

/// Why an utterance, or the model, did not come through.
public struct SpeechFailure: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// No model on the Mac yet, or it is still downloading.
        case modelNotReady
        case tooLong
        /// Audio for an utterance the Mac is not taking, or out of order.
        case unexpectedAudio
        case transcriptionFailed
        /// Voice input is off on the Mac.
        case unavailable
        case unsupported

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Reason(rawValue: raw) ?? .transcriptionFailed
        }
    }

    public let utteranceID: String?
    public let reason: Reason
    public let message: String

    public init(utteranceID: String?, reason: Reason, message: String) throws {
        self.utteranceID = try utteranceID.map(SpeechIdentifier.validated)
        self.reason = reason
        self.message = try SpeechText.short(message)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            utteranceID: container.decodeIfPresent(String.self, forKey: .utteranceID),
            reason: container.decode(Reason.self, forKey: .reason),
            message: container.decode(String.self, forKey: .message)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case utteranceID
        case reason
        case message
    }
}

extension SpeechRequest: Codable {
    private enum Kind: String {
        case subscribe
        case prepare
        case begin
        case audio
        case end
        case cancel
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case utteranceID
        case audio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try? container.decode(Int.self, forKey: .version), version >= 1 else {
            throw SpeechProtocolError.missingVersion
        }
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard version <= SpeechProtocol.version, let kind = Kind(rawValue: rawKind) else {
            self = .unsupported(version: version, kind: String(rawKind.prefix(64)))
            return
        }
        switch kind {
        case .subscribe: self = .subscribe
        case .prepare: self = .prepare
        case .begin: self = .begin(utteranceID: try Self.identifier(container))
        case .audio: self = .audio(try container.decode(SpeechAudioChunk.self, forKey: .audio))
        case .end: self = .end(utteranceID: try Self.identifier(container))
        case .cancel: self = .cancel(utteranceID: try Self.identifier(container))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SpeechProtocol.version, forKey: .version)
        switch self {
        case .subscribe:
            try container.encode(Kind.subscribe.rawValue, forKey: .kind)
        case .prepare:
            try container.encode(Kind.prepare.rawValue, forKey: .kind)
        case let .begin(utteranceID):
            try container.encode(Kind.begin.rawValue, forKey: .kind)
            try container.encode(SpeechIdentifier.validated(utteranceID), forKey: .utteranceID)
        case let .audio(chunk):
            try container.encode(Kind.audio.rawValue, forKey: .kind)
            try container.encode(chunk, forKey: .audio)
        case let .end(utteranceID):
            try container.encode(Kind.end.rawValue, forKey: .kind)
            try container.encode(SpeechIdentifier.validated(utteranceID), forKey: .utteranceID)
        case let .cancel(utteranceID):
            try container.encode(Kind.cancel.rawValue, forKey: .kind)
            try container.encode(SpeechIdentifier.validated(utteranceID), forKey: .utteranceID)
        case .unsupported:
            throw SpeechProtocolError.notSendable
        }
    }

    private static func identifier(_ container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        try SpeechIdentifier.validated(container.decode(String.self, forKey: .utteranceID))
    }

    /// The utterance this request is about, if any.
    public var utteranceID: String? {
        switch self {
        case let .begin(id), let .end(id), let .cancel(id): id
        case let .audio(chunk): chunk.utteranceID
        case .subscribe, .prepare, .unsupported: nil
        }
    }
}

extension SpeechEvent: Codable {
    private enum Kind: String {
        case status
        case transcript
        case failure
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case status
        case transcript
        case failure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try? container.decode(Int.self, forKey: .version), version >= 1 else {
            throw SpeechProtocolError.missingVersion
        }
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard version <= SpeechProtocol.version, let kind = Kind(rawValue: rawKind) else {
            self = .unsupported(version: version, kind: String(rawKind.prefix(64)))
            return
        }
        switch kind {
        case .status: self = .status(try container.decode(SpeechModelStatus.self, forKey: .status))
        case .transcript: self = .transcript(try container.decode(SpeechTranscript.self, forKey: .transcript))
        case .failure: self = .failure(try container.decode(SpeechFailure.self, forKey: .failure))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SpeechProtocol.version, forKey: .version)
        switch self {
        case let .status(status):
            try container.encode(Kind.status.rawValue, forKey: .kind)
            try container.encode(status, forKey: .status)
        case let .transcript(transcript):
            try container.encode(Kind.transcript.rawValue, forKey: .kind)
            try container.encode(transcript, forKey: .transcript)
        case let .failure(failure):
            try container.encode(Kind.failure.rawValue, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        case .unsupported:
            throw SpeechProtocolError.notSendable
        }
    }
}

enum SpeechIdentifier {
    static func validated(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= SpeechProtocol.maximumIdentifierBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  // Letters, digits and dashes: a UUID, as both sides make them.
                  switch scalar.value {
                  case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D: true
                  default: false
                  }
              })
        else {
            throw SpeechProtocolError.invalidIdentifier
        }
        return value
    }
}

enum SpeechText {
    static func short(_ value: String) throws -> String {
        guard value.utf8.count <= SpeechProtocol.maximumMessageBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" }) else {
            throw SpeechProtocolError.invalidText
        }
        return value
    }
}
