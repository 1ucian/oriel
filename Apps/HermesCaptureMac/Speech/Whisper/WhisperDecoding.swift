import Foundation
import MLX
import zlib

/// Whisper's transcription loop: a port of mlx_whisper's `transcribe()` and `DecodingTask`
/// (MIT, Copyright © 2023 Apple Inc.) with the options Hermes uses: transcribe, timestamps on,
/// temperatures 0, 0.2 … 1.0 as fallbacks, compression ratio 2.4, log probability −1.0,
/// no-speech 0.6, the previous window's text as the next one's prompt, greedy decoding.
struct WhisperTranscriber {
    let model: WhisperModel
    let tokenizer: WhisperTokenizer

    static let temperatures: [Float] = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
    static let compressionRatioThreshold = 2.4
    static let logProbabilityThreshold = -1.0
    static let noSpeechThreshold = 0.6
    /// Timestamps start within the first second of a window.
    static let maximumInitialTimestamp = 1.0

    struct Result {
        let text: String
        let language: String
    }

    /// One window's decode (mlx_whisper `DecodingResult`).
    struct WindowResult {
        let tokens: [Int]
        let text: String
        let averageLogProbability: Double
        let noSpeechProbability: Double
        let temperature: Float
        let compressionRatio: Double
    }

    private struct Segment {
        let start: Double
        let end: Double
        var tokens: [Int]
    }

    /// `samples`: 16 kHz mono. `language` nil detects it from the first 30 seconds.
    func transcribe(_ samples: [Float], language: String?, initialPrompt: String?) -> Result {
        let mel = WhisperAudio.logMelSpectrogram(
            samples, melCount: model.dimensions.melCount, padding: WhisperAudio.windowSamples
        )
        let windowFrames = WhisperAudio.windowFrames
        let contentFrames = mel.dim(0) - windowFrames
        let language = language ?? detectLanguage(
            WhisperAudio.padOrTrim(mel, length: windowFrames, axis: 0).asType(.float16)
        )
        let inputStride = windowFrames / model.dimensions.audioContext
        let timePrecision = Double(inputStride * WhisperAudio.hopLength) / Double(WhisperAudio.sampleRate)

        var allTokens: [Int] = []
        var promptResetSince = 0
        var initialPromptTokens: [Int] = []
        if let initialPrompt {
            initialPromptTokens = tokenizer.encode(" " + initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
            allTokens += initialPromptTokens
        }

        var seek = 0
        while seek < contentFrames {
            let timeOffset = Double(seek * WhisperAudio.hopLength) / Double(WhisperAudio.sampleRate)
            let segmentSize = min(windowFrames, contentFrames - seek)
            let segmentDuration = Double(segmentSize * WhisperAudio.hopLength) / Double(WhisperAudio.sampleRate)
            let melSegment = WhisperAudio.padOrTrim(mel[seek ..< (seek + segmentSize)], length: windowFrames, axis: 0)
                .asType(.float16)
            let result = decodeWithFallback(
                melSegment, language: language, prompt: Array(allTokens[promptResetSince...])
            )
            let tokens = result.tokens

            // Silence: the model says no speech and was not confident about what it heard.
            var shouldSkip = result.noSpeechProbability > Self.noSpeechThreshold
            if result.averageLogProbability > Self.logProbabilityThreshold { shouldSkip = false }
            if shouldSkip {
                seek += segmentSize
                continue
            }

            let isTimestamp = tokens.map { $0 >= tokenizer.timestampBegin }
            let singleTimestampEnding = Array(isTimestamp.suffix(2)) == [false, true]
            var consecutive: [Int] = []
            if tokens.count > 1 {
                for index in 0 ..< (tokens.count - 1) where isTimestamp[index] && isTimestamp[index + 1] {
                    consecutive.append(index + 1)
                }
            }

            var segments: [Segment] = []
            if !consecutive.isEmpty {
                var slices = consecutive
                if singleTimestampEnding { slices.append(tokens.count) }
                var lastSlice = 0
                for currentSlice in slices {
                    let sliced = Array(tokens[lastSlice ..< currentSlice])
                    let startPosition = sliced[0] - tokenizer.timestampBegin
                    let endPosition = sliced[sliced.count - 1] - tokenizer.timestampBegin
                    segments.append(Segment(
                        start: timeOffset + Double(startPosition) * timePrecision,
                        end: timeOffset + Double(endPosition) * timePrecision,
                        tokens: sliced
                    ))
                    lastSlice = currentSlice
                }
                if singleTimestampEnding {
                    // A single timestamp at the end: nothing more was said in this window.
                    seek += segmentSize
                } else {
                    // Leave out the unfinished segment and go on from the last timestamp.
                    seek += (tokens[lastSlice - 1] - tokenizer.timestampBegin) * inputStride
                }
            } else {
                var duration = segmentDuration
                let timestamps = tokens.filter { $0 >= tokenizer.timestampBegin }
                if let last = timestamps.last, last != tokenizer.timestampBegin {
                    duration = Double(last - tokenizer.timestampBegin) * timePrecision
                }
                segments.append(Segment(start: timeOffset, end: timeOffset + duration, tokens: tokens))
                seek += segmentSize
            }

            // An instantaneous segment, or one without text, contributes nothing.
            for index in segments.indices {
                let text = tokenizer.decode(segments[index].tokens.filter { $0 < tokenizer.endOfText })
                if segments[index].start == segments[index].end
                    || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments[index].tokens = []
                }
            }
            allTokens += segments.flatMap(\.tokens)
            // A high temperature's text is not fed to the next window.
            if result.temperature > 0.5 { promptResetSince = allTokens.count }
        }

        let text = tokenizer.decode(Array(allTokens[initialPromptTokens.count...]))
        return Result(text: text, language: language)
    }

