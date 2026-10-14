import Foundation
import MLX
import MLXNN

/// The model's shape, from `config.json`.
struct WhisperDimensions: Decodable, Sendable, Equatable {
    let melCount: Int
    let audioContext: Int
    let audioState: Int
    let audioHeads: Int
    let audioLayers: Int
    let vocabularySize: Int
    let textContext: Int
    let textState: Int
    let textHeads: Int
    let textLayers: Int
    let quantization: Quantization?

    struct Quantization: Decodable, Sendable, Equatable {
        let groupSize: Int?
        let bits: Int?

        enum CodingKeys: String, CodingKey {
            case groupSize = "group_size"
            case bits
        }
    }

    enum CodingKeys: String, CodingKey {
        case melCount = "n_mels"
        case audioContext = "n_audio_ctx"
        case audioState = "n_audio_state"
        case audioHeads = "n_audio_head"
        case audioLayers = "n_audio_layer"
        case vocabularySize = "n_vocab"
        case textContext = "n_text_ctx"
        case textState = "n_text_state"
        case textHeads = "n_text_head"
        case textLayers = "n_text_layer"
        case quantization
    }

    var isMultilingual: Bool { vocabularySize >= 51_865 }
    var languageCount: Int { vocabularySize - 51_765 - (isMultilingual ? 1 : 0) }
}

/// Whisper's encoder and decoder as plain MLX arrays: a port of mlx_whisper's `whisper.py`
/// (MIT, Copyright © 2023 Apple Inc.). Same layer order, float16 like the Python transcriber,
/// attention softmax in full precision, logits cast to float32.
final class WhisperModel: @unchecked Sendable {
    let dimensions: WhisperDimensions
    let encoder: WhisperAudioEncoder
    let decoder: WhisperTextDecoder

    enum Failure: Error, CustomStringConvertible {
        case missingWeight(String)
        case quantized

        var description: String {
            switch self {
            case let .missingWeight(name): "The Whisper weights have no \(name)."
            case .quantized: "Quantized Whisper weights are not supported; use the float16 model."
            }
        }
    }

    init(dimensions: WhisperDimensions, weights: [String: MLXArray]) throws {
        guard dimensions.quantization == nil else { throw Failure.quantized }
        let source = WhisperWeights(weights: weights)
        self.dimensions = dimensions
        self.encoder = try WhisperAudioEncoder(dimensions: dimensions, weights: source.scoped("encoder"))
        self.decoder = try WhisperTextDecoder(dimensions: dimensions, weights: source.scoped("decoder"))
    }

    /// Every array the model holds, to evaluate them once after loading.
    var parameters: [MLXArray] { encoder.parameters + decoder.parameters }
}

/// Looks weights up by their mlx_whisper names, float16 like the model they came from.
struct WhisperWeights {
    let weights: [String: MLXArray]
    var prefix = ""

    func scoped(_ name: String) -> WhisperWeights {
        WhisperWeights(weights: weights, prefix: prefix.isEmpty ? name : "\(prefix).\(name)")
    }

    func array(_ name: String) throws -> MLXArray {
        let key = prefix.isEmpty ? name : "\(prefix).\(name)"
        guard let value = weights[key] else { throw WhisperModel.Failure.missingWeight(key) }
        return value.dtype == .float32 ? value.asType(.float16) : value
    }

    func optional(_ name: String) -> MLXArray? {
        try? array(name)
    }
}

struct WhisperLinear {
    let weight: MLXArray
    let bias: MLXArray?

    init(_ weights: WhisperWeights, bias hasBias: Bool = true) throws {
        weight = try weights.array("weight")
        bias = hasBias ? try weights.array("bias") : nil
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        if let bias { return addMM(bias, x, weight.T) }
        return matmul(x, weight.T)
    }

    var parameters: [MLXArray] { [weight] + (bias.map { [$0] } ?? []) }
}

struct WhisperLayerNorm {
    let weight: MLXArray
    let bias: MLXArray

    init(_ weights: WhisperWeights) throws {
        weight = try weights.array("weight")
        bias = try weights.array("bias")
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.layerNorm(x, weight: weight, bias: bias, eps: 1e-5)
    }

    var parameters: [MLXArray] { [weight, bias] }
}

/// Keys and values a layer keeps between decoding steps.
struct WhisperKeyValue {
    var keys: MLXArray
    var values: MLXArray
}

struct WhisperAttention {
    let query: WhisperLinear
    let key: WhisperLinear
    let value: WhisperLinear
    let out: WhisperLinear
    let heads: Int

