import Testing
@testable import HermesCaptureCore

struct DisplayModeProfileTests {
    @Test func agentProfileSelectsExact1080p60Mode() {
        let modes = [
            mode(id: 1, width: 2560, height: 1440, refreshRate: 60),
            mode(id: 2, width: 1920, height: 1080, refreshRate: 120),
            mode(id: 3, width: 1920, height: 1080, refreshRate: 60),
        ]

        let selected = DisplayProfileSelector.agentMode(in: modes)

        #expect(selected?.modeID == 3)
    }

    @Test func agentProfilePrefersCaptureEfficientPixelDimensions() {
        let modes = [
            mode(
                id: 1,
                width: 1920,
                height: 1080,
                pixelWidth: 3840,
                pixelHeight: 2160,
                refreshRate: 60
            ),
            mode(id: 2, width: 1920, height: 1080, refreshRate: 60),
        ]

        let selected = DisplayProfileSelector.agentMode(in: modes)

        #expect(selected?.modeID == 2)
    }

    @Test func agentProfileUsesNearestSupportedResolution() {
        let modes = [
            mode(id: 1, width: 1600, height: 900, refreshRate: 60),
            mode(id: 2, width: 1920, height: 1200, refreshRate: 60),
            mode(id: 3, width: 2560, height: 1440, refreshRate: 60),
        ]

        let selected = DisplayProfileSelector.agentMode(in: modes)

        #expect(selected?.modeID == 2)
    }

    @Test func agentProfileRejectsModesMarkedUnavailable() {
        let modes = [
            mode(
                id: 1,
                width: 1920,
                height: 1080,
                refreshRate: 60,
                isUsable: false
            ),
            mode(id: 2, width: 1680, height: 1050, refreshRate: 60),
        ]

        let selected = DisplayProfileSelector.agentMode(in: modes)

        #expect(selected?.modeID == 2)
    }

    @Test func ownerProfileRestoresExactModeIdentifier() {
        let saved = mode(id: 42, width: 2560, height: 1440, refreshRate: 120)
        let modes = [
            mode(id: 7, width: 2560, height: 1440, refreshRate: 120),
            saved,
        ]

        let selected = DisplayProfileSelector.ownerMode(
            matching: saved,
            in: modes
        )

        #expect(selected?.modeID == 42)
    }

    @Test func ownerProfileRefusesDifferentModeIdentifierWithMatchingGeometry() {
        let saved = mode(
            id: 42,
            width: 2560,
            height: 1440,
            pixelWidth: 5120,
            pixelHeight: 2880,
            refreshRate: 120
        )
        let replacement = mode(
            id: 99,
            width: 2560,
            height: 1440,
            pixelWidth: 5120,
            pixelHeight: 2880,
            refreshRate: 120
        )

        let selected = DisplayProfileSelector.ownerMode(
            matching: saved,
            in: [replacement]
        )

        #expect(selected == nil)
    }

    @Test func standardAspectRatioInventoryCoversLandscapeSquareAndPortrait() {
        #expect(DisplayAspectRatio.standardLandscape == [
            .landscape16x9,
            .landscape16x10,
            .landscape4x3,
            .landscape3x2,
            .square,
        ])
        #expect(DisplayAspectRatio.standardPortrait == [
            .portrait9x16,
            .portrait10x16,
            .portrait3x4,
            .portrait2x3,
        ])
    }

    @Test func aspectRatioClassificationRecognizesEveryStandardPreset() {
        let samples: [(Int, Int, DisplayAspectRatio)] = [
            (1_920, 1_080, .landscape16x9),
            (1_920, 1_200, .landscape16x10),
            (1_440, 1_080, .landscape4x3),
            (1_620, 1_080, .landscape3x2),
            (1_080, 1_080, .square),
            (1_080, 1_920, .portrait9x16),
            (1_200, 1_920, .portrait10x16),
            (1_080, 1_440, .portrait3x4),
            (1_080, 1_620, .portrait2x3),
        ]

        for (width, height, expected) in samples {
            #expect(DisplayAspectRatio.classify(width: width, height: height) == expected)
        }
        #expect(DisplayAspectRatio.classify(width: 1_728, height: 1_117) == nil)
    }

    @Test func resolutionPresetsKeepUnavailableLandscapeChoicesVisible() {
        let modes = [
            mode(id: 1, width: 1_920, height: 1_080, refreshRate: 60),
            mode(id: 2, width: 1_080, height: 1_920, refreshRate: 60),
        ]

        let presets = DisplayProfileSelector.resolutionPresets(in: modes)

        #expect(presets.map(\.aspectRatio) == [
            .landscape16x9,
            .landscape16x10,
            .landscape4x3,
            .landscape3x2,
            .square,
            .portrait9x16,
        ])
        #expect(presets.first?.mode?.modeID == 1)
        #expect(presets[1].mode == nil)
        #expect(presets.last?.mode?.modeID == 2)
    }

    @Test func resolutionPresetPrefersCaptureEfficientModeNearItsStandardSize() {
        let modes = [
            mode(id: 1, width: 2_560, height: 1_600, refreshRate: 60),
            mode(id: 2, width: 1_920, height: 1_200, refreshRate: 60),
            mode(
                id: 3,
                width: 1_920,
                height: 1_200,
                pixelWidth: 3_840,
                pixelHeight: 2_400,
                refreshRate: 60
            ),
        ]

        let selected = DisplayProfileSelector.mode(
            for: .landscape16x10,
            in: modes
        )

        #expect(selected?.modeID == 2)
    }

    @Test func exactCustomDimensionsAreBoundedAndNeverApproximated() {
        let modes = [
            mode(id: 1, width: 1_600, height: 1_000, refreshRate: 60),
            mode(id: 2, width: 1_600, height: 1_000, refreshRate: 120),
            mode(id: 3, width: 1_680, height: 1_050, refreshRate: 60),
        ]

        #expect(
            DisplayProfileSelector.customMode(
                width: 1_600,
                height: 1_000,
                in: modes
            )?.modeID == 1
        )
        #expect(
            DisplayProfileSelector.customMode(
                width: 1_601,
                height: 1_000,
                in: modes
            ) == nil
        )
        #expect(
            DisplayProfileSelector.customMode(
                width: 320,
                height: 200,
                in: modes
            ) == nil
        )
        #expect(
            DisplayProfileSelector.customMode(
                width: 9_000,
                height: 1_000,
                in: modes
            ) == nil
        )
    }

    private func mode(
        id: UInt32,
        width: Int,
        height: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        refreshRate: Double,
        isUsable: Bool = true
    ) -> DisplayModeProfile {
        DisplayModeProfile(
            modeID: id,
            width: width,
            height: height,
            pixelWidth: pixelWidth ?? width,
            pixelHeight: pixelHeight ?? height,
            refreshRate: refreshRate,
            isUsable: isUsable
        )
    }
}
