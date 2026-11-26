import Foundation

nonisolated enum TextFunctions {
    static let all: [String: FormulaFunction] = [
        "CONCAT": { args, _ in concat(args.flatMap(\.flattened)) },
        // CONCATENATE predates ranges: a range argument uses its first cell.
        "CONCATENATE": { args, _ in concat(args.map(\.scalar)) },
        "TEXTJOIN": { args, _ in
            evaluating {
                guard args.count >= 3 else { return .error(.value) }
                let delimiter = try Args.text(args[0]).get()
                let ignoreEmpty = try Args.bool(args[1]).get()
                var parts: [String] = []
                for v in args.dropFirst(2).flatMap(\.flattened) {
                    let s = try v.asText().get()
                    if ignoreEmpty && s.isEmpty { continue }
                    parts.append(s)
                }
                return .text(parts.joined(separator: delimiter))
            }
        },
        "LEN": { args, _ in
            evaluating {
                if let bad = Args.arity(args, 1...1) { return bad }
                return .number(Double(try Args.text(args[0]).get().count))
            }
        },
        "LEFT": { args, _ in side(args) { s, n in String(s.prefix(n)) } },
        "RIGHT": { args, _ in side(args) { s, n in String(s.suffix(n)) } },
        "MID": { args, _ in
            evaluating {
                if let bad = Args.arity(args, 3...3) { return bad }
                let s = try Args.text(args[0]).get()
                let start = try Args.int(args[1]).get(), count = try Args.int(args[2]).get()
                guard start >= 1, count >= 0 else { return .error(.value) }
                return .text(String(s.dropFirst(start - 1).prefix(count)))
            }
        },
        "UPPER": { args, _ in transform(args) { $0.uppercased() } },
        "LOWER": { args, _ in transform(args) { $0.lowercased() } },
        // TRIM also collapses runs of inner spaces to one, like Excel.
        "TRIM": { args, _ in transform(args) { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") } },
        "SUBSTITUTE": { args, _ in
            evaluating {
                if let bad = Args.arity(args, 3...4) { return bad }
                let s = try Args.text(args[0]).get()
                let old = try Args.text(args[1]).get(), new = try Args.text(args[2]).get()
                guard !old.isEmpty else { return .text(s) }
                guard args.count == 4 else { return .text(s.replacingOccurrences(of: old, with: new)) }
                let instance = try Args.int(args[3]).get()
                guard instance >= 1 else { return .error(.value) }
                var seen = 0
                var search = s.startIndex
                while let r = s.range(of: old, range: search..<s.endIndex) {
                    seen += 1
                    if seen == instance { return .text(s.replacingCharacters(in: r, with: new)) }
                    search = r.upperBound
                }
                return .text(s)
            }
        },
    ]

    private static func concat(_ values: [CellValue]) -> EvalValue {
        evaluating {
            var out = ""
            for v in values { out += try v.asText().get() }
            return .text(out)
        }
    }

    private static func side(_ args: [EvalValue], _ take: (String, Int) -> String) -> EvalValue {
        evaluating {
            if let bad = Args.arity(args, 1...2) { return bad }
            let s = try Args.text(args[0]).get()
            let n = args.count > 1 ? try Args.int(args[1]).get() : 1
            guard n >= 0 else { return .error(.value) }
            return .text(take(s, n))
        }
    }

    private static func transform(_ args: [EvalValue], _ f: (String) -> String) -> EvalValue {
        evaluating {
            if let bad = Args.arity(args, 1...1) { return bad }
            return .text(f(try Args.text(args[0]).get()))
        }
    }
}
