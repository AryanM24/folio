# Text & Code editor (`FolioCode`)

Plain text, source code and Markdown. One `NSTextView` with code-editor behavior, a
dependency-free syntax highlighter, and a live Markdown/HTML/SVG preview.

## Features

- **Syntax coloring** for Swift, JavaScript, TypeScript, Java, Kotlin, C, C++, C#, Go, Rust, PHP,
  Python, Ruby, shell, SQL, HTML, XML/plist, SVG, CSS, JSON, YAML, TOML, INI and Markdown.
  The language comes from the file name, then a shebang, then the content type, and can be
  changed from the status bar.
- **Editing:** line numbers, current-line highlight, bracket matching, auto-indent (including
  `{|}` splitting and Python/YAML colons), auto-closing pairs (quotes only in code), Tab and
  Shift-Tab with tabs or spaces, toggle comment, move/duplicate lines, go to line (`line:col`),
  wrap toggle, zoom, show invisibles.
- **Find:** the native find bar (⌘F) plus a regular-expression Find & Replace bar (⌥⌘F) with
  `$1` templates and a one-step Replace All.
- **Files are kept as they were:** encoding (UTF-8, UTF-8 with BOM, UTF-16 LE/BE, Windows Latin 1,
  ISO Latin 1, Mac Roman), line endings (LF, CRLF, CR) and the trailing newline round-trip
  byte for byte. Encoding and line endings can be changed from the status bar (undoable);
  Folio refuses an encoding that can't represent the text instead of losing characters.
- **Markdown:** Editor / Split / Preview (Hero tabs in the toolbar), editor-to-preview scroll
  sync, ⌘B ⌘I ⌘K, export to HTML, PDF and Word, and Print (prints the rendered document).
- **JSON:** format (keeps key order and number spelling), minify, and live validation with the
  error's line and column in the status bar (click it to jump there).
- **HTML / SVG:** preview pane.
- **Status bar:** Ln/Col (tabs expanded), selection length, words and characters, language,
  indentation, encoding, line endings.

## Shortcuts

`CodeCommands` (a "Text" menu) lists them all. The same keys also work inside the editor when the
menu isn't mounted (`CodeTextView.performKeyEquivalent`).

| Command | Keys | Command | Keys |
| --- | --- | --- | --- |
| Toggle comment | ⌘/ | Go to line | ⌘L |
| Indent / outdent | ⌘] / ⌘[ | Find & Replace (regex) | ⌥⌘F |
| Move line up / down | ⌥⌘↑ / ⌥⌘↓ | Bold / italic / link (Markdown) | ⌘B / ⌘I / ⌘K |
| Duplicate line | ⇧⌘D | Format JSON | ⌥⇧⌘F |
| Bigger / smaller / actual size | ⌘+ / ⌘- / ⌘0 | Print | ⌘P |

## Settings

The Settings window's Editor tab: `code.fontSize`, `code.wrapLines`, `code.showLineNumbers`,
`code.tabWidth`. The View toggles in the Text menu write the same keys, plus
`code.showInvisibles`. Changes apply to open windows immediately.

## Tools

| id | What it does |
| --- | --- |
| `code.markdownToPDF` / `code.markdownToHTML` / `code.markdownToDOCX` | Render Markdown files |
| `code.formatJSON` | Pretty-print JSON (2/4 spaces or tabs) |
| `code.convertLineEndings` | Copy with LF or CRLF line endings |
| `code.convertToUTF8` | Copy re-encoded as UTF-8 |

Outputs go next to the input (`name (formatted).json`, `name (CRLF).txt`…), never over it.

## How it works

```
Document/   CodeDocument (ReferenceFileDocument), TextFormat (encodings, line endings), IndentStyle
Syntax/     Token + LexState, GenericLexer + Grammars (C-like, scripts, SQL, JSON, CSS),
            ConfigLexer (YAML/TOML/INI), MarkupLexer (HTML/XML/SVG), MarkdownLexer, Language, LineIndex
Editor/     EditorController (+Commands), CodeTextView, SyntaxHighlighter, LineNumberRuler,
            CodeLayoutManager (invisibles), CodeScrollView, CodeTheme, TextEditing (pure commands)
Markdown/   MarkdownRenderer + MarkdownInline (GFM → sanitized HTML), HTMLPage (Hero CSS)
Formats/    JSONTools, MarkdownExport (+ PrintSupport)
Views/      CodeEditorView, CodeStatusBar, FindReplaceBar (+ GoToLineSheet), PreviewPane
```

- **Text ownership.** The `NSTextStorage` is the source of truth while a window is open.
  Typing never copies the text into the document; `snapshot` copies it once per autosave and
  `fileWrapper` encodes it.
- **Highlighting** is a line-at-a-time state machine (`Lexer`) over UTF-16 buffers. The state
  at each line start is cached; an edit invalidates from the edited line down and the cache
  refills lazily. Only visible lines (plus a screen above and below) are colored, using
  `NSLayoutManager` temporary attributes, so colors never touch undo or the file. Lines over
  20,000 characters stay uncolored.
- **TextKit 1, on purpose.** Non-contiguous layout gives the same lazy, viewport-only layout
  TextKit 2 would, while keeping mature APIs for the gutter (line fragments), invisibles
  (`drawGlyphs`), printing, and drawing in `draw(_:)` (so `scripts/snapshot.sh` captures text).
- **Saving.** SwiftUI's `ReferenceFileDocument` does not mark the window edited from
  NSTextView's undo registrations (verified: typing left it clean and nothing was written, even
  on quit). The controller therefore calls `NSDocument.updateChangeCount(.changeDone)` on every
  text change and on undo/redo of format changes (`EditorController.noteChange`). Also note that
  NSDocument calls `snapshot` on its background writer during autosave, with the main thread
  blocked until it returns; `snapshot` must not assert the main actor.
- **Preview safety.** Markdown never passes raw HTML through (it's escaped), link and image URLs
  are limited to http(s), mailto, relative paths and `data:image/*`, page JavaScript is off, and a
  Content-Security-Policy blocks network loads. Clicked links open in the default browser.

## Performance (Apple silicon, release build)

| Measure | Result |
| --- | --- |
| Open a 10.5 MB Swift file, read to first paint | 357 ms cold, 103–135 ms warm |
| Keystroke in that file (edit + line index + recolor) | 1.6 ms |
| Autosave after typing | file rewritten within ~1 s |

The open time is logged: `log stream --predicate 'subsystem == "app.folio" AND category == "Code"'`.

## Known gaps

- No multi-cursor typing: multiple selections (⌘-drag, ⌥-drag) work as in any text view, and
  editor commands act on the first selection only.
- Preview → editor scroll sync is one-way (editor drives preview).
- Relative images in the Markdown preview don't load (no file read access is granted).
- Fenced code inside the Markdown *source* is one color; the preview colors it by language.
- Wrapped lines aren't indented to their first line's indentation.
- UTF-16 files without a BOM gain one on save. "Reopen with encoding" isn't offered.
- Markdown: no footnotes, no raw HTML passthrough (by design), reference links only by exact label.

## Tests

`make test` runs `Tests/FolioCodeTests`: lexers per language, language detection, encoding and
line-ending round trips, the line index, incremental highlighting vs. a fresh lex, editing
commands, Markdown rendering and sanitizing, JSON format/minify/errors, the file tools, and
Word/PDF export.
