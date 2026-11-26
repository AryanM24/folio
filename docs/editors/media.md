# Audio & Video (FolioMedia)

A QuickTime-style player that never changes your file. Trims, rotations, re-encodes and GIFs are always written to a **new** file.

## How it opens files

Media files can be gigabytes, so `MediaDocument` holds no data. `init(configuration:)` doesn't read the file. `MediaEditorView` gets the URL from `@Environment(\.documentConfiguration)` and AVFoundation streams it from disk. Details, waveform and filmstrip load in `.task` after the window is on screen.

Measured on a 2.1 GB ProRes 422 HQ `.mov` (M-series Mac, debug build):

| | |
| --- | --- |
| Document init → window content ready | 23–25 ms (logged by the module) |
| `open` → content ready, including cold app launch | 363–400 ms |
| Resident memory after opening | ~140 MB |

To measure it yourself, run `log stream --predicate 'subsystem == "app.folio" AND category == "Media"'` and open a file. Look for "content ready … ms".

**Mounting:** `DocumentGroup(viewing: MediaDocument.self) { MediaEditorView(document: $0.document) }`. The type also works in an editable group. It never registers undo, so it's never dirty and never autosaves. `fileWrapper` returns the original file unchanged when AppKit has one (`configuration.existingFile`), for example on Duplicate. Otherwise it throws a plain-language error.

## Window

- **Player:** `AVPlayerView` with floating controls for video and inline controls for audio. AVKit provides Picture in Picture, AirPlay, chapters, subtitle and audio-track menus, full screen, timecodes and the trim bar.
- **Audio files:** a waveform card. Click to seek, drag to select. The waveform is computed off the main thread with `AVAssetReader` (mono, 8 kHz, 2000 peaks) and cached in `~/Library/Caches/app.folio/Waveforms`. The cache key is the file's path, size and modification date.
- **Video files:** a filmstrip of 12 thumbnails under the player. Click one to jump there.
- **Inspector (Hero surface):** duration, size, overall bitrate, codecs, resolution after rotation, frame rate, channels, sample rate, creation date and location (ISO 6709 metadata). Below those: Selection, Edits and Export.
- **Status bar:** the selection, a note when edits are pending, and "Saved … · Show in Finder" after an export.
- **Progress HUD** for every export, with Cancel (also Esc). A cancelled or failed export leaves no file behind and never replaces an existing one. Output is written to a temporary file on the same volume and swapped in at the end.

## Keyboard

