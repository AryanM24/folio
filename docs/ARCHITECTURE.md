# Architecture

Folio is a native macOS app written in Swift 6 with SwiftUI and AppKit. It edits PDFs, rich-text documents, spreadsheets, images, plain text and code, and audio/video. This page explains how the pieces fit together and the rules every module follows.

## Goals, in priority order

1. **Never lose an edit.** Changes are saved about a second after you stop typing, written atomically, and kept as Versions you can browse in *File › Revert To*.
2. **Open and quit in under a second.** Measured by `make launch-time`. Nothing heavy runs before the first window draws.
3. **Feel native.** Use the system's own engines (PDFKit, the Cocoa text system, Core Image, AVFoundation, Vision) rather than reimplementing them. Menus, shortcuts, Undo, Find, Services, tabs and full screen behave like every other Mac app.
4. **Look like Folio.** One design language, a SwiftUI port of HeroUI. See [DESIGN.md](DESIGN.md).

## Package layout

```
Package.swift
Sources/
  Folio/          App target: scenes, the workspace window, Settings, menus, tool runner, Services
  FolioKit/       Shared by every module: FileKind, FolioTool, Exporter, Log, Hero design system
  FolioPDF/       PDF editor (PDFKit) and PDF tools
  FolioDocs/      Rich-text editor (NSTextView: docx, rtf, rtfd, odt, html, doc)
  FolioSheets/    Spreadsheet editor, formula engine, CSV/TSV/XLSX/ODS codecs
  FolioImage/     Image editor (Core Image) and image tools
  FolioCode/      Plain text, Markdown and source code editor
  FolioMedia/     Audio and video player, trimming and export (AVFoundation)
  FolioArchive/   Archive viewer: browse and extract zip, tar, 7z, rar, iso (libarchive)
  FolioPreview/   Read-only Quick Look window for files Folio can't edit (iWork, PowerPoint, fonts, 3D)
  CArchive/       Module map and hand-written header for the system libarchive (the SDK has no headers)
  FolioConvert/   The conversion engine: one converter per file family, no UI
  FolioAgent/     The `folio` CLI, the MCP server, path policy and agent setup
  FolioCLI/       `main.swift` for the `folio` binary (bundled as Contents/Helpers/folio)
Tests/<Module>Tests/   Swift Testing suites, one per module
Resources/        Info.plist (document types, Services), entitlements
scripts/          bundle.sh, make-icon.swift, snapshot.sh, launch-time.sh
site/             Landing page deployed to Vercel
docs/             This folder
```

`FileKind` (FolioKit) lists the content types each editor opens; `Resources/Info.plist` declares the same ones (and imports the types macOS leaves dynamic, like `.mkv` and `.srt`). `make check-plist` fails when the two drift.

Each editor is its own module so it can be built, tested and reviewed alone. Editor modules depend only on `FolioKit`, never on each other. `FolioConvert` reuses the document, spreadsheet and Markdown codecs; `FolioAgent` and the app sit on top of everything.

## The document model

Every editor follows the same contract:

```swift
public final class XDocument: ReferenceFileDocument {        // FolioX/XDocument.swift
    public nonisolated static var readableContentTypes: [UTType] { FileKind.x.readableTypes }
    public nonisolated init()                                  // new, empty document
    public nonisolated init(configuration: ReadConfiguration) throws
    public func snapshot(contentType: UTType) throws -> Snapshot
    public nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper
}
public struct XEditorView: View { public init(document: XDocument) }
public enum XTools { public nonisolated static let all: [FolioTool] }
```

The app target registers one `DocumentGroup` per editor (`Sources/Folio/FolioApp.swift`). **Order matters:** when a file matches more than one group (a CSV is also plain text), SwiftUI uses the group declared last. So the Text & Code catch-all is declared first and the specific editors after it. Check routing with `scripts/snapshot.sh` whenever you add types. SwiftUI backs each group with an `NSDocument`, which provides:

- **Autosave in place.** `AppDelegate` sets `NSDocumentController.autosavingDelay` to 1 s.
- **Atomic writes.** The file wrapper is written to a temporary file and swapped in, so a crash mid-save never corrupts the original.
- **Versions, window tabs, iCloud Drive, Recent Items, and the "edited" dot in the close button.**

