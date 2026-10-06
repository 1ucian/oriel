import Foundation

struct DiagnosticsReport: Equatable, Sendable {
    let generatedAt: Date
    let appVersion: String
    let operatingSystemVersion: String
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool
    let activeSessionCount: Int
    let captureRunning: Bool

    static func current(activeSessionCount: Int, captureRunning: Bool) -> Self {
        let permission = PermissionState.current()
        return Self(
            generatedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            screenRecordingGranted: permission.screenRecordingGranted,
            accessibilityGranted: permission.accessibilityGranted,
            activeSessionCount: activeSessionCount,
            captureRunning: captureRunning
        )
    }

    func redactedText() -> String {
        """
        Oriel Diagnostics
        Generated: \(generatedAt.formatted(.iso8601))
        App version: \(appVersion)
        OS: \(operatingSystemVersion)
        Screen Recording: \(screenRecordingGranted ? "granted" : "not granted")
        Accessibility: \(accessibilityGranted ? "granted" : "not granted")
        Active session count: \(activeSessionCount)
        Capture service: \(captureRunning ? "running" : "stopped")

        \(recoveryGuidance)

        Excluded by design: device identifiers, screen content, target labels, typed text, clipboard data, network addresses, pairing material, and secrets.
        """
    }

    func write(to url: URL) throws {
        try redactedText().write(to: url, atomically: true, encoding: .utf8)
    }

    private var recoveryGuidance: String {
        if !screenRecordingGranted || !accessibilityGranted {
            return "Next step: Open Oriel Settings > Permissions, grant the required access, then return to Oriel."
        }
        return "Next step: If pairing fails, stop control on both devices and start pairing again."
    }
}
