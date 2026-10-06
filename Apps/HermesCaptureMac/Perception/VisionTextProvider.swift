import CoreGraphics
import HermesCaptureCore
import Vision

struct VisionTextProvider {
    func targets(
        in image: CGImage,
        frameSequence: UInt64,
        monotonicTimestampNanoseconds: UInt64
    ) throws -> [TargetCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first,
                  !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let box = observation.boundingBox
            let normalized = NormalizedTargetBounds(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            )
            let identifier = "ocr:\(frameSequence):\(Int(box.minX * 10_000)):\(Int(box.minY * 10_000))"
            return try? TargetCandidate.validated(
                stableIdentifier: identifier,
                bounds: normalized,
                label: text.string,
                role: .text,
                source: .visionOCR,
                frameSequence: frameSequence,
                monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
                confidence: Double(text.confidence),
                isEnabled: true,
                isSensitive: SensitiveTextClassifier.isSensitive(text.string)
            )
        }
    }
}