### How a change gets saved

Autosave fires when the document's `UndoManager` records a change. So **every mutation must go through the undo manager**:

- AppKit views wired to the window (`NSTextView`, `PDFView` annotations) register undo themselves. Make sure they use the window's undo manager, which is the document's.
- For your own model changes, register an undo action:

  ```swift
  func setCell(_ ref: CellRef, to value: String, undoManager: UndoManager?) {
      let old = cells[ref]
      cells[ref] = value
      undoManager?.registerUndo(withTarget: self) { doc in
          doc.setCell(ref, to: old ?? "", undoManager: undoManager)
      }
  }
  ```

  Get the undo manager with `@Environment(\.undoManager)` in SwiftUI, or `view.undoManager` in AppKit.

### Snapshots: off the main thread, with the main thread parked

During autosave, AppKit calls `snapshot(contentType:)` on a **background save thread**, while it keeps the main thread parked until the snapshot is taken (`NSDocument.unblockUserInteraction`). Then `fileWrapper(snapshot:configuration:)` encodes the snapshot on that save thread while you keep editing.

So:

- Declare `snapshot` as `nonisolated`, and read your main-actor state inside `readDuringSave { … }` (FolioKit). It's race-free because the main thread is parked. Don't use `MainActor.assumeIsolated`, which traps on the save thread, or `DispatchQueue.main.sync`, which deadlocks.
- Keep `snapshot` to a cheap copy, such as value types or an immutable copy, and do the slow encoding (PDF serialization, XLSX zipping, image encoding) in `fileWrapper`.
- Check saving in the real app: edit a file and confirm it changes on disk about a second later.

### Large files

`init(configuration:)` reads the bytes and parses only what the first screen needs. Defer the rest (page thumbnails, syntax highlighting past the viewport, video thumbnails) until after first paint with `.task {}`.

## The workspace

The workspace (`Sources/Folio/Workspace/`) is the app's home window: a single `Window` scene, opened at launch unless *Settings › General* turns it off. It manages files the Mac way, with no private database:

