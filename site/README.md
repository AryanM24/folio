# Folio landing page

A single static page: plain HTML, one stylesheet and a little vanilla JavaScript. No framework, no build step, no web fonts.

## Files

| File | What it is |
| --- | --- |
| `index.html` | The page. Sections: hero, editors, Mac features, privacy, open source, footer. Icons are an inline SVG sprite at the top of `<body>`. |
| `styles.css` | All styling. Tokens at the top mirror [`docs/DESIGN.md`](../docs/DESIGN.md) (the HeroUI v3 port), with dark values for `prefers-color-scheme` and for `data-theme="dark"`. |
| `main.js` | Theme toggle (saved in `localStorage["theme"]`), the copy button, and the hero screenshot swap. |
| `favicon.svg` | The app icon, same geometry as `scripts/make-icon.swift`. Also used as the header logo. |
| `assets/` | Images you supply (see below). |

## Images to add

- **`assets/hero.png`**: a screenshot of the Welcome window (about 1620 × 960, 2×). When the file exists, `main.js` swaps it in for the HTML/CSS mock of the window; until then the mock shows. The same file is the Open Graph image.
- Once the production domain is known, make the `og:image` URL in `index.html` absolute (social crawlers ignore relative URLs).

## Design rules carried over from the app

- Colors come only from the tokens in `styles.css`. Two additions exist for contrast and are commented: `--muted-on-bg` (muted text on the page background) and `--accent-fill` (filled buttons, so white labels pass WCAG AA).
- Pill buttons, 24 px card corners, soft layered shadows in light mode and none in dark.
- One primary button per section, sentence case, 4 px spacing grid, no gradients or glows.
- Motion is limited to 150 ms state changes and a 0.97 press scale, and is switched off under `prefers-reduced-motion`.

## Preview locally

```sh
python3 -m http.server 4173 --directory site
```

Then open <http://localhost:4173>. Check light, dark (toggle in the header) and a 375 px wide window.

## Deployment

The repository root has a `vercel.json` that serves this folder as static output:

```json
{ "buildCommand": "", "outputDirectory": "site", "framework": null, "cleanUrls": true }
```

Import the repository in Vercel (or run `vercel` from the repo root) and every push to `main` deploys the page. There is nothing to install or build.
