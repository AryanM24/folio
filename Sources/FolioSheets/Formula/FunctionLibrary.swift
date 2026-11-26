import Foundation

/// A built-in function: evaluated arguments in, value out.
typealias FormulaFunction = @Sendable (_ args: [EvalValue], _ context: Evaluator) -> EvalValue

/// Every built-in function, keyed by upper-case name.
///
/// Functions are grouped by family in `MathFunctions`, `TextFunctions`,
/// `LookupFunctions`, `DateFunctions` and `ConditionalFunctions`.
nonisolated enum FunctionLibrary {
    static let functions: [String: FormulaFunction] = {
        var all: [String: FormulaFunction] = [:]
        for family in [MathFunctions.all, TextFunctions.all, LookupFunctions.all, DateFunctions.all, ConditionalFunctions.all] {
            all.merge(family) { a, _ in a }
        }
        return all
    }()

    /// Sorted names, for autocomplete.
    public static let names: [String] = functions.keys.sorted()
}

// MARK: - Argument helpers shared by every family

nonisolated enum Args {
    /// Checks the argument count; `nil` means OK.
    static func arity(_ args: [EvalValue], _ range: ClosedRange<Int>) -> EvalValue? {
        range.contains(args.count) ? nil : .error(.value)
    }

    static func number(_ v: EvalValue) -> Result<Double, FormulaError> { v.scalar.asNumber() }
    static func text(_ v: EvalValue) -> Result<String, FormulaError> { v.scalar.asText() }
    static func bool(_ v: EvalValue) -> Result<Bool, FormulaError> { v.scalar.asBool() }

    /// Integer argument, truncated toward zero like Excel.
    static func int(_ v: EvalValue) -> Result<Int, FormulaError> {
        number(v).flatMap { n in
            guard abs(n) < 1e15 else { return .failure(.num) }
            return .success(Int(n.rounded(.towardZero)))
        }
    }

    /// Numbers for aggregate functions (SUM, AVERAGE, MIN, MAX).
    ///
    /// Inside references only real numbers count (text and booleans are skipped);
    /// typed arguments are coerced, so `SUM("3", TRUE)` is 4. Errors propagate.
    static func numbers(_ args: [EvalValue]) -> Result<[Double], FormulaError> {
        var out: [Double] = []
        for a in args {
            switch a {
            case .matrix(let m):
                for v in m.values {
                    switch v {
                    case .number(let n): out.append(n)
                    case .error(let e): return .failure(e)
                    default: continue
                    }
                }
            case .scalar(let v):
                if v.isEmpty { continue }
                switch v.asNumber() {
                case .success(let n): out.append(n)
                case .failure(let e): return .failure(e)
                }
            }
        }
        return .success(out)
    }
}

/// Lets function bodies use `try` on `Result`s and return the error as a value.
nonisolated func evaluating(_ body: () throws -> EvalValue) -> EvalValue {
    do { return try body() } catch { return .error(error as? FormulaError ?? .value) }
}

// MARK: - Math and logic

