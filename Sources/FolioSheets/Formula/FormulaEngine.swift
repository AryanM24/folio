import Foundation

/// A cell in a workbook, identified by its sheet's stable id.
public nonisolated struct CellKey: Hashable, Sendable {
    public var sheetID: Int
    public var cell: CellRef
    public init(sheetID: Int, cell: CellRef) {
        self.sheetID = sheetID
        self.cell = cell
    }
}

/// Parses formulas, tracks which cells depend on which, and keeps computed values.
///
/// **Why it's iterative.** A naive evaluator recurses into each referenced cell, so a
/// 10,000-cell chain (`A2=A1+1`, `A3=A2+1`, …) overflows the stack. Here evaluation
/// order is a topological sort done with an explicit stack: precedents are always
/// computed before the formulas that read them, and reading a reference is just a
/// dictionary lookup. Cycles are found during the same walk and become `#CIRC!`.
///
/// **Why it's incremental.** After an edit only the changed cells and everything that
/// (transitively) depends on them are recomputed, so typing in a 100k-row sheet
/// doesn't recompute every formula.
///
/// The engine never stores the workbook between calls. Holding a copy would make the
/// document's next edit copy every cell (copy-on-write), so each call takes the
/// workbook as an argument and drops it before returning.
///
/// `@unchecked Sendable`: an engine is mutable and not thread-safe. Each one is owned
/// by exactly one document (used on the main actor after `init`) or one tool run, and
/// is never shared between threads; the conformance only lets the document hold it.
public nonisolated final class FormulaEngine: CellSource, @unchecked Sendable {
    private struct Formula {
        var expr: Expr
        var precedents: [Precedent]
        var volatile: Bool
    }

    private enum Precedent: Hashable {
        case cell(CellKey)
        /// Inclusive bounds; `r1 == Int.max` for whole columns.
        case range(sheetID: Int, r0: Int, r1: Int, c0: Int, c1: Int)
    }

    private struct RangeDependent {
        var r0, r1, c0, c1: Int
        var dependent: CellKey
        func contains(_ c: CellRef) -> Bool { c.row >= r0 && c.row <= r1 && c.col >= c0 && c.col <= c1 }
    }

    /// Computed values of formula cells. Non-formula cells aren't stored here.
    public private(set) var values: [CellKey: CellValue] = [:]
    private var formulas: [CellKey: Formula] = [:]
    private var formulaCells: [Int: Set<CellRef>] = [:]
    private var cellDependents: [CellKey: Set<CellKey>] = [:]
    private var rangeDependents: [Int: [RangeDependent]] = [:]
    private var volatile: Set<CellKey> = []

    /// Only set for the duration of a public call; see the type comment.
    private var workbook: Workbook?
    private let clock: @Sendable () -> Date

    public convenience init() { self.init(clock: { Date() }) }

    /// - Parameter clock: the time TODAY/NOW see; tests pass a fixed date.
    init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    public var formulaCount: Int { formulas.count }

    /// The computed value of a formula cell, `nil` for non-formula cells.
    public func value(sheetID: Int, cell: CellRef) -> CellValue? { values[CellKey(sheetID: sheetID, cell: cell)] }

    /// Forget everything and recompute every formula. Use after structural edits
    /// (rows/columns inserted or deleted, sheets added/renamed/removed, file load).
    public func recalculateAll(_ workbook: Workbook) {
        self.workbook = workbook
        defer { self.workbook = nil }
        values = [:]
        formulas = [:]
        formulaCells = [:]
        cellDependents = [:]
        rangeDependents = [:]
        volatile = []
        for sheet in workbook.sheets {
            for (cell, input) in sheet.cells where input.utf8.first == UInt8(ascii: "=") {
                register(CellKey(sheetID: sheet.id, cell: cell), input: input, in: workbook)
            }
        }
        evaluate(Set(formulas.keys))
    }

    /// Recompute after the inputs of `changed` cells were edited (the workbook already
    /// holds the new inputs).
    public func cellsChanged(_ changed: [CellKey], in workbook: Workbook) {
        self.workbook = workbook
        defer { self.workbook = nil }
        for key in changed {
            unregister(key)
            guard let idx = workbook.index(ofSheetID: key.sheetID) else { continue }
            let input = workbook.sheets[idx][key.cell]
            if input.utf8.first == UInt8(ascii: "=") { register(key, input: input, in: workbook) }
        }
        var dirty = Set(changed.filter { formulas[$0] != nil })
        var queue = changed
        while let key = queue.popLast() {
            for d in dependents(of: key) where dirty.insert(d).inserted { queue.append(d) }
        }
        dirty.formUnion(volatile)
        evaluate(dirty)
    }

    // MARK: - Dependency graph

    private func register(_ key: CellKey, input: String, in workbook: Workbook) {
        let expr = Parser.parse(String(input.dropFirst()))
        var refs: [Reference] = []
        expr.collectReferences(into: &refs)
        var precedents: [Precedent] = []
        for r in refs where !r.isDeleted {
            let sheetID: Int
            if let name = r.sheet {
                guard let idx = workbook.index(ofSheetNamed: name) else { continue }
                sheetID = workbook.sheets[idx].id
            } else {
                sheetID = key.sheetID
            }
            let end = r.end ?? r.start
            let c0 = min(r.start.col, end.col), c1 = max(r.start.col, end.col)
            if let a = r.start.row, let b = end.row, r.end == nil || (a == b && c0 == c1) {
                precedents.append(.cell(CellKey(sheetID: sheetID, cell: CellRef(row: a, col: c0))))
            } else if let a = r.start.row, let b = end.row {
                precedents.append(.range(sheetID: sheetID, r0: min(a, b), r1: max(a, b), c0: c0, c1: c1))
            } else {
                precedents.append(.range(sheetID: sheetID, r0: 0, r1: Int.max, c0: c0, c1: c1))
            }
        }
        let f = Formula(expr: expr, precedents: precedents, volatile: expr.isVolatile)
        formulas[key] = f
        formulaCells[key.sheetID, default: []].insert(key.cell)
        if f.volatile { volatile.insert(key) }
        for p in precedents {
            switch p {
            case .cell(let c): cellDependents[c, default: []].insert(key)
            case .range(let s, let r0, let r1, let c0, let c1):
                rangeDependents[s, default: []].append(RangeDependent(r0: r0, r1: r1, c0: c0, c1: c1, dependent: key))
            }
        }
    }

    private func unregister(_ key: CellKey) {
        guard let f = formulas.removeValue(forKey: key) else {
            values[key] = nil
            return
        }
        values[key] = nil
        formulaCells[key.sheetID]?.remove(key.cell)
        volatile.remove(key)
        for p in f.precedents {
            switch p {
            case .cell(let c): cellDependents[c]?.remove(key)
            case .range(let s, _, _, _, _): rangeDependents[s]?.removeAll { $0.dependent == key }
            }
        }
    }

    private func dependents(of key: CellKey) -> [CellKey] {
        var out = Array(cellDependents[key] ?? [])
        if let ranges = rangeDependents[key.sheetID] {
            for r in ranges where r.contains(key.cell) { out.append(r.dependent) }
        }
        return out
    }

    /// Formula precedents of `key` that are themselves waiting to be evaluated.
    private func pendingPrecedents(of key: CellKey, among pending: Set<CellKey>) -> [CellKey] {
        guard let f = formulas[key] else { return [] }
        var out: [CellKey] = []
        for p in f.precedents {
            switch p {
            case .cell(let c):
                if pending.contains(c) { out.append(c) }
            case .range(let s, let r0, let r1, let c0, let c1):
                guard let cells = formulaCells[s], !cells.isEmpty else { continue }
                let bounded = r1 == Int.max ? Int.max : (r1 - r0 + 1) * (c1 - c0 + 1)
                if bounded < cells.count {
                    for r in r0...r1 {
                        for c in c0...c1 {
                            let k = CellKey(sheetID: s, cell: CellRef(row: r, col: c))
                            if pending.contains(k) { out.append(k) }
                        }
                    }
                } else {
                    for cell in cells where cell.row >= r0 && cell.row <= r1 && cell.col >= c0 && cell.col <= c1 {
                        let k = CellKey(sheetID: s, cell: cell)
                        if pending.contains(k) { out.append(k) }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Evaluation

    /// Evaluates `pending` in dependency order using an explicit stack (no recursion).
    private func evaluate(_ pending: Set<CellKey>) {
        guard !pending.isEmpty, let workbook else { return }
        let indexByID = Dictionary(uniqueKeysWithValues: workbook.sheets.enumerated().map { ($1.id, $0) })
        // 1 = on the stack, 2 = done.
        var state: [CellKey: UInt8] = [:]
        state.reserveCapacity(pending.count)
        var circular: Set<CellKey> = []

        struct Frame {
            let key: CellKey
            let deps: [CellKey]
            var next = 0
        }

        for root in pending where state[root] == nil {
            var stack = [Frame(key: root, deps: pendingPrecedents(of: root, among: pending))]
            state[root] = 1
            while let top = stack.indices.last {
                if stack[top].next < stack[top].deps.count {
                    let d = stack[top].deps[stack[top].next]
                    stack[top].next += 1
                    switch state[d] {
                    case nil:
                        state[d] = 1
                        stack.append(Frame(key: d, deps: pendingPrecedents(of: d, among: pending)))
                    case 1:
                        // Everything on the stack from `d` up is part of the cycle.
                        if let start = stack.lastIndex(where: { $0.key == d }) {
                            for f in stack[start...] { circular.insert(f.key) }
                        }
                    default:
                        break
                    }
                } else {
                    let key = stack.removeLast().key
                    state[key] = 2
                    if circular.contains(key) {
                        values[key] = .error(.circular)
                    } else {
                        values[key] = compute(key, sheetIndex: indexByID[key.sheetID] ?? 0)
                    }
                }
            }
        }
    }

    private func compute(_ key: CellKey, sheetIndex: Int) -> CellValue {
        guard let f = formulas[key] else { return .empty }
        let result = Evaluator(source: self, sheetIndex: sheetIndex).evaluate(f.expr).scalar
        // A formula pointing at an empty cell shows 0, as in every spreadsheet.
        return result.isEmpty ? .number(0) : result
    }

    // MARK: - CellSource

    func value(sheetIndex: Int, cell: CellRef) -> CellValue {
        guard let workbook, workbook.sheets.indices.contains(sheetIndex) else { return .error(.ref) }
        let sheet = workbook.sheets[sheetIndex]
        let key = CellKey(sheetID: sheet.id, cell: cell)
        if formulas[key] != nil { return values[key] ?? .empty }
        return CellValue.literal(sheet[cell])
    }

    func sheetIndex(named name: String) -> Int? { workbook?.index(ofSheetNamed: name) }

    func maxRow(sheetIndex: Int) -> Int {
        guard let workbook, workbook.sheets.indices.contains(sheetIndex) else { return -1 }
        return workbook.sheets[sheetIndex].maxRow
    }

    var now: Date { clock() }
}

public nonisolated extension FormulaEngine {
    /// Evaluates a one-off formula against a workbook without storing it (tests, tools).
    func evaluate(formula: String, in workbook: Workbook, sheetIndex: Int = 0) -> CellValue {
        self.workbook = workbook
        defer { self.workbook = nil }
        let text = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
        let v = Evaluator(source: self, sheetIndex: sheetIndex).evaluate(Parser.parse(text)).scalar
        return v.isEmpty ? .number(0) : v
    }
}