    /// Decodes at temperature 0, and again warmer while the text is too repetitive or too
    /// unlikely, unless the window is silence.
    func decodeWithFallback(_ mel: MLXArray, language: String, prompt: [Int]) -> WindowResult {
        let features = model.encoder(mel.expandedDimensions(axis: 0))
        var result: WindowResult?
        for temperature in Self.temperatures {
            let attempt = decode(features: features, language: language, prompt: prompt, temperature: temperature)
            result = attempt
            var needsFallback = false
            if attempt.compressionRatio > Self.compressionRatioThreshold { needsFallback = true }
            if attempt.averageLogProbability < Self.logProbabilityThreshold { needsFallback = true }
            if attempt.noSpeechProbability > Self.noSpeechThreshold { needsFallback = false }
            if !needsFallback { break }
        }
        return result!
    }

    /// The most likely language over the first window (mlx_whisper `detect_language`).
    func detectLanguage(_ mel: MLXArray) -> String {
        let features = model.encoder(mel.expandedDimensions(axis: 0))
        let start = MLXArray([Int32(tokenizer.startOfTranscript)]).reshaped([1, 1])
        let logits = model.decoder(start, audio: features, cache: nil).0[0, 0]
        var mask = [Float](repeating: -Float.infinity, count: logits.dim(-1))
        for token in tokenizer.allLanguageTokens { mask[token] = 0 }
        let best = argMax(logits + MLXArray(mask), axis: -1).item(Int.self)
        let index = best - tokenizer.startOfTranscript - 1
        return WhisperTokenizer.languageCodes.indices.contains(index) ? WhisperTokenizer.languageCodes[index] : "en"
    }