nonisolated enum MathFunctions {
    static let all: [String: FormulaFunction] = [
        "SUM": { args, _ in evaluating { .number(try Args.numbers(args).get().reduce(0, +)) } },
        "AVERAGE": { args, _ in
            evaluating {
                let n = try Args.numbers(args).get()
                guard !n.isEmpty else { return .error(.div0) }
                return .number(n.reduce(0, +) / Double(n.count))
            }
        },
        "MIN": { args, _ in evaluating { .number(try Args.numbers(args).get().min() ?? 0) } },
        "MAX": { args, _ in evaluating { .number(try Args.numbers(args).get().max() ?? 0) } },
        "COUNT": { args, _ in
            var n = 0
            for a in args {
                switch a {
                case .matrix(let m): n += m.values.filter(\.isNumber).count
                case .scalar(let v): if (try? v.asNumber().get()) != nil, !v.isEmpty { n += 1 }
                }
            }
            return .number(Double(n))
        },
        "COUNTA": { args, _ in
            var n = 0
            for a in args {
                switch a {
                case .matrix(let m): n += m.values.filter { !$0.isEmpty }.count
                case .scalar(let v): if !v.isEmpty { n += 1 }
                }
            }
            return .number(Double(n))
        },
        "ROUND": { args, _ in round(args, nudge: true) { $0.rounded(.toNearestOrAwayFromZero) } },
        "ROUNDUP": { args, _ in round(args, nudge: false) { $0.rounded(.awayFromZero) } },
        "ROUNDDOWN": { args, _ in round(args, nudge: false) { $0.rounded(.towardZero) } },
        "ABS": { args, _ in unary(args) { .number(abs($0)) } },
        "SQRT": { args, _ in unary(args) { $0 < 0 ? .error(.num) : .number($0.squareRoot()) } },
        "INT": { args, _ in unary(args) { .number($0.rounded(.down)) } },
        "POWER": { args, _ in
            if let bad = Args.arity(args, 2...2) { return bad }
            return Operators.apply("^", args[0], args[1])
        },
        "MOD": { args, _ in
            evaluating {
                if let bad = Args.arity(args, 2...2) { return bad }
                let n = try Args.number(args[0]).get(), d = try Args.number(args[1]).get()
                guard d != 0 else { return .error(.div0) }
                // Excel's MOD takes the sign of the divisor.
                return .number(n - d * (n / d).rounded(.down))
            }
        },
        "IF": { args, _ in
            evaluating {
                if let bad = Args.arity(args, 1...3) { return bad }
                let condition = try Args.bool(args[0]).get()
                if condition { return args.count > 1 ? args[1] : .bool(true) }
                return args.count > 2 ? args[2] : .bool(false)
            }
        },
        "IFS": { args, _ in
            evaluating {
                guard !args.isEmpty, args.count % 2 == 0 else { return .error(.value) }
                for i in stride(from: 0, to: args.count, by: 2) {
                    if try Args.bool(args[i]).get() { return args[i + 1] }
                }
                return .error(.na)
            }
        },
        "IFERROR": { args, _ in
            if let bad = Args.arity(args, 2...2) { return bad }
            return args[0].scalar.errorValue == nil ? args[0] : args[1]
        },
        "AND": { args, _ in logical(args, initial: true) { $0 && $1 } },
        "OR": { args, _ in logical(args, initial: false) { $0 || $1 } },
        "NOT": { args, _ in
            evaluating {
                if let bad = Args.arity(args, 1...1) { return bad }
                return .bool(!(try Args.bool(args[0]).get()))
            }
        },
    ]

    private static func unary(_ args: [EvalValue], _ f: (Double) -> EvalValue) -> EvalValue {
        evaluating {
            if let bad = Args.arity(args, 1...1) { return bad }
            return f(try Args.number(args[0]).get())
        }
    }

    /// ROUND family: digits may be negative (round to tens, hundreds…).
    private static func round(_ args: [EvalValue], nudge: Bool, _ rule: (Double) -> Double) -> EvalValue {
        evaluating {
            if let bad = Args.arity(args, 1...2) { return bad }
            let x = try Args.number(args[0]).get()
            let digits = args.count > 1 ? try Args.int(args[1]).get() : 0
            // Scale by an exact power of ten (dividing by 0.01 isn't exact; multiplying by 100 is).
            let factor = pow(10, Double(abs(digits)))
            let scaled = digits >= 0 ? x * factor : x / factor
            // ROUND nudges by a few ULPs so 2.675 rounds to 2.68 as people expect, not 2.67.
            // ROUNDUP/ROUNDDOWN snap to 12 significant digits first so 0.1*3 doesn't round up to 0.31.
            let adjusted =
                nudge
                ? scaled + (scaled >= 0 ? 1 : -1) * scaled.ulp * 4
                : (Double(String(format: "%.12G", scaled)) ?? scaled)
            let r = rule(adjusted)
            return .number(digits >= 0 ? r / factor : r * factor)
        }
    }

    private static func logical(_ args: [EvalValue], initial: Bool, _ combine: (Bool, Bool) -> Bool) -> EvalValue {
        guard !args.isEmpty else { return .error(.value) }
        var result = initial
        var sawValue = false
        for a in args {
            for v in a.flattened {
                switch v {
                case .empty: continue
                case .text where a.isReference: continue
                case .error(let e): return .error(e)
                default:
                    guard let b = try? v.asBool().get() else { return .error(.value) }
                    result = combine(result, b)
                    sawValue = true
                }
            }
        }
        return sawValue ? .bool(result) : .error(.value)
    }
}
