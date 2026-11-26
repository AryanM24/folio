public import FolioKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// File tools owned by this module. Surfaced in the Welcome window, File > Tools and
/// Finder Quick Actions. See `FolioTool`.
///
/// Each tool is a thin wrapper: load inputs, call a pure function in
/// ``PDFOperations``, write new files next to the first input. Inputs are never
/// modified.
public enum PDFTools {
    public nonisolated static let all: [FolioTool] = [
        FolioTool(
            id: "pdf.combine", title: "Combine PDFs", subtitle: "Merge files into one PDF, in the order chosen",
            symbol: "doc.on.doc", inputTypes: [.pdf], minimumInputs: 2
        ) { inputs, _ in
            try [PDFToolJobs.combine(inputs)]
        },
        FolioTool(
            id: "pdf.imagesToPDF", title: "Images to PDF", subtitle: "One page per image",
            symbol: "photo.on.rectangle", inputTypes: [.image]
        ) { inputs, _ in
            try [PDFToolJobs.imagesToPDF(inputs)]
        },
        FolioTool(
            id: "pdf.toImages", title: "PDF to Images", subtitle: "Save every page as a picture",
            symbol: "photo.stack", inputTypes: [.pdf],
            options: [
                .init(id: "format", label: "Format", choices: [("png", "PNG"), ("jpeg", "JPEG")], defaultValue: "png"),
                .init(
                    id: "dpi", label: "Resolution", choices: [("72", "72 dpi (screen)"), ("150", "150 dpi"), ("300", "300 dpi (print)")],
                    defaultValue: "150"),
            ]
        ) { inputs, options in
            try inputs.flatMap {
                try PDFToolJobs.toImages($0, format: options["format"] ?? "png", dpi: Double(options["dpi"] ?? "") ?? 150)
            }
        },
        FolioTool(
            id: "pdf.split", title: "Split PDF", subtitle: "One PDF per page",
            symbol: "rectangle.split.3x1", inputTypes: [.pdf]
        ) { inputs, _ in
            try inputs.flatMap(PDFToolJobs.split)
        },
        FolioTool(
            id: "pdf.rotate", title: "Rotate PDF", subtitle: "Turn every page",
            symbol: "rotate.right", inputTypes: [.pdf],
            options: [
                .init(
                    id: "degrees", label: "Rotate", choices: [("90", "90° right"), ("-90", "90° left"), ("180", "180°")], defaultValue: "90"
                )
            ]
        ) { inputs, options in
            let degrees = Int(options["degrees"] ?? "") ?? 90
            return try inputs.map { try PDFToolJobs.transform($0, suffix: "rotated") { PDFOperations.rotateAll($0, by: degrees) } }
        },
        FolioTool(
            id: "pdf.compress", title: "Compress PDF", subtitle: "Smaller file, images recompressed",
            symbol: "arrow.down.right.and.arrow.up.left", inputTypes: [.pdf]
        ) { inputs, _ in
            try inputs.map(PDFToolJobs.compress)
        },
        FolioTool(
            id: "pdf.extractText", title: "Extract Text", subtitle: "Save the text of a PDF as a .txt file",
            symbol: "text.alignleft", inputTypes: [.pdf]
        ) { inputs, _ in
            try inputs.map(PDFToolJobs.extractText)
        },
        FolioTool(
            id: "pdf.pageNumbers", title: "Add Page Numbers", subtitle: "“1 of 12” at the bottom of each page",
            symbol: "number", inputTypes: [.pdf]
        ) { inputs, _ in
            try inputs.map { try PDFToolJobs.transform($0, suffix: "numbered", PDFOperations.addPageNumbers) }
        },
        FolioTool(
            id: "pdf.watermark", title: "Add Watermark", subtitle: "Diagonal text across every page",
            symbol: "drop", inputTypes: [.pdf],
            options: [
                .init(
                    id: "text", label: "Text",
                    choices: ["CONFIDENTIAL", "DRAFT", "COPY", "SAMPLE", "DO NOT COPY"].map { ($0, $0.capitalized) },
                    defaultValue: "CONFIDENTIAL"
                )
            ]
        ) { inputs, options in
            let text = options["text"] ?? "CONFIDENTIAL"
            return try inputs.map { try PDFToolJobs.transform($0, suffix: "watermarked") { PDFOperations.addWatermark($0, text: text) } }
        },
    ]
}

/// The file-level halves of the tools: read inputs, write outputs. Separate from
/// `PDFTools.all` so tests can call them with URLs directly.
nonisolated enum PDFToolJobs {
    static func combine(_ inputs: [URL]) throws -> URL {
        let combined = PDFOperations.combine(try inputs.map(PDFOperations.load))
        return try write(combined, nextTo: inputs[0], name: "Combined")
    }

    static func imagesToPDF(_ inputs: [URL]) throws -> URL {
        let images = inputs.compactMap(PageFactory.image(at:))
        guard !images.isEmpty else { throw FolioError("None of the chosen files could be read as an image.") }
        let name = inputs.count == 1 ? inputs[0].deletingPathExtension().lastPathComponent : "Images"
        return try write(PDFOperations.document(fromImages: images), nextTo: inputs[0], name: name)
    }

    static func toImages(_ input: URL, format: String, dpi: Double) throws -> [URL] {
        let document = try PDFOperations.load(input)
        let type: UTType = format == "jpeg" ? .jpeg : .png
        let base = input.deletingPathExtension().lastPathComponent
        return try (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index),
                let image = Rasterizer.displayImage(page, scale: dpi / 72),
                let data = Rasterizer.encode(image, as: type)
            else { return nil }
            let url = FolioTool.outputURL(nextTo: input, name: "\(base) page \(index + 1)", ext: type.preferredFilenameExtension ?? format)
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    static func split(_ input: URL) throws -> [URL] {
        let base = input.deletingPathExtension().lastPathComponent
        return try PDFOperations.split(try PDFOperations.load(input)).enumerated().map { index, page in
            try write(page, nextTo: input, name: "\(base) page \(index + 1)")
        }
    }

    static func compress(_ input: URL) throws -> URL {
        let data = try PDFOperations.compressedData(try PDFOperations.load(input))
        return try write(data, nextTo: input, name: "\(input.deletingPathExtension().lastPathComponent) compressed", ext: "pdf")
    }

    static func extractText(_ input: URL) throws -> URL {
        let text = PDFOperations.text(of: try PDFOperations.load(input))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FolioError(
                "“\(input.lastPathComponent)” has no text. If it's a scan, open it in Folio and choose PDF › Recognize Text first.")
        }
        return try write(Data(text.utf8), nextTo: input, name: input.deletingPathExtension().lastPathComponent, ext: "txt")
    }

    /// Loads `input`, applies `change`, writes "<name> <suffix>.pdf".
    static func transform(_ input: URL, suffix: String, _ change: (PDFDocument) -> Void) throws -> URL {
        let document = try PDFOperations.load(input)
        change(document)
        return try write(document, nextTo: input, name: "\(input.deletingPathExtension().lastPathComponent) \(suffix)")
    }

    private static func write(_ document: PDFDocument, nextTo input: URL, name: String) throws -> URL {
        try write(try PDFOperations.data(document), nextTo: input, name: name, ext: "pdf")
    }

    private static func write(_ data: Data, nextTo input: URL, name: String, ext: String) throws -> URL {
        let url = FolioTool.outputURL(nextTo: input, name: name, ext: ext)
        try data.write(to: url, options: .atomic)
        return url
    }
}
