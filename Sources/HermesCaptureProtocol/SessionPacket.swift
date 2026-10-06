import Foundation

public struct H264ParameterSets: Codable, Equatable, Sendable {
    public let sequenceParameterSet: Data
    public let pictureParameterSet: Data

    public init(sequenceParameterSet: Data, pictureParameterSet: Data) {
        self.sequenceParameterSet = sequenceParameterSet
        self.pictureParameterSet = pictureParameterSet
    }
}

public struct VideoFramePacket: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let presentationTimeNanoseconds: UInt64
    public let isKeyFrame: Bool
    public let payload: Data
    public let parameterSets: H264ParameterSets?

    public init(
        sequence: UInt64,
        presentationTimeNanoseconds: UInt64,
        isKeyFrame: Bool,
        payload: Data,
        parameterSets: H264ParameterSets? = nil
    ) {
        self.sequence = sequence
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.isKeyFrame = isKeyFrame
        self.payload = payload
        self.parameterSets = parameterSets
    }
}

public struct SessionApproval: Codable, Equatable, Sendable {
    public let capabilities: Set<SessionCapability>
    public let expiresAt: Date
    /// The Mac's standing relay rendezvous, so this phone can reconnect from anywhere.
    public let reconnectRoute: ReconnectRoute?

    public init(capabilities: Set<SessionCapability>, expiresAt: Date, reconnectRoute: ReconnectRoute? = nil) {
        self.capabilities = capabilities
        self.expiresAt = expiresAt
        self.reconnectRoute = reconnectRoute
    }
}

public enum SessionPacket: Equatable, Sendable {
    public static let maximumVideoBytes = 4 * 1_024 * 1_024
    public static let maximumEncodedBytes = 5 * 1_024 * 1_024

    case heartbeat(monotonicNanoseconds: UInt64)
    case video(VideoFramePacket)
    case input(RemoteInputEvent)
    case approval(SessionApproval)
    case close(reason: String)
    /// The assistant (runAgentActions): phone to Mac.
    case agentInstruction(AgentInstruction)
    case agentControl(AgentControl)
    /// The assistant: Mac to phone.
    case agentTrace(AgentTraceEvent)
    case agentStatus(AgentProviderSummary)
}

extension SessionPacket: Codable {
    private enum Kind: String, Codable {
        case heartbeat
        case video
        case input
        case approval
        case close
        case agentInstruction
        case agentControl
        case agentTrace
        case agentStatus
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case monotonicNanoseconds
        case video
        case input
        case approval
        case reason
        case agentInstruction
        case agentControl
        case agentTrace
        case agentStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try? container.decode(Kind.self, forKey: .kind) else {
            throw PeerSessionError.invalidPacket
        }
        switch kind {
        case .heartbeat:
            self = .heartbeat(
                monotonicNanoseconds: try container.decode(
                    UInt64.self,
                    forKey: .monotonicNanoseconds
                )
            )
        case .video:
            self = .video(
                try container.decode(VideoFramePacket.self, forKey: .video)
            )
        case .input:
            self = .input(
                try container.decode(RemoteInputEvent.self, forKey: .input)
            )
        case .approval:
            self = .approval(
                try container.decode(SessionApproval.self, forKey: .approval)
            )
        case .close:
            self = .close(
                reason: try container.decode(String.self, forKey: .reason)
            )
        case .agentInstruction:
            self = .agentInstruction(
                try container.decode(AgentInstruction.self, forKey: .agentInstruction)
            )
        case .agentControl:
            self = .agentControl(
                try container.decode(AgentControl.self, forKey: .agentControl)
            )
        case .agentTrace:
            self = .agentTrace(
                try container.decode(AgentTraceEvent.self, forKey: .agentTrace)
            )
        case .agentStatus:
            self = .agentStatus(
                try container.decode(AgentProviderSummary.self, forKey: .agentStatus)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .heartbeat(monotonicNanoseconds):
            try container.encode(Kind.heartbeat, forKey: .kind)
            try container.encode(
                monotonicNanoseconds,
                forKey: .monotonicNanoseconds
            )
        case let .video(video):
            try container.encode(Kind.video, forKey: .kind)
            try container.encode(video, forKey: .video)
        case let .input(input):
            try container.encode(Kind.input, forKey: .kind)
            try container.encode(input, forKey: .input)
        case let .approval(approval):
            try container.encode(Kind.approval, forKey: .kind)
            try container.encode(approval, forKey: .approval)
        case let .close(reason):
            try container.encode(Kind.close, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case let .agentInstruction(instruction):
            try container.encode(Kind.agentInstruction, forKey: .kind)
            try container.encode(instruction, forKey: .agentInstruction)
        case let .agentControl(control):
            try container.encode(Kind.agentControl, forKey: .kind)
            try container.encode(control, forKey: .agentControl)
        case let .agentTrace(event):
            try container.encode(Kind.agentTrace, forKey: .kind)
            try container.encode(event, forKey: .agentTrace)
        case let .agentStatus(summary):
            try container.encode(Kind.agentStatus, forKey: .kind)
            try container.encode(summary, forKey: .agentStatus)
        }
    }
}

public enum SessionPacketCodec {
    public static func encode(_ packet: SessionPacket) throws -> Data {
        try validate(packet)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(packet)
        guard data.count <= SessionPacket.maximumEncodedBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> SessionPacket {
        guard data.count <= SessionPacket.maximumEncodedBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let packet: SessionPacket
        do {
            packet = try decoder.decode(SessionPacket.self, from: data)
        } catch let error as PeerSessionError {
            throw error
        } catch {
            throw PeerSessionError.invalidPacket
        }
        try validate(packet)
        return packet
    }

    private static func validate(_ packet: SessionPacket) throws {
        switch packet {
        case let .video(frame):
            guard frame.payload.count <= SessionPacket.maximumVideoBytes else {
                throw PeerSessionError.payloadTooLarge
            }
        case let .approval(approval):
            guard !approval.capabilities.isEmpty,
                  approval.capabilities.isSubset(
                    of: SessionCapability.approvable
                  ) else {
                throw PeerSessionError.capabilityDenied
            }
        case let .close(reason):
            guard reason.utf8.count <= 256 else {
                throw PeerSessionError.payloadTooLarge
            }
        default:
            break
        }
    }
}
