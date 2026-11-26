# PDF editor

The PDF editor (`Sources/FolioPDF`) views, annotates, fills, redacts, OCRs and reorganises PDFs. It is built on PDFKit, Vision and Quartz, and every edit is undoable and therefore autosaved.

## Using it

### Viewing

- **Scroll and zoom.** Pinch, ⌘+ / ⌘−, ⌘0 for actual size, ⌘9 to fit the page, ⌥⌘9 to fit the width. The zoom-to-fit menu in the toolbar has the same presets.
- **Layout.** Single page (⌥⌘1) or two pages side by side (⌥⌘2), always continuous.
- **Sidebar.** *Pages* shows thumbnails; *Contents* shows the PDF's table of contents, if it has one. Toggle it with the sidebar button.
- **Go to page.** ⌥⌘G, or click "Page 3 of 12" in the status bar.
- **Find.** ⌘F opens the find bar. Matches stream in as PDFKit finds them; Return or ⌘G goes to the next one, ⇧Return or ⇧⌘G to the previous one, Esc closes.
- **Select and copy text** with the Select tool (⌃⌘1), as in any PDF viewer.

### Annotating

The floating toolbar at the bottom holds the tools. Each has a ⌃⌘ shortcut, listed in the **PDF › Annotate** menu.

| Tool | Shortcut | How |
| --- | --- | --- |
| Select | ⌃⌘1 | Click an annotation to select it. Drag to move, drag a handle to resize, arrows to nudge (⇧ for 10 pt), ⌫ to delete, Esc to deselect. |
| Highlight, Underline, Strikethrough | ⌃⌘H, ⌃⌘U, ⌃⌘K | Select text, then pick the tool, or pick the tool and then select text. |
| Pen, Highlighter | ⌃⌘P, ⌃⌘M | Drag to draw. The tool stays active. |
| Text box | ⌃⌘T | Click (default size) or drag. Type the text in the inspector. |
| Note | ⌃⌘N | Click to place. Type the note in the inspector. |
| Rectangle, Ellipse, Line, Arrow | ⌃⌘R, ⌃⌘O, ⌃⌘L, ⌃⌘A | Drag. |
| Redact | ⌃⌘X | Drag over content to remove it permanently (see below). |

**Stamps** (⌃⌘S): Approved, Rejected, Draft, Confidential, Final, For Comment, a check, a cross and today's date. **Signature** (⌃⌘G): draw it once, and Folio reuses it in every PDF. Right-click the signature button to draw a new one or clear the saved one. **Image** (⌃⌘I): any image file. All three drop the item in the middle of the visible page, selected, so you can move and resize it right away.

The **inspector** floats at the top right while an annotation is selected or a drawing tool is active. It shows only what applies: text, color, stroke width, font size, opacity, and a delete button. Changes apply to the selection, and Folio remembers them for the next annotation of that kind.

Annotations are standard PDF annotations (Highlight, Ink, FreeText, Square, Line, Stamp…), so they show and stay editable in Preview, Acrobat and browsers.

### Forms

Click into a form field and type, or click checkboxes and radio buttons. Each change is undoable. **PDF › Flatten Form** burns the current values into the pages so they print everywhere and can no longer be changed.

### Redaction

Redaction removes content; it doesn't just cover it. When you drag a redaction box, Folio renders the whole page as an image at 216 dpi with the box painted black, and replaces the page with that image. The text, images and annotations underneath no longer exist in the file. Undo brings the original page back until you close the document.

The cost is that the redacted page has no selectable text left at all. Run **Recognize Text** on it to make the remaining text searchable again.

### Pages

All of these act on the pages selected in the sidebar (⌘-click to add, ⇧-click for a range), or on the current page if none are selected. They're in **PDF**, in the toolbar's *Pages* menu, and in each thumbnail's context menu.

- Insert a blank page (⌥⌘N) or pages from other PDFs and images (⇧⌥⌘N)
- Duplicate (⌥⌘D) or delete (⌥⌘⌫). Folio won't delete the last page.
- Rotate left (⌘L) or right (⌘R)
- Reorder by dragging thumbnails. Dragging a selected page moves the whole selection.
- Extract to a new PDF (⌥⌘E)

