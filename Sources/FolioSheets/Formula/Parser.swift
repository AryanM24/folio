import Foundation

/// A parsed formula.
nonisolated indirect enum Expr: Sendable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(FormulaError)
    case reference(Reference)
    /// An omitted argument, as in `IF(A1,,2)`.
    case missing
    case negate(Expr)
    case percent(Expr)
    case binary(String, Expr, Expr)
    case call(String, [Expr])
    /// An unknown bare name; evaluates to `#NAME?`.
    case name(String)

    /// Every reference in the expression, for dependency tracking.
    func collectReferences(into out: inout [Reference]) {
        switch self {
        case .reference(let r): out.append(r)
        case .negate(let e), .percent(let e): e.collectReferences(into: &out)
        case .binary(_, let a, let b):
            a.collectReferences(into: &out)
            b.collectReferences(into: &out)
        case .call(_, let args): for a in args { a.collectReferences(into: &out) }
        default: break
        }
    }

    /// Whether the result depends on the clock, so it must recalculate every time.
    var isVolatile: Bool {
        switch self {
        case .call(let name, let args): name == "TODAY" || name == "NOW" || args.contains(where: \.isVolatile)
        case .negate(let e), .percent(let e): e.isVolatile
        case .binary(_, let a, let b): a.isVolatile || b.isVolatile
        default: false
        }
    }
}

/// Precedence-climbing parser following Excel's operator order:
/// comparison < & < + - < * / < ^ < % < unary minus.
nonisolated struct Parser {
    private let tokens: [Token]
    private var pos = 0

    /// Parse formula text (without the leading "="). Syntax errors become `.error(.syntax)`.
    static func parse(_ formula: String) -> Expr {
        var p = Parser(tokens: Tokenizer.tokenize(formula))
        guard !p.tokens.isEmpty else { return .error(.syntax) }
        guard let e = p.expression(0), p.pos == p.tokens.count else { return .error(.syntax) }
        return e
    }

    private init(tokens: [Token]) { self.tokens = tokens }

    private var current: TokenKind? { pos < tokens.count ? tokens[pos].kind : nil }

    private static func precedence(_ op: String) -> Int? {
        switch op {
        case "=", "<", ">", "<=", ">=", "<>": 1
        case "&": 2
        case "+", "-": 3
        case "*", "/": 4
        case "^": 5
        default: nil
        }
    }

    private mutating func expression(_ minPrec: Int) -> Expr? {
        guard var lhs = unary() else { return nil }
        while case .op(let op)? = current, let prec = Parser.precedence(op), prec >= minPrec {
            pos += 1
            // All binary operators are left-associative in Excel, including ^.
            guard let rhs = expression(prec + 1) else { return nil }
            lhs = .binary(op, lhs, rhs)
        }
        return lhs
    }

    private mutating func unary() -> Expr? {
        if case .op(let op)? = current, op == "-" || op == "+" {
            pos += 1
            guard let operand = unary() else { return nil }
            return op == "-" ? .negate(operand) : operand
        }
        return postfix()
    }

    private mutating func postfix() -> Expr? {
        guard var e = primary() else { return nil }
        while case .op("%")? = current {
            pos += 1
            e = .percent(e)
        }
        return e
    }

    private mutating func primary() -> Expr? {
        guard let token = current else { return nil }
        pos += 1
        switch token {
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .error(let e): return e == .syntax ? nil : .error(e)
        case .reference(let r): return .reference(r)
        case .name(let n): return .name(n)
        case .lparen:
            guard let inner = expression(0), current == .rparen else { return nil }
            pos += 1
            return inner
        case .function(let name):
            guard current == .lparen else { return nil }
            pos += 1
            var args: [Expr] = []
            if current == .rparen { pos += 1; return .call(name, args) }
            while true {
                if current == .comma || current == .rparen {
                    args.append(.missing)
                } else {
                    guard let a = expression(0) else { return nil }
                    args.append(a)
                }
                if current == .comma { pos += 1; continue }
                if current == .rparen { pos += 1; return .call(name, args) }
                return nil
            }
        default:
            return nil
        }
    }
}
