import Foundation

nonisolated enum LookupFunctions {
    static let all: [String: FormulaFunction] = [
        "VLOOKUP": { args, _ in tableLookup(args, vertical: true) },
        "HLOOKUP": { args, _ in tableLookup(args, vertical: false) },
        "INDEX": { args, _ in
            evaluating {
                guard (2...3).contains(args.count) else { return .error(.value) }
                let m = matrix(args[0])
                var row = try Args.int(args[1]).get()
                var col = args.count == 3 ? try Args.int(args[2]).get() : 1
                // INDEX(row_or_column, n) indexes along the only dimension.
                if args.count == 2 && m.rows == 1 { col = row; row = 1 }
                guard row >= 0, col >= 0, row <= m.rows, col <= m.cols else { return .error(.ref) }
                if row == 0 && col == 0 { return .matrix(m) }
                if row == 0 { return .matrix(Matrix(rows: m.rows, cols: 1, values: (0..<m.rows).map { m[$0, col - 1] })) }
                if col == 0 { return .matrix(Matrix(rows: 1, cols: m.cols, values: (0..<m.cols).map { m[row - 1, $0] })) }
                return .scalar(m[row - 1, col - 1])
            }
        },
        "MATCH": { args, _ in
            evaluating {
                guard (2...3).contains(args.count) else { return .error(.value) }
                let needle = args[0].scalar
                let m = matrix(args[1])
                guard m.rows == 1 || m.cols == 1 else { return .error(.na) }
                let type = args.count == 3 ? try Args.int(args[2]).get() : 1
                let hit: Int? =
                    switch type {
                    case 0: exactIndex(of: needle, in: m.values, reverse: false)
                    case 1: approximateIndex(of: needle, in: m.values, descending: false)
                    default: approximateIndex(of: needle, in: m.values, descending: true)
                    }
                guard let hit else { return .error(.na) }
                return .number(Double(hit + 1))
            }
        },
        "XLOOKUP": { args, _ in
            evaluating {
                guard (3...6).contains(args.count) else { return .error(.value) }
                let needle = args[0].scalar
                let keys = matrix(args[1]), results = matrix(args[2])
                guard keys.rows == 1 || keys.cols == 1 else { return .error(.value) }
                let vertical = keys.cols == 1
                let length = keys.values.count
                guard vertical ? results.rows == length : results.cols == length else { return .error(.value) }
                let mode = args.count > 4 && args[4].scalar != .empty ? try Args.int(args[4]).get() : 0
                let search = args.count > 5 ? try Args.int(args[5]).get() : 1
                let reverse = search == -1 || search == -2
                var hit: Int?
                switch mode {
                case 0: hit = exactIndex(of: needle, in: keys.values, reverse: reverse)
                case 2: hit = wildcardIndex(of: needle, in: keys.values, reverse: reverse)
                case -1, 1: hit = nearestIndex(of: needle, in: keys.values, larger: mode == 1, reverse: reverse)
                default: return .error(.value)
                }
                guard let i = hit else {
                    if args.count > 3, args[3].scalar != .empty || args[3].isReference { return args[3] }
                    return .error(.na)
                }
                if vertical {
                    if results.cols == 1 { return .scalar(results[i, 0]) }
                    return .matrix(Matrix(rows: 1, cols: results.cols, values: (0..<results.cols).map { results[i, $0] }))
                }
                if results.rows == 1 { return .scalar(results[0, i]) }
                return .matrix(Matrix(rows: results.rows, cols: 1, values: (0..<results.rows).map { results[$0, i] }))
            }
        },
    ]

    static func matrix(_ v: EvalValue) -> Matrix {
        switch v {
        case .matrix(let m): m
        case .scalar(let s): Matrix(rows: 1, cols: 1, values: [s])
        }
    }

    /// VLOOKUP/HLOOKUP: approximate match by default (sorted ascending keys), exact with FALSE.
    private static func tableLookup(_ args: [EvalValue], vertical: Bool) -> EvalValue {
        evaluating {
            guard (3...4).contains(args.count) else { return .error(.value) }
            let needle = args[0].scalar
            if case .error(let e) = needle { return .error(e) }
            let table = matrix(args[1])
            let index = try Args.int(args[2]).get()
            let approximate = args.count == 4 ? try Args.bool(args[3]).get() : true
            let span = vertical ? table.cols : table.rows
            guard index >= 1 else { return .error(.value) }
            guard index <= span else { return .error(.ref) }
            let keys = vertical ? (0..<table.rows).map { table[$0, 0] } : (0..<table.cols).map { table[0, $0] }
            let hit =
                approximate
                ? approximateIndex(of: needle, in: keys, descending: false)
                : (Criteria.hasWildcards((try? needle.asText().get()) ?? "") && !needle.isNumber
                    ? wildcardIndex(of: needle, in: keys, reverse: false)
                    : exactIndex(of: needle, in: keys, reverse: false))
            guard let hit else { return .error(.na) }
            return .scalar(vertical ? table[hit, index - 1] : table[index - 1, hit])
        }
    }

    static func exactIndex(of needle: CellValue, in values: [CellValue], reverse: Bool) -> Int? {
        let indices = reverse ? Array(values.indices.reversed()) : Array(values.indices)
        return indices.first { sameKind(values[$0], needle) && Operators.compare(values[$0], needle) == 0 }
    }

    static func wildcardIndex(of needle: CellValue, in values: [CellValue], reverse: Bool) -> Int? {
        guard case .text(let pattern) = needle else { return exactIndex(of: needle, in: values, reverse: reverse) }
        let indices = reverse ? Array(values.indices.reversed()) : Array(values.indices)
        return indices.first { i in
            if case .text(let s) = values[i] { return Criteria.wildcardMatch(s, pattern) }
            return false
        }
    }

    /// Largest value ≤ needle in ascending data (or smallest ≥ needle in descending data),
    /// scanning like Excel's binary search does on sorted input.
    static func approximateIndex(of needle: CellValue, in values: [CellValue], descending: Bool) -> Int? {
        var best: Int?
        for (i, v) in values.enumerated() where sameKind(v, needle) {
            let c = Operators.compare(v, needle)
            if descending ? c >= 0 : c <= 0 { best = i } else { break }
        }
        return best
    }

    /// XLOOKUP match modes −1/1: exact, else the next smaller/larger value (no sorting required).
    static func nearestIndex(of needle: CellValue, in values: [CellValue], larger: Bool, reverse: Bool) -> Int? {
        if let exact = exactIndex(of: needle, in: values, reverse: reverse) { return exact }
        var best: Int?
        let indices = reverse ? Array(values.indices.reversed()) : Array(values.indices)
        for i in indices where sameKind(values[i], needle) {
            let c = Operators.compare(values[i], needle)
            guard larger ? c > 0 : c < 0 else { continue }
            if let b = best {
                let better = Operators.compare(values[i], values[b])
                if larger ? better < 0 : better > 0 { best = i }
            } else {
                best = i
            }
        }
        return best
    }

    /// Lookups never match a number against text or vice versa.
    private static func sameKind(_ a: CellValue, _ b: CellValue) -> Bool {
        switch (a, b) {
        case (.number, .number), (.text, .text), (.bool, .bool): true
        default: false
        }
    }
}
