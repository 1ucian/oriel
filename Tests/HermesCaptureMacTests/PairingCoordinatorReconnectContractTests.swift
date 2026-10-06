import Foundation
import Testing
@testable import HermesCaptureMac

struct PairingCoordinatorReconnectContractTests {
    /// The iOS app is not in the open-source tree; this contract check runs only where it is.
    static var iOSSourcesPresent: Bool {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Apps/HermesCaptureIOS/Pairing/PairingClientCoordinator.swift").path
        )
    }

    private var source: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: root.appendingPathComponent(
                    "Apps/HermesCaptureMac/Pairing/PairingCoordinator.swift"
                ),
                encoding: .utf8
            )
        }
    }

    @Test func onlyOneReconnectHandshakeCanOwnTheCoordinator() throws {
        let source = try source

        #expect(source.contains("private var reconnectInFlight = false"))
        #expect(source.contains("!reconnectInFlight"))
        #expect(source.contains("reconnectInFlight = true"))
        #expect(source.contains("defer { reconnectInFlight = false }"))
    }

    @Test func singleFlightGateRejectsConcurrentAndStaleCompletionAttempts() {
        var gate = SingleFlightGate<String>()

        let firstAccepted = gate.begin("first")
        let duplicateAccepted = gate.begin("first")
        let concurrentAccepted = gate.begin("second")
        #expect(firstAccepted)
        #expect(!duplicateAccepted)
        #expect(!concurrentAccepted)

        gate.end("second")
        let acceptedAfterStaleCompletion = gate.begin("second")
        #expect(!acceptedAfterStaleCompletion)

        gate.end("first")
        let acceptedAfterOwnerCompleted = gate.begin("second")
        #expect(acceptedAfterOwnerCompleted)
    }

    @Test func approvalActivationIsSingleFlightAndAvailabilityStopsWhileControlling() throws {
        let source = try source

        #expect(source.contains("private var approvalInFlight = SingleFlightGate<String>()"))
        #expect(source.contains("approvalInFlight.begin(pending.sessionID)"))
        #expect(source.contains("approvalInFlight.end(pending.sessionID)"))
        #expect(source.contains("guard !isShuttingDown, !isPairing, pending == nil, !isControlling"))
    }

    @Test func revokedPeerCannotCompleteAnInFlightReconnect() throws {
        let source = try source

        #expect(source.contains(
            "trustedClientStore.record(\n                signingPublicKey: accepted.trustedPeer.signingPublicKey\n            )"
        ))
        #expect(source.contains("currentTrustedPeer == accepted.trustedPeer"))
    }

    @Test func unauthenticatedReconnectCannotHoldSingleFlightIndefinitely() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let server = try String(
            contentsOf: root.appendingPathComponent(
                "Apps/HermesCaptureMac/Pairing/ReconnectServer.swift"
            ),
            encoding: .utf8
        )

        #expect(server.contains("receiveFrameBeforeDeadline"))
        #expect(server.contains("withThrowingTaskGroup"))
        #expect(server.contains("ReconnectHandshakePolicy.timeoutSeconds"))
        #expect(server.contains("ReconnectServerError.handshakeTimedOut"))
    }

    @Test(.enabled(if: PairingCoordinatorReconnectContractTests.iOSSourcesPresent))
    func reconnectApprovalRefreshesIOSPersistedCapabilities() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let client = try String(
            contentsOf: root.appendingPathComponent(
                "Apps/HermesCaptureIOS/Pairing/PairingClientCoordinator.swift"
            ),
            encoding: .utf8
        )
        let reconnect = try #require(
            client.components(separatedBy: "private func reconnect(").dropFirst().first?
                .components(separatedBy: "private func receiveReconnectFrame").first
        )

        #expect(reconnect.contains("approvedCapabilities: channel.currentCapabilities"))
        #expect(reconnect.contains("try self.trustedMacStore.save(updatedRecord)"))
        #expect(reconnect.contains("self.savedMac = updatedRecord"))
    }

    @Test func stopControlWaitsForRemoteTeardownBeforeAdvertisingAgain() throws {
        let source = try source
        let body = try #require(
            source.components(separatedBy: "func stopControl()").dropFirst().first?
                .components(separatedBy: "func shutdown()").first
        )
        let stopIndex = try #require(body.range(of: "await remoteController.stop()"))
        let advertiseIndex = try #require(body.range(of: "startAvailability()"))

        #expect(stopIndex.lowerBound < advertiseIndex.lowerBound)
    }
}
