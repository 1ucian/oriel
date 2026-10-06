import CoreGraphics
import Foundation
import HermesCaptureCore
import Observation

enum ScreenModeApplyResult: Equatable {
    case success
    case unavailable
    case failed(Int32)
}

@MainActor
protocol ScreenModeSystem {
    func mainScreenID() -> UInt32
    func availableProfiles(screenID: UInt32) -> [DisplayModeProfile]
    func currentProfile(screenID: UInt32) -> DisplayModeProfile?
    func apply(profile: DisplayModeProfile, screenID: UInt32) -> ScreenModeApplyResult
}

struct CoreGraphicsScreenModeSystem: ScreenModeSystem {
    func mainScreenID() -> UInt32 {
        CGMainDisplayID()
    }

    func availableProfiles(screenID: UInt32) -> [DisplayModeProfile] {
        records(screenID: screenID).map(\.profile)
    }

    func currentProfile(screenID: UInt32) -> DisplayModeProfile? {
        guard let value = CGDisplayCopyDisplayMode(screenID) else { return nil }
        return makeProfile(from: value)
    }

    func apply(
        profile: DisplayModeProfile,
        screenID: UInt32
    ) -> ScreenModeApplyResult {
        guard let record = records(screenID: screenID).first(where: {
            $0.profile.modeID == profile.modeID
        }) else {
            return .unavailable
        }
        let result = CGDisplaySetDisplayMode(screenID, record.systemValue, nil)
        return result == .success ? .success : .failed(result.rawValue)
    }

    private struct Record {
        let profile: DisplayModeProfile
        let systemValue: CGDisplayMode
    }

    private func records(screenID: UInt32) -> [Record] {
        let options = [
            kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any,
        ] as CFDictionary
        guard let copied = CGDisplayCopyAllDisplayModes(screenID, options),
              let values = copied as? [CGDisplayMode] else {
            return []
        }
        return values.compactMap { value in
            let profile = makeProfile(from: value)
            guard profile.isUsable else { return nil }
            return Record(profile: profile, systemValue: value)
        }
    }

    private func makeProfile(from value: CGDisplayMode) -> DisplayModeProfile {
        let interlaced = value.ioFlags & UInt32(kDisplayModeInterlacedFlag) != 0
        return DisplayModeProfile(
            modeID: UInt32(bitPattern: value.ioDisplayModeID),
            width: value.width,
            height: value.height,
            pixelWidth: value.pixelWidth,
            pixelHeight: value.pixelHeight,
            refreshRate: value.refreshRate,
            isUsable: !interlaced
        )
    }
}

@MainActor
@Observable
final class ScreenProfileController {
    enum ActiveProfile: String, Sendable {
        case owner = "Owner"
        case automation = "Automation"
        case custom = "Custom"
    }

    private struct StoredOwnerConfiguration: Codable {
        let screenID: UInt32
        let profile: DisplayModeProfile
    }


    private(set) var currentConfiguration: DisplayModeProfile?
    private(set) var choices: [DisplayModeProfile] = []
    private(set) var savedOwnerConfiguration: DisplayModeProfile?
    private(set) var activeProfile: ActiveProfile = .owner
    private(set) var errorDescription: String?

    private let defaults: UserDefaults
    private let system: any ScreenModeSystem
    private let ownerKey = "screen-profile.owner-v1"

    init(
        defaults: UserDefaults = .standard,
        system: any ScreenModeSystem = CoreGraphicsScreenModeSystem()
    ) {
        self.defaults = defaults
        self.system = system
        reload()
    }

    var currentLabel: String {
        currentConfiguration?.detailedLabel ?? String(localized: "Unavailable")
    }

    var landscapeResolutionPresets: [DisplayResolutionPreset] {
        DisplayProfileSelector.resolutionPresets(in: choices).filter {
            !$0.aspectRatio.isPortrait
        }
    }

    var portraitResolutionPresets: [DisplayResolutionPreset] {
        DisplayProfileSelector.resolutionPresets(in: choices).filter {
            $0.aspectRatio.isPortrait
        }
    }

    var automationLabel: String {
        guard let value = DisplayProfileSelector.agentMode(in: choices) else {
            return "No compatible configuration"
        }
        return value.label
    }

    var canRestoreOwner: Bool {
        guard let savedOwnerConfiguration else { return false }
        return DisplayProfileSelector.ownerMode(
            matching: savedOwnerConfiguration,
            in: choices
        ) != nil
    }

    var selectableConfigurations: [DisplayModeProfile] {
        var seen = Set<String>()
        return choices
            .sorted(by: Self.sortProfiles)
            .filter { seen.insert($0.label).inserted }
    }

    func reload() {
        let screenID = system.mainScreenID()
        choices = system.availableProfiles(screenID: screenID)
        currentConfiguration = system.currentProfile(screenID: screenID)
        savedOwnerConfiguration = loadOwner(screenID: screenID)
        inferActiveProfile()
    }

    func useAutomationProfile() {
        reload()
        guard let currentConfiguration else {
            errorDescription = "The main screen configuration is unavailable."
            return
        }
        guard let target = DisplayProfileSelector.agentMode(in: choices) else {
            errorDescription = "No compatible 1920×1080 at 60 Hz configuration is available."
            return
        }

        preserveOwnerConfigurationIfNeeded(currentConfiguration)
        activate(target, profile: .automation)
    }

