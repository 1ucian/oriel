import Foundation
import HermesCaptureCore
import HermesCaptureProtocol
import Testing
@testable import HermesCaptureMac

@MainActor
struct ScreenProfileControllerTests {
    @Test func automationRoundTripRestoresExactOwnerModeIdentifier() {
        let owner = mode(id: 42, width: 2560, height: 1440, refreshRate: 120)
        let automation = mode(id: 7, width: 1920, height: 1080, refreshRate: 60)
        let system = FakeScreenModeSystem(
            current: owner,
            profiles: [automation, owner]
        )
        let suiteName = "ScreenProfileControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ScreenProfileController(defaults: defaults, system: system)

        #expect(system.appliedModeIDs.isEmpty)
        controller.useAutomationProfile()
        #expect(system.appliedModeIDs == [automation.modeID])
        #expect(controller.savedOwnerConfiguration?.modeID == owner.modeID)
        #expect(controller.activeProfile == .automation)

        controller.restoreOwnerProfile()
        #expect(system.appliedModeIDs == [automation.modeID, owner.modeID])
        #expect(system.current?.modeID == owner.modeID)
        #expect(controller.activeProfile == .owner)
        #expect(controller.errorDescription == nil)
    }

    @Test func restoreFailsClosedWhenExactOwnerModeIsUnavailable() {
        let owner = mode(id: 42, width: 2560, height: 1440, refreshRate: 120)
        let automation = mode(id: 7, width: 1920, height: 1080, refreshRate: 60)
        let system = FakeScreenModeSystem(
            current: owner,
            profiles: [automation, owner]
        )
        let suiteName = "ScreenProfileControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ScreenProfileController(defaults: defaults, system: system)
        controller.useAutomationProfile()

        system.nextApplyResult = .unavailable
        controller.restoreOwnerProfile()

        #expect(system.appliedModeIDs == [automation.modeID])
        #expect(controller.activeProfile == .automation)
        #expect(controller.errorDescription == "That screen configuration is no longer available.")
    }

    @Test func restoreDoesNotSubstituteMatchingGeometryWithDifferentModeIdentifier() {
        let owner = mode(id: 42, width: 2560, height: 1440, refreshRate: 120)
        let replacement = mode(id: 99, width: 2560, height: 1440, refreshRate: 120)
        let automation = mode(id: 7, width: 1920, height: 1080, refreshRate: 60)
        let system = FakeScreenModeSystem(
            current: owner,
            profiles: [automation, owner]
        )
        let suiteName = "ScreenProfileControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ScreenProfileController(defaults: defaults, system: system)
        controller.useAutomationProfile()

        system.profiles = [automation, replacement]
        controller.restoreOwnerProfile()

        #expect(system.appliedModeIDs == [automation.modeID])
        #expect(system.current?.modeID == automation.modeID)
        #expect(controller.activeProfile == .automation)
        #expect(controller.errorDescription == "The saved owner configuration is no longer supported.")
    }

    @Test func customPresetSavesOwnerBeforeFirstDisplayChange() {
        let owner = mode(id: 42, width: 2560, height: 1440, refreshRate: 120)
        let custom = mode(id: 9, width: 1728, height: 1117, refreshRate: 60)
        let system = FakeScreenModeSystem(current: owner, profiles: [custom, owner])
        let suiteName = "ScreenProfileControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ScreenProfileController(defaults: defaults, system: system)

        controller.useCustomProfile(custom)

        #expect(controller.savedOwnerConfiguration?.modeID == owner.modeID)
        #expect(controller.activeProfile == .custom)
        #expect(controller.canRestoreOwner)
    }

    @Test func automationAfterCustomPresetPreservesOriginalOwnerConfiguration() {
        let owner = mode(id: 42, width: 2560, height: 1440, refreshRate: 120)
        let custom = mode(id: 9, width: 1728, height: 1117, refreshRate: 60)
        let automation = mode(id: 7, width: 1920, height: 1080, refreshRate: 60)
        let system = FakeScreenModeSystem(current: owner, profiles: [automation, custom, owner])
        let suiteName = "ScreenProfileControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ScreenProfileController(defaults: defaults, system: system)

        controller.useCustomProfile(custom)
        controller.useAutomationProfile()
        controller.restoreOwnerProfile()

        #expect(system.appliedModeIDs == [custom.modeID, automation.modeID, owner.modeID])
        #expect(system.current?.modeID == owner.modeID)
        #expect(controller.savedOwnerConfiguration?.modeID == owner.modeID)
        #expect(controller.activeProfile == .owner)
    }

