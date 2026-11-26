# Image editor

`Sources/FolioImage` is a Photos and Preview-style editor for PNG, JPEG, HEIC, TIFF, GIF, BMP and WebP files. You can adjust, filter, crop and straighten, resize, mark up, remove the background, select text with Live Text, and export. Every edit can be undone, and saving never stacks up compression loss.

## The model: original + recipe

```
ImageDocument
├── source: SourceImage    original bytes, a ≤2048 px proxy, the full decode (lazy, then kept)
└── recipe: EditRecipe     crop, turns, straighten, flips, resize, adjustments,
                           auto-enhance, filter + strength, cut-out, markup, strip-metadata
```

- The editor never changes pixels. `EditRecipe` is a `Codable`, `Sendable` value. Undo puts the previous recipe back (`ImageDocument.setRecipe(_:actionName:undoManager:)`).
- `RenderPipeline.render` is a pure Core Image function of `(source, recipe, scale)`. It uses one shared `CIContext` on the GPU. The live preview calls it with the proxy. Saving calls it at full resolution inside `fileWrapper`, which runs off the main thread.
- Pipeline order: cut-out → auto-enhance → adjustments → filter → flip, turn, straighten and crop → vignette (framed on the crop) → resize (Lanczos) → markup. Markup goes last so filters never tint it.
- Geometry (`ImageGeometry`) is affine. The same transforms render the image, place markup and map clicks back to source pixels. Markup is stored in source-pixel coordinates, so it stays attached to the content through later turns and crops, as if painted on.
- Auto-enhance is stored as data (`[FilterSpec]`, frozen from `CIImage.autoAdjustmentFilters`). The preview, the saved file and a reopened session therefore always agree.

### Undo and autosave

All changes go through `ImageEditorModel.commit(_:_:)`, which is one undo step. A slider or crop drag uses `live(_:)` while it moves, and `endLive(_:)` records the whole drag as a single step. Text typing works the same way and commits when the field loses focus. A registered undo marks the document dirty, and NSDocument autosaves about a second later.

The document keeps its recipe behind a `Mutex`, not in `@Published`. SwiftUI documents must be `Sendable`, and their `init` and `fileWrapper` run off the main actor. `objectWillChange` fires before every change, so SwiftUI still refreshes.

## Saving

| Situation | What is written |
| --- | --- |
| Nothing changed | The original bytes, untouched |
| Only "Remove location and metadata" | A metadata-only rewrite (`CGImageDestinationCopyImageSource`), no recompression |
| Anything else | A full-resolution render in the file's own format. Metadata is kept and orientation is reset to "up". JPEG quality is 0.92, HEIC 0.85 |
| Cut-out saved as JPEG/BMP | The transparent areas are flattened onto white. Use Export → PNG to keep transparency |
| GIF | The first frame is edited and saved (an unedited GIF keeps all its frames) |
| WebP | macOS can't write WebP, so `writableContentTypes` leaves it out. The editor shows a banner with **Export as PNG**, and `fileWrapper` throws a plain-language error if asked anyway |

Each save renders from the in-memory original, so the tenth autosave of a JPEG has the same quality as the first. `SaverTests.repeatedSavesDoNotCompound` checks that the bytes are identical.

### Continuing to edit after reopening (`EditSessionStore`)

After writing an edited file, Folio also records two things, keyed by the SHA-256 of the exact bytes it wrote:

- the recipe, in `~/Library/Application Support/Folio/Image Sessions/sessions/<hash>.json`
- one pristine copy of the original, in `…/originals/<hash>`

When you open a file whose bytes match a recorded hash, Folio restores the original and the recipe. You can then keep adjusting or choose Reset All without another generation of loss.

**Why not an extended attribute (`app.folio.recipe`)?**

- `ReferenceFileDocument` returns a `FileWrapper`, which can't carry xattrs.
- NSDocument's safe-save copies the old file's xattrs onto the new file, so a recipe stored that way would go stale as soon as another app saved the file.
- Many copy and sync paths strip xattrs.

A content hash can't go stale. If anything else changes the file, the hash no longer matches and Folio opens the new pixels as a fresh original. The hash also survives renames and moves.

Housekeeping and privacy:

