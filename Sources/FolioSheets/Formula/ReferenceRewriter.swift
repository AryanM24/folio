import Foundation

/// Rewrites the references inside formula text, leaving everything else byte-for-byte.
///
/// Used when formulas move (copy, fill, paste, sort), when rows or columns are
/// inserted or deleted, and when a sheet is renamed. Works on tokens rather than the
/// parsed tree so spacing and the user's spelling of function names survive.
public nonisolated enum ReferenceRewriter {
    public enum Axis: Sendable { case rows, columns }

    /// Applies `transform` to every reference in `formula` ("=…"). Non-formulas pass through.
    static func rewrite(_ formula: String, _ transform: (Reference) -> Reference) -> String {
        guard formula.hasPrefix("=") else { return formula }
        let tokens = Tokenizer.tokenize(String(formula.dropFirst()))
        var out = "="
        for t in tokens {
            out += t.leading
            if case .reference(let r) = t.kind {
                let new = transform(r)
                out += new == r ? t.text : new.text
            } else {
                out += t.text
            }
        }
        return out
    }

    /// Copy/fill: relative parts move by the offset; absolute ($) parts stay.
    /// References pushed off the top or left edge become `#REF!`.
    public static func offset(_ formula: String, rows dr: Int, cols dc: Int) -> String {
        rewrite(formula) { r in
            var r = r
            /// Returns false when the point moved off the sheet.
            func move(_ p: inout RefPoint) -> Bool {
                if !p.colAbsolute { p.col += dc }
                if !p.rowAbsolute, let row = p.row { p.row = row + dr }
                return p.col >= 0 && (p.row ?? 0) >= 0
            }
            var ok = move(&r.start)
            if var e = r.end {
                ok = move(&e) && ok
                r.end = e
            }
            if !ok { r.isDeleted = true }
            return r
        }
    }

    /// Rows or columns were inserted before index `at` on sheet `sheetName`.
    /// `formulaSheet` is the sheet holding the formula (unqualified refs point there).
    public static func insert(_ formula: String, axis: Axis, at: Int, count: Int, sheetName: String, formulaSheet: String) -> String {
        adjust(formula, axis: axis, sheetName: sheetName, formulaSheet: formulaSheet) { a, b in
            (a >= at ? a + count : a, b >= at ? b + count : b)
        }
    }

    /// Rows or columns `at..<at+count` were deleted. References entirely inside become
    /// `#REF!`; ranges that overlap shrink.
    public static func delete(_ formula: String, axis: Axis, at: Int, count: Int, sheetName: String, formulaSheet: String) -> String {
        let last = at + count - 1
        return adjust(formula, axis: axis, sheetName: sheetName, formulaSheet: formulaSheet) { a, b in
            if a >= at && b <= last { return nil }
            let na = a < at ? a : (a <= last ? at : a - count)
            let nb = b < at ? b : (b <= last ? at - 1 : b - count)
            return (na, nb)
        }
    }

    /// A sheet was renamed: qualified references follow it.
    public static func renameSheet(_ formula: String, from old: String, to new: String) -> String {
        rewrite(formula) { r in
            guard let s = r.sheet, s.compare(old, options: .caseInsensitive) == .orderedSame else { return r }
            var r = r
            r.sheet = new
            return r
        }
    }

    /// A sheet was deleted: references to it become `#REF!`.
    public static func deleteSheet(_ formula: String, named name: String) -> String {
        rewrite(formula) { r in
            guard let s = r.sheet, s.compare(name, options: .caseInsensitive) == .orderedSame else { return r }
            var r = r
            r.isDeleted = true
            return r
        }
    }

    /// Shared insert/delete logic: `shift` maps an inclusive index span along `axis`,
    /// returning `nil` when the span was deleted.
    private static func adjust(
        _ formula: String, axis: Axis, sheetName: String, formulaSheet: String,
        _ shift: (Int, Int) -> (Int, Int)?
    ) -> String {
        rewrite(formula) { r in
            let target = r.sheet ?? formulaSheet
            guard target.compare(sheetName, options: .caseInsensitive) == .orderedSame, !r.isDeleted else { return r }
            var r = r
            var start = r.start, end = r.end ?? r.start
            let get: (RefPoint) -> Int? = { axis == .rows ? $0.row : $0.col }
            guard let a0 = get(start), let b0 = get(end) else { return r }  // whole columns ignore row edits
            let (a, b) = (min(a0, b0), max(a0, b0))
            if a0 > b0 { swap(&start, &end) }
            guard let (na, nb) = shift(a, b) else {
                r.isDeleted = true
                return r
            }
            if axis == .rows {
                start.row = na
                end.row = nb
            } else {
                start.col = na
                end.col = nb
            }
            r.start = start
            if r.end != nil { r.end = end }
            return r
        }
    }
}
