# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-27

### Added
- **Convert anything it opens.** A shared conversion engine (`FolioConvert`) for PDFs, documents, spreadsheets, images, audio and video, with three qualities: lossless, balanced and small. Lossless results are verified, compressed copies that aren't smaller are discarded, originals are never overwritten, and every result reports sizes, time and fidelity.
- The Convert panel (⇧⌘C, the context menu, ⌘K, or ⌥-drop on the Dock icon), Finder Quick Actions *Convert with Folio…* and *Compress with Folio*, a menu-bar drop shelf, and a result card you can drag, copy, open or undo.
- **`folio`**, a command-line tool and local MCP server bundled at `Folio.app/Contents/Helpers/folio`: `convert`, `inspect`, `extract`, `preview`, `run`, `formats`, `tools`, `mcp`, `connect` and `install`.
- *Settings › Agents* connects Claude Code, Claude Desktop, Cursor and Codex in one click. The repository is also a Claude Code plugin marketplace.
- `make bench` (timed against `sips`, `afconvert` and `avconvert`), `make mcp-check` and `make site-data`.
- A redesigned landing page.

### Fixed
- Video compression no longer uses export presets that could make files several times larger than the source.

### Security
- The MCP server only reads and writes inside allowed folders (realpath-resolved, compared by component) and always refuses `~/Library`, `~/.ssh` and other sensitive locations. HTML is sanitized with an allowlist and loaded behind a Content-Security-Policy, so converting it never touches the network.

## [0.1.0] - 2026-11-26

### Added
- Native macOS app built with Swift 6.2, SwiftUI and AppKit, with one editor module per file type: PDF, documents, spreadsheets, images, text and code, audio and video.
- The Folio workspace, the app's home window: a sidebar of Home, Recent, Favorites, Tools, the library folder (~/Documents/Folio) and added locations; one-click new files saved straight into the library; Recent from Open Recent and Spotlight; favorites as a Finder tag; live folder views with Quick Look thumbnails, search, kind filters, sorting and grid or list; Finder-style selection, Quick Look, rename, duplicate, move, share, Move to Trash with Undo, drag and drop; a ⌘K command palette and a Go menu.
- File tools in the workspace's Tools view, in each file's context menu, under *File › Tools*, and as Finder Quick Actions.
- Autosave about a second after each edit, with Versions history.
- A SwiftUI port of the HeroUI v3 design system (`FolioKit/Design`).
- Landing page in `site/`.

### Removed
- The earlier browser-based editor. Folio is now a Mac app.

[Unreleased]: https://github.com/AryanM24/folio/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/AryanM24/folio/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/AryanM24/folio/releases/tag/v0.1.0
