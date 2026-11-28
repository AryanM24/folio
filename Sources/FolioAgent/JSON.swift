public import FolioConvert
import Foundation

// JSON-RPC messages, tool schemas and results are all `JSONValue`, so the CLI's `--json`
// and the MCP `structuredContent` come out of the same encoder.

extension JSONValue: ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    /// Integers, and doubles with no fraction (some clients send `5.0`).
    var int: Int? {
        switch self {
        case .int(let i): Int(exactly: i)
        case .double(let d): d.rounded() == d ? Int(exactly: d) : nil
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    /// Any `Encodable` as a JSON tree (engine results, inspect info).
    init(encoding value: some Encodable) {
        // Our own types always encode; a failure here is a programming error worth surfacing loudly in JSON.
        do { self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) } catch {
            self = ["encoding_error": .string(error.localizedDescription)]
        }
    }

    init?(parsing text: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        self = value
    }

    /// One compact line with sorted keys: the exact bytes MCP sends and `--json` prints.
    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
