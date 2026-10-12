import Foundation
import Testing
import HermesCaptureProtocol
@testable import HermesCaptureMac

struct PairedDevicesPresentationTests {
    @Test func approvedCapabilitiesReadAsOneSentenceInDeclaredOrder() {
        #expect(MacHostPresentation.allowedSentence(SessionCapability.assistantDefaults)
            == "Can view the screen, control the pointer, type text and run the assistant.")
        #expect(MacHostPresentation.allowedSentence([.typeText, .viewScreen]) == "Can view the screen and type text.")
        #expect(MacHostPresentation.allowedSentence([.viewScreen]) == "Can view the screen.")
        #expect(MacHostPresentation.allowedSentence([]) == "Nothing approved.")
    }

    /// Outside the key window macOS drops a prominent button's fill but keeps its white label, so
    /// the pairing window's main actions go through one helper that falls back to a bordered button.
    @Test func prominentButtonsStayReadableOutsideTheKeyWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let view = try source("Apps/HermesCaptureMac/MenuBar/MacStatusView.swift")
        let section = try source("Apps/HermesCaptureMac/MenuBar/PairedDevicesSection.swift")

        #expect(view.components(separatedBy: ".buttonStyle(.borderedProminent)").count == 2)
        #expect(view.contains("if activeState == .key {"))
        #expect(view.components(separatedBy: ".prominentButton()").count == 3)
        #expect(!section.contains(".buttonStyle(.borderedProminent)"))
        #expect(section.contains(".prominentButton(destructive: true)"))
    }

    @Test func pairedDateShowsTheDayItWasPaired() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let line = MacHostPresentation.pairedLine(
            Date(timeIntervalSince1970: 1_791_676_800),
            locale: Locale(identifier: "en_US"),
            timeZone: utc
        )

        #expect(line == "Paired Oct 11, 2026")
    }
}
