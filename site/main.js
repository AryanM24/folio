// Folio landing page: theme, header state, and the live replicas in the feature grid.
// formats.json comes from `folio formats --json` and bench.json from `make bench`
// (see scripts/site-data.sh and scripts/bench.sh), so the page can't promise more than the app does.

const root = document.documentElement;
const el = (tag, props = {}, children = []) => {
  const { dataset, ...rest } = props;
  const node = Object.assign(document.createElement(tag), rest);
  Object.assign(node.dataset, dataset);  // dataset is read-only, so fill it instead
  node.append(...children);
  return node;
};

// ---- Theme ----
const toggle = document.getElementById("theme-toggle");
const systemDark = matchMedia("(prefers-color-scheme: dark)");
const theme = () => root.dataset.theme || (systemDark.matches ? "dark" : "light");
const darkSource = document.querySelector("source[data-dark]");
function syncTheme() {
  const next = theme() === "dark" ? "light" : "dark";
  toggle.dataset.next = next;
  toggle.setAttribute("aria-label", `Switch to ${next} theme`);
  toggle.title = `Switch to ${next} theme`;
  if (darkSource) darkSource.media = theme() === "dark" ? "all" : "not all";
}
toggle.addEventListener("click", () => {
  root.dataset.theme = theme() === "dark" ? "light" : "dark";
  try { localStorage.setItem("theme", root.dataset.theme); } catch {}
  syncTheme();
});
systemDark.addEventListener("change", syncTheme);
syncTheme();

const header = document.querySelector(".site-header");
const onScroll = () => header.toggleAttribute("data-scrolled", scrollY > 8);
addEventListener("scroll", onScroll, { passive: true });
onScroll();

// ---- Convert panel replica ----
// Three HEIC photos, 27.6 MB in all. Output sizes are typical ratios for photos at each
// preset; the targets, and which of them can be lossless, are the app's real ones.
const NAMES = { png: "PNG", jpeg: "JPEG", heic: "HEIC", avif: "AVIF", tiff: "TIFF", gif: "GIF", pdf: "PDF", jp2: "JP2", bmp: "BMP" };
const RATIO = {
  png: { lossless: 4.3, balanced: 4.3, small: 1.1 }, tiff: { lossless: 4.6, balanced: 4.6, small: 1.2 },
  jpeg: { balanced: 1.6, small: 0.34 }, heic: { lossless: 1, balanced: 0.74, small: 0.22 },
  avif: { balanced: 0.46, small: 0.15 }, gif: { balanced: 0.62, small: 0.3 },
  pdf: { balanced: 1.64, small: 0.4 }, jp2: { lossless: 2.4, balanced: 0.9, small: 0.3 },
};
const SECONDS = { png: 1.1, tiff: 0.9, jpeg: 0.3, heic: 0.4, avif: 0.9, gif: 0.6, pdf: 0.5, jp2: 2.2 };
const IN_MB = 27.6;

