# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Native macOS app built with Swift 6.2, SwiftUI and AppKit, with one editor module per file type: PDF, documents, spreadsheets, images, text and code, audio and video.
- The Folio workspace, the app's home window: a sidebar of Home, Recent, Favorites, Tools, the library folder (~/Documents/Folio) and added locations; one-click new files saved straight into the library; Recent from Open Recent and Spotlight; favorites as a Finder tag; live folder views with Quick Look thumbnails, search, kind filters, sorting and grid or list; Finder-style selection, Quick Look, rename, duplicate, move, share, Move to Trash with Undo, drag and drop; a ⌘K command palette and a Go menu.
- File tools in the workspace's Tools view, in each file's context menu, under *File › Tools*, and as Finder Quick Actions.
- Autosave about a second after each edit, with Versions history.
- A SwiftUI port of the HeroUI v3 design system (`FolioKit/Design`).
- Landing page in `site/`.

### Removed
- The earlier browser-based editor. Folio is now a Mac app.
