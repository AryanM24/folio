import FolioKit
public import SwiftUI
public import UniformTypeIdentifiers

/// What gets written to disk: the workbook plus computed formula values (cached in
/// XLSX so other apps show results without recalculating). Both are copy-on-write,
/// so taking a snapshot on the main thread is O(1).
public nonisolated struct SpreadsheetSnapshot: Sendable {
    public var workbook: Workbook
    public var values: [CellKey: CellValue]
}

/// A spreadsheet file: CSV, TSV, XLSX or ODS.
///
/// Every edit goes through `apply(_:)` or `replaceWorkbook(_:)`, which register undo
/// and therefore trigger autosave (see docs/ARCHITECTURE.md). The file is saved back
/// in the format it was opened in.
///
/// `workbook` is deliberately *not* `@Published`: `@Published` has no in-place
/// mutation, so every single-cell edit would copy the whole cell dictionary (slow on
/// 100k-row files). We mutate the stored property in place and send
/// `objectWillChange` ourselves.
public final class SpreadsheetDocument: ReferenceFileDocument {
    public typealias Snapshot = SpreadsheetSnapshot

    public nonisolated static var readableContentTypes: [UTType] { FileKind.spreadsheet.readableTypes }
    public nonisolated static var writableContentTypes: [UTType] { FileKind.spreadsheet.readableTypes }

    @MainActor public private(set) var workbook: Workbook
    public let engine: FormulaEngine
    /// The format the file was opened as; new documents save as XLSX.
    public let format: SpreadsheetFormat
    /// Set once when an edit introduces something the file format can't store.
    @MainActor public private(set) var formatWarning: String?
    @MainActor private var warnedAboutFormat = false

    /// Bumped on every change, so views can cheaply tell that something changed.
    @MainActor public private(set) var revision = 0

    private nonisolated static let log = Log.make("Sheets")

    public nonisolated init() {
        workbook = Workbook()
        engine = FormulaEngine()
        format = .xlsx
    }