### Recognize text (OCR)

**PDF › Recognize Text** (⌥⌘T) runs Apple's Vision text recognition on the selected pages. **Recognize Text on All Scanned Pages** does every page that has no text yet. Folio adds the recognised words as an *invisible text layer* positioned over the visible ones. The page looks unchanged, but you can now select, copy, search and extract its text, in Folio and in any other PDF reader. One undo step reverts the whole run.

### Print and export

- **Print** with File › Print (⌘P) or the Export menu. This uses the native print panel.
- **Export as Flattened PDF**: a copy with every annotation and form value burned in.
- **Export Pages as PNG / JPEG**: the selected pages (or the current page) at 144 dpi, into a folder you choose.
- **Reduce File Size**: a copy redrawn through macOS's *Reduce File Size* Quartz filter, the same filter Preview uses. Images are downsampled and recompressed. Text stays vector, and annotations and the table of contents are kept.
- **Document Properties** (⌥⌘I): title, author, subject and keywords.

### Tools

These are available without opening the file, from the workspace's Tools view, *File › Tools*, and Finder Quick Actions. They write new files next to the first input and never change the inputs.

| Id | Tool | Output |
| --- | --- | --- |
| `pdf.combine` | Combine PDFs | `Combined.pdf` |
| `pdf.imagesToPDF` | Images to PDF (one page per image, fitted to your paper size) | `<image>.pdf` or `Images.pdf` |
| `pdf.toImages` | PDF to Images (PNG or JPEG, 72/150/300 dpi) | `<name> page N.png` |
| `pdf.split` | Split into single pages | `<name> page N.pdf` |
| `pdf.rotate` | Rotate every page 90° left, right or 180° | `<name> rotated.pdf` |
| `pdf.compress` | Compress (Reduce File Size filter) | `<name> compressed.pdf` |
| `pdf.extractText` | Extract text, with pages separated by form feeds | `<name>.txt` |
| `pdf.pageNumbers` | Add "n of N" at the bottom of every page | `<name> numbered.pdf` |
| `pdf.watermark` | Add a diagonal text watermark (Confidential, Draft, Copy, Sample, Do Not Copy) | `<name> watermarked.pdf` |

## How it works

### Files

```
FolioPDF/
  PDFTools.swift, PDFCommands.swift     Public: tool list, "PDF" menu
  Document/PDFFileDocument.swift        ReferenceFileDocument + PDFAccess lock
  Model/                                PDFEditorModel: every mutation + undo, by area
  Views/                                SwiftUI chrome, FolioPDFView (PDFView subclass), overlay
  Annotations/                          Tools, styles, factory, image stamps, signature store
  Engine/                               Pure, nonisolated, unit-tested operations
```

### Document, snapshots and the lock

The live `PDFDocument` is the model, and `PDFView` renders it directly. Two PDFKit facts shape the save path:

1. `PDFDocument.copy()` is cheap, but **its copies drop every annotation when written**. The same is true of `PDFAnnotation.copy()`.
2. `dataRepresentation()` takes tens to hundreds of milliseconds on large or image-heavy files, too slow for the main thread.

So the snapshot is a handle to the live document behind a recursive lock (`PDFAccess`). `fileWrapper(snapshot:)` serialises off the main thread while holding the lock. Every mutation goes through `PDFEditorModel.mutate`, which takes the same lock, so a save never sees a half-applied edit. The main thread waits only if the user edits during an in-flight save, and only for that save. Exports and thumbnail rendering use the same lock.

Where annotations must be carried to a rebuilt page, use `PDFAnnotation.persistentCopy()`. It rebuilds the annotation from its PDF dictionary, and recreates Folio's image stamps from their bitmap.

### Undo is the save trigger

Autosave runs when the document's undo manager records a change. Every model method registers its inverse with `registerUndo`, and the inverse registers the original again, so redo works. A few cases need care:

