public enum CaptureCadence: String, CaseIterable, Sendable {
    case idle
    case interactive
    case highMotion

    public var framesPerSecond: Int32 {
        switch self {
        case .idle: 5
        case .interactive: 30
        case .highMotion: 60
        }
    }

    public var frameIntervalNanoseconds: UInt64 {
        1_000_000_000 / UInt64(framesPerSecond)
    }
}
