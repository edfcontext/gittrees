import Foundation

/// String helpers that match Python 3's `str.splitlines()` and `str.split()` so the
/// Swift `normalize_diff` port stays byte-for-byte with the training preprocessor.
enum PythonText {
    /// Python `str.splitlines()`: split on `\n` / `\r\n` / `\r`, and a trailing
    /// linebreak does not produce an extra empty line.
    static func splitlines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines: [String] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\r" {
                lines.append(String(text[start..<i]))
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "\n" {
                    i = text.index(after: next)
                } else {
                    i = next
                }
                start = i
                continue
            }
            if ch == "\n" {
                lines.append(String(text[start..<i]))
                i = text.index(after: i)
                start = i
                continue
            }
            i = text.index(after: i)
        }
        if start < text.endIndex {
            lines.append(String(text[start...]))
        }
        return lines
    }

    /// Python `str.split()` with no arguments: runs of Unicode whitespace, no empties.
    static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
