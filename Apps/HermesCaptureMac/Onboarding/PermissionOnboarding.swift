import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

struct PermissionState: Equatable, Sendable {
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool

    static func current() -> Self {
        .init(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }
}

struct PermissionOnboarding: View {
    @State private var state = PermissionState.current()

    var body: some View {
        Form {
            permissionRow(
                title: "Screen Recording",
                explanation: "Needed to show the selected Mac display on your paired iPhone or iPad.",
                granted: state.screenRecordingGranted,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
            permissionRow(
                title: "Accessibility",
                explanation: "Needed to identify controls and send user-approved pointer or keyboard input.",
                granted: state.accessibilityGranted,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            Text("\u{4F}\u{72}\u{69}\u{65}\u{6C} never clicks or types into macOS permission dialogs. You remain in control of System Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Refresh Status") { state = .current() }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            state = .current()
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, explanation: String, granted: Bool, settingsURL: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                Spacer()
                Text(granted ? "Granted" : "Required")
                    .foregroundStyle(granted ? .green : .orange)
            }
            Text(explanation).foregroundStyle(.secondary)
            if !granted {
                Button("Open \(title) Settings") {
                    if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                }
                .accessibilityIdentifier("permission.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
        }
    }
}
