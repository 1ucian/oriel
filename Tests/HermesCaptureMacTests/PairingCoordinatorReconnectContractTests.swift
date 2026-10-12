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

    @Test func revokeRemovesTrustFirstAndTearsDownBeforeAdvertisingAgain() throws {
        let source = try source
        let body = try #require(
            source.components(separatedBy: "func revokePeer(signingPublicKey: Data)").dropFirst().first?
                .components(separatedBy: "private func connectRelayUntilPaired").first
        )
        let trust = try #require(body.range(of: "trustedClientStore.revoke(signingPublicKey: signingPublicKey)"))
        let session = try #require(body.range(of: "channel?.close(reason: \"revoked-on-mac\")"))
        let request = try #require(body.range(of: "pending?.channel.close(reason: \"revoked-on-mac\")"))
        let teardown = try #require(body.range(of: "await remoteController.revoke(deviceID: deviceID)"))
        let advertise = try #require(body.range(of: "startAvailability()"))

        #expect(trust.lowerBound < session.lowerBound)
        #expect(trust.lowerBound < request.lowerBound)
        #expect(teardown.lowerBound < advertise.lowerBound)
    }

    @Test func revokeStopsTheBrokerBeforeTheSessionAndOnlyAnApprovalReadmits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = try String(
            contentsOf: root.appendingPathComponent("Apps/HermesCaptureMac/Networking/MacRemoteSessionController.swift"),
            encoding: .utf8
        )
        let revoke = try #require(
            controller.components(separatedBy: "func revoke(deviceID: String) async").dropFirst().first?
                .components(separatedBy: "func readmit(deviceID: String) async").first
        )
        let broker = try #require(revoke.range(of: "await inputBroker.revoke(deviceID: deviceID)"))
        let stop = try #require(revoke.range(of: "await stop(closeReason: \"revoked-on-mac\")"))
        #expect(broker.lowerBound < stop.lowerBound)

        let source = try source
        let approve = try #require(
            source.components(separatedBy: "func approve()").dropFirst().first?
                .components(separatedBy: "private func activate(").first
        )
        #expect(approve.contains("await remoteController.readmit(deviceID: pending.deviceID)"))
        #expect(source.components(separatedBy: "readmit(deviceID:").count == 2)
    }

    @Test func aSessionEndedWhileItStartsIsEndedOnceAndAdvertisedOnce() throws {
        let source = try source
        let approve = try #require(
            source.components(separatedBy: "func approve()").dropFirst().first?
                .components(separatedBy: "private func activate(").first
        )
        let readmit = try #require(approve.range(of: "await remoteController.readmit(deviceID: pending.deviceID)"))
        let stillPending = try #require(approve.range(of: "guard self.pending?.sessionID == pending.sessionID else { return }"))
        let activate = try #require(approve.range(of: "await activate("))
        #expect(readmit.lowerBound < stillPending.lowerBound)
        #expect(stillPending.lowerBound < activate.lowerBound)

        let body = try #require(
            source.components(separatedBy: "private func activate(").dropFirst().first?
                .components(separatedBy: "func decline()").first
        )
        // Revoke and Stop Control see the starting phone as the active one before the first wait.
        let marked = try #require(body.range(of: "activePeerSigningPublicKey = pending.clientSigningPublicKey"))
        let start = try #require(body.range(of: "try await remoteController.start("))
        #expect(marked.lowerBound < start.lowerBound)
        let failure = try #require(body.components(separatedBy: "} catch {").dropFirst().first)
        let ended = try #require(failure.range(of: "guard !endedMeanwhile else { return }"))
        let advertise = try #require(failure.range(of: "startAvailability()"))
        #expect(ended.lowerBound < advertise.lowerBound)
    }

    @Test func confirmationCodeComesFromAVerifiedRequestAndOnlyForNewPairings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let server = try String(
            contentsOf: root.appendingPathComponent("Apps/HermesCaptureMac/Pairing/PairingServer.swift"),
            encoding: .utf8
        )
        let verify = try #require(server.range(of: "try request.verify(expectedNonce: offer.payload.nonce)"))
        let code = try #require(server.range(of: "try PairingConfirmationCode("))

        #expect(verify.lowerBound < code.lowerBound)
        #expect(try source.contains("isReconnect: true,\n                confirmationCode: nil"))
    }

    /// Phones that predate the code show none, and nothing on the wire says which kind asks.
    @Test func approvalPromptReadsRightForPhonesWithAndWithoutACode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Apps/HermesCaptureMac/MenuBar/MacStatusView.swift"),
            encoding: .utf8
        )

        #expect(view.contains("If your phone shows a code, it should be \\(Text(code.formatted)"))
        #expect(view.contains("accessibilityLabel(\"If your phone shows a code, it should be \\(code.spokenDigits).\")"))
        #expect(!view.contains("Check that your phone shows"))
    }

    @Test func stopControlEndsInputLikeRevokeAndReachesARunWithoutItsPhone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func file(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let broker = try file("Apps/HermesCaptureMac/Input/InputBroker.swift")
        let stop = try #require(
            broker.components(separatedBy: "func stopControl(keepingRunInput: Bool = false) {").dropFirst().first?
                .components(separatedBy: "func resumeAcceptingNewSessions()").first
        )
        let ending = try #require(stop.components(separatedBy: "} else {").dropFirst().first)
        #expect(ending.contains("stops &+= 1"))
        #expect(ending.contains("releaseHeldButton()"))

        // Only the same phone coming back to its run keeps the run's input going.
        let controller = try file("Apps/HermesCaptureMac/Networking/MacRemoteSessionController.swift")
        #expect(controller.components(separatedBy: "stopControl(keepingRunInput: true)").count == 2)
        let resume = try #require(
            controller.components(separatedBy: "if resumingRun {").dropFirst().first?
                .components(separatedBy: "} else {").first
        )
        #expect(resume.contains("stopControl(keepingRunInput: true)"))

        let view = try file("Apps/HermesCaptureMac/MenuBar/MacStatusView.swift")
        #expect(view.contains(".disabled(!pairing.isControlling && !assistant.isActive)"))
        let coordinator = try source
        let stopControl = try #require(
            coordinator.components(separatedBy: "func stopControl()").dropFirst().first?
                .components(separatedBy: "func shutdown()").first
        )
        #expect(!stopControl.contains("trustedClientStore"))
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
