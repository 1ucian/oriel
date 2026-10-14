import Foundation

/// Whisper's multilingual tokenizer: byte-level BPE over the 50,257 ranks in the model's
/// `vocab.json` (byte for byte the ranks of mlx_whisper's `multilingual.tiktoken`), then
/// Whisper's special tokens in tiktoken's order. Encoding follows tiktoken's pre-split pattern
/// and merge loop, so prompts tokenize exactly as they do in the Python transcriber.
struct WhisperTokenizer: Sendable {
    /// mlx_whisper's LANGUAGES, in token order.
    static let languageCodes = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it",
        "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur",
        "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn",
        "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si",
        "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha",
        "ba", "jw", "su", "yue",
    ]

    static let languageNames: [String] = [
        "english", "chinese", "german", "spanish", "russian", "korean", "french", "japanese", "portuguese",
        "turkish", "polish", "catalan", "dutch", "arabic", "swedish", "italian", "indonesian", "hindi",
        "finnish", "vietnamese", "hebrew", "ukrainian", "greek", "malay", "czech", "romanian", "danish",
        "hungarian", "tamil", "norwegian", "thai", "urdu", "croatian", "bulgarian", "lithuanian", "latin",
        "maori", "malayalam", "welsh", "slovak", "telugu", "persian", "latvian", "bengali", "serbian",
        "azerbaijani", "slovenian", "kannada", "estonian", "macedonian", "breton", "basque", "icelandic",
        "armenian", "nepali", "mongolian", "bosnian", "kazakh", "albanian", "swahili", "galician", "marathi",
        "punjabi", "sinhala", "khmer", "shona", "yoruba", "somali", "afrikaans", "occitan", "georgian",
        "belarusian", "tajik", "sindhi", "gujarati", "amharic", "yiddish", "lao", "uzbek", "faroese",
        "haitian creole", "pashto", "turkmen", "nynorsk", "maltese", "sanskrit", "luxembourgish", "myanmar",
        "tibetan", "tagalog", "malagasy", "assamese", "tatar", "hawaiian", "lingala", "hausa", "bashkir",
        "javanese", "sundanese", "cantonese",
    ]

    /// A language code from a code or an English name, as mlx_whisper's get_tokenizer accepts them.
    static func languageCode(for language: String) -> String? {
        let lowered = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if languageCodes.contains(lowered) { return lowered }
        if let index = languageNames.firstIndex(of: lowered) { return languageCodes[index] }
        let aliases = [
            "burmese": "my", "valencian": "ca", "flemish": "nl", "haitian": "ht", "letzeburgesch": "lb",
            "pushto": "ps", "panjabi": "pa", "moldavian": "ro", "moldovan": "ro", "sinhalese": "si",
            "castilian": "es", "mandarin": "zh",
        ]
        return aliases[lowered]
    }

    let languageCount: Int
    let endOfText = 50_257
    let startOfTranscript = 50_258
    var translate: Int { startOfTranscript + languageCount + 1 }
    var transcribe: Int { translate + 1 }
    var startOfLM: Int { transcribe + 1 }
    var startOfPrevious: Int { startOfLM + 1 }
    var noSpeech: Int { startOfPrevious + 1 }
    var noTimestamps: Int { noSpeech + 1 }
    var timestampBegin: Int { noTimestamps + 1 }

    private let ranks: [[UInt8]: Int]
    private let tokenBytes: [[UInt8]]
    private let specialNames: [String]

    enum Failure: Error, CustomStringConvertible {
        case vocabulary

        var description: String { "The Whisper tokenizer's vocabulary could not be read." }
    }

    /// Reads `vocab.json`; `languageCount` is 100 for large-v3, 99 for earlier multilingual models.
    init(vocabularyURL: URL, languageCount: Int) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabularyURL)) as? [String: Int] else {
            throw Failure.vocabulary
        }
        let decoder = Self.byteDecoder
        var ranks: [[UInt8]: Int] = [:]
        ranks.reserveCapacity(object.count)
        var tokenBytes = [[UInt8]](repeating: [], count: object.count)
        var assigned = [Bool](repeating: false, count: object.count)
        for (token, rank) in object {
            guard rank >= 0, rank < object.count, !assigned[rank] else { throw Failure.vocabulary }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(token.unicodeScalars.count)
            for scalar in token.unicodeScalars {
                guard let byte = decoder[scalar] else { throw Failure.vocabulary }
                bytes.append(byte)
            }
            // Rank 50,256 is empty in Whisper's multilingual ranks too; encoding never yields it.
            ranks[bytes] = rank
            tokenBytes[rank] = bytes
            assigned[rank] = true
        }
        guard object.count == 50_257 else { throw Failure.vocabulary }
        self.ranks = ranks
        self.tokenBytes = tokenBytes
        self.languageCount = languageCount
        var names = ["<|endoftext|>", "<|startoftranscript|>"]
        names += Self.languageCodes.prefix(languageCount).map { "<|\($0)|>" }
        names += ["<|translate|>", "<|transcribe|>", "<|startoflm|>", "<|startofprev|>", "<|nospeech|>", "<|notimestamps|>"]
        self.specialNames = names
    }

    func languageToken(_ code: String) -> Int? {
        guard let index = Self.languageCodes.prefix(languageCount).firstIndex(of: code) else { return nil }
        return startOfTranscript + 1 + index
    }

    var allLanguageTokens: [Int] { (0 ..< languageCount).map { startOfTranscript + 1 + $0 } }

    /// Text to tokens, special-token text included as plain text.
    func encode(_ text: String) -> [Int] {
        var tokens: [Int] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in Self.pattern.matches(in: text, range: range) {
            guard let pieceRange = Range(match.range, in: text) else { continue }
            let piece = Array(text[pieceRange].utf8)
            if let rank = ranks[piece] {
                tokens.append(rank)
            } else {
                tokens += bytePairEncode(piece)
            }
        }
        return tokens
    }

    /// Tokens to text without timestamp tokens (mlx_whisper `Tokenizer.decode`); other special
    /// tokens read as their names.
    func decode(_ tokens: [Int]) -> String {
        var bytes: [UInt8] = []
        for token in tokens where token >= 0 && token < timestampBegin {
            if token < tokenBytes.count {
                bytes += tokenBytes[token]
            } else if token - endOfText < specialNames.count {
                bytes += Array(specialNames[token - endOfText].utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Speaker tags, music notes and other non-speech symbols the decoder may not produce, with
    /// hyphens and apostrophes still allowed inside words (mlx_whisper `non_speech_tokens`).
    var nonSpeechTokens: [Int] {
        var symbols = "\"#()*+/:;<=>@[\\]^_`{|}~「」『』".map(String.init)
        symbols += "<< >> <<< >>> -- --- -( -[ (' (\" (( )) ((( ))) [[ ]] {{ }} ♪♪ ♪♪♪".split(separator: " ").map(String.init)
        let miscellaneous = "♩♪♫♬♭♮♯".map(String.init)
        var result: Set<Int> = []
        if let hyphen = encode(" -").first { result.insert(hyphen) }
        if let apostrophe = encode(" '").first { result.insert(apostrophe) }
        for symbol in symbols + miscellaneous {
            for tokens in [encode(symbol), encode(" " + symbol)] {
                if let first = tokens.first, tokens.count == 1 || miscellaneous.contains(symbol) {
                    result.insert(first)
                }
            }
        }
        return result.sorted()
    }

    /// tiktoken's merge loop: repeatedly join the adjacent pair with the lowest rank, leftmost first.
    private func bytePairEncode(_ piece: [UInt8]) -> [Int] {
        if piece.count == 1 { return [ranks[piece] ?? 0] }
        var parts: [(start: Int, rank: Int)] = []
        parts.reserveCapacity(piece.count + 1)
        var minimum = (rank: Int.max, index: Int.max)
        for index in 0 ..< (piece.count - 1) {
            let rank = ranks[Array(piece[index ..< (index + 2)])] ?? Int.max
            if rank < minimum.rank { minimum = (rank, index) }
            parts.append((index, rank))
        }
        parts.append((piece.count - 1, Int.max))
        parts.append((piece.count, Int.max))

        func rank(at index: Int) -> Int {
            guard index + 3 < parts.count else { return Int.max }
            return ranks[Array(piece[parts[index].start ..< parts[index + 3].start])] ?? Int.max
        }

        while minimum.rank != Int.max {
            let index = minimum.index
            if index > 0 { parts[index - 1].rank = rank(at: index - 1) }
            parts[index].rank = rank(at: index)
            parts.remove(at: index + 1)
            minimum = (Int.max, Int.max)
            for (position, part) in parts.dropLast().enumerated() where part.rank < minimum.rank {
                minimum = (part.rank, position)
            }
        }
        return (0 ..< (parts.count - 1)).map { index in
            ranks[Array(piece[parts[index].start ..< parts[index + 1].start])] ?? 0
        }
    }

    /// tiktoken's pre-split pattern for Whisper. `\s` is spelled out as Unicode White_Space,
    /// which is what tiktoken's regex engine means by it (ICU's `\s` leaves out U+000B and U+0085).
    private static let pattern: NSRegularExpression = {
        let space = #"\t\n\x{0B}\f\r\x{20}\x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}"#
        let source = #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^"# + space + #"\p{L}\p{N}]+|["# + space
            + #"]+(?![^"# + space + #"])|["# + space + "]+"
        return try! NSRegularExpression(pattern: source)
    }()

    /// GPT-2's byte-to-character table, inverted: each character of `vocab.json` back to its byte.
    private static let byteDecoder: [Unicode.Scalar: UInt8] = {
        var bytes = Array(UInt8(ascii: "!") ... UInt8(ascii: "~")) + Array(0xA1 ... 0xAC) + Array(0xAE ... 0xFF)
        var scalars = bytes.map { UInt32($0) }
        var next: UInt32 = 0
        for byte in 0 ... 255 where !bytes.contains(UInt8(byte)) {
            bytes.append(UInt8(byte))
            scalars.append(256 + next)
            next += 1
        }
        var table: [Unicode.Scalar: UInt8] = [:]
        for (byte, scalar) in zip(bytes, scalars) {
            table[Unicode.Scalar(scalar)!] = byte
        }
        return table
    }()
}
