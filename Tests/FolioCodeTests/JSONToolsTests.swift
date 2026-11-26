import Testing

@testable import FolioCode

@Suite("JSON tools")
struct JSONToolsTests {
    @Test func formatsKeepingOrderAndNumbers() throws {
        let input = #"{"b":1.0,"a":[1,2,{}],"s":"x\"y","e":[]}"#
        let expected = """
            {
              "b": 1.0,
              "a": [
                1,
                2,
                {}
              ],
              "s": "x\\"y",
              "e": []
            }

            """
        #expect(try JSONTools.format(input) == expected)
    }

    @Test func minifies() throws {
        #expect(try JSONTools.minify("{\n  \"a\" : [ 1 , true , null ]\n}") == #"{"a":[1,true,null]}"#)
    }

    @Test func formatThenMinifyRoundTrips() throws {
        let input = #"{"name":"Folio","tags":["a","b"],"nested":{"n":-0.5e+2,"u":"é"}}"#
        #expect(try JSONTools.minify(JSONTools.format(input)) == input)
    }

    @Test(
        "Reports line and column",
        arguments: [
            ("{\n  \"a\": 1,\n}", 3, 1, "Trailing comma before ‘}’"),
            ("[1, 2", 1, 6, "This array is never closed"),
            ("{\"a\" 1}", 1, 6, "Expected ‘:’ after the property name"),
            ("[01]", 1, 3, "Numbers can’t have leading zeros"),
            ("\"é\" x", 1, 5, "Unexpected text after the end of the JSON"),
            ("", 1, 1, "The document is empty"),
        ])
    func reportsErrors(input: String, line: Int, column: Int, message: String) {
        let issue = JSONTools.validate(input)
        #expect(issue?.line == line)
        #expect(issue?.column == column)
        #expect(issue?.message == message)
    }

    @Test func acceptsValidDocuments() {
        for valid in ["0", "\"s\"", "[]", "{\"a\":{\"b\":[null,false,1e5]}}", " \n[ -0.0 ]\n"] {
            #expect(JSONTools.validate(valid) == nil, "\(valid)")
        }
    }

    @Test func rejectsDeepNesting() {
        #expect(JSONTools.validate(String(repeating: "[", count: 600) + String(repeating: "]", count: 600)) != nil)
    }
}
