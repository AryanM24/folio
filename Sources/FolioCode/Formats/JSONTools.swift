import Foundation

/// Validate, pretty-print and minify JSON without changing its meaning.
///
/// `JSONSerialization` would reorder keys and rewrite numbers (`1.0` → `1`), which is
/// not what anyone wants from "Format". This is a small strict parser (RFC 8259) that copies
/// strings and numbers through byte for byte and only changes whitespace.
nonisolated enum JSONTools {
    /// Where and why the JSON is invalid. Lines and columns start at 1.
    struct Issue: Error, Equatable, Sendable, CustomStringConvertible {
        let line: Int
        let column: Int
        let message: String
        /// UTF-8 byte offset, for jumping to the spot.
        let offset: Int
        var description: String { "Line \(line), column \(column): \(message)" }
    }

    static func validate(_ text: String) -> Issue? {
        do { _ = try run(text, style: .validate); return nil } catch { return error }
    }

    static func format(_ text: String, indent: String = "  ") throws(Issue) -> String {
        try run(text, style: .pretty(indent))
    }

    static func minify(_ text: String) throws(Issue) -> String {
        try run(text, style: .minified)
    }

    private enum Style { case validate, minified, pretty(String) }

    private static func run(_ text: String, style: Style) throws(Issue) -> String {
        var parser = Parser(bytes: Array(text.utf8), style: style)
        try parser.document()
        if case .pretty = style, !parser.out.isEmpty { parser.out.append(10) }
        return String(decoding: parser.out, as: UTF8.self)
    }

    private struct Parser {
        let bytes: [UInt8]
        let style: Style
        var i = 0
        var depth = 0
        var out: [UInt8] = []
        private let writes: Bool
        private let indent: [UInt8]?

        init(bytes: [UInt8], style: Style) {
            self.bytes = bytes
            self.style = style
            switch style {
            case .validate: writes = false; indent = nil
            case .minified: writes = true; indent = nil
            case .pretty(let unit): writes = true; indent = Array(unit.utf8)
            }
            if writes { out.reserveCapacity(bytes.count) }
        }

        mutating func document() throws(Issue) {
            skipWhitespace()
            guard i < bytes.count else { throw issue("The document is empty") }
            try value()
            skipWhitespace()
            if i < bytes.count { throw issue("Unexpected text after the end of the JSON") }
        }

        private mutating func value() throws(Issue) {
            guard i < bytes.count else { throw issue("Expected a value, but the text ended") }
            switch bytes[i] {
            case UInt8(ascii: "{"): try container(close: UInt8(ascii: "}"), isObject: true)
            case UInt8(ascii: "["): try container(close: UInt8(ascii: "]"), isObject: false)
            case UInt8(ascii: "\""): try string()
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number()
            case UInt8(ascii: "t"): try word("true")
            case UInt8(ascii: "f"): try word("false")
            case UInt8(ascii: "n"): try word("null")
            default: throw issue("Unexpected character \(describe(bytes[i])); expected a value")
            }
        }

        private mutating func container(close: UInt8, isObject: Bool) throws(Issue) {
            depth += 1
            guard depth <= 512 else { throw issue("The JSON is nested too deeply") }
            emit(bytes[i])
            i += 1
            skipWhitespace()
            if i < bytes.count, bytes[i] == close {
                emit(close)
                i += 1
                depth -= 1
                return
            }
            while true {
                newline(depth)
                skipWhitespace()
                if isObject {
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                        throw issue(
                            i < bytes.count && bytes[i] == close
                                ? "Trailing comma before \(describe(close))" : "Expected a property name in double quotes")
                    }
                    try string()
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw issue("Expected ‘:’ after the property name") }
                    emit(UInt8(ascii: ":"))
                    if indent != nil { emit(32) }
                    i += 1
                    skipWhitespace()
                } else if i < bytes.count, bytes[i] == close {
                    throw issue("Trailing comma before ‘]’")
                }
                try value()
                skipWhitespace()
                guard i < bytes.count else { throw issue("This \(isObject ? "object" : "array") is never closed") }
                if bytes[i] == UInt8(ascii: ",") {
                    emit(UInt8(ascii: ","))
                    i += 1
                    continue
                }
                guard bytes[i] == close else { throw issue("Expected ‘,’ or \(describe(close))") }
                depth -= 1
                newline(depth)
                emit(close)
                i += 1
                return
            }
        }

        private mutating func string() throws(Issue) {
            let start = i
            i += 1
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    if writes { out.append(contentsOf: bytes[start..<i]) }
                    return
                }
                if b == UInt8(ascii: "\\") {
                    guard i + 1 < bytes.count else { break }
                    let e = bytes[i + 1]
                    if e == UInt8(ascii: "u") {
                        guard i + 5 < bytes.count, bytes[i + 2...i + 5].allSatisfy(\.isHexDigit) else {
                            i += 1
                            throw issue("‘\\u’ must be followed by four hex digits")
                        }
                        i += 6
                        continue
                    }
                    guard "\"\\/bfnrt".utf8.contains(e) else { i += 1; throw issue("Unknown escape ‘\\\(Character(Unicode.Scalar(e)))’") }
                    i += 2
                    continue
                }
                if b < 0x20 { throw issue(b == 10 ? "This string is never closed" : "Control characters must be escaped in strings") }
                i += 1
            }
            i = start
            throw issue("This string is never closed")
        }

        private mutating func number() throws(Issue) {
            let start = i
            if bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, bytes[i].isDigit else { throw issue("Expected a digit") }
            if bytes[i] == UInt8(ascii: "0") {
                i += 1
                if i < bytes.count, bytes[i].isDigit { throw issue("Numbers can’t have leading zeros") }
            } else {
                while i < bytes.count, bytes[i].isDigit { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard i < bytes.count, bytes[i].isDigit else { throw issue("Expected a digit after the decimal point") }
                while i < bytes.count, bytes[i].isDigit { i += 1 }
            }
            if i < bytes.count, bytes[i] | 0x20 == UInt8(ascii: "e") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard i < bytes.count, bytes[i].isDigit else { throw issue("Expected a digit in the exponent") }
                while i < bytes.count, bytes[i].isDigit { i += 1 }
            }
            if writes { out.append(contentsOf: bytes[start..<i]) }
        }

        private mutating func word(_ literal: StaticString) throws(Issue) {
            let expected = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
            guard i + expected.count <= bytes.count, bytes[i..<i + expected.count].elementsEqual(expected) else {
                throw issue("Unexpected word; expected ‘\(literal)’")
            }
            if writes { out.append(contentsOf: expected) }
            i += expected.count
        }

        private mutating func skipWhitespace() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 10 || bytes[i] == 13 || bytes[i] == 9 { i += 1 }
        }

        private mutating func emit(_ byte: UInt8) { if writes { out.append(byte) } }

        private mutating func newline(_ level: Int) {
            guard let indent else { return }
            out.append(10)
            for _ in 0..<level { out.append(contentsOf: indent) }
        }

        private func describe(_ byte: UInt8) -> String {
            byte < 0x80 && byte >= 0x20 ? "‘\(Character(Unicode.Scalar(byte)))’" : "byte 0x\(String(byte, radix: 16, uppercase: true))"
        }

        /// Builds an error at the current position, counting characters (not bytes) for the column.
        private func issue(_ message: String) -> Issue {
            let position = min(i, bytes.count)
            var line = 1, column = 1
            for b in bytes[0..<position] {
                if b == 10 { line += 1; column = 1 } else if b & 0xC0 != 0x80 { column += 1 }
            }
            return Issue(line: line, column: column, message: message, offset: position)
        }
    }
}

private nonisolated extension UInt8 {
    var isDigit: Bool { self >= 48 && self <= 57 }
    var isHexDigit: Bool { isDigit || (self | 0x20 >= 97 && self | 0x20 <= 102) }
}