    func restoreOwnerProfile() {
        reload()
        guard let savedOwnerConfiguration else {
            errorDescription = "No saved owner configuration exists yet."
            return
        }
        guard let target = DisplayProfileSelector.ownerMode(
            matching: savedOwnerConfiguration,
            in: choices
        ) else {
            errorDescription = "The saved owner configuration is no longer supported."
            return
        }
        activate(target, profile: .owner)
    }

    func useCustomProfile(_ value: DisplayModeProfile) {
        reload()
        guard choices.contains(where: { $0.modeID == value.modeID }) else {
            errorDescription = "That screen configuration is no longer available."
            return
        }
        guard let currentConfiguration else {
            errorDescription = "The main screen configuration is unavailable."
            return
        }
        preserveOwnerConfigurationIfNeeded(currentConfiguration)
        activate(value, profile: .custom)
    }

    func useResolutionPreset(_ preset: DisplayResolutionPreset) {
        guard let mode = preset.mode else {
            errorDescription = String(
                localized: "That aspect ratio is not supported by this display."
            )
            return
        }
        useCustomProfile(mode)
    }

    func useCustomDimensions(width: Int, height: Int) {
        guard DisplayProfileSelector.customDimensionsAreValid(
            width: width,
            height: height
        ) else {
            errorDescription = String(
                localized: "Enter dimensions from 640 to 8192 pixels."
            )
            return
        }

        reload()
        guard let target = DisplayProfileSelector.customMode(
            width: width,
            height: height,
            in: choices
        ) else {
            errorDescription = String(
                localized: "That exact resolution is not supported by this display."
            )
            return
        }
        guard let currentConfiguration else {
            errorDescription = String(
                localized: "The main screen configuration is unavailable."
            )
            return
        }
        preserveOwnerConfigurationIfNeeded(currentConfiguration)
        activate(target, profile: .custom)
    }

    private func preserveOwnerConfigurationIfNeeded(
        _ currentConfiguration: DisplayModeProfile
    ) {
        guard savedOwnerConfiguration == nil || activeProfile == .owner else {
            return
        }
        saveOwner(currentConfiguration, screenID: system.mainScreenID())
        savedOwnerConfiguration = currentConfiguration
    }

    private func activate(
        _ value: DisplayModeProfile,
        profile: ActiveProfile
    ) {
        let screenID = system.mainScreenID()
        switch system.apply(profile: value, screenID: screenID) {
        case .unavailable:
            errorDescription = "That screen configuration is no longer available."
            return
        case let .failed(code):
            errorDescription = "macOS rejected the screen change (\(code))."
            return
        case .success:
            break
        }

        errorDescription = nil
        reloadAfterChange(expectedProfile: profile)
    }

    private func reloadAfterChange(expectedProfile: ActiveProfile) {
        let screenID = system.mainScreenID()
        choices = system.availableProfiles(screenID: screenID)
        currentConfiguration = system.currentProfile(screenID: screenID)
        savedOwnerConfiguration = loadOwner(screenID: screenID)
        activeProfile = expectedProfile
    }

    private func inferActiveProfile() {
        guard let currentConfiguration else {
            activeProfile = .custom
            return
        }
        if let savedOwnerConfiguration,
           DisplayProfileSelector.ownerMode(
               matching: savedOwnerConfiguration,
               in: [currentConfiguration]
           ) != nil {
            activeProfile = .owner
            return
        }
        if let automationChoice = DisplayProfileSelector.agentMode(in: choices),
           automationChoice.modeID == currentConfiguration.modeID,
           savedOwnerConfiguration != nil {
            activeProfile = .automation
            return
        }
        activeProfile = savedOwnerConfiguration == nil ? .owner : .custom
    }


    private func saveOwner(
        _ profile: DisplayModeProfile,
        screenID: CGDirectDisplayID
    ) {
        let stored = StoredOwnerConfiguration(
            screenID: screenID,
            profile: profile
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: ownerKey)
    }

    private func loadOwner(
        screenID: CGDirectDisplayID
    ) -> DisplayModeProfile? {
        guard let data = defaults.data(forKey: ownerKey),
              let stored = try? JSONDecoder().decode(
                  StoredOwnerConfiguration.self,
                  from: data
              ),
              stored.screenID == screenID else {
            return nil
        }
        return stored.profile
    }

    private static func sortProfiles(
        _ lhs: DisplayModeProfile,
        _ rhs: DisplayModeProfile
    ) -> Bool {
        if lhs.width != rhs.width { return lhs.width > rhs.width }
        if lhs.height != rhs.height { return lhs.height > rhs.height }
        if lhs.refreshRate != rhs.refreshRate {
            return lhs.refreshRate > rhs.refreshRate
        }
        let leftPixels = lhs.pixelWidth * lhs.pixelHeight
        let rightPixels = rhs.pixelWidth * rhs.pixelHeight
        if leftPixels != rightPixels { return leftPixels < rightPixels }
        return lhs.modeID < rhs.modeID
    }
}