    init(_ weights: WhisperWeights, heads: Int) throws {
        query = try WhisperLinear(weights.scoped("query"))
        key = try WhisperLinear(weights.scoped("key"), bias: false)
        value = try WhisperLinear(weights.scoped("value"))
        out = try WhisperLinear(weights.scoped("out"))
        self.heads = heads
    }

    /// Self-attention when `crossInput` is nil (keys grow with `cache`); cross-attention otherwise
    /// (keys computed once from the audio and reused).
    func callAsFunction(
        _ x: MLXArray,
        crossInput: MLXArray? = nil,
        mask: MLXArray? = nil,
        cache: WhisperKeyValue? = nil
    ) -> (MLXArray, WhisperKeyValue) {
        let q = query(x)
        var k: MLXArray
        var v: MLXArray
        if let crossInput {
            if let cache {
                k = cache.keys
                v = cache.values
            } else {
                k = key(crossInput)
                v = value(crossInput)
            }
        } else {
            k = key(x)
            v = value(x)
            if let cache {
                k = concatenated([cache.keys, k], axis: 1)
                v = concatenated([cache.values, v], axis: 1)
            }
        }
        return (out(attention(q, k, v, mask: mask)), WhisperKeyValue(keys: k, values: v))
    }

    private func attention(_ q: MLXArray, _ k: MLXArray, _ v: MLXArray, mask: MLXArray?) -> MLXArray {
        let batch = q.dim(0)
        let context = q.dim(1)
        let state = q.dim(2)
        let scale = Float(pow(Double(state / heads), -0.25))
        let queries = q.reshaped([batch, context, heads, -1]).transposed(0, 2, 1, 3) * scale
        let keys = k.reshaped([k.dim(0), k.dim(1), heads, -1]).transposed(0, 2, 3, 1) * scale
        let values = v.reshaped([v.dim(0), v.dim(1), heads, -1]).transposed(0, 2, 1, 3)
        var scores = matmul(queries, keys)
        if let mask {
            scores = scores + mask[0 ..< context, 0 ..< context]
        }
        let weights = softmax(scores, axis: -1, precise: true)
        return matmul(weights, values).transposed(0, 2, 1, 3).reshaped([batch, context, state])
    }

    var parameters: [MLXArray] { query.parameters + key.parameters + value.parameters + out.parameters }
}

struct WhisperBlockCache {
    var selfAttention: WhisperKeyValue?
    var crossAttention: WhisperKeyValue?
}

struct WhisperResidualBlock {
    let attention: WhisperAttention
    let attentionNorm: WhisperLayerNorm
    let crossAttention: WhisperAttention?
    let crossAttentionNorm: WhisperLayerNorm?
    let mlp1: WhisperLinear
    let mlp2: WhisperLinear
    let mlpNorm: WhisperLayerNorm

    init(_ weights: WhisperWeights, heads: Int, crossAttention hasCrossAttention: Bool) throws {
        attention = try WhisperAttention(weights.scoped("attn"), heads: heads)
        attentionNorm = try WhisperLayerNorm(weights.scoped("attn_ln"))
        crossAttention = hasCrossAttention ? try WhisperAttention(weights.scoped("cross_attn"), heads: heads) : nil
        crossAttentionNorm = hasCrossAttention ? try WhisperLayerNorm(weights.scoped("cross_attn_ln")) : nil
        mlp1 = try WhisperLinear(weights.scoped("mlp1"))
        mlp2 = try WhisperLinear(weights.scoped("mlp2"))
        mlpNorm = try WhisperLayerNorm(weights.scoped("mlp_ln"))
    }

    func callAsFunction(
        _ input: MLXArray,
        audio: MLXArray? = nil,
        mask: MLXArray? = nil,
        cache: WhisperBlockCache? = nil
    ) -> (MLXArray, WhisperBlockCache) {
        var x = input
        let (attended, selfCache) = attention(attentionNorm(x), mask: mask, cache: cache?.selfAttention)
        x = x + attended
        var crossCache: WhisperKeyValue?
        if let crossAttention, let crossAttentionNorm {
            let (crossed, newCrossCache) = crossAttention(
                crossAttentionNorm(x), crossInput: audio, cache: cache?.crossAttention
            )
            x = x + crossed
            crossCache = newCrossCache
        }
        x = x + mlp2(gelu(mlp1(mlpNorm(x))))
        return (x, WhisperBlockCache(selfAttention: selfCache, crossAttention: crossCache))
    }

    var parameters: [MLXArray] {
        attention.parameters + attentionNorm.parameters + (crossAttention?.parameters ?? [])
            + (crossAttentionNorm?.parameters ?? []) + mlp1.parameters + mlp2.parameters + mlpNorm.parameters
    }
}

