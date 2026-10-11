import Foundation

/// Where a model runs, judged from its endpoint. Pixels may go to a model on this Mac or on
/// the user's own network; a model on the internet gets text unless the user turns sharing on.
public enum ModelLocality: String, Codable, Equatable, Sendable {
    case onThisMac
    case localNetwork
    case internet
}

public enum ScreenshotSharingPolicy {
    public static func locality(ofHost rawHost: String) -> ModelLocality {
        let host = rawHost.lowercased().trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") {
            return .onThisMac
        }
        // Address ranges apply to address literals only; "127.example.com" is an internet name.
        if let octets = ipv4Octets(host) {
            if octets[0] == 127 || octets == [0, 0, 0, 0] { return .onThisMac }
            if octets[0] == 10 { return .localNetwork }
            if octets[0] == 192, octets[1] == 168 { return .localNetwork }
            if octets[0] == 172, (16...31).contains(octets[1]) { return .localNetwork }
            if octets[0] == 169, octets[1] == 254 { return .localNetwork }
            if octets[0] == 100, (64...127).contains(octets[1]) { return .localNetwork } // Tailscale CGNAT range
            return .internet
        }
        if host.contains(":") {
            if host == "::1" { return .onThisMac }
            if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return .localNetwork }
            return .internet
        }
        // One number, or hex, is an IPv4 address to the resolver: "134744072" is 8.8.8.8.
        if !host.contains("."), host.hasPrefix("0x") || host.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return .internet
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".internal") || host.hasSuffix(".ts.net") || !host.contains(".") {
            return .localNetwork
        }
        return .internet
    }

    /// Screenshots reach a model only on this Mac or the user's network, or on the internet when
    /// the user switched remote sharing on in Settings and the instruction asked for it.
    public static func mayShareScreenshots(
        locality: ModelLocality,
        remoteSharingEnabled: Bool,
        instructionAllows: Bool
    ) -> Bool {
        switch locality {
        case .onThisMac, .localNetwork:
            return true
        case .internet:
            return remoteSharingEnabled && instructionAllows
        }
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}
