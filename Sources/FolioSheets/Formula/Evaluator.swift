import Foundation

/// A rectangular block of values, row-major. References evaluate to matrices (a single
/// cell is 1×1) so functions can tell "a cell holding text" from "a text literal",
/// which Excel treats differently in SUM, COUNT and friends.
nonisolated struct Matrix: Sendable, Equatable {
    var rows: Int
    var cols: Int
    var values: [CellValue]

    init(rows: Int, cols: Int, values: [CellValue]) {
        self.rows = rows
        self.cols = cols
        self.values = values
    }

    subscript(r: Int, c: Int) -> CellValue { values[r * cols + c] }

    var first: CellValue { values.first ?? .empty }
    var isScalar: Bool { rows == 1 && cols == 1 }
}

/// What an expression evaluates to.
nonisolated enum EvalValue: Sendable, Equatable {
    case scalar(CellValue)
    case matrix(Matrix)

    /// The single value used where a scalar is required (top-left of a range).
    var scalar: CellValue {
        switch self {
        case .scalar(let v): v
        case .matrix(let m): m.first
        }
    }

    /// Every value, flattened row-major.
    var flattened: [CellValue] {
        switch self {
        case .scalar(let v): [v]
        case .matrix(let m): m.values
        }
    }

    var isReference: Bool { if case .matrix = self { true } else { false } }

    static func error(_ e: FormulaError) -> EvalValue { .scalar(.error(e)) }
    static func number(_ n: Double) -> EvalValue { n.isFinite ? .scalar(.number(n)) : .error(.num) }
    static func text(_ s: String) -> EvalValue { .scalar(.text(s)) }
    static func bool(_ b: Bool) -> EvalValue { .scalar(.bool(b)) }
}

/// Where the evaluator reads cell values from. `FormulaEngine` supplies computed values
/// for formula cells and literal values for everything else.
nonisolated protocol CellSource: AnyObject {
    /// Value of a cell on the sheet at `sheetIndex`.
    func value(sheetIndex: Int, cell: CellRef) -> CellValue
    func sheetIndex(named: String) -> Int?
    /// Last used row of a sheet (−1 if empty); bounds whole-column references.
    func maxRow(sheetIndex: Int) -> Int
    /// Wall-clock time for TODAY/NOW, injectable for tests.
    var now: Date { get }
}

