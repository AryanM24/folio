# Document editor (`FolioDocs`)

Rich-text editing for Word (`.docx`), Word 97 (`.doc`), RTF, RTFD, OpenDocument (`.odt`), HTML and web archives. A file is always saved back in the format it was opened in. New documents are Word files.

## What you get

- **Paper.** A white sheet with the document's real paper size (US Letter or A4) and margins, centered on the canvas. It stays white in dark mode, as in Pages. Zoom from 50% to 300% (pinch, ⌘< / ⌘>, ⌘0, or the status bar). *View › Wrap to Window* swaps the sheet for a column as wide as the window.
- **Formatting toolbar** (a floating HeroUI pill): paragraph style, font, size, bold, italic, underline, strikethrough, superscript and subscript, text color and highlight (swatches, or *More…* for the system color panel), alignment, line spacing, bulleted, numbered and checklist lists, indent and outdent, link, image, table (hover a grid to pick its size), horizontal rule, page break, Clear Formatting, and Copy and Paste Style. Table and image controls appear when the selection is in a table or on an image. In narrow windows, less-used controls move into the "…" menu.
- **Format menu** (`DocumentCommands`): every toolbar command, with shortcuts. Title ⌥⌘1, Heading 1–3 ⌥⌘2–4, Body ⌥⌘0, lists ⇧⌘7/8/9, link ⌘K, page break ⌘↩, Copy and Paste Style ⌥⌘C and ⌥⌘V.
- **Built into the text view:** Find & Replace bar with incremental search, spelling and grammar, smart quotes and dashes, text replacements, Writing Tools, Services, dictation, Look Up, and *Import from iPhone* (Continuity Camera) in the context menu.
- **Outline sidebar** (⌃⌘S): headings in order. Click one to jump to it. The section holding the caret is highlighted.
- **Status bar:** words, characters, reading time (238 words per minute) and estimated pages (500 words a page, plus page breaks).
- **Export** (toolbar or *File › Export To*): PDF, Word, RTF, OpenDocument, HTML, Markdown, plain text, web archive and Word 97. **Print** (⌘P) prints real pages with the document's margins.
- **Tool** `docs.convert` (*Convert Documents*): converts Word, RTF, ODT, HTML, web archive, Word 97, Markdown or text files into PDF, Word, RTF, ODT, HTML, Markdown or text. The result goes next to the input, which is never changed.

## How it works

| Piece | File |
| --- | --- |
| Document model, snapshot and save | `RichTextDocument.swift` |
| Formats, extension and content type | `Formats/DocFormat.swift` |
| Read and write all formats, as pure functions of bytes | `Formats/DocumentCodec.swift` |
| Word writer, Word reader fix-ups, minimal ZIP | `Formats/DocxWriter.swift`, `Formats/DocxStyles.swift`, `Formats/ZipArchive.swift` |
| Markdown export and import | `Formats/Markdown.swift` |
| Styles, lists, tables, stats, outline | `Editing/*.swift` |
| Text view, paper canvas, list markers, pagination | `Layout/*.swift` |
| SwiftUI shell, toolbar, popovers, outline, controller | `UI/*.swift` |
| Menus | `DocumentCommands.swift` |
| Tools | `DocumentTools.swift` |

- **One text storage.** The document owns an `NSTextStorage`. The editor's layout manager attaches to it, so there is no second copy to keep in sync. `snapshot` copies it, and `fileWrapper` encodes in the background.
- **Autosave goes through undo.** Edits go through the text view (`shouldChangeText` / `didChangeText`). Its undo manager is the window's, which is the document's, so every edit marks the document as edited. Paper changes register their own undo. Measured in the running app: a typed edit was written to disk 1.0 s later.
- **TextKit 1.** `NSTextTable` lays out only in TextKit 1, and a TextKit 2 view falls back to TextKit 1 the first time it meets a table. Pagination for Print and PDF uses the same `NSLayoutManager`, with one text container per page. Non-contiguous layout keeps long documents fast.
- **List markers.** From macOS 26, list markers are no longer characters in the text (`NSTextList.includesTextListMarkers` is false), and only TextKit 2 draws them. `MarkerLayoutManager` draws them for TextKit 1. On macOS 15, markers are text and are handled as text.
- **Page breaks** are form feeds. In the editor a page break ends the line and is drawn as a dashed rule. In print and PDF it starts a new page.

### Why Folio writes Word files itself

The system's Word writer drops lists, tables and heading styles. Autosave would silently strip them from any Word file opened in Folio. `DocxWriter` writes paragraphs and runs, lists (`numbering.xml`), tables, links, images, page breaks, rules, heading styles that Word's navigation pane recognises, and page setup.

Reading still uses the system reader. It ignores paragraph styles, reads every list as bullets, and drops hyperlink targets, so `DocxStyles` restores those from `styles.xml`, `numbering.xml` and the relationships. It runs only when its paragraph count matches the reader's.

## Performance

A 360-section Word file (315 pages, 157,000 words, 890,000 characters):

- **Reading and parsing:** 78–128 ms in the app.
- **Read to first paint:** 518 ms in the app.
- **Read, lay out and draw in a hosted window:** 184 ms (test `largeDocumentOpensFast`).

Stats and the outline are computed 350 ms after typing stops, and stats are computed off the main thread.

## Testing

`make test` runs `Tests/FolioDocsTests`:

- Every format round-trips. Word keeps lists, tables, headings, links, page breaks and page setup.
- Word heading styles that exist only in `styles.xml` are restored.
- ZIP read and write.
- Markdown export and import.
- List, table, style, stats and outline helpers.
- PDF pagination and paper size.
- The converter.
- Open-time budgets.
- Editor commands in a hosted window, including undo registration.

Set `FOLIO_SAMPLES_DIR=/some/dir` to also write sample files (`Sample.docx`, `Long.docx`, …) and light and dark renderings of the editor (`editor-light.png`, …) for review.

## Known gaps

- Merged table cells are un-merged when a Word file is saved, and when a row or column is added to or removed from that table. RTF and ODT keep merges.
- Images can be resized from the toolbar's size menu (25–100% of the text width). There are no drag handles.
- Headers, footers, footnotes, comments and tracked changes in Word files are not shown. The system reader drops them, so saving a Word file that has them loses them.
- On macOS 15, numbered lists read from Word files keep the reader's bullet text.
- Backspace at the start of a list item doesn't remove the item from the list. Use the list button, or press Return on an empty item.