    public nonisolated init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw FolioError("The file couldn't be read.")
        }
        let type = configuration.contentType
        let fmt =
            SpreadsheetFormat(type: type)
            ?? configuration.file.filename.flatMap { SpreadsheetFormat(fileExtension: ($0 as NSString).pathExtension) }
            ?? .csv
        let start = Date()
        do {
            workbook = try fmt.read(bytes)
        } catch {
            Self.log.error("Couldn't read spreadsheet: \(error.localizedDescription, privacy: .public)")
            throw FolioError("Folio couldn't read this spreadsheet. \(error.localizedDescription)")
        }
        format = fmt
        engine = FormulaEngine()
        engine.recalculateAll(workbook)
        let cells = workbook.sheets.reduce(0) { $0 + $1.cells.count }
        Self.log.info(
            "Opened \(fmt.rawValue, privacy: .public): \(cells) cells in \(Date().timeIntervalSince(start), format: .fixed(precision: 3)) s"
        )
    }

    /// Opens bytes directly (tests, tools).
    public nonisolated init(data: Data, format: SpreadsheetFormat) throws {
        workbook = try format.read(data)
        self.format = format
        engine = FormulaEngine()
        engine.recalculateAll(workbook)
    }

    /// Runs on AppKit's save thread with the main thread parked; see `readDuringSave`.
    public nonisolated func snapshot(contentType: UTType) throws -> SpreadsheetSnapshot {
        readDuringSave { SpreadsheetSnapshot(workbook: workbook, values: engine.values) }
    }

    public nonisolated func fileWrapper(snapshot: SpreadsheetSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let fmt = SpreadsheetFormat(type: configuration.contentType) ?? format
        let data = try fmt.write(snapshot.workbook, values: snapshot.values)
        return FileWrapper(regularFileWithContents: data)
    }

    // MARK: - Reading (main actor)

    @MainActor public var activeSheetIndex: Int { min(max(0, workbook.activeSheetIndex), workbook.sheets.count - 1) }
    @MainActor public var activeSheet: Sheet { workbook.sheets[activeSheetIndex] }

    /// The computed value of a cell on the active sheet.
    @MainActor public func value(at ref: CellRef) -> CellValue { value(at: ref, sheet: activeSheetIndex) }

    @MainActor public func value(at ref: CellRef, sheet index: Int) -> CellValue {
        let sheet = workbook.sheets[index]
        if let v = engine.value(sheetID: sheet.id, cell: ref) { return v }
        return CellValue.literal(sheet[ref])
    }

    /// The text a cell shows on screen.
    @MainActor public func displayText(at ref: CellRef) -> String {
        let sheet = activeSheet
        guard sheet.cells[ref] != nil else { return "" }
        return ValueFormatter.shared.string(for: value(at: ref), format: sheet.style(at: ref).numberFormat)
    }

    // MARK: - Editing (all undoable)

    /// Replaces cell contents on one sheet as a single undo step.
    @MainActor public func apply(_ changes: [CellRef: CellContent], sheet index: Int? = nil, actionName: String, undoManager: UndoManager?)
    {
        guard !changes.isEmpty else { return }
        let i = index ?? activeSheetIndex
        guard workbook.sheets.indices.contains(i) else { return }
        objectWillChange.send()
        var inverse: [CellRef: CellContent] = [:]
        inverse.reserveCapacity(changes.count)
        for (ref, content) in changes {
            inverse[ref] = CellContent(input: workbook.sheets[i][ref], style: workbook.sheets[i].style(at: ref))
            workbook.sheets[i].setInput(content.input, at: ref)
            workbook.sheets[i].setStyle(content.style, at: ref)
        }
        let id = workbook.sheets[i].id
        engine.cellsChanged(changes.keys.map { CellKey(sheetID: id, cell: $0) }, in: workbook)
        revision += 1
        noteFormatLoss(changes.values)
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.apply(inverse, sheet: doc.workbook.index(ofSheetID: id) ?? i, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Swaps in a new workbook (structural edits: rows, columns, sheets, sort of whole
    /// sheets). Recalculates everything.
    @MainActor public func replaceWorkbook(_ new: Workbook, actionName: String, undoManager: UndoManager?) {
        objectWillChange.send()
        let old = workbook
        workbook = new
        engine.recalculateAll(workbook)
        revision += 1
        if format.isPlainText && workbook.sheets.count > 1 { warn() }
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.replaceWorkbook(old, actionName: actionName, undoManager: undoManager) }
        }
        undoManager?.setActionName(actionName)
    }

    /// Sheet-level properties that don't touch cells (column widths, frozen panes).
    @MainActor public func updateSheet(_ index: Int, actionName: String, undoManager: UndoManager?, _ edit: (inout Sheet) -> Void) {
        guard workbook.sheets.indices.contains(index) else { return }
        objectWillChange.send()
        let before = (workbook.sheets[index].columnWidths, workbook.sheets[index].frozenRows, workbook.sheets[index].frozenCols)
        edit(&workbook.sheets[index])
        revision += 1
        let id = workbook.sheets[index].id
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let i = doc.workbook.index(ofSheetID: id) else { return }
                doc.updateSheet(i, actionName: actionName, undoManager: undoManager) { s in
                    (s.columnWidths, s.frozenRows, s.frozenCols) = before
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Switching sheets is view state: it changes what CSV saves but isn't an edit.
    @MainActor public func selectSheet(_ index: Int) {
        guard workbook.sheets.indices.contains(index), index != workbook.activeSheetIndex else { return }
        objectWillChange.send()
        workbook.activeSheetIndex = index
        revision += 1
    }

    /// Clears the one-time format warning after it has been shown.
    @MainActor public func dismissFormatWarning() {
        objectWillChange.send()
        formatWarning = nil
    }

    @MainActor private func noteFormatLoss(_ changes: Dictionary<CellRef, CellContent>.Values) {
        guard format.isPlainText, !warnedAboutFormat else { return }
        if changes.contains(where: { $0.input.hasPrefix("=") || !$0.style.isPlain }) { warn() }
    }

    @MainActor private func warn() {
        guard !warnedAboutFormat, let message = format.losses(in: workbook) else { return }
        warnedAboutFormat = true
        formatWarning = message
    }
}