async function convertDemo() {
  const panel = document.getElementById("convert-demo");
  const card = document.getElementById("result-demo");
  const data = await fetch("formats.json").then((r) => r.json());
  const heic = data.pairs.find((p) => p.from === "heic");
  const targets = ["png", "heic", "jpeg", "avif", "tiff", "gif", "pdf", "jp2"].map((to) => heic.targets.find((t) => t.to === to)).filter(Boolean);
  const chips = panel.querySelector(".cp-chips");
  const fidelity = panel.querySelector(".cp-fidelity");
  const qualityButtons = [...panel.querySelectorAll(".segmented button")];
  let target = targets.find((t) => t.to === "heic");
  let quality = "small";

  const label = (t, q) => q === "lossless" ? "Lossless, verified" : t.fidelity === "lossless" ? "Lossless" : q === "small" ? "Smaller, some loss" : "Visually lossless";

  function render() {
    for (const chip of chips.children) chip.setAttribute("aria-checked", String(chip.dataset.to === target.to));
    if (quality === "lossless" && !target.lossless_available) quality = "balanced";
    for (const b of qualityButtons) {
      b.setAttribute("aria-checked", String(b.dataset.q === quality));
      b.disabled = b.dataset.q === "lossless" && !target.lossless_available;
      b.title = b.disabled ? `${NAMES[target.to]} can't be lossless` : "";
    }
    fidelity.textContent = label(target, quality);
  }
  chips.replaceChildren(...targets.map((t) => {
    const chip = el("button", { type: "button", className: "chip", textContent: NAMES[t.to], role: "radio", dataset: { to: t.to } });
    chip.addEventListener("click", () => { target = t; render(); });
    return chip;
  }));
  for (const b of qualityButtons) b.addEventListener("click", () => { if (!b.disabled) { quality = b.dataset.q; render(); } });

  const mb = (n) => (n >= 10 ? n.toFixed(1) : n.toFixed(1)) + " MB";
  function result(animate) {
    const out = IN_MB * (RATIO[target.to][quality] ?? RATIO[target.to].balanced);
    const change = Math.round((out / IN_MB - 1) * 100);
    card.querySelector(".rc-size").textContent = `${mb(IN_MB)} → ${mb(out)} · ${change > 0 ? "+" : "−"}${Math.abs(change)} %`;
    card.querySelector(".rc-meta").textContent = `${label(target, quality)} · ${SECONDS[target.to].toFixed(1)} s`;
    card.querySelector(".rc-name").textContent = `IMG_2041.${target.to === "jpeg" ? "jpg" : target.to} and 2 more`;
    if (!animate) return;
    card.setAttribute("data-hidden", "");
    requestAnimationFrame(() => setTimeout(() => card.removeAttribute("data-hidden"), 120));
  }
  document.getElementById("convert-go").addEventListener("click", () => result(true));
  render();
  result(false);
}

// ---- Spreadsheet replica: the same sheet as docs/screenshots/spreadsheet.png ----
function sheet() {
  const grid = document.getElementById("sheet-grid");
  const rows = [["South", "Desk", 37, 80], ["West", "Shelf", 65, 353], ["West", "Chair", 17, 269], ["North", "Shelf", 60, 331], ["North", "Shelf", 39, 389], ["South", "Desk", 45, 35], ["North", "Desk", 88, 297]];
  const cells = [el("span", { className: "h" })];
  for (const c of "ABCDEF") cells.push(el("span", { className: "h" + (c === "E" ? " is-sel" : ""), textContent: c }));
  cells.push(el("span", { className: "h", textContent: "1" }), ...["Region", "Product", "Units", "Price", "Revenue", ""].map((t) => el("span", { textContent: t })));
  rows.forEach(([region, product, units, price], i) => {
    const n = i + 2;
    cells.push(
      el("span", { className: "h", textContent: String(n) }),
      el("span", { textContent: region }), el("span", { textContent: product }),
      el("span", { className: "n", textContent: String(units) }), el("span", { className: "n", textContent: String(price) }),
      el("span", { className: "n" + (n === 2 ? " sel" : ""), textContent: String(units * price) }), el("span"));
  });
  grid.replaceChildren(...cells);
}

// ---- Benchmarks ----
const fmt = (ms) => (ms >= 1000 ? (ms / 1000).toFixed(1) + " s" : Math.round(ms) + " ms");
async function bench() {
  const list = document.querySelector("[data-bench]");
  const { machine, rows } = await fetch("bench.json").then((r) => r.json());
  list.replaceChildren(...rows.map((r) => {
    const max = Math.max(r.folio_ms, r.other_ms);
    const line = (who, ms, us) => el("div", { className: "row" }, [
      el("div", { className: "bar" + (us ? " us" : ""), style: `width:${Math.max(2, (ms / max) * 100)}%`, title: who }),
      el("b", { textContent: fmt(ms) }),
    ]);
    return el("li", {}, [
      el("p", { className: "task", textContent: r.task }),
      line("Folio", r.folio_ms, true),
      line(r.other, r.other_ms, false),
    ]);
  }));
  document.querySelector("[data-bench-note]").textContent = `Blue is Folio, grey is ${[...new Set(rows.map((r) => r.other.split(",")[0]))].join(", ")}. Measured with make bench on ${machine.replace(/^an? /, "")}.`;
}

if (document.getElementById("sheet-grid")) sheet();
if (document.getElementById("convert-demo")) convertDemo().catch(() => {});
if (document.querySelector("[data-bench]")) bench().catch(() => document.querySelector(".tile-speed")?.remove());
