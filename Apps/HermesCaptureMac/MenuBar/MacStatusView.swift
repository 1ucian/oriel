import AppKit
import HermesCaptureCore
import HermesCaptureProtocol
import SwiftUI

/// The menu-bar panel: what is connected, what it may do, the assistant, and the display
/// controls tucked away until needed. Every control keeps its accessibility identifier.
struct MacStatusView: View {
    @Bindable var pairing: PairingCoordinator
    @Bindable var screenProfiles: ScreenProfileController
    let prepareForTermination: @MainActor () async -> Void
    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var showDisplay = false
    private var assistant: AssistantStatus { AssistantStatus.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            connectionCard
            if pairing.isControlling, pairing.activeCapabilities.contains(.runAgentActions) {
                assistantCard
            }
            if !pairing.pairedDevices.isEmpty || pairing.pairedDevicesError != nil {
                PairedDevicesSection(
                    devices: pairing.pairedDevices,
                    connectedSigningPublicKey: pairing.activePeerSigningPublicKey,
                    errorMessage: pairing.pairedDevicesError
                ) { device in
                    pairing.revokePeer(signingPublicKey: device.signingPublicKey)
                }
            }
            displaySection
            if let error = pairing.errorDescription {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("pairing.error")
                    if !pairing.isControlling && pairing.pending == nil {
                        Button("Try Pairing Again") {
                            pairing.startPairing()
                        }
                        .accessibilityIdentifier("pairing.retry")
                    }
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 390)
        .onAppear {
            pairing.refreshPairedDevices()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            MacWindowMark()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("\u{4F}\u{72}\u{69}\u{65}\u{6C}")
                    .font(.headline)
                Text(connectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("connection.description")
            }
            Spacer()
            Label(statusPresentation.title, systemImage: statusPresentation.icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(statusTint.opacity(0.14), in: Capsule())
                .foregroundStyle(statusTint)
                .lineLimit(1)
        }
    }

    // MARK: Connection

    @ViewBuilder
    private var connectionCard: some View {
        if let pending = pairing.pending {
            card {
                Text(pending.deviceName)
                    .font(.headline)
                Text("Asks to: " + MacHostPresentation.capabilitySummary(pending.requestedCapabilities).lowercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let code = pending.confirmationCode {
                    // Phones on the first release show no code, and the Mac cannot tell which one asks.
                    Text("If your phone shows a code, it should be \(Text(code.formatted).font(.title3.monospacedDigit().weight(.semibold))).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("If your phone shows a code, it should be \(code.spokenDigits).")
                        .accessibilityIdentifier("pairing.confirmationCode")
                }
                HStack {
                    Button("Decline", role: .cancel) {
                        pairing.decline()
                    }
                    .disabled(pairing.isApprovalInFlight)
                    Spacer()
                    Button(pairing.isApprovalInFlight ? "Allowing…" : "Allow Control") {
                        pairing.approve()
                    }
                    .prominentButton()
                    .disabled(pairing.isApprovalInFlight)
                }
            }
        } else if let qrImage = pairing.qrImage {
            card {
                VStack(spacing: 8) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 196, height: 196)
                        .padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("\u{4F}\u{72}\u{69}\u{65}\u{6C} pairing code")
                    Text("Scan with \u{4F}\u{72}\u{69}\u{65}\u{6C} on iPhone or iPad")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if let code = pairing.pairingCode {
                            Button("Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }
                            .help("For a phone whose camera can't scan: paste it in Oriel on the phone. The code expires with this pairing session.")
                            .accessibilityIdentifier("pairing.copyCode")
                        }
                        Button("Cancel Pairing") {
                            pairing.stopPairing()
                        }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            }
        } else if pairing.isControlling {
            card {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pairing.connectedDeviceName ?? "iPhone")
                            .font(.headline)
                        Text(pairing.connectedThroughRelay ? "Connected through the relay" : "Connected on your network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                capabilityChips
            }
        } else {
            card {
                Text("No iPhone connected")
                    .font(.subheadline.weight(.semibold))
                Text("Pair once with a code; the phone reconnects on your network from then on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    pairing.startPairing()
                } label: {
                    Label("Pair iPhone or iPad", systemImage: "qrcode")
                }
                .prominentButton()
                .disabled(pairing.isPairing)
                .accessibilityIdentifier("pairing.start")
            }
        }
    }

    private var capabilityChips: some View {
        HStack(spacing: 6) {
            ForEach(pairing.activeCapabilities.sorted { $0.rawValue < $1.rawValue }, id: \.self) { capability in
                Text(MacHostPresentation.capabilityName(capability))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityLabel("Approved capabilities: " + MacHostPresentation.capabilitySummary(pairing.activeCapabilities))
    }

    // MARK: Assistant

    private var assistantCard: some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(assistant.statusLine)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .accessibilityIdentifier("assistant.status")
                Spacer()
            }
            // The card keeps one height while a run streams events: a panel whose
            // height follows every trace line sends AppKit into a constraint loop.
            Text(assistant.isActive ? (assistant.lastLine ?? " ") : " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            Button("Stop Assistant", role: .destructive) {
                assistant.stopRequest?()
            }
            .controlSize(.small)
            .disabled(!assistant.isActive)
            .accessibilityIdentifier("assistant.stop")
        }
    }

    // MARK: Display

    private var displaySection: some View {
        DisclosureGroup(isExpanded: $showDisplay) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Optimize · \(screenProfiles.automationLabel)") {
                        screenProfiles.useAutomationProfile()
                    }
                    .help("Save the current display mode, then use a remote-control-friendly mode.")
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    .accessibilityIdentifier("screen-preset.automation")

                    Button("Restore Owner") {
                        screenProfiles.restoreOwnerProfile()
                    }
                    .help("Restore the exact display mode saved before Oriel changed it.")
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(!screenProfiles.canRestoreOwner)
                    .accessibilityIdentifier("screen-preset.human")
                }
                .controlSize(.small)

                Menu("Resolution & Aspect Ratio") {
                    Section("Current Display") {
                        Text(screenProfiles.currentLabel)
                    }
                    Section("Landscape") {
                        ForEach(screenProfiles.landscapeResolutionPresets) { preset in
                            resolutionPresetButton(preset)
                        }
                    }
                    if !screenProfiles.portraitResolutionPresets.isEmpty {
                        Section("Portrait") {
                            ForEach(screenProfiles.portraitResolutionPresets) { preset in
                                resolutionPresetButton(preset)
                            }
                        }
                    }
                    Section("All Supported Modes") {
                        ForEach(screenProfiles.selectableConfigurations, id: \.modeID) { item in
                            Button(item.detailedLabel) {
                                screenProfiles.useCustomProfile(item)
                            }
                            .accessibilityLabel(item.detailedLabel)
                        }
                    }
                }
                .disabled(screenProfiles.selectableConfigurations.isEmpty)
                .help("Choose a mode reported by macOS. Unavailable aspect ratios are never approximated.")
                .accessibilityIdentifier("screen-resolution.chooser")

                DisclosureGroup("Custom Supported Size") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            TextField("Width", text: $customWidth)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 78)
                                .accessibilityLabel("Custom resolution width")
                                .accessibilityIdentifier("screen-resolution.custom.width")
                            Text("×")
                                .accessibilityHidden(true)
                            TextField("Height", text: $customHeight)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 78)
                                .accessibilityLabel("Custom resolution height")
                                .accessibilityIdentifier("screen-resolution.custom.height")
                            Button("Apply") {
                                guard let dimensions = customDimensions else { return }
                                screenProfiles.useCustomDimensions(
                                    width: dimensions.width,
                                    height: dimensions.height
                                )
                            }
                            .disabled(customDimensions == nil)
                            .accessibilityLabel("Apply custom supported resolution")
                            .accessibilityIdentifier("screen-resolution.custom.apply")
                        }
                        Text("Exact sizes only · 640–8192 pixels · macOS support required")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .accessibilityIdentifier("screen-resolution.custom")

                Text("Oriel keeps the display's aspect ratio and streams at most 1920×1080. Display changes are always manual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = screenProfiles.errorDescription {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label("Display", systemImage: "display")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(screenProfiles.activeProfile.rawValue) · \(screenProfiles.currentLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Stop Control", role: .destructive) {
                pairing.stopControl()
            }
            .keyboardShortcut(".", modifiers: [.command, .option])
            // A run that went on without its phone is stopped here too.
            .disabled(!pairing.isControlling && !assistant.isActive)
            Spacer()
            SettingsLink {
                Text("Settings…")
            }
            Button("Quit") {
                Task {
                    await prepareForTermination()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .controlSize(.small)
    }

    // MARK: Helpers

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var customDimensions: (width: Int, height: Int)? {
        guard let width = Int(customWidth.trimmingCharacters(in: .whitespaces)),
              let height = Int(customHeight.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (width, height)
    }

    private func resolutionPresetButton(
        _ preset: DisplayResolutionPreset
    ) -> some View {
        Button(preset.accessibilityLabel) {
            screenProfiles.useResolutionPreset(preset)
        }
        .disabled(!preset.isAvailable)
        .accessibilityLabel(preset.accessibilityLabel)
        .accessibilityIdentifier("screen-resolution.\(preset.id)")
    }

    private var statusPresentation: MacHostPresentation.Status {
        MacHostPresentation.status(
            isControlling: pairing.isControlling,
            hasPendingRequest: pairing.pending != nil,
            isPairing: pairing.isPairing,
            hasError: pairing.errorDescription != nil
        )
    }

    private var statusTint: Color {
        if pairing.errorDescription != nil { return .red }
        if pairing.isControlling { return .green }
        if pairing.pending != nil || pairing.isPairing { return .orange }
        return .secondary
    }

    private var connectionDescription: String {
        if let deviceName = pairing.connectedDeviceName {
            return "Connected to \(deviceName)"
        }
        if let deviceName = pairing.pending?.deviceName {
            return "Review the request from \(deviceName)"
        }
        if pairing.isPairing {
            return "Scan the code below with Oriel on iPhone"
        }
        if pairing.errorDescription != nil {
            return "Pairing stopped. Review the error, then try again."
        }
        return "No iPhone connected"
    }
}

extension View {
    /// A window's main action: prominent while its window is key. In any other window macOS draws
    /// a prominent button without its fill but keeps its white label, which vanishes on a light
    /// background, so there it is a bordered button, with a red label when it is destructive.
    func prominentButton(destructive: Bool = false) -> some View {
        modifier(ProminentButton(destructive: destructive))
    }
}

private struct ProminentButton: ViewModifier {
    let destructive: Bool
    @Environment(\.controlActiveState) private var activeState

    @ViewBuilder
    func body(content: Content) -> some View {
        if activeState == .key {
            content
                .buttonStyle(.borderedProminent)
                .tint(destructive ? .red : nil)
        } else if destructive {
            content
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
        } else {
            content
                .buttonStyle(.bordered)
        }
    }
}

/// The icon's lit window at menu size.
private struct MacWindowMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.086, green: 0.251, blue: 0.247), Color(red: 0.043, green: 0.141, blue: 0.145)],
                                     startPoint: .top, endPoint: .bottom))
            GeometryReader { proxy in
                let w = proxy.size.width, h = proxy.size.height
                let centre = CGRect(x: w * 0.34, y: h * 0.24, width: w * 0.32, height: h * 0.5)
                Path { path in
                    path.move(to: CGPoint(x: w * 0.2, y: centre.minY + h * 0.06))
                    path.addLine(to: CGPoint(x: centre.minX - w * 0.025, y: centre.minY))
                    path.addLine(to: CGPoint(x: centre.minX - w * 0.025, y: centre.maxY))
                    path.addLine(to: CGPoint(x: w * 0.2, y: centre.maxY - h * 0.06))
                    path.closeSubpath()
                    path.move(to: CGPoint(x: w * 0.8, y: centre.minY + h * 0.06))
                    path.addLine(to: CGPoint(x: centre.maxX + w * 0.025, y: centre.minY))
                    path.addLine(to: CGPoint(x: centre.maxX + w * 0.025, y: centre.maxY))
                    path.addLine(to: CGPoint(x: w * 0.8, y: centre.maxY - h * 0.06))
                    path.closeSubpath()
                    path.addRect(centre)
                }
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.965, blue: 0.886), Color(red: 0.561, green: 0.820, blue: 0.776)],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
        .accessibilityHidden(true)
    }
}
