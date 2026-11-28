import FolioCode
import FolioConvert
import FolioDocs
import FolioImage
public import FolioKit
import FolioMedia
import FolioPDF
import FolioSheets
import Foundation

/// Every `FolioTool` from the editor modules, for `folio_run` and `folio tools`.
///
/// The same list as the app's `ToolCatalog`; it's rebuilt here because the app target
/// can't be imported, and the tools themselves stay in their modules.
public nonisolated enum AgentCatalog {
    public static let all: [FolioTool] =
        PDFTools.all + ImageTools.all + DocumentTools.all + SpreadsheetTools.all + MediaTools.all + CodeTools.all

    public static func tool(id: String) -> FolioTool? { all.first { $0.id == id } }

    /// One tool with its options, as `folio tools --json` and `folio_formats` print it.
    static func describe(_ tool: FolioTool) -> JSONValue {
        [
            "id": .string(tool.id),
            "title": .string(tool.title),
            "subtitle": .string(tool.subtitle),
            "input_types": .array(tool.inputTypes.map { .string($0.identifier) }),
            "minimum_inputs": .int(Int64(tool.minimumInputs)),
            "options": optionsSchema(tool),
        ]
    }

    /// JSON Schema for a tool's `options`, generated from `Option.choices` so it can't drift.
    static func optionsSchema(_ tool: FolioTool) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for option in tool.options {
            properties[option.id] = [
                "type": "string",
                "title": .string(option.label),
                "enum": .array(option.choices.map { .string($0.value) }),
                "default": .string(option.defaultValue),
            ]
        }
        return ["type": "object", "properties": .object(properties), "additionalProperties": false]
    }

    /// "pdf.rotate {degrees: 90|-90|180}; pdf.watermark {text: CONFIDENTIAL|DRAFT…}" for the
    /// `options` description, so the model has the choices without a second call.
    static var optionsSummary: String {
        all.filter { !$0.options.isEmpty }.map { tool in
            let options = tool.options.map { "\($0.id): \($0.choices.map(\.value).joined(separator: "|"))" }
            return "\(tool.id) {\(options.joined(separator: ", "))}"
        }.joined(separator: "; ")
    }
}
