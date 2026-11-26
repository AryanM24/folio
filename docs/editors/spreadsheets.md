# Spreadsheets

The spreadsheet editor (`Sources/FolioSheets`) opens CSV, TSV, Excel (.xlsx) and OpenDocument (.ods) files, recalculates formulas, and saves back in the format you opened.

## What you can do

- **Grid**: a custom-drawn, virtualized grid. Only visible cells are drawn, so a 100,000 × 50 sheet scrolls like a small one. Column letters and row numbers stay pinned. Drag a column border to resize it, or double-click the border to fit the column's contents. Freeze the header row from the toolbar or *Data › Freeze Header Row*.
- **Selection and keys**: these work like Numbers and Excel.
  - Click, shift-click, or drag. Click a row or column header to select it, and the corner to select everything (⌘A).
  - Move with the arrows, Tab and Return; hold ⇧ to go the other way or to extend the selection.
  - ⌘-arrows jump to the edge of the data. Page Up and Page Down move a screen at a time. Home goes to column A of the row, ⌘Home to A1.
  - Start typing to replace a cell. Return with ⌘, F2 or a double-click edits the cell in place, and Esc cancels.
- **Formula bar** with a name box: type `B12`, `A1:C10` or `Sheet 2!A1` to jump there. Inside a cell, function names autocomplete once you've typed two letters after `=`, an operator, `(` or `,`.
- **Typing**: `12%`, `$4.50` and `2024-03-15` set a percentage, currency or date format when the cell has none. Start with `'` to keep text such as `00123` as text.
- **Clipboard**: copying puts TSV (Numbers, Excel and Google Sheets paste it as cells), an HTML table (keeps bold, colours and alignment) and Folio's own format on the clipboard. Folio's format keeps formulas and shifts their relative references when you paste. Pasting one cell into a selection fills the selection.
- **Edits**: Fill Down (⌘D) and Fill Right (⌘R) adjust references as they copy. Delete clears values and keeps formatting. You can insert and delete rows and columns, sort by the active column, and find and replace (⌘F). Every edit is undoable, and every edit autosaves.
- **Formatting**: bold, italic and underline; left, center and right alignment; fill and text colours; number formats (Automatic, Number, Currency, Percentage, Date); and Clear Formatting.
- **Sheets**: add, rename (double-click a tab), reorder (right-click › Move Left/Right) and delete.
- **Status bar**: shows the Sum, Average and Count of the selection. For a single cell that holds an error, it explains the error in plain language.
- **Charts**: select a range and choose *Insert › Chart* or the toolbar's chart button. A bar, line, area or pie chart (Swift Charts) opens beside the grid. Charts are a **live view only and aren't saved in the file**. The chart panel closes when you switch sheets.
- **Tools** (`SpreadsheetTools.all`):
  - `sheets.convert` converts files between XLSX, ODS, CSV and TSV.
  - `sheets.mergeCSV` stacks CSV and TSV files into one, keeping a shared header row once.

## Formulas

The engine is pure Swift (`Formula/`) and doesn't depend on the UI.

- **Syntax**:
  - Values: numbers, `"strings"` (with `""` as an escaped quote), and `TRUE`/`FALSE`.
  - Operators, from lowest to highest precedence: comparisons (`= <> < > <= >=`), `&`, `+ -`, `* /`, `^`, `%`, then unary minus. Like Excel, `-2^2` is 4.
  - References: `A1`, `$A$1`, ranges, whole columns (`A:A`), and other sheets (`Data!B2`, `'My Sheet'!A1`).
- **Functions**:
  - Aggregates: SUM, AVERAGE, MIN, MAX, COUNT, COUNTA.
  - Logic: IF, IFS, IFERROR, AND, OR, NOT.
  - Maths: ROUND, ROUNDUP, ROUNDDOWN, ABS, SQRT, POWER, MOD, INT.
  - Text: CONCAT, CONCATENATE, TEXTJOIN, LEN, LEFT, RIGHT, MID, UPPER, LOWER, TRIM, SUBSTITUTE.
  - Dates: TODAY, NOW, DATE, YEAR, MONTH, DAY.
  - Conditional: SUMIF, SUMIFS, COUNTIF, COUNTIFS, AVERAGEIF. Criteria accept operators and the `*`/`?` wildcards.
  - Lookup: VLOOKUP, HLOOKUP, XLOOKUP, INDEX, MATCH.
