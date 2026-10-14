import Foundation
import MLX

/// Whisper's audio front end: 16 kHz mono in, log-mel frames out. A port of mlx_whisper's
/// `audio.py` (MIT, Copyright © 2023 Apple Inc.), the same operations in the same order, so the
/// features match the Python transcriber's.
enum WhisperAudio {
    static let sampleRate = 16_000
    static let fftSize = 400
    static let hopLength = 160
    static let chunkSeconds = 30
    /// Samples in one 30-second window.
    static let windowSamples = chunkSeconds * sampleRate
    /// Mel frames in one 30-second window.
    static let windowFrames = windowSamples / hopLength

    /// The log-mel spectrogram of `samples` with `padding` zeros appended, shaped
    /// `[frames, melCount]` (mlx_whisper.audio.log_mel_spectrogram).
    static func logMelSpectrogram(_ samples: [Float], melCount: Int, padding: Int = 0) -> MLXArray {
        var audio = MLXArray(samples)
        if padding > 0 {
            audio = padded(audio, widths: [IntOrPair((0, padding))])
        }
        let spectrum = stft(audio, window: hanning)
        let magnitudes = abs(spectrum[0 ..< (spectrum.dim(0) - 1)]).square()
        let melSpectrum = matmul(magnitudes, melFilters(melCount).T)
        var logSpectrum = log10(maximum(melSpectrum, Float(1e-10)))
        logSpectrum = maximum(logSpectrum, logSpectrum.max() - Float(8.0))
        return (logSpectrum + Float(4.0)) / Float(4.0)
    }

    /// Pads with zeros or trims along `axis` to `length`.
    static func padOrTrim(_ array: MLXArray, length: Int, axis: Int) -> MLXArray {
        let current = array.dim(axis)
        if current > length {
            return split(array, indices: [length], axis: axis)[0]
        }
        if current < length {
            var widths = Array(repeating: IntOrPair((0, 0)), count: array.ndim)
            widths[(axis + array.ndim) % array.ndim] = IntOrPair((0, length - current))
            return padded(array, widths: widths)
        }
        return array
    }

    /// Short-time Fourier transform with reflect padding and Whisper's hop.
    private static func stft(_ x: MLXArray, window: MLXArray) -> MLXArray {
        let padding = fftSize / 2
        let count = x.dim(0)
        let prefix = x[1 ..< (padding + 1)][.stride(by: -1)]
        let suffix = x[(count - padding - 1) ..< (count - 1)][.stride(by: -1)]
        let signal = concatenated([prefix, x, suffix])
        let frames = (signal.size - fftSize + hopLength) / hopLength
        let strided = asStrided(signal, [frames, fftSize], strides: [hopLength, 1])
        return rfft(strided * window)
    }

    /// `np.hanning(401)[:-1]`, computed the way NumPy does, in double precision.
    private static var hanning: MLXArray { MLXArray(hanningValues) }

    private static let hanningValues: [Float] = {
        let size = fftSize + 1
        return (0 ..< fftSize).map { index -> Float in
            let n = Double(1 - size + 2 * index)
            return Float(0.5 + 0.5 * cos(Double.pi * n / Double(size - 1)))
        }
    }()

    private static let filterLock = NSLock()
    nonisolated(unsafe) private static var filterCache: [Int: MLXArray] = [:]

    /// librosa's `filters.mel(sr=16000, n_fft=400, n_mels=…)`: Slaney mel scale and area
    /// normalization, `[melCount, 201]`. The Python transcriber ships these as a file.
    static func melFilters(_ melCount: Int) -> MLXArray {
        filterLock.lock()
        defer { filterLock.unlock() }
        if let cached = filterCache[melCount] { return cached }
        let filters = MLXArray(melFilterValues(melCount), [melCount, fftSize / 2 + 1])
        filterCache[melCount] = filters
        return filters
    }

    static func melFilterValues(_ melCount: Int) -> [Float] {
        let binCount = fftSize / 2 + 1
        // np.fft.rfftfreq(400, d=1/16000) and np.linspace, rounding step for step as NumPy does.
        let binWidth = 1.0 / (Double(fftSize) * (1.0 / Double(sampleRate)))
        let frequencies = (0 ..< binCount).map { Double($0) * binWidth }
        let lowest = hertzToMel(0)
        let highest = hertzToMel(Double(sampleRate) / 2)
        let step = (highest - lowest) / Double(melCount + 1)
        let melPoints = (0 ..< (melCount + 2)).map { index -> Double in
            index == melCount + 1 ? highest : Double(index) * step + lowest
        }.map(melToHertz)
        var weights = [Float](repeating: 0, count: melCount * binCount)
        for mel in 0 ..< melCount {
            let lowerWidth = melPoints[mel + 1] - melPoints[mel]
            let upperWidth = melPoints[mel + 2] - melPoints[mel + 1]
            // Slaney area normalization; NumPy multiplies the stored float32 weights by a double.
            let normalization = 2.0 / (melPoints[mel + 2] - melPoints[mel])
            for bin in 0 ..< binCount {
                let lower = -(melPoints[mel] - frequencies[bin]) / lowerWidth
                let upper = (melPoints[mel + 2] - frequencies[bin]) / upperWidth
                let weight = Float(max(0, min(lower, upper)))
                weights[mel * binCount + bin] = Float(Double(weight) * normalization)
            }
        }
        return weights
    }

    private static let melStep = 200.0 / 3
    private static let logRegionHertz = 1_000.0
    private static let logRegionMel = logRegionHertz / melStep
    private static let logStep = log(6.4) / 27.0

    private static func hertzToMel(_ hertz: Double) -> Double {
        hertz >= logRegionHertz ? logRegionMel + log(hertz / logRegionHertz) / logStep : hertz / melStep
    }

    private static func melToHertz(_ mel: Double) -> Double {
        mel >= logRegionMel ? logRegionHertz * exp(logStep * (mel - logRegionMel)) : melStep * mel
    }
}