struct WhisperAudioEncoder {
    let conv1Weight: MLXArray
    let conv1Bias: MLXArray
    let conv2Weight: MLXArray
    let conv2Bias: MLXArray
    let positionalEmbedding: MLXArray
    let blocks: [WhisperResidualBlock]
    let finalNorm: WhisperLayerNorm

    init(dimensions: WhisperDimensions, weights: WhisperWeights) throws {
        conv1Weight = try weights.scoped("conv1").array("weight")
        conv1Bias = try weights.scoped("conv1").array("bias")
        conv2Weight = try weights.scoped("conv2").array("weight")
        conv2Bias = try weights.scoped("conv2").array("bias")
        positionalEmbedding = Self.sinusoids(length: dimensions.audioContext, channels: dimensions.audioState)
            .asType(.float16)
        blocks = try (0 ..< dimensions.audioLayers).map { index in
            try WhisperResidualBlock(
                weights.scoped("blocks.\(index)"), heads: dimensions.audioHeads, crossAttention: false
            )
        }
        finalNorm = try WhisperLayerNorm(weights.scoped("ln_post"))
    }

    /// `mel` is `[batch, frames, melCount]` float16.
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var x = gelu(conv1d(mel, conv1Weight, stride: 1, padding: 1) + conv1Bias)
        x = gelu(conv1d(x, conv2Weight, stride: 2, padding: 1) + conv2Bias)
        x = x + positionalEmbedding
        for block in blocks {
            x = block(x).0
        }
        return finalNorm(x)
    }

    /// mlx_whisper's `sinusoids`, in float32 like the Python, before the float16 cast.
    static func sinusoids(length: Int, channels: Int, maxTimescale: Double = 10_000) -> MLXArray {
        let half = channels / 2
        let increment = log(maxTimescale) / Double(half - 1)
        let inverseTimescales = exp(MLXArray(Int32(0) ..< Int32(half)) * Float(-increment))
        let scaledTime = MLXArray(Int32(0) ..< Int32(length)).expandedDimensions(axis: 1)
            * inverseTimescales.expandedDimensions(axis: 0)
        return concatenated([sin(scaledTime), cos(scaledTime)], axis: 1)
    }

    var parameters: [MLXArray] {
        [conv1Weight, conv1Bias, conv2Weight, conv2Bias] + blocks.flatMap(\.parameters) + finalNorm.parameters
    }
}

struct WhisperTextDecoder {
    let tokenEmbedding: MLXArray
    let positionalEmbedding: MLXArray
    let blocks: [WhisperResidualBlock]
    let finalNorm: WhisperLayerNorm
    let causalMask: MLXArray

    init(dimensions: WhisperDimensions, weights: WhisperWeights) throws {
        tokenEmbedding = try weights.scoped("token_embedding").array("weight")
        positionalEmbedding = try weights.array("positional_embedding")
        blocks = try (0 ..< dimensions.textLayers).map { index in
            try WhisperResidualBlock(
                weights.scoped("blocks.\(index)"), heads: dimensions.textHeads, crossAttention: true
            )
        }
        finalNorm = try WhisperLayerNorm(weights.scoped("ln"))
        // nn.MultiHeadAttention.create_additive_causal_mask, then the model's float16.
        let indices = MLXArray(Int32(0) ..< Int32(dimensions.textContext))
        let upper = indices.expandedDimensions(axis: 1) .< indices.expandedDimensions(axis: 0)
        causalMask = (upper.asType(.float32) * -Float.greatestFiniteMagnitude).asType(.float16)
    }

    /// Logits as float32 for `tokens` (`[batch, count]` int32), continuing from `cache`.
    func callAsFunction(
        _ tokens: MLXArray,
        audio: MLXArray,
        cache: [WhisperBlockCache]?
    ) -> (MLXArray, [WhisperBlockCache]) {
        let offset = cache?.first?.selfAttention?.keys.dim(1) ?? 0
        var x = tokenEmbedding[tokens] + positionalEmbedding[offset ..< (offset + tokens.dim(-1))]
        var newCache: [WhisperBlockCache] = []
        newCache.reserveCapacity(blocks.count)
        for (index, block) in blocks.enumerated() {
            let (output, blockCache) = block(x, audio: audio, mask: causalMask, cache: cache?[index])
            x = output
            newCache.append(blockCache)
        }
        x = finalNorm(x)
        return (matmul(x, tokenEmbedding.T).asType(.float32), newCache)
    }

    var parameters: [MLXArray] {
        [tokenEmbedding, positionalEmbedding] + blocks.flatMap(\.parameters) + finalNorm.parameters
    }
}