- **Drags** (move, resize) change bounds live without undo, then record one step on mouse-up.
- **Inspector sliders** apply live between `beginStyleEdit` and `endStyleEdit`, then record one step.
- **Form fields**: PDFKit edits widget values without telling the undo manager. `FolioPDFView` records a field's value when it's clicked and commits an undo step when editing ends (text end-editing notification, the next click, or the window closing).
- **Typing in a text box or note** records a step per change. That's deliberate: coalescing typing would leave later keystrokes unsaved after an autosave.

### Rewriting page content

PDFKit can't edit content streams, so anything that changes printed content rebuilds the page and swaps it in, keeping the original object for undo:

- `PageFactory.render` records Quartz drawing into a one-page PDF. All new content goes through it.
- `PageRebuilder.rebuild` redraws a page's content, optionally burning in annotations (for Flatten Form) and drawing an overlay on top.
- `Redactor` rasterises the page (`Rasterizer.raster`) with the boxes painted in.
- `TextRecognizer` runs Vision's `RecognizeTextRequest`, then draws each line in text render mode 3 (invisible), sized and horizontally scaled to cover the recognised box.
- `PageStamper` (page numbers, watermark) draws in *display space* through `Geometry.displayToPage`, so text is upright and at the visual bottom on rotated pages.

### Annotations

`AnnotationFactory` turns gestures into standard annotations and converts page-space coordinates into annotation space, which is relative to the bounds origin. `AnnotationKind` decides what can be selected, moved, resized and styled, based on the subtype, so it works for annotations that came with the file too. Note that `PDFAnnotation.type` has no leading slash, unlike `PDFAnnotationSubtype.rawValue`; compare with `PDFAnnotationSubtype.name`.

Images, signatures and stamps are `ImageAnnotation`, a `nonisolated` Stamp subclass whose `draw(with:in:)` paints a bitmap. PDFKit calls it when writing, so the bitmap becomes the annotation's appearance stream and shows in every reader. After reopening, it's a plain Stamp with that appearance.

### Interaction

`FolioPDFView` is a `PDFView` subclass. Rendering, scrolling, text selection, links and form filling stay PDFKit's. The subclass takes the mouse only when a drawing tool is active, or when the pointer is on an annotation in Select mode. Live feedback (the selection outline, handles, ink and shape previews) is drawn in `CanvasOverlay`, a non-interactive view on top. Nothing drawn there is ever part of the document.

`scripts/snapshot.sh` captures windows by asking views to draw themselves, which misses PDFKit's asynchronously rendered page tiles. When `FOLIO_SNAPSHOT_DIR` is set, the overlay paints the visible pages itself so snapshots show real content.

### Performance

- Opening is `PDFDocument(data:)`, which is lazy. A 500-page PDF parses and draws its first window in about 170 ms, as logged by `Opened … parse to first paint` in the `PDF` log category.
- Thumbnails render off the main actor, only for rows on screen, and are cached per page.
- Find uses PDFKit's asynchronous `beginFindString`, so typing never blocks.
- OCR renders on the main actor (milliseconds per page) and runs Vision off it.

### Testing

`Tests/FolioPDFTests` builds every input PDF with Quartz at test time (`Fixtures.swift`), so there are no binary fixtures. The suites cover page operations with undo and redo, redaction (the redacted string is absent from the reopened file's text), OCR, flattening, stamping on rotated pages, image stamps surviving a save, every tool, and the geometry helpers.

## Known limits

- Password-protected PDFs aren't supported yet. Opening one shows an error.
- Ink strokes and lines can be moved but not resized. PDFKit doesn't rescale their paths.
- Text boxes and notes are edited in the inspector, not inline on the page.
- Opacity is stored as the annotation color's alpha. Stamps reopened from a file keep their saved appearance, and their opacity can't be changed.
- OCR assumes upright scans (page rotation 0).
- PDFKit doesn't save outline trees built in code, so Folio never edits the table of contents. Existing outlines are preserved, and *Reduce File Size* rewrites them through Quartz.