- Each save deletes the previous session for that document.
- Sessions are pruned after 30 days, or when originals exceed 2 GB.
- Originals that no session refers to are deleted.
- If "Remove location and metadata" is on, no session is stored, because the pristine copy would still contain the location.

## Features and shortcuts

`ImageCommands` adds an **Image** menu. Its items are disabled unless an image editor is in the key window.

| Command | Shortcut |
| --- | --- |
| Zoom in / out / actual size / fit | ⌘+ ⌘− ⌘0 ⌘9, pinch |
| Rotate left / right | ⌘L ⌘R |
| Flip horizontal / vertical | menu, toolbar, Crop tab |
| Show Adjust / Filters / Crop / Markup | ⌥⌘1 … ⌥⌘4 |
| Auto-enhance | ⌥⌘E |
| Remove background | ⇧⌘K (Preview's shortcut) |
| Live Text | ⌥⌘T |
| Pick color (copies hex, sets markup color) | ⌥⌘C |
| Compare with original | hold **M**, or press and hold the toolbar button |
| Copy image | ⇧⌘C |
| Export… / Info | ⇧⌘E / ⌘I |
| Reset all edits | ⇧⌘R |
| Delete selected markup | ⌫ |

- **Adjust:** exposure, brightness, contrast, highlights, shadows, saturation, vibrance, warmth, tint, sharpness, noise reduction and vignette. Double-click a slider to reset it.
- **Filters:** twelve presets with live thumbnails of the current edit, and a strength slider.
- **Crop:** handles, rule-of-thirds grid, aspect presets (free, original, square, 4:5, 4:3, 3:2, 16:9, 9:16), straighten (±45°, auto-scaled so no empty corners show), rotate, flip, and resize (pixels with a lock, or 25–100 %).
- **Markup:** pen, highlighter, arrow, rectangle, ellipse and text, with color and width. Use Select to pick an item and drag to move it.
- **Info popover:** dimensions, file size, format, color profile, bit depth, camera, lens, exposure, date and location, plus the switch that removes metadata on save.
- **Export popover:** PNG, JPEG, HEIC or TIFF with a quality setting, plus Copy and Share (`NSSharingServicePicker`).

## Tools (`ImageTools.all`)

| id | What it does |
| --- | --- |
| `image.convert` | Saves copies as PNG, JPEG, HEIC or TIFF, with a quality option |
| `image.resize` | Shrinks copies to a maximum long edge (1024–4096 px), with a quality option, using ImageIO's fast thumbnail decode |
| `image.removeBackground` | Writes a transparent PNG of the subject |
| `image.stripMetadata` | Removes GPS, EXIF, IPTC and XMP, losslessly when the format allows |

The pure byte-in, byte-out helpers live in `ImageToolOps` and are tested directly.

## Performance

Measured on this Mac with a release build (`PerformanceTests`, `FOLIO_PERF_IMAGE=<photo.jpg>`), using a 24 MP, 12 MB JPEG with sensor-like noise:

| Step | Time |
| --- | --- |
| Open (session-hash lookup + proxy decode) | 110 ms |
| First preview render | 55 ms |
| One slider frame (exposure + filter) | 26 ms |
| Full decode | 127 ms, in the background after first paint |

When you zoom past the proxy's resolution, a full-resolution preview follows 300 ms after you stop interacting, so dragging stays smooth.

## Testing and checking screens

- `make test` runs the `FolioImageTests` suites: recipe math, geometry, crop math, markup hit-testing, the pipeline, codec round-trips, metadata stripping, saving, sessions, tools and performance.
- In debug builds, `FOLIO_IMAGE_DEMO=crop|filters|markup|edited|cutout|popovers` puts the editor into that state for `scripts/snapshot.sh`. `popovers` also renders the Info and Export popovers to PNG files.

## Known gaps

- Bipolar sliders (−100…100) fill from the left edge, because `HeroSlider` has no centered-fill mode.
- Zoom keeps the visible center, not the point under the cursor.
- Markup text is edited in the inspector, not inline on the canvas.
- Markup items can be moved but not resized.
- Saving an edited multi-frame GIF keeps only the first frame.
- HDR (gain-map) photos are saved as SDR.