- **Errors**: `#REF!`, `#DIV/0!`, `#NAME?`, `#VALUE!`, `#N/A`, `#NUM!`, `#CIRC!` (a cycle) and `#ERROR!` (unreadable formula text).
- **Arrays**: `SUM(A1:A3*B1:B3)` works element by element.
- **Dates**: stored as serial numbers in the 1900 date system, including Excel's phantom 29 February 1900, so dates match Excel and Numbers.

**How recalculation works.** `FormulaEngine` keeps a dependency graph: each formula's precedents, plus an index from each cell back to the formulas that read it. After an edit, only the edited cells and the cells that depend on them are recomputed. Evaluation is a topological walk with an explicit stack, not recursion, so a 10,000-cell chain (`A2=A1+1`, …) can't overflow the stack. The same walk detects cycles. TODAY and NOW recalculate on every edit.

**Reference rewriting** (`ReferenceRewriter`) works on tokens, so your spacing and spelling survive. It handles:
- copy, fill, paste and sort, where relative parts move and `$` parts stay;
- inserting or deleting rows and columns, where references follow their data, ranges grow or shrink, and references to deleted cells become `#REF!`;
- renaming or deleting a sheet.

## Files

| Format | Read | Write | Notes |
| --- | --- | --- | --- |
| CSV / TSV | ✓ | ✓ | RFC 4180 quoting, delimiter sniffing (`,` tab `;` `\|`). Detects BOMs, UTF-8, BOM-less UTF-16 and Windows-1252. Writes UTF-8 with CRLF. Saves the **current sheet's values**. |
| XLSX | ✓ | ✓ | Shared and inline strings, numbers, booleans, errors, formulas with cached values, shared formulas, bold/italic/underline, colours, fills, alignment, number formats, column widths, frozen panes and the active sheet. Worksheets are read by a byte-level scanner (`XLSXSheetParser`). |
| ODS | ✓ | ✓ | Values, formulas (OpenFormula ↔ A1), repeated rows and cells, and date, percentage and currency types. Cell styles and column widths aren't written yet. |

CSV and TSV can't hold formulas, formatting or more than one sheet. The first time an edit adds one of these to a CSV or TSV, a non-modal banner says what won't be kept. Saving writes formula results.

## Performance

Release build, Apple silicon:

| Task | Time |
| --- | --- |
| Open a 100,000-row × 20-column CSV (2M cells), including parsing and the formula scan | 0.18 s |
| Read a 100,000 × 50 XLSX (5M cells) | 1.0 s |
| Write and read back 500k cells of XLSX | 0.6 s |
| Recalculate 10,000 formulas from scratch | 0.09 s |

These are measured by `Tests/FolioSheetsTests/PerformanceTests.swift`; run them with `swift test -c release -Xswiftc -enable-testing --filter Performance`. Editing a cell only recalculates what depends on it.

## Code map

```
Model/       CellRef, CellRange, Sheet, Workbook, CellStyle, CellValue, DateSerial, ValueFormatter
Formula/     Tokenizer, Parser, Evaluator, FunctionLibrary (+ Text/Date/Lookup/Conditional), FormulaEngine, ReferenceRewriter
Operations/  StructuralEdits (rows/cols/sheets), RangeEdits (fill, paste, sort, find/replace, clear)
Codecs/      CSVCodec, XLSXReader, XLSXSheetParser, XLSXWriter, ODSCodec, XMLScanner (+ ZipPackage), SpreadsheetFormat
Document/    SpreadsheetDocument: ReferenceFileDocument, undoable edits, saves in the opened format
Editor/      SpreadsheetEditorView, SheetController (+Actions, Clipboard), GridView (+Drawing, +Input), CellEditorField,
             GridLayout, FormatToolbar, FormulaBar (+FindBar), SheetTabBar, ChartPanel
SpreadsheetCommands.swift   Insert / Format › Cells / Data menus (mount in the app)
SpreadsheetTools.swift      sheets.convert, sheets.mergeCSV
```

Model, formula and codec types are `nonisolated` and `Sendable`, and are tested without UI. The document keeps `workbook` as a plain stored property rather than `@Published`. `@Published` can't mutate in place, so every edit would copy every cell.

## Known gaps

- Merged cells, borders, fonts other than the system font, wrapped text and row heights aren't supported. Long text spills into empty neighbours instead of wrapping.
- The editor doesn't read the 1904 date system, conditional formats, data validation, comments, images or charts in files.
- Other formula features aren't supported: OFFSET and INDIRECT, named ranges, and row-only ranges (`1:3`).
- You can't drag the fill handle or drag to reorder sheet tabs. Use ⌘D/⌘R and the tab's context menu instead.
- VoiceOver announces the active cell and its value, but the grid isn't exposed as a full accessibility table.
