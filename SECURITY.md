# Security

## What Folio does with your files

- Folio makes **no network requests**. There is no analytics, telemetry, crash reporting, account or update check.
- Files are read and written only where you open or save them. Tools write new files next to the files you give them and never modify the originals.
- Signatures you draw are stored in `~/Library/Application Support/Folio/` on your Mac.
- PDF redaction rasterizes the redacted page, so the hidden text and images are actually removed rather than covered. The rest of the page becomes an image too, so text on that page is no longer selectable.

## Sandboxing

Folio runs with the hardened runtime but **without the App Sandbox**. The sandbox would only let Folio write to files you pick in a save panel, which breaks Finder Quick Actions like "Combine PDFs" that save their output next to the inputs. If you'd rather run sandboxed, add `com.apple.security.app-sandbox` and `com.apple.security.files.user-selected.read-write` to `Resources/Folio.entitlements` and rebuild. The editors work, but tools will ask where to save.

## Reporting a vulnerability

Please report security issues privately through [GitHub's private vulnerability reporting](https://github.com/AryanM24/folio/security/advisories/new) rather than in a public issue. Include the macOS version, the Folio version (Folio › About Folio) and, if you can, a file that reproduces the problem. You'll get a reply within a week.

Malformed files are the main attack surface (PDF, docx, xlsx and image parsing). Most parsing is done by Apple frameworks. The XLSX/ODS reader in `Sources/FolioSheets` is Folio's own code, so reports about it are especially welcome.