    /// One greedy (or sampled, above temperature 0) pass over a window.
    func decode(features: MLXArray, language: String, prompt: [Int], temperature: Float) -> WindowResult {
        var sotSequence = [tokenizer.startOfTranscript]
        if let languageToken = tokenizer.languageToken(language) { sotSequence.append(languageToken) }
        sotSequence.append(tokenizer.transcribe)
        var initialTokens = sotSequence
        if !prompt.isEmpty {
            let keep = model.dimensions.textContext / 2 - 1
            initialTokens = [tokenizer.startOfPrevious] + prompt.suffix(keep) + sotSequence
        }
        let sampleBegin = initialTokens.count
        let sotIndex = initialTokens.firstIndex(of: tokenizer.startOfTranscript) ?? 0
        let sampleLength = model.dimensions.textContext / 2
        let filters = WhisperLogitFilters.shared(for: tokenizer, vocabularySize: model.dimensions.vocabularySize)

        var tokens = initialTokens
        var sumLogProbability: Float = 0
        var cache: [WhisperBlockCache]?

        func step(_ inputs: [Int]) -> (logits: MLXArray, next: Int, logProbability: Float) {
            let input = MLXArray(inputs.map(Int32.init)).reshaped([1, inputs.count])
            let (preLogits, newCache) = model.decoder(input, audio: features, cache: cache)
            cache = newCache
            var logits = preLogits[0, -1]
            if tokens.count == sampleBegin { logits = logits + filters.blank }
            logits = logits + filters.suppress
            logits = filters.applyTimestampRules(logits, tokens: tokens, sampleBegin: sampleBegin, tokenizer: tokenizer)
            let next = temperature == 0
                ? argMax(logits, axis: -1)
                : MLXRandom.categorical(logits / temperature)
            let logProbabilities = logits - logSumExp(logits, axis: -1, keepDims: true)
            let chosen = logProbabilities.take(next, axis: -1)
            eval(next, chosen)
            return (preLogits, next.item(Int.self), chosen.item(Float.self))
        }

        let first = step(tokens)
        let noSpeech = softmax(first.logits[0, sotIndex], axis: -1)[tokenizer.noSpeech].item(Float.self)
        var completed = accept(first, into: &tokens, sum: &sumLogProbability)
        var sampled = 1
        while sampled < sampleLength, tokens.count <= model.dimensions.textContext, !completed {
            let next = step([tokens[tokens.count - 1]])
            completed = accept(next, into: &tokens, sum: &sumLogProbability)
            sampled += 1
        }

        var output = Array(tokens[sampleBegin...])
        if let end = output.firstIndex(of: tokenizer.endOfText) { output = Array(output[..<end]) }
        let text = tokenizer.decode(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return WindowResult(
            tokens: output,
            text: text,
            averageLogProbability: Double(sumLogProbability) / Double(output.count + 1),
            noSpeechProbability: Double(noSpeech),
            temperature: temperature,
            compressionRatio: Self.compressionRatio(text)
        )
    }

    /// The greedy decoder's update: the token joins, and its log probability counts unless the
    /// sequence had already ended.
    private func accept(
        _ step: (logits: MLXArray, next: Int, logProbability: Float),
        into tokens: inout [Int],
        sum: inout Float
    ) -> Bool {
        let ended = tokens.last == tokenizer.endOfText
        if !ended { sum += step.logProbability }
        tokens.append(ended ? tokenizer.endOfText : step.next)
        return tokens.last == tokenizer.endOfText
    }

    /// Bytes of the text over bytes zlib makes of it: high for repetition loops.
    static func compressionRatio(_ text: String) -> Double {
        var input = Array(text.utf8)
        guard !input.isEmpty else { return 0 }
        var length = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        guard compress2(&output, &length, &input, uLong(input.count), Z_DEFAULT_COMPRESSION) == Z_OK,
              length > 0 else { return 0 }
        return Double(input.count) / Double(length)
    }
}

/// The logit masks decoding applies at every step, built once per vocabulary.
final class WhisperLogitFilters: @unchecked Sendable {
    /// No blank and no end of text as the first token.
    let blank: MLXArray
    /// Non-speech symbols and the special tokens that are not text.
    let suppress: MLXArray
    /// Timestamp-rule masks: always no `<|notimestamps|>`; then after two timestamps, text only;
    /// after one, a timestamp or the end; at the start, a timestamp within the first second.
    private let base: MLXArray
    private let afterPair: MLXArray
    private let afterSingle: MLXArray
    private let initial: MLXArray

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: WhisperLogitFilters] = [:]

