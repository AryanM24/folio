# Folio

A local-first PDF editor on an infinite canvas. Open a PDF, then annotate, sign, redact, rearrange and merge pages, with Miro-style sticky notes, shapes and arrows around them. Everything is stored in your browser (IndexedDB). There is no server and no account.

## Features

- **Canvas**: pan (space-drag, trackpad), pinch or ⌘-scroll zoom, dot grid, zoom to fit, marquee select, move, resize, alt-drag to duplicate, lock, layer order, undo/redo
- **Tools**: pen, highlighter, eraser, text, sticky notes, rectangle, ellipse, line, arrow, image (pick, paste or drop), saved signature
- **Redaction**: pages with a redaction are rasterised on export, so the covered text is actually removed
- **Pages**: thumbnails, drag to reorder, rotate, duplicate, delete, insert blank, append another PDF, extract pages
- **Find in PDF** with match navigation
- **Export**: flattened PDF (vector text kept where possible), current page as PNG

## Shortcuts

V select · H hand · P pen · M highlighter · E eraser · T text · N sticky · R rect · O ellipse · L line · A arrow · X redact · I image · S signature
⌘Z / ⇧⌘Z undo/redo · ⌘C/⌘V/⌘D copy/paste/duplicate · ⌘A select all · ⌫ delete · arrows nudge · [ ] layer order · ⇧1 fit · ⌘0 100% · ⌘F find · ⌘S export

## Stack

Vite, React 19, [HeroUI v3](https://heroui.com), pdf.js (render and search), pdf-lib (export), idb-keyval.

```bash
npm install
npm run dev
```
