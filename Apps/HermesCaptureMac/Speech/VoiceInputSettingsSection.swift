import AppKit
import SwiftUI

/// Settings, Assistant: voice input from the phone. Whisper large-v3 downloads once, runs on this Mac, and gets the
/// language and vocabulary set here.
struct VoiceInputSettingsSection: View {
    @Bindable var settings: SpeechSettings
    private var status: SpeechStatus { SpeechStatus.shared }

    var body: some View {
        Section {
            Toggle("Voice input from iPhone and iPad", isOn: $settings.isEnabled)
                .accessibilityIdentifier("speech.enabled")
            if settings.isEnabled {
                Picker("Language", selection: $settings.language) {
                    ForEach(SpeechSettings.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .accessibilityIdentifier("speech.language")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vocabulary")
                    TextEditor(text: $settings.vocabulary)
                        .font(.callout)
                        .frame(minHeight: 48, maxHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        .accessibilityLabel("Vocabulary")
                        .accessibilityIdentifier("speech.vocabulary")
                    Text("Names and terms Whisper should expect, such as people, products or jargon. Leave it empty for none.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                modelRow
            }
        } header: {
            Text("Voice input")
                .task { await SpeechService.shared.refresh() }
        } footer: {
            Text("The phone records only while its mic is on and sends the audio, end-to-end encrypted, to this Mac. Whisper turns it into text here and the text goes back to the phone. Audio is never saved on either device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WhisperModelStore.displayName)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            switch status.phase {
            case .unsupported:
                Text("Needs Apple silicon").font(.caption).foregroundStyle(.secondary)
            case .notInstalled:
                Button("Download") { Task { await SpeechService.shared.prepare() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("speech.download")
            case let .downloading(fraction):
                ProgressView(value: fraction)
                    .frame(width: 90)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                Button("Cancel") { Task { await SpeechService.shared.cancelDownload() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("speech.cancelDownload")
            case .installed:
                Text("Downloaded").font(.caption).foregroundStyle(.secondary)
                Button("Remove") { Task { await SpeechService.shared.removeModel() } }
                    .controlSize(.small)
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading").font(.caption).foregroundStyle(.secondary)
            case .ready:
                Text("Loaded").font(.caption).foregroundStyle(.green)
                Button("Unload") { Task { await SpeechService.shared.unload() } }
                    .controlSize(.small)
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button("Try again") { Task { await SpeechService.shared.prepare() } }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speech.model")
    }

    private var detailLine: String {
        var parts = [String(format: "%.1f GB, downloaded once from Hugging Face", Double(WhisperModelStore.approximateBytes) / 1e9), "MIT"]
        if let last = status.lastTranscription {
            parts.append(String(format: "last: %.1f s of speech in %.2f s", last.audioSeconds, last.elapsedSeconds))
        }
        return parts.joined(separator: " · ")
    }
}