    static func shared(for tokenizer: WhisperTokenizer, vocabularySize: Int) -> WhisperLogitFilters {
        lock.lock()
        defer { lock.unlock() }
        if let filters = cache[vocabularySize] { return filters }
        let filters = WhisperLogitFilters(tokenizer: tokenizer, vocabularySize: vocabularySize)
        cache[vocabularySize] = filters
        return filters
    }

    private init(tokenizer: WhisperTokenizer, vocabularySize: Int) {
        func mask(_ build: (inout [Float]) -> Void) -> MLXArray {
            var values = [Float](repeating: 0, count: vocabularySize)
            build(&values)
            return MLXArray(values)
        }
        let blankTokens = tokenizer.encode(" ") + [tokenizer.endOfText]
        blank = mask { values in for token in blankTokens { values[token] = -.infinity } }
        let suppressed = tokenizer.nonSpeechTokens + [
            tokenizer.transcribe, tokenizer.translate, tokenizer.startOfTranscript,
            tokenizer.startOfPrevious, tokenizer.startOfLM, tokenizer.noSpeech,
        ]
        suppress = mask { values in for token in suppressed { values[token] = -.infinity } }
        let timestampBegin = tokenizer.timestampBegin
        let noTimestamps = tokenizer.noTimestamps
        base = mask { values in values[noTimestamps] = -.infinity }
        afterPair = mask { values in
            values[noTimestamps] = -.infinity
            for token in timestampBegin ..< vocabularySize { values[token] = -.infinity }
        }
        afterSingle = mask { values in
            values[noTimestamps] = -.infinity
            for token in 0 ..< tokenizer.endOfText { values[token] = -.infinity }
        }
        let precision = Double(WhisperAudio.chunkSeconds) / 1_500
        let lastAllowed = timestampBegin + Int((WhisperTranscriber.maximumInitialTimestamp / precision).rounded())
        initial = mask { values in
            values[noTimestamps] = -.infinity
            for token in 0 ..< timestampBegin { values[token] = -.infinity }
            for token in (lastAllowed + 1) ..< vocabularySize { values[token] = -.infinity }
        }
    }

    /// mlx_whisper `ApplyTimestampRules`. Its rule against decreasing timestamps compares
    /// positions with token ids and never masks anything; leaving it out keeps the same output.
    func applyTimestampRules(
        _ logits: MLXArray, tokens: [Int], sampleBegin: Int, tokenizer: WhisperTokenizer
    ) -> MLXArray {
        let timestampBegin = tokenizer.timestampBegin
        let sampled = tokens.count - sampleBegin
        var mask = base
        if tokens.count == sampleBegin {
            mask = initial
        } else if let last = tokens.last, last >= timestampBegin {
            let penultimateWasTimestamp = sampled < 2 || tokens[tokens.count - 2] >= timestampBegin
            mask = penultimateWasTimestamp ? afterPair : afterSingle
        }
        // When the timestamps together are likelier than any text token, a timestamp comes next.
        let logProbabilities = logits - logSumExp(logits, axis: -1, keepDims: true)
        let timestampLogProbability = logSumExp(logProbabilities[timestampBegin...], axis: -1, keepDims: true)
        let maximumTextLogProbability = logProbabilities[..<timestampBegin].max(axis: -1, keepDims: true)
        let textMask = which(
            timestampLogProbability .> maximumTextLogProbability,
            MLXArray(-Float.infinity),
            mask[..<timestampBegin]
        )
        return logits + concatenated([textMask, mask[timestampBegin...]])
    }
}
