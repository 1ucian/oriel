import CryptoKit
import Foundation

/// Six digits both devices show while the Mac waits for the owner's approval of a new pairing,
/// so the owner can check that the request on the Mac came from the phone in their hand.
///
/// Nothing new travels. After the pairing request each side holds the same X25519 secret: the
/// Mac from its agreement key and the request, the phone from its agreement key and the scanned
/// offer. The code is HKDF-SHA256 over that secret, salted with the offer's nonce and bound to
/// both devices' signing and agreement public keys:
///
///     info   = "Oriel/v1/pairing-code" || macSigning || macAgreement || phoneSigning || phoneAgreement
///     output = HKDF-SHA256(secret, salt: offer nonce, info, 8 bytes)
///     code   = UInt64(big-endian output) mod 1_000_000, as six digits
///
/// Someone who saw the QR code and answers the Mac in the phone's place can compute the code
/// the Mac shows, but not the one the phone shows: that needs the phone's private key or the
/// Mac's. An offer is accepted once, so each code on screen is one guess in a million.
///
/// That rests on the phone holding the real Mac's offer, read from the Mac's screen. Someone who
/// swaps the offer before the phone reads it (a planted QR code, an altered pasted code) picks
/// the keys on both sides, can search for a pair of matching codes, and is not caught by them.
public struct PairingConfirmationCode: Equatable, Sendable, CustomStringConvertible {
    public static let digitCount = 6
    static let info = Data("Oriel/v1/pairing-code".utf8)

    /// Six ASCII digits, leading zeros kept: "042117".
    public let digits: String

    /// The Mac's side: its agreement key and signing key, and the verified request.
    public init(
        macAgreementKey: Curve25519.KeyAgreement.PrivateKey,
        macSigningPublicKey: Data,
        request: PairingRequestPayload
    ) throws {
        let phoneAgreementKey = try Self.agreementPublicKey(request.clientKeyAgreementPublicKey)
        try self.init(
            sharedSecret: macAgreementKey.sharedSecretFromKeyAgreement(with: phoneAgreementKey),
            pairingNonce: request.pairingNonce,
            macSigningPublicKey: macSigningPublicKey,
            macAgreementPublicKey: macAgreementKey.publicKey.rawRepresentation,
            phoneSigningPublicKey: request.clientSigningPublicKey,
            phoneAgreementPublicKey: request.clientKeyAgreementPublicKey
        )
    }

    /// The phone's side: its agreement key and signing key, and the offer it scanned or pasted.
    public init(
        phoneAgreementKey: Curve25519.KeyAgreement.PrivateKey,
        phoneSigningPublicKey: Data,
        offer: SignedPairingPayload
    ) throws {
        let macAgreementKey = try Self.agreementPublicKey(offer.payload.macPublicKey)
        try self.init(
            sharedSecret: phoneAgreementKey.sharedSecretFromKeyAgreement(with: macAgreementKey),
            pairingNonce: offer.payload.nonce,
            macSigningPublicKey: offer.signingPublicKey,
            macAgreementPublicKey: offer.payload.macPublicKey,
            phoneSigningPublicKey: phoneSigningPublicKey,
            phoneAgreementPublicKey: phoneAgreementKey.publicKey.rawRepresentation
        )
    }

    init(
        sharedSecret: SharedSecret,
        pairingNonce: Data,
        macSigningPublicKey: Data,
        macAgreementPublicKey: Data,
        phoneSigningPublicKey: Data,
        phoneAgreementPublicKey: Data
    ) throws {
        guard (16...64).contains(pairingNonce.count) else {
            throw PeerSessionError.invalidPairingNonce
        }
        let keys = [macSigningPublicKey, macAgreementPublicKey, phoneSigningPublicKey, phoneAgreementPublicKey]
        guard keys.allSatisfy({ $0.count == 32 }) else {
            throw PeerSessionError.invalidPeerKey
        }
        let output = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairingNonce,
            sharedInfo: keys.reduce(into: Self.info) { $0.append($1) },
            outputByteCount: 8
        )
        let value = output.withUnsafeBytes { bytes in
            bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        digits = Self.digits(from: value)
    }

    init(digits: String) {
        self.digits = digits
    }

    /// As the devices show it: "042 117".
    public var formatted: String {
        String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    /// For VoiceOver, one digit at a time: "0 4 2, 1 1 7".
    public var spokenDigits: String {
        digits.prefix(3).map(String.init).joined(separator: " ") + ", "
            + digits.suffix(3).map(String.init).joined(separator: " ")
    }

    public var description: String { formatted }

    static func digits(from value: UInt64) -> String {
        let number = String(value % 1_000_000)
        return String(repeating: "0", count: digitCount - number.count) + number
    }

    private static func agreementPublicKey(_ data: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do {
            return try .init(rawRepresentation: data)
        } catch {
            throw PeerSessionError.invalidPeerKey
        }
    }
}
