import Foundation

/// Dates are serial numbers (see `DateSerial`), so these are plain numeric functions.
nonisolated enum DateFunctions {
    static let all: [String: FormulaFunction] = [
        "TODAY": { args, ctx in
            if let bad = Args.arity(args, 0...0) { return bad }
            return .number(DateSerial.serial(for: ctx.source.now).rounded(.down))
        },
        "NOW": { args, ctx in
            if let bad = Args.arity(args, 0...0) { return bad }
            return .number(DateSerial.serial(for: ctx.source.now))
        },
        "DATE": { args, _ in
            evaluating {
                if let bad = Args.arity(args, 3...3) { return bad }
                let y = try Args.int(args[0]).get(), m = try Args.int(args[1]).get(), d = try Args.int(args[2]).get()
                guard let s = DateSerial.serial(year: y, month: m, day: d) else { return .error(.num) }
                return .number(s)
            }
        },
        "YEAR": { args, _ in part(args) { $0.year } },
        "MONTH": { args, _ in part(args) { $0.month } },
        "DAY": { args, _ in part(args) { $0.day } },
    ]

    private static func part(_ args: [EvalValue], _ pick: ((year: Int, month: Int, day: Int)) -> Int) -> EvalValue {
        evaluating {
            if let bad = Args.arity(args, 1...1) { return bad }
            let v = args[0].scalar
            // Accept ISO date text as well as serials, so YEAR("2024-03-01") works.
            let serial: Double
            if case .text(let s) = v, let iso = DateSerial.parseISO(s) {
                serial = iso
            } else {
                serial = try v.asNumber().get()
            }
            guard let c = DateSerial.components(serial) else { return .error(.num) }
            return .number(Double(pick(c)))
        }
    }
}