| Key | Action |
| --- | --- |
| Space | Play/pause |
| J / K / L | Shuttle back / stop / forward. Press again for 2×, 4×, 8×. |
| ← / → | Step one frame (`AVPlayerItem.step(byCount:)`) |
| I / O | Set the in or out point |
| ⌘T | Trim with handles (AVPlayerView's trim bar). Clicking Trim makes the handles the selection. |
| ⇧⌘E | Export… |

The player view handles the plain keys. They aren't menu key equivalents, so other editors keep their keys. The **Media** menu (`MediaCommands`) lists every command with its key in the title.

The selection also limits playback (`forward/reversePlaybackEndTime`), so what you hear is what you export.

## Export

| Format | How |
| --- | --- |
| Original quality | `AVAssetExportPresetPassthrough`. Lossless and as fast as a copy. Keeps the source's container when it can; otherwise `.mov`/`.m4a`, chosen by asking the session. |
| HEVC 4K / 1080p | `AVAssetExportPresetHEVC3840x2160` / `HEVC1920x1080` → `.mp4` |
| H.264 4K / 1080p / 720p / 480p | `AVAssetExportPreset3840x2160` / `1920x1080` / `1280x720` / `640x480` → `.mp4` |
| ProRes 422 | `AVAssetExportPresetAppleProRes422LPCM` → `.mov` |
| Audio only, M4A | `AVAssetExportPresetAppleM4A` |
| Audio only, WAV | `AVAssetReader` → 16-bit PCM → `AVAssetWriter(.wav)`, because no export preset writes WAVE |

Every export uses the selection, or the whole file when there's none. Without edits, the source asset is exported directly, which keeps chapters, subtitles and all metadata.

### Edits (applied on export)

| Edit | Status |
| --- | --- |
| Rotate left/right, flip horizontal/vertical | Done, and lossless. It sets the composition track's `preferredTransform`, re-anchored to the origin, so passthrough keeps the original frames. |
| Remove audio | Done, and lossless. Audio tracks are left out of the composition. Previewed live (player muted). |
| Speed 0.5× / 1.5× / 2× | Done with `AVMutableComposition.scaleTimeRange`. Audio uses the spectral pitch algorithm. Passthrough can't retime audio, so "Original quality" re-encodes at `HighestQuality` when speed ≠ 1. Previewed live (`player.defaultRate`). |

With edits, the export comes from a composition, so chapters and subtitle tracks are dropped. The source's metadata (creation date, location…) is copied onto the output.

Rotation and flips aren't previewed in the player.

### Frames

- **Save frame:** `AVAssetImageGenerator` with zero tolerance (the exact frame, not the nearest keyframe), at full resolution and with the track transform applied. Saved as PNG.
- **Make GIF:** 15 fps, 480 px wide, from the selection, written with `CGImageDestination`. Each delay is the difference of rounded cumulative times, so a 15 fps GIF stays in sync instead of drifting 5 %. Above 450 frames, frames are spread across the range rather than dropped.

## Tools (`MediaTools.all`)

| id | What it does |
| --- | --- |
| `media.extractAudio` | Video → M4A or WAV (option) |
| `media.convertMP4` | Any movie → H.264 MP4 (up to 4K, never upscaled) |
| `media.compress` | 1080p HEVC, 720p H.264 or 480p H.264 (option) |
| `media.makeGIF` | The first 450 frames at 10/15/24 fps, 320/480/640 px (options) |

Not built: **trim silence**. It needs a threshold UI and a non-destructive preview to be safe. The waveform peaks already exist, so it's a reasonable next step.

## Code map

| File | What |
| --- | --- |
| `MediaDocument.swift` | The empty document and the viewer contract |
| `MediaEditorView.swift` | Window layout, HUD overlay, focused value for commands |
| `MediaController.swift` | Per-window state and actions; `Shuttle` rates |
| `PlayerView.swift` | `AVPlayerView` wrapper, keyboard map (`PlayerKey`) |
| `InfoSidebar.swift` | Inspector; `InfoFormat` number formatting |
| `WaveformView.swift` | Waveform, filmstrip, export HUD views |
| `MediaInfo.swift` | Header-only metadata loading, codec names, ISO 6709 |
| `ExportSettings.swift` | Formats → presets/containers, `MediaEdits`, `MediaMath` (transforms, ranges, timecodes) |
| `MediaExport.swift` | Composition building, export session, WAV writer, atomic output |
| `Waveform.swift` | `PeakAccumulator` and the cached reader |
| `Frames.swift` | Still frames, filmstrip, `GIFTiming`, `GIFMaker` |
| `MediaCommands.swift` | The Media menu |
| `MediaTools.swift` | Tools |

## Tests

`Tests/FolioMediaTests` has 33 tests. Pure logic is covered: preset and container mapping, transforms, speed scaling, range clamping and in/out points, timecodes, waveform downsampling (batch and streaming), GIF timing, codec and location parsing, the shuttle and the key map. End-to-end tests run on media generated in the test (an H.264 clip via `AVAssetWriter`, a sine WAV via `AVAudioFile`): passthrough trim, lossless rotation, 2× speed, WAV and M4A export, the error for exporting audio from a silent video, GIF frame count and delay, and still-frame resolution.

## Known gaps

- Snapshots can't render AVKit's layer-hosted controls faithfully, so the player looks black or washed out in `scripts/snapshot.sh` output. Check the controls live.
- Rotation and flips aren't previewed in the player.
- Exports run one at a time per window. A second export is disabled while the HUD is up.
