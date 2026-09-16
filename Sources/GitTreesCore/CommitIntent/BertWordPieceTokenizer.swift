import Foundation

/// BERT WordPiece encoder that reads Hugging Face `tokenizer.json`.
///
/// MiniLM was trained with this exact tokenizer. Loading `tokenizer.json` here
/// (rather than re-deriving a vocab) keeps train/serve token ids aligned.
public struct BertWordPieceTokenizer: Sendable {
    public var maxTokens: Int
    public var clsId: Int
    public var sepId: Int
    public var padId: Int
    public var unkId: Int

    private var vocab: [String: Int]
    private var continuingPrefix: String
    private var maxCharsPerWord: Int
    private var lowercase: Bool
    private var handleChinese: Bool
    private var stripAccents: Bool

    public init(tokenizerJSON: URL, maxTokens: Int) throws {
        let data = try Data(contentsOf: tokenizerJSON)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let model = root["model"] as? [String: Any] ?? [:]
        let vocab = model["vocab"] as? [String: Int] ?? [:]
        let normalizer = root["normalizer"] as? [String: Any] ?? [:]
        let lowercase = (normalizer["lowercase"] as? Bool) ?? true
        let handleChinese = (normalizer["handle_chinese_chars"] as? Bool) ?? true
        // Hugging Face: `strip_accents: null` means "strip when lowercasing".
        let stripAccents = (normalizer["strip_accents"] as? Bool) ?? lowercase

        self.vocab = vocab
        self.maxTokens = maxTokens
        self.continuingPrefix = (model["continuing_subword_prefix"] as? String) ?? "##"
        self.maxCharsPerWord = (model["max_input_chars_per_word"] as? Int) ?? 100
        self.lowercase = lowercase
        self.handleChinese = handleChinese
        self.stripAccents = stripAccents
        self.clsId = vocab["[CLS]"] ?? 101
        self.sepId = vocab["[SEP]"] ?? 102
        self.padId = vocab["[PAD]"] ?? 0
        self.unkId = vocab["[UNK]"] ?? 100
    }

    /// Token ids with `[CLS]` / `[SEP]`, truncated to `maxTokens`, padded to that length.
    /// Returns `(inputIds, attentionMask)` both of length `maxTokens`.
    public func encode(_ text: String) -> (ids: [Int], mask: [Int]) {
        var pieces = wordPieces(in: normalize(text))
        let budget = max(maxTokens - 2, 0)
        if pieces.count > budget {
            pieces = Array(pieces.prefix(budget))
        }
        var ids = [clsId] + pieces + [sepId]
        var mask = Array(repeating: 1, count: ids.count)
        if ids.count < maxTokens {
            let pad = maxTokens - ids.count
            ids.append(contentsOf: Array(repeating: padId, count: pad))
            mask.append(contentsOf: Array(repeating: 0, count: pad))
        }
        return (ids, mask)
    }

    // MARK: - Normalize + pretokenize (BertNormalizer + BertPreTokenizer)

    private func normalize(_ text: String) -> String {
        var scalars: [UnicodeScalar] = []
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD { continue }
            if isControl(scalar) { continue }
            if handleChinese && isChinese(scalar) {
                scalars.append(" ")
                scalars.append(scalar)
                scalars.append(" ")
                continue
            }
            if isWhitespace(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        var string = String(String.UnicodeScalarView(scalars))
        if lowercase {
            string = string.lowercased()
        }
        if stripAccents {
            string = strip(accents: string)
        }
        return string
    }

    private func wordPieces(in text: String) -> [Int] {
        var ids: [Int] = []
        for token in pretokenize(text) {
            ids.append(contentsOf: wordpiece(token))
        }
        return ids
    }

    /// Split on whitespace, then isolate punctuation as its own tokens.
    private func pretokenize(_ text: String) -> [String] {
        var words: [String] = []
        for whitespaceToken in text.split(whereSeparator: { isWhitespace($0) }).map(String.init) {
            var current = ""
            for scalar in whitespaceToken.unicodeScalars {
                if isPunctuation(scalar) {
                    if !current.isEmpty {
                        words.append(current)
                        current = ""
                    }
                    words.append(String(scalar))
                } else {
                    current.append(Character(scalar))
                }
            }
            if !current.isEmpty {
                words.append(current)
            }
        }
        return words
    }

    private func wordpiece(_ token: String) -> [Int] {
        if token.count > maxCharsPerWord {
            return [unkId]
        }
        var sub: [Int] = []
        let chars = Array(token)
        var start = 0
        while start < chars.count {
            var end = chars.count
            var cur: Int?
            while start < end {
                var piece = String(chars[start..<end])
                if start > 0 {
                    piece = continuingPrefix + piece
                }
                if let id = vocab[piece] {
                    cur = id
                    break
                }
                end -= 1
            }
            guard let id = cur else { return [unkId] }
            sub.append(id)
            start = end
        }
        return sub
    }

    private func strip(accents string: String) -> String {
        let decomposed = string.decomposedStringWithCanonicalMapping
        return String(decomposed.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark })
    }

    private func isWhitespace(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { isWhitespace($0) }
    }

    private func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
        if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { return true }
        return scalar.properties.generalCategory == .spaceSeparator
    }

    private func isControl(_ scalar: UnicodeScalar) -> Bool {
        if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    private func isPunctuation(_ scalar: UnicodeScalar) -> Bool {
        let cp = Int(scalar.value)
        if (33...47).contains(cp) || (58...64).contains(cp) || (91...96).contains(cp) || (123...126).contains(cp) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private func isChinese(_ scalar: UnicodeScalar) -> Bool {
        let cp = scalar.value
        return (cp >= 0x4E00 && cp <= 0x9FFF)
            || (cp >= 0x3400 && cp <= 0x4DBF)
            || (cp >= 0x20000 && cp <= 0x2A6DF)
            || (cp >= 0x2A700 && cp <= 0x2B73F)
            || (cp >= 0x2B740 && cp <= 0x2B81F)
            || (cp >= 0x2B820 && cp <= 0x2CEAF)
            || (cp >= 0xF900 && cp <= 0xFAFF)
            || (cp >= 0x2F800 && cp <= 0x2FA1F)
    }
}
