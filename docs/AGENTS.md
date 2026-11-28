# Folio for agents

Folio ships a command-line tool and a local MCP server in one binary, `folio`, inside the app at `Folio.app/Contents/Helpers/folio`. Agents such as Claude Code, Claude Desktop, Cursor and Codex can use it to convert, compress, preview and read files on your Mac. Everything runs in-process with the system's own engines: no installs, no network, and the Folio app doesn't need to be open.

Code: `Sources/FolioAgent/` (shared by the CLI, the MCP server and the app's Settings), `Sources/FolioCLI/main.swift` (entry point), `Sources/Folio/Settings/AgentsSettings.swift` (the Settings pane).

## Set up

The easiest way is **Folio › Settings › Agents**, which has a Connect button per client. It shows what will change and asks before changing anything. The same thing from Terminal:

```sh
F=/Applications/Folio.app/Contents/Helpers/folio
$F connect claude           # Claude Code: runs `claude mcp add --scope user folio -- $F mcp`
$F connect claude-desktop   # merges mcpServers.folio into claude_desktop_config.json
$F connect cursor           # merges mcpServers.folio into ~/.cursor/mcp.json
$F connect codex            # runs `codex mcp add`, or appends [mcp_servers.folio] to ~/.codex/config.toml
$F connect cursor --print   # show the change without making it
$F install                  # link ~/.local/bin/folio so `folio` works in Terminal
```

JSON edits change only the `folio` entry, keep a `.folio-backup` copy and are written atomically. Restart the client afterwards.

**Claude Code plugin.** The repository is also a plugin marketplace. The plugin adds the server (expecting Folio in `/Applications`) and a short skill on when to use it:

```
/plugin marketplace add AryanM24/folio
/plugin install folio@folio
```

**Any other client.** Register a stdio server with the absolute path: command `/Applications/Folio.app/Contents/Helpers/folio`, args `["mcp"]`. GUI apps don't inherit your shell's `PATH`, so a bare `folio` won't work there. Keep Folio in Applications: a copy run from Downloads gets a random, temporary path.

## MCP tools

The server speaks MCP `2025-11-25` (and accepts `2025-06-18` and `2025-03-26`) over newline-delimited JSON-RPC on stdin/stdout. It answers `initialize` in about 25 ms (`make mcp-check`). Every tool has an `outputSchema`, returns `structuredContent` plus a text block, and is annotated `destructiveHint: false`. Long calls send `notifications/progress` when the request carries `_meta.progressToken`, and `notifications/cancelled` stops a call.

| Tool | Does | Read-only |
|---|---|---|
| `folio_inspect` | What each file is, its key facts, every format it can become (with fidelity) and the `folio_run` tools that accept it | yes |
| `folio_convert` | Convert or compress files; batch up to 500 | no |
| `folio_run` | Run a catalog tool: combine, split, rotate, number or watermark PDFs; resize, cut out or strip images; merge CSVs; make GIFs; format JSON… | no |
| `folio_extract` | A document, PDF or spreadsheet as Markdown or text, paginated | yes |
| `folio_preview` | A PNG (≤ 768 px) of a PDF page, image, video frame or document | yes |
| `folio_formats` | Every supported pair, the quality levels and the tool ids | yes |

### `folio_convert`

```json
{"paths": ["/Users/me/Desktop/report.docx"], "to": "pdf", "quality": "balanced"}
```

Arguments: `paths` (required), `to` (omit to compress in the same format), `quality` (`lossless` | `balanced` | `small`, default `balanced`), `max_bytes`, `max_dimension`, `output_dir` (default: next to each input), `on_conflict` (`rename` | `skip` | `fail`, default `rename`), `strip_metadata`, `verify`, `dry_run`.

```json
{
  "results": [{
    "input": "/Users/me/Desktop/report.docx", "output": "/Users/me/Desktop/report.pdf",
    "status": "ok", "fidelity": "visually_lossless", "method": "render",
    "bytes_in": 482113, "bytes_out": 391022, "ratio": 0.811, "duration_ms": 412,
    "details": {}, "verification": {"passed": true, "checks": ["opens", "pages=12"], "metrics": {}},
    "dropped": [], "warnings": []
  }],
  "summary": {"ok": 1, "failed": 0, "skipped": 0, "bytes_in": 482113, "bytes_out": 391022, "duration_ms": 415}
}
```

`status` is `ok`, `skipped`, `failed` or `planned` (dry run). A failed item carries `error: {code, message, hint, alternatives}`. The call sets `isError` only when every item failed. `quality: "lossless"` never degrades silently: it fails with `LOSSLESS_UNAVAILABLE` and lists the lossless targets.

Error codes: `NOT_FOUND`, `UNSUPPORTED_INPUT`, `UNSUPPORTED_PAIR`, `LOSSLESS_UNAVAILABLE`, `SIZE_UNREACHABLE`, `OUTPUT_EXISTS`, `PATH_NOT_ALLOWED`, `ENCRYPTED`, `CORRUPT_INPUT`, `TOO_LARGE`, `VERIFICATION_FAILED`, `CANCELLED`, `INTERNAL`.

### `folio_run`

```json
{"tool": "pdf.rotate", "paths": ["/Users/me/scan.pdf"], "options": {"degrees": "90"}}
```

Same `{results, summary}` shape. Each output gets its own result; `details.tool` names the tool, and when several inputs make one output (combine), `details.inputs` lists them all. Options and their choices come from the tool catalog (`folio tools --json`), so they can't drift from the app.

### `folio_extract`

```json
{"path": "/Users/me/contract.pdf", "format": "markdown", "pages": "1-5", "max_chars": 40000}
```

```json
{"path": "/Users/me/contract.pdf", "format": "markdown", "text": "# Agreement…", "chars": 40000,
 "total_chars": 93120, "offset": 0, "truncated": true, "next_offset": 40000, "untrusted_content": true}
```

`max_chars` defaults to 40,000 and is capped at 80,000, which keeps a page under Claude Code's output limit. In `content`, the text is wrapped in `<file-content path="…" untrusted="true">…</file-content>`.

### `folio_preview`

```json
{"path": "/Users/me/report.pdf", "page": 3, "max_dimension": 512}
```

Returns an `image` content block (PNG) and `{"path", "width", "height", "source": "page 3 of 12", "bytes"}`. PDFs render with PDFKit, video frames (`time_s`) with AVFoundation, everything else with Quick Look, falling back to ImageIO for images.

### `folio_inspect` and `folio_formats`

```json
{"paths": ["/Users/me/clip.mov"]}
```

```json
{"files": [{"path": "/Users/me/clip.mov", "kind": "video", "format": "mov", "uti": "com.apple.quicktime-movie",
  "bytes": 81234567, "meta": {"duration_s": 42.1, "width": 1920, "height": 1080},
  "targets": [{"to": "mp4", "fidelity": "lossless", "lossless_available": true, "drops": []}],
  "tools": ["media.extractAudio", "media.convertMP4", "media.compress", "media.makeGIF"]}]}
```

`folio_formats` takes no arguments and returns `{pairs: [{from, to, fidelity, lossless_available, drops}], qualities, tools, version}`.

## CLI

Each command calls the same code as its MCP tool, and `--json` prints exactly that tool's `structuredContent`.

```
folio convert <files…> [--to FMT] [--quality lossless|balanced|small] [--max-bytes 25MB]
              [--max-dimension PX] [--out DIR] [--on-conflict rename|skip|fail]
              [--strip-metadata] [--verify|--no-verify] [--dry-run] [--json]
folio inspect <files…> [--json]
folio run <tool> <files…> [--opt key=value …] [--out DIR] [--dry-run] [--json]
folio extract <file> [--markdown|--text] [--pages 1-5] [--sheet NAME] [--offset N] [--max-chars N] [--json]
folio preview <file> [--page N] [--time S] [--max-dimension PX] [--out FILE.png] [--json]
folio formats [--json]
folio tools [--json]
folio mcp
folio connect claude|claude-desktop|cursor|codex [--print]
folio install
folio --version
folio <command> --help
```

Human output is one line per file:

```
report.docx → report.pdf  482 KB → 391 KB  visually lossless  0.4 s ✓
```

Exit codes: `0` all done, `1` some items failed, `2` usage error, `3` nothing done, `130` cancelled (Ctrl-C). Progress goes to stderr, and only when stderr is a terminal.

## Security model

Folio is built so that an agent that has been prompt-injected still can't use it to do harm.

- **No destructive tools.** There is no delete, move, rename, overwrite, shell, URL fetch or "open in app". Every write creates a new file with a free name; inputs are never modified.
- **Allowed folders.** Every input and output folder is checked before use. If the client provides MCP roots, those are the allowed folders. Otherwise: the working folder, your home folder, `/Volumes` and `/tmp`, plus any folders in `FOLIO_ALLOWED_DIRS` (colon-separated).
- **Always denied,** whatever the roots say: `~/Library` (except `~/Library/Mobile Documents`, which is iCloud Drive), `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config`, `~/.kube`, `~/.docker`, keychains, `/System`, `/usr`, `/etc`, `/bin` and `/sbin`. Writes inside any `.git` folder are denied too.
- **No path tricks.** Paths are resolved with `realpath` (following every symlink, including in output folders that don't exist yet) before they're checked, and compared by path component, case-insensitively. A symlink pointing out of an allowed folder, `..`, and a sibling like `/Users/me/Docs-evil` next to an allowed `/Users/me/Docs` are all refused. The resolved path is what gets used, not the string that was checked.
- **File content is data.** `folio_extract` fences text as untrusted and defuses closing tags inside it; the tool description tells the model not to follow instructions in it.
- **Bounded output.** At most 500 files per call, extract pages of at most 80,000 characters, previews of at most 768 px.
- **Clean stdout.** In `mcp` mode the process keeps a private copy of stdout for JSON-RPC and points file descriptor 1 at stderr, so a stray log line can't corrupt the protocol.
- **Config edits need consent.** `connect` shows the change first (`--print` shows only that), backs files up, writes atomically and touches only the `folio` key.
