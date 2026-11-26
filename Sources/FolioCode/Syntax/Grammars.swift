import Foundation

/// Word lists and comment/string rules per language. Lists are space-separated strings so
/// they stay readable and easy to extend.
nonisolated enum Grammars {
    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }
    private static let slashes = ["//".utf16Array]
    private static let cBlock = (open: "/*".utf16Array, close: "*/".utf16Array)
    private static let hash = ["#".utf16Array]
    private static let q = Char.of("\""), sq = Char.of("'"), bt = Char.of("`")

    private static let cTypes =
        "char double float int long short void bool signed unsigned size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t uintptr_t FILE"

    static let c = Grammar(
        lineComments: slashes, blockComment: cBlock,
        keywords: words(
            "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Bool _Complex _Atomic _Thread_local"
        ),
        types: words(cTypes), literals: words("true false NULL nullptr"), preprocessor: true
    )

    static let cpp = Grammar(
        lineComments: slashes, blockComment: cBlock,
        keywords: words(
            "alignas alignof and asm auto break case catch class compl concept const consteval constexpr constinit const_cast continue co_await co_return co_yield decltype default delete do dynamic_cast else enum explicit export extern final for friend goto if inline mutable namespace new noexcept not operator or override private protected public register reinterpret_cast requires return sizeof static static_assert static_cast struct switch template this thread_local throw try typedef typeid typename union using virtual volatile while xor"
        ),
        types: words(cTypes + " wchar_t char8_t char16_t char32_t std string vector map"), literals: words("true false NULL nullptr"),
        capitalizedTypes: true, preprocessor: true
    )

    static let csharp = Grammar(
        lineComments: slashes, blockComment: cBlock,
        keywords: words(
            "abstract as async await base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach get goto if implicit in init interface internal is lock namespace new operator out override params partial private protected public readonly record ref return sealed set sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using value var virtual volatile when where while yield"
        ),
        types: words("bool byte char decimal double dynamic float int long nint nuint object sbyte short string uint ulong ushort void"),
        literals: words("true false null"),
        capitalizedTypes: true, preprocessor: true
    )

    static let swift = Grammar(
        lineComments: slashes, blockComment: cBlock, tripleQuotes: true,
        keywords: words(
            "actor any associatedtype async await borrowing break case catch class consuming continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is lazy let macro mutating nonisolated isolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet as"
        ),
        literals: words("true false nil"),
        capitalizedTypes: true, attributePrefix: Char.of("@"), preprocessor: true
    )

    private static let jsKeywords =
        "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield"

    static let javascript = Grammar(
        lineComments: slashes, blockComment: cBlock, quotes: [q, sq, bt], multilineQuotes: [bt],
        keywords: words(jsKeywords), literals: words("true false null undefined NaN Infinity"),
        capitalizedTypes: true, attributePrefix: Char.of("@"), identifierExtras: [Char.of("$")]
    )

    static let typescript = Grammar(
        lineComments: slashes, blockComment: cBlock, quotes: [q, sq, bt], multilineQuotes: [bt],
        keywords: words(
            jsKeywords
                + " abstract as declare enum implements infer interface is keyof module namespace override private protected public readonly satisfies type unique"
        ),
        types: words("any bigint boolean never number object string symbol unknown void"),
        literals: words("true false null undefined NaN Infinity"),
        capitalizedTypes: true, attributePrefix: Char.of("@"), identifierExtras: [Char.of("$")]
    )

    static let java = Grammar(
        lineComments: slashes, blockComment: cBlock, tripleQuotes: true,
        keywords: words(
            "abstract assert break case catch class const continue default do else enum exports extends final finally for goto if implements import instanceof interface module native new non-sealed package permits private protected public record requires return sealed static strictfp super switch synchronized this throw throws transient try var volatile while yield"
        ),
        types: words("boolean byte char double float int long short void"), literals: words("true false null"),
        capitalizedTypes: true, attributePrefix: Char.of("@")
    )

    static let kotlin = Grammar(
        lineComments: slashes, blockComment: cBlock, tripleQuotes: true,
        keywords: words(
            "abstract actual annotation as break by catch class companion const constructor continue crossinline data do else enum expect external final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias val value var vararg when where while"
        ),
        literals: words("true false null"),
        capitalizedTypes: true, attributePrefix: Char.of("@")
    )

    static let go = Grammar(
        lineComments: slashes, blockComment: cBlock, quotes: [q, sq, bt], multilineQuotes: [bt], rawQuotes: [bt],
        keywords: words(
            "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"
        ),
        types: words(
            "any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr"
        ),
        literals: words("true false nil iota"), capitalizedTypes: false
    )

    /// Single quotes are left out: Rust lifetimes (`'a`) would otherwise open a string.
    static let rust = Grammar(
        lineComments: slashes, blockComment: cBlock, quotes: [q], multilineQuotes: [q],
        keywords: words(
            "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while"
        ),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        literals: words("true false None Some Ok Err"), capitalizedTypes: true
    )

    static let php = Grammar(
        lineComments: slashes + hash, blockComment: cBlock, multilineQuotes: [q, sq],
        keywords: words(
            "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield"
        ),
        literals: words("true false null"), caseInsensitive: true, variablePrefix: Char.of("$")
    )

    static let python = Grammar(
        lineComments: hash, tripleQuotes: true,
        keywords: words(
            "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield"
        ),
        types: words("bool bytes dict float frozenset int list object set str tuple type"),
        literals: words("True False None self cls"), attributePrefix: Char.of("@")
    )

    static let ruby = Grammar(
        lineComments: hash, quotes: [q, sq, bt], multilineQuotes: [q, sq],
        keywords: words(
            "alias and begin BEGIN break case class def defined? do else elsif end END ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer private protected public lambda proc raise"
        ),
        literals: words("true false nil self"),
        capitalizedTypes: true, attributePrefix: Char.of("@"), symbols: true
    )

    static let shell = Grammar(
        lineComments: hash, quotes: [q, sq, bt], multilineQuotes: [q, sq, bt], rawQuotes: [sq],
        keywords: words(
            "if then else elif fi case esac for select while until do done in function time return exit export local readonly declare typeset unset shift source alias set break continue eval exec trap"
        ),
        literals: words("true false"), variablePrefix: Char.of("$"), commentNeedsBoundary: true,
        identifierExtras: [Char.of("-")]
    )

    static let sql = Grammar(
        lineComments: ["--".utf16Array], blockComment: cBlock, quotes: [q, sq, bt], multilineQuotes: [sq],
        keywords: words(
            "add all alter and any as asc begin between by cascade case check column commit constraint create cross database declare default delete desc distinct drop else end except exists foreign from full function group having if in index inner insert intersect into is join key left like limit not null offset on or order outer primary procedure references replace returning returns right rollback select set table then transaction trigger truncate union unique update using values view when where with recursive"
        ),
        types: words(
            "bigint binary bit blob bool boolean char date datetime decimal double float int integer interval json jsonb money numeric real serial smallint text time timestamp timestamptz tinyint uuid varchar"
        ),
        literals: words("true false null"), caseInsensitive: true
    )

    /// JSONC comments are allowed so `tsconfig.json`-style files still color correctly.
    static let json = Grammar(
        lineComments: slashes, blockComment: cBlock, quotes: [q],
        literals: words("true false null"), keysBeforeColon: true
    )

    static let css = Grammar(
        blockComment: cBlock,
        literals: words("inherit initial unset revert none auto transparent currentColor important"),
        attributePrefix: Char.of("@"), identifierExtras: [Char.of("-")], css: true
    )
}
