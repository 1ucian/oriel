import AppKit
import HermesCaptureProtocol
import SwiftUI

/// The phones this Mac trusts: what each may do, when it was paired, and Revoke, which asks
/// once more in the row before it ends the phone's session and removes its pairing.
struct PairedDevicesSection: View {
    let devices: [TrustedPeerRecord]
    let connectedSigningPublicKey: Data?
    let errorMessage: String?
    let revoke: (TrustedPeerRecord) -> Void
    @State private var isExpanded: Bool
    @State private var confirmingID: String?
    /// VoiceOver follows the row: to the question when Revoke swaps in the confirmation, back to
    /// Revoke on Cancel.
    @AccessibilityFocusState private var focus: Focus?

    private enum Focus: Hashable {
        case revoke(String)
        case question(String)
    }

    init(
        devices: [TrustedPeerRecord],
        connectedSigningPublicKey: Data?,
        errorMessage: String?,
        isExpanded: Bool = false,
        confirmingID: String? = nil,
        revoke: @escaping (TrustedPeerRecord) -> Void
    ) {
        self.devices = devices
        self.connectedSigningPublicKey = connectedSigningPublicKey
        self.errorMessage = errorMessage
        self.revoke = revoke
        _isExpanded = State(initialValue: isExpanded)
        _confirmingID = State(initialValue: confirmingID)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(devices) { device in
                    row(device)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pairedDevices.error")
                }
            }
            .padding(.top, 6)
            .onChange(of: confirmingID) { previous, current in
                focus = current.map(Focus.question) ?? previous.map(Focus.revoke)
            }
        } label: {
            HStack {
                Label("Paired devices", systemImage: "iphone")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(devices.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(devices.count == 1 ? "Paired devices, 1 device" : "Paired devices, \(devices.count) devices")
        }
        .accessibilityIdentifier("pairedDevices")
    }

    private func row(_ device: TrustedPeerRecord) -> some View {
        let isConnected = device.signingPublicKey == connectedSigningPublicKey
        let isConfirming = confirmingID == device.id
        let allowed = MacHostPresentation.allowedSentence(device.approvedCapabilities)
        let paired = MacHostPresentation.pairedLine(device.createdAt)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "iphone")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if isConnected {
                            Text("Connected")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text(allowed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(paired)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    ([device.displayName + "."] + (isConnected ? ["Connected now."] : []) + [allowed, paired + "."])
                        .joined(separator: " ")
                )
                Spacer(minLength: 8)
                if !isConfirming {
                    Button("Revoke", role: .destructive) {
                        confirmingID = device.id
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Revoke \(device.displayName)")
                    .accessibilityHint("Asks first. Then the phone's session ends and it must pair again.")
                    .accessibilityIdentifier("pairedDevices.revoke")
                    .accessibilityFocused($focus, equals: .revoke(device.id))
                }
            }
            if isConfirming {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Revoke \(device.displayName)?")
                        .font(.caption.weight(.semibold))
                        .accessibilityFocused($focus, equals: .question(device.id))
                    Text((isConnected ? "Its session ends now. " : "")
                        + "It needs a new pairing code and your approval to connect again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            confirmingID = nil
                        }
                        .accessibilityLabel("Keep \(device.displayName)")
                        .accessibilityIdentifier("pairedDevices.cancelRevoke")
                        Button("Revoke", role: .destructive) {
                            confirmingID = nil
                            revoke(device)
                        }
                        .prominentButton(destructive: true)
                        .accessibilityLabel("Revoke \(device.displayName) now")
                        .accessibilityIdentifier("pairedDevices.confirmRevoke")
                    }
                    .controlSize(.small)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(10)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.6),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}