- **Library.** New files are written to disk before they open, in the library folder (`~/Documents/Folio` by default, changeable in Settings) with Finder-style unique names. Each editor module provides its empty file (`RichTextDocument.emptyFileData()`, `SpreadsheetDocument.emptyFileData()`, `PDFFileDocument.emptyFileData()`).
- **Recent** merges *Open Recent*, a Spotlight query (`kMDItemLastUsedDate` within 30 days, Folio's content types) and recently changed library files. **Favorites** are the Finder tag "Folio Favorite", found with Spotlight. **Locations** are folders the person adds, stored as bookmarks.
- **Folder views** list one level, off the main thread, and stay live through a kqueue watcher (`FolderWatcher`). Thumbnails come from Quick Look, lazily per visible card, cached in memory.
- `WorkspaceModel` (`@Observable`, one per app) holds navigation, lists, selection and every file action; menus reach it through `FocusedValues.workspace`. Pure logic (search, fuzzy matching, sorting, filters, dates, rename rules) lives in `WorkspaceLogic.swift` and is tested in `Tests/FolioTests`.
- `FOLIO_LIBRARY_DIR` points the library at another folder and keeps Recent and Favorites inside it, so tests and `scripts/snapshot.sh` never touch real files.

Launch rule: the window draws from in-memory state first; Spotlight, listings and thumbnails start after the first frame and stream in.

## Concurrency

UI modules use Swift 6.2's `defaultIsolation(MainActor.self)`, so types are main-actor isolated unless they opt out. Pure logic (formula engine, codecs, geometry) is marked `nonisolated` and `Sendable`, and is unit-tested without a UI. Expensive work runs in `Task.detached` or `nonisolated async` functions and hops back to the main actor to publish results.

## Tools and Quick Actions

A `FolioTool` (FolioKit) is a one-shot operation such as combining PDFs or converting images. Modules declare tools in `XTools.all`. The app surfaces them in:

- the workspace's Tools view and each file's *Tools ›* context menu,
- *File › Tools*,
- Finder › Quick Actions and the Services menu. `scripts/bundle.sh` runs `Folio --services-json` and writes one `NSServices` entry per tool into the built app's Info.plist, so adding a tool to `XTools.all` is all it takes. `NSUserData` is the tool's `id`, and `AppDelegate.runTool` dispatches it.

Tools never modify their inputs. They write new files next to the first input with `FolioTool.outputURL(nextTo:name:ext:)` and return the URLs. Folio then reveals them in Finder.

## The conversion engine

`FolioConvert` turns one file into another, for the Convert panel, the menu-bar shelf, Finder's Quick Actions, the `folio` CLI and the MCP server alike. Nothing in it touches UI, and nothing defaults to the main actor.

- **Contract** (`Model.swift`, `Engine.swift`, `Format.swift`). A request names inputs, a target `Format` and a `Quality` (`lossless`, `balanced` or `small`), plus an optional size budget, maximum dimension and output folder. Every input gets a `ConvertResult` with sizes, time, a `Fidelity` label, what was dropped, a verification and a stable error code. The same structs are the CLI's `--json` and the MCP `structuredContent`.
- **The engine owns the rules.** It routes by source family, refuses `lossless` when the pair can't be (`LOSSLESS_UNAVAILABLE`, with lossless alternatives), writes to a temporary file in the destination, moves it into a free Finder-style name (never overwriting), throws away compressed copies that aren't at least 2 % smaller, and enforces size budgets.
- **Every family has a converter.** `Engine.converter(for:)` throws `UNSUPPORTED_INPUT` rather than trapping. Formats that need their own reader route from their family's converter to a file of their own (`Video+Matroska.swift`, `Documents+Ebook.swift`, `Sheets+Import.swift`…), so each can grow without touching the shared files.
- **Converters own the craft.** One `FamilyConverter` per family: `ImageConverter` (ImageIO, re-encoding straight from the source, thumbnail decoding for downscales), `PDFConverter` (Quartz filters per quality, parallel page rendering), `DocumentFamilyConverter` (the Cocoa text system and Folio's Markdown renderer), `SheetConverter` (Folio's spreadsheet codecs), `AudioConverter` (AVAudioFile) and `VideoConverter` (passthrough first, then hardware HEVC with decode-time scaling and a frame-rate cap).
- **Verification.** Lossless results are checked after writing: decoded pixels, audio samples (or a hash of what was written, since AAC decoding isn't deterministic), compressed video samples, cell values and text.
- **Scheduling.** A small actor limits work per resource: one job per core for CPU codecs, three for the hardware HEIC encoder, one video encode at a time, eight passthrough jobs.
- **Main thread.** HTML import and PDF printing need the main thread, so the converter hops there. The `folio` binary keeps `RunLoop.main` running for this; `dispatchMain()` would exit the real main thread and AppKit would refuse.
- **No network.** HTML is sanitized with an allowlist (relative, fragment and `data:` URLs only) and loaded behind a Content-Security-Policy that blocks every request.

## Agents: the `folio` CLI and MCP server

`FolioAgent` is shared by the `folio` binary and the app's *Settings › Agents*. One binary is both the CLI and a stdio MCP server (`folio mcp`); the JSON-RPC layer is hand-written with Foundation, so it adds no dependencies and answers `initialize` in about 12 ms. Every path goes through `PathPolicy` (resolved with `realpath`, compared by component, sensitive folders always denied). See [AGENTS.md](AGENTS.md).

## Sandboxing

Folio is not sandboxed, because tools write results next to the files you pass them. The hardened runtime is on, and Folio makes no network requests. See [SECURITY.md](../SECURITY.md).

## Logging

Use `Log.make("<Module>")` (an `os.Logger`). Mark file names `privacy: .private`. Stream with:

```sh
log stream --predicate 'subsystem == "app.folio"'
```

## Building without Xcode

The repo needs only the Swift toolchain (Xcode or the Command Line Tools).

| Command | What it does |
| --- | --- |
| `make build` | Compile every module (debug) |
| `make test` | Run all Swift Testing suites |
| `make run` | Build `build/Folio.app` (debug) and open it |
| `make app` | Release build of `build/Folio.app` |
| `make launch-time` | Check the < 1 s launch and quit budgets |
| `scripts/snapshot.sh file…` | Open files and save a PNG of each window to `build/snapshots/` |

Xcode users can open `Package.swift` directly.