    @Test func resolutionPresetsExposeStandardLandscapeAndValidPortraitOptions() {
        let owner = mode(id: 42, width: 2_560, height: 1_440, refreshRate: 120)
        let modes = [
            owner,
            mode(id: 1, width: 1_920, height: 1_080, refreshRate: 60),
            mode(id: 2, width: 1_920, height: 1_200, refreshRate: 60),
            mode(id: 3, width: 1_440, height: 1_080, refreshRate: 60),
            mode(id: 4, width: 1_620, height: 1_080, refreshRate: 60),
            mode(id: 5, width: 1_080, height: 1_080, refreshRate: 60),
            mode(id: 6, width: 1_080, height: 1_920, refreshRate: 60),
        ]
        let system = FakeScreenModeSystem(current: owner, profiles: modes)
        let suiteName = "ScreenProfileControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ScreenProfileController(defaults: defaults, system: system)

        #expect(controller.landscapeResolutionPresets.map(\.aspectRatio) == [
            .landscape16x9,
            .landscape16x10,
            .landscape4x3,
            .landscape3x2,
            .square,
        ])
        #expect(controller.landscapeResolutionPresets.allSatisfy { $0.isAvailable })
        #expect(controller.portraitResolutionPresets.map(\.aspectRatio) == [
            .portrait9x16,
        ])
    }

    @Test func customDimensionsApplyOnlyAnExactSupportedMode() {
        let owner = mode(id: 42, width: 2_560, height: 1_440, refreshRate: 120)
        let custom = mode(id: 9, width: 1_600, height: 1_000, refreshRate: 60)
        let system = FakeScreenModeSystem(current: owner, profiles: [custom, owner])
        let suiteName = "ScreenProfileControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ScreenProfileController(defaults: defaults, system: system)

        controller.useCustomDimensions(width: 1_601, height: 1_000)
        #expect(system.appliedModeIDs.isEmpty)
        #expect(controller.errorDescription == "That exact resolution is not supported by this display.")

        controller.useCustomDimensions(width: 1_600, height: 1_000)
        #expect(system.appliedModeIDs == [custom.modeID])
        #expect(controller.savedOwnerConfiguration?.modeID == owner.modeID)
        #expect(controller.activeProfile == .custom)
        #expect(controller.errorDescription == nil)
    }

    @Test func customDimensionsRejectValuesOutsideCaptureBounds() {
        let owner = mode(id: 42, width: 2_560, height: 1_440, refreshRate: 120)
        let system = FakeScreenModeSystem(current: owner, profiles: [owner])
        let suiteName = "ScreenProfileControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ScreenProfileController(defaults: defaults, system: system)

        controller.useCustomDimensions(width: 9_000, height: 1_000)

        #expect(system.appliedModeIDs.isEmpty)
        #expect(controller.errorDescription == "Enter dimensions from 640 to 8192 pixels.")
    }

    @Test func hostStatusSurfacesFailureInsteadOfClaimingReady() {
        let presentation = MacHostPresentation.status(
            isControlling: false,
            hasPendingRequest: false,
            isPairing: false,
            hasError: true
        )

        #expect(presentation.title == "Needs attention")
        #expect(presentation.icon == "exclamationmark.triangle.fill")
    }

    @Test func capabilitySummaryUsesReadableStableLabels() {
        let summary = MacHostPresentation.capabilitySummary([
            .typeText,
            .viewScreen,
            .controlPointer,
        ])

        #expect(summary == "Control pointer, Type text, View screen")
    }

    @Test func diagnosticsReportGuidesPermissionRecovery() {
        let report = DiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.0",
            operatingSystemVersion: "macOS",
            screenRecordingGranted: false,
            accessibilityGranted: false,
            activeSessionCount: 0,
            captureRunning: false
        )

        #expect(
            report.redactedText().contains(
                "Next step: Open Oriel Settings > Permissions, grant the required access, then return to Oriel."
            )
        )
    }

    @Test func diagnosticsReportCanBeSavedWithoutSensitiveContent() throws {
        let report = DiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.0",
            operatingSystemVersion: "macOS",
            screenRecordingGranted: true,
            accessibilityGranted: true,
            activeSessionCount: 1,
            captureRunning: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("Oriel-Diagnostics.txt")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try report.write(to: url)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == report.redactedText())
        #expect(!saved.contains("example-device-id"))
        #expect(!saved.contains("example-secret"))
    }

    private func mode(
        id: UInt32,
        width: Int,
        height: Int,
        refreshRate: Double
    ) -> DisplayModeProfile {
        DisplayModeProfile(
            modeID: id,
            width: width,
            height: height,
            pixelWidth: width,
            pixelHeight: height,
            refreshRate: refreshRate,
            isUsable: true
        )
    }
}

@MainActor
private final class FakeScreenModeSystem: ScreenModeSystem {
    let screenID: UInt32 = 1
    var current: DisplayModeProfile?
    var profiles: [DisplayModeProfile]
    var nextApplyResult: ScreenModeApplyResult = .success
    private(set) var appliedModeIDs: [UInt32] = []

    init(current: DisplayModeProfile, profiles: [DisplayModeProfile]) {
        self.current = current
        self.profiles = profiles
    }

    func mainScreenID() -> UInt32 {
        screenID
    }

    func availableProfiles(screenID: UInt32) -> [DisplayModeProfile] {
        profiles
    }

    func currentProfile(screenID: UInt32) -> DisplayModeProfile? {
        current
    }

    func apply(
        profile: DisplayModeProfile,
        screenID: UInt32
    ) -> ScreenModeApplyResult {
        guard profiles.contains(where: { $0.modeID == profile.modeID }) else {
            return .unavailable
        }
        guard nextApplyResult == .success else { return nextApplyResult }
        appliedModeIDs.append(profile.modeID)
        current = profile
        return .success
    }
}
