import AppKit
import HermesCaptureCore
import HermesCaptureProtocol
import SwiftUI

struct MacHostPresentation {
    struct Status: Equatable {
        let title: String
        let icon: String
    }

    static func status(
        isControlling: Bool,
        hasPendingRequest: Bool,
        isPairing: Bool,
        hasError: Bool
    ) -> Status {
        if hasError {
            return Status(
                title: "Needs attention",
                icon: "exclamationmark.triangle.fill"
            )
        }
        if isControlling {
            return Status(
                title: "Remote control active",
                icon: "checkmark.circle.fill"
            )
        }
        if hasPendingRequest {
            return Status(
                title: "Approval required",
                icon: "exclamationmark.shield.fill"
            )
        }
        if isPairing {
            return Status(
                title: "Waiting for iPhone",
                icon: "qrcode.viewfinder"
            )
        }
        return Status(
            title: "Ready to pair",
            icon: "iphone.and.arrow.forward"
        )
    }

    static func capabilitySummary(
        _ capabilities: Set<SessionCapability>
    ) -> String {
        capabilities
            .map(capabilityName)
            .sorted()
            .joined(separator: ", ")
    }

    static func capabilityName(_ capability: SessionCapability) -> String {
        switch capability {
        case .viewScreen: "View screen"
        case .controlPointer: "Control pointer"
        case .typeText: "Type text"
        case .readClipboard: "Read clipboard"
        case .writeClipboard: "Write clipboard"
        case .transferFiles: "Transfer files"
        case .runAgentActions: "Run the assistant"
        case .enterSecrets: "Enter secrets"
        case .approveSensitiveAction: "Approve sensitive actions"
        }
    }

    /// What a paired phone may do, as a sentence in the order the capabilities are declared.
    static func allowedSentence(_ capabilities: Set<SessionCapability>) -> String {
        let phrases = SessionCapability.allCases.filter(capabilities.contains).map(allowedPhrase)
        guard let last = phrases.last else { return "Nothing approved." }
        let list = phrases.count == 1 ? last : phrases.dropLast().joined(separator: ", ") + " and " + last
        return "Can " + list + "."
    }

    static func allowedPhrase(_ capability: SessionCapability) -> String {
        switch capability {
        case .viewScreen: "view the screen"
        case .controlPointer: "control the pointer"
        case .typeText: "type text"
        case .readClipboard: "read the clipboard"
        case .writeClipboard: "write to the clipboard"
        case .transferFiles: "transfer files"
        case .runAgentActions: "run the assistant"
        case .enterSecrets: "enter secrets"
        case .approveSensitiveAction: "approve sensitive actions"
        }
    }

    static func pairedLine(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        "Paired " + date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone))
    }
}

@main
struct HermesCaptureMacApp: App {
    @NSApplicationDelegateAdaptor(OrielApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(
            "\u{4F}\u{72}\u{69}\u{65}\u{6C}",
            systemImage: appDelegate.pairingCoordinator.isControlling
                ? "display.and.arrow.down"
                : "display"
        ) {
            MacStatusView(
                pairing: appDelegate.pairingCoordinator,
                screenProfiles: appDelegate.screenProfiles,
                prepareForTermination: appDelegate.prepareForTermination
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            TabView {
                PermissionOnboarding()
                    .tabItem {
                        Label("Permissions", systemImage: "hand.raised")
                    }
                AssistantSettingsView(settings: AssistantSettings.shared)
                    .tabItem {
                        Label("Assistant", systemImage: "sparkles")
                    }
                DiagnosticsView(
                    pairing: appDelegate.pairingCoordinator,
                    captureRunning: { appDelegate.captureRunning }
                )
                    .tabItem {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
            }
            .frame(width: 600, height: 520)
        }
    }
}

private struct DiagnosticsView: View {
    @Bindable var pairing: PairingCoordinator
    let captureRunning: () -> Bool
    @State private var reportText = ""
    @State private var didCopyReport = false
    @State private var saveError: String?
    @State private var didDeleteLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redacted diagnostics")
                .font(.headline)
            Text(
                "The report excludes screen content, target labels, typed text, clipboard data, addresses, device identifiers, pairing material, and secrets."
            )
            .foregroundStyle(.secondary)
            ScrollView {
                Text(reportText.isEmpty ? "Generate a report to see system status and recovery guidance." : reportText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(reportText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Generated redacted diagnostics report")

            HStack {
                Button("Generate Redacted Report") {
                    reportText = DiagnosticsReport.current(
                        activeSessionCount: pairing.isControlling ? 1 : 0,
                        captureRunning: captureRunning()
                    ).redactedText()
                    didCopyReport = false
                    saveError = nil
                }
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportText, forType: .string)
                    didCopyReport = true
                }
                .disabled(reportText.isEmpty)
                Button("Save Report…") {
                    saveReport()
                }
                .disabled(reportText.isEmpty)
                if didCopyReport {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            Text("Activity log")
                .font(.headline)
            Text(
                "For troubleshooting, Oriel keeps a log of sessions and assistant steps on this Mac for seven days, including your instructions, the controls the assistant used and what it reported back. It never leaves this Mac. Typed text and your answers are recorded by length only, and long numbers are masked."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") {
                    revealActivityLog()
                }
                .accessibilityIdentifier("diagnostics.showLog")
                Button("Delete Activity Log") {
                    ActivityLog.shared.deleteAll()
                    didDeleteLog = true
                }
                .accessibilityIdentifier("diagnostics.deleteLog")
                if didDeleteLog {
                    Label("Deleted", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private func revealActivityLog() {
        let log = ActivityLog.shared
        log.flush()
        try? FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([log.logFiles().last ?? log.directory])
        didDeleteLog = false
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Oriel Diagnostics.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try reportText.write(to: url, atomically: true, encoding: .utf8)
            saveError = nil
        } catch {
            saveError = "Could not save the diagnostics report: \(error.localizedDescription)"
        }
    }
}
