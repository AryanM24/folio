import Foundation

/// A SUMIF/COUNTIF criterion such as `">5"`, `"<>"`, `"app*"` or `42`.
nonisolated struct Criteria {
    private enum Operand {
        case number(Double)
        case text(String)
        case bool(Bool)
        case empty
    }

    private let op: String
    private let operand: Operand

    init(_ value: CellValue) {
        switch value {
        case .number(let n): op = "="; operand = .number(n)
        case .bool(let b): op = "="; operand = .bool(b)
        case .empty, .error: op = "="; operand = .empty
        case .text(let raw):
            var s = Substring(raw)
            var o = "="
            for candidate in ["<=", ">=", "<>", "<", ">", "="] where s.hasPrefix(candidate) {
                o = candidate
                s = s.dropFirst(candidate.count)
                break
            }
            op = o
            if s.isEmpty {
                operand = .empty
            } else if let n = CellValue.parseNumber(String(s)) {
                operand = .number(n)
            } else if s.uppercased() == "TRUE" || s.uppercased() == "FALSE" {
                operand = .bool(s.uppercased() == "TRUE")
            } else {
                operand = .text(String(s))
            }
        }
    }

    func matches(_ v: CellValue) -> Bool {
        switch operand {
        case .empty:
            let isBlank = v.isEmpty || v == .text("")
            return op == "<>" ? !isBlank : (op == "=" ? isBlank : false)
        case .number(let target):
            let n: Double
            switch v {
            case .number(let x): n = x
            case .text(let s):
                guard op == "=" || op == "<>", let x = CellValue.parseNumber(s) else { return op == "<>" }
                n = x
            default: return op == "<>"
            }
            return compare(n == target ? 0 : (n < target ? -1 : 1))
        case .bool(let target):
            guard case .bool(let b) = v else { return op == "<>" }
            return compare(b == target ? 0 : (b ? 1 : -1))
        case .text(let pattern):
            guard case .text(let s) = v else { return op == "<>" }
            if op == "=" || op == "<>" {
                let hit = Criteria.wildcardMatch(s, pattern)
                return op == "=" ? hit : !hit
            }
            return compare(Operators.compare(.text(s), .text(pattern)))
        }
    }

    private func compare(_ c: Int) -> Bool {
        switch op {
        case "=": c == 0
        case "<>": c != 0
        case "<": c < 0
        case ">": c > 0
        case "<=": c <= 0
        default: c >= 0
        }
    }

    /// Case-insensitive match with `*` (any run), `?` (one character) and `~` escaping.
    static func wildcardMatch(_ text: String, _ pattern: String) -> Bool {
        let t = Array(text.lowercased()), p = Array(pattern.lowercased())
        // Iterative matcher with backtracking to the last star: O(n·m) worst case, no recursion.
        var ti = 0, pi = 0, starP = -1, starT = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "~", pi + 1 < p.count, p[pi + 1] == t[ti] {
                pi += 2; ti += 1
            } else if pi < p.count, p[pi] != "*", p[pi] != "~", p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starP = pi; starT = ti; pi += 1
            } else if starP >= 0 {
                pi = starP + 1; starT += 1; ti = starT
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    static func hasWildcards(_ s: String) -> Bool { s.contains("*") || s.contains("?") }
}

nonisolated enum ConditionalFunctions {
    static let all: [String: FormulaFunction] = [
        "SUMIF": { args, _ in
            guard (2...3).contains(args.count), let range = matrix(args[0]) else { return .error(.value) }
            let sums = args.count == 3 ? matrix(args[2]) : range
            guard let sums else { return .error(.value) }
            let c = Criteria(args[1].scalar)
            var total = 0.0
            for (i, v) in range.values.enumerated() where c.matches(v) {
                if let n = value(in: sums, sameAs: range, index: i) { total += n }
            }
            return .number(total)
        },
        "AVERAGEIF": { args, _ in
            guard (2...3).contains(args.count), let range = matrix(args[0]) else { return .error(.value) }
            let values = args.count == 3 ? matrix(args[2]) : range
            guard let values else { return .error(.value) }
            let c = Criteria(args[1].scalar)
            var total = 0.0, count = 0
            for (i, v) in range.values.enumerated() where c.matches(v) {
                if let n = value(in: values, sameAs: range, index: i) { total += n; count += 1 }
            }
            return count == 0 ? .error(.div0) : .number(total / Double(count))
        },
        "COUNTIF": { args, _ in
            guard args.count == 2, let range = matrix(args[0]) else { return .error(.value) }
            let c = Criteria(args[1].scalar)
            return .number(Double(range.values.filter(c.matches).count))
        },
        "SUMIFS": { args, _ in
            guard args.count >= 3, args.count % 2 == 1, let sums = matrix(args[0]) else { return .error(.value) }
            guard let mask = mask(Array(args.dropFirst()), size: sums) else { return .error(.value) }
            var total = 0.0
            for (i, ok) in mask.enumerated() where ok {
                if case .number(let n) = sums.values[i] { total += n }
            }
            return .number(total)
        },
        "COUNTIFS": { args, _ in
            guard args.count >= 2, args.count % 2 == 0, let first = matrix(args[0]) else { return .error(.value) }
            guard let mask = mask(args, size: first) else { return .error(.value) }
            return .number(Double(mask.filter { $0 }.count))
        },
    ]

    private static func matrix(_ v: EvalValue) -> Matrix? {
        if case .matrix(let m) = v { return m }
        return nil
    }

    /// The number at the same position in a parallel range; Excel sizes the sum range
    /// from its top-left cell to match the criteria range.
    private static func value(in m: Matrix, sameAs shape: Matrix, index: Int) -> Double? {
        let r = index / shape.cols, c = index % shape.cols
        guard r < m.rows, c < m.cols, case .number(let n) = m[r, c] else { return nil }
        return n
    }

    /// AND of every (range, criterion) pair. All ranges must match `size`.
    private static func mask(_ pairs: [EvalValue], size: Matrix) -> [Bool]? {
        var mask = [Bool](repeating: true, count: size.values.count)
        for i in stride(from: 0, to: pairs.count, by: 2) {
            guard let range = matrix(pairs[i]), range.rows == size.rows, range.cols == size.cols else { return nil }
            let c = Criteria(pairs[i + 1].scalar)
            for (j, v) in range.values.enumerated() where mask[j] && !c.matches(v) { mask[j] = false }
        }
        return mask
    }
}