/// Evaluates an expression for a formula cell on `sheetIndex`.
///
/// Recursion here is bounded by formula *nesting*, never by the chain of cells a
/// formula depends on: `FormulaEngine` evaluates precedents first, so a reference is
/// always a cache lookup.
nonisolated struct Evaluator {
    let source: any CellSource
    let sheetIndex: Int

    func evaluate(_ expr: Expr) -> EvalValue {
        switch expr {
        case .number(let n): return .number(n)
        case .string(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .error(let e): return .error(e)
        case .missing: return .scalar(.empty)
        case .name: return .error(.name)
        case .reference(let r): return resolve(r)
        case .negate(let e):
            return map(evaluate(e)) { v in
                switch v.asNumber() {
                case .success(let n): .number(-n)
                case .failure(let err): .error(err)
                }
            }
        case .percent(let e):
            return map(evaluate(e)) { v in
                switch v.asNumber() {
                case .success(let n): .number(n / 100)
                case .failure(let err): .error(err)
                }
            }
        case .binary(let op, let a, let b):
            return Operators.apply(op, evaluate(a), evaluate(b))
        case .call(let name, let args):
            guard let fn = FunctionLibrary.functions[name] else { return .error(.name) }
            return fn(args.map(evaluate), self)
        }
    }

    /// Resolves a reference to a matrix of current values.
    func resolve(_ r: Reference) -> EvalValue {
        if r.isDeleted { return .error(.ref) }
        let target: Int
        if let name = r.sheet {
            guard let idx = source.sheetIndex(named: name) else { return .error(.ref) }
            target = idx
        } else {
            target = sheetIndex
        }
        let end = r.end ?? r.start
        let c0 = min(r.start.col, end.col), c1 = max(r.start.col, end.col)
        let r0: Int, r1: Int
        if let a = r.start.row, let b = end.row {
            r0 = min(a, b)
            r1 = max(a, b)
        } else {
            // Whole columns: only the rows that hold data.
            r0 = 0
            r1 = source.maxRow(sheetIndex: target)
            if r1 < 0 { return .matrix(Matrix(rows: 1, cols: 1, values: [.empty])) }
        }
        let rows = r1 - r0 + 1, cols = c1 - c0 + 1
        guard rows * cols <= 20_000_000 else { return .error(.num) }
        var values: [CellValue] = []
        values.reserveCapacity(rows * cols)
        for row in r0...r1 {
            for col in c0...c1 { values.append(source.value(sheetIndex: target, cell: CellRef(row: row, col: col))) }
        }
        return .matrix(Matrix(rows: rows, cols: cols, values: values))
    }

    /// Applies a unary function to a scalar or element-wise to a matrix.
    func map(_ v: EvalValue, _ f: (CellValue) -> EvalValue) -> EvalValue {
        switch v {
        case .scalar(let s): return f(s)
        case .matrix(let m):
            if m.isScalar { return f(m.first) }
            return .matrix(Matrix(rows: m.rows, cols: m.cols, values: m.values.map { f($0).scalar }))
        }
    }
}

/// Infix operators with Excel's coercion rules and element-wise array broadcasting.
nonisolated enum Operators {
    static func apply(_ op: String, _ a: EvalValue, _ b: EvalValue) -> EvalValue {
        let ma = asMatrix(a), mb = asMatrix(b)
        if ma.isScalar && mb.isScalar { return .scalar(scalar(op, ma.first, mb.first)) }
        // Broadcast a 1×1 (or a single row/column) across the other operand.
        let rows = max(ma.rows, mb.rows), cols = max(ma.cols, mb.cols)
        var out: [CellValue] = []
        out.reserveCapacity(rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = element(ma, r, c), y = element(mb, r, c)
                if let x, let y { out.append(scalar(op, x, y)) } else { out.append(.error(.na)) }
            }
        }
        return .matrix(Matrix(rows: rows, cols: cols, values: out))
    }

    private static func asMatrix(_ v: EvalValue) -> Matrix {
        switch v {
        case .scalar(let s): Matrix(rows: 1, cols: 1, values: [s])
        case .matrix(let m): m
        }
    }

    private static func element(_ m: Matrix, _ r: Int, _ c: Int) -> CellValue? {
        let rr = m.rows == 1 ? 0 : r, cc = m.cols == 1 ? 0 : c
        guard rr < m.rows, cc < m.cols else { return nil }
        return m[rr, cc]
    }

    static func scalar(_ op: String, _ a: CellValue, _ b: CellValue) -> CellValue {
        if case .error(let e) = a { return .error(e) }
        if case .error(let e) = b { return .error(e) }
        switch op {
        case "&":
            switch (a.asText(), b.asText()) {
            case (.success(let x), .success(let y)): return .text(x + y)
            case (.failure(let e), _), (_, .failure(let e)): return .error(e)
            }
        case "=", "<>", "<", ">", "<=", ">=":
            let c = compare(a, b)
            let result =
                switch op {
                case "=": c == 0
                case "<>": c != 0
                case "<": c < 0
                case ">": c > 0
                case "<=": c <= 0
                default: c >= 0
                }
            return .bool(result)
        default:
            let x: Double, y: Double
            switch a.asNumber() {
            case .success(let n): x = n;
            case .failure(let e): return .error(e)
            }
            switch b.asNumber() {
            case .success(let n): y = n;
            case .failure(let e): return .error(e)
            }
            let r: Double
            switch op {
            case "+": r = x + y
            case "-": r = x - y
            case "*": r = x * y
            case "/":
                guard y != 0 else { return .error(.div0) }
                r = x / y
            case "^":
                if x == 0 && y < 0 { return .error(.div0) }
                r = pow(x, y)
            default: return .error(.value)
            }
            return r.isFinite ? .number(r) : .error(.num)
        }
    }

    /// Excel ordering: numbers < text < booleans; text compares case-insensitively.
    /// An empty cell compares as 0 against numbers, "" against text, FALSE against booleans.
    static func compare(_ a: CellValue, _ b: CellValue) -> Int {
        func rank(_ v: CellValue) -> Int {
            switch v {
            case .number, .empty: 0
            case .text: 1
            case .bool: 2
            case .error: 3
            }
        }
        switch (a, b) {
        case (.empty, .empty): return 0
        case (.empty, .text(let s)): return s.isEmpty ? 0 : -1
        case (.text(let s), .empty): return s.isEmpty ? 0 : 1
        case (.empty, .bool(let x)): return x ? -1 : 0
        case (.bool(let x), .empty): return x ? 1 : 0
        default: break
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb ? -1 : 1 }
        switch (a, b) {
        case (.text(let x), .text(let y)):
            switch x.compare(y, options: [.caseInsensitive]) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        case (.bool(let x), .bool(let y)): return x == y ? 0 : (x ? 1 : -1)
        default:
            let x = (try? a.asNumber().get()) ?? 0, y = (try? b.asNumber().get()) ?? 0
            return x == y ? 0 : (x < y ? -1 : 1)
        }
    }
}
