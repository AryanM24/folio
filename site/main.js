// Folio landing page: theme, header state, copy buttons, the format map and the benchmarks.
// The data files come from the app itself: formats.json from `folio formats --json`,
// bench.json from `make bench`. See scripts/site-data.sh.

const root = document.documentElement;

// ---- Theme ----
// The saved choice lives in localStorage["theme"]; without one the page follows the system.
const toggle = document.getElementById("theme-toggle");
const systemDark = matchMedia("(prefers-color-scheme: dark)");
const theme = () => root.dataset.theme || (systemDark.matches ? "dark" : "light");

// The workspace screenshot follows the page theme, not only the system one.
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

// ---- Header hairline once the page scrolls ----
const header = document.querySelector(".site-header");
const onScroll = () => header.toggleAttribute("data-scrolled", scrollY > 8);
addEventListener("scroll", onScroll, { passive: true });
onScroll();

// ---- Copy buttons ----
for (const button of document.querySelectorAll("[data-copy]")) {
  const label = button.querySelector(".copy-label");
  let timer;
  button.addEventListener("click", async () => {
    clearTimeout(timer);
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.dataset.copied = "";
      label.textContent = "Copied";
    } catch {
      // Clipboard blocked: select the text so ⌘C still works.
      const range = document.createRange();
      range.selectNodeContents(button.closest(".code-card").querySelector("pre"));
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      label.textContent = "Press ⌘C";
    }
    timer = setTimeout(() => { delete button.dataset.copied; label.textContent = "Copy"; }, 2000);
  });
}

const el = (tag, { dataset, ...props } = {}, children = []) => {
  const node = Object.assign(document.createElement(tag), props);
  Object.assign(node.dataset, dataset);  // dataset is read-only, so fill it instead
  node.append(...children);
  return node;
};

// ---- Format map ----
const FAMILY_NAMES = { pdf: "PDF", document: "Documents", spreadsheet: "Spreadsheets", image: "Images", audio: "Audio", video: "Video" };
const FIDELITY = { lossless: "Lossless", visually_lossless: "Visually lossless", lossy: "Smaller, some loss", content_only: "Content only" };

async function formatMap() {
  const box = document.getElementById("formats");
  const data = await fetch("formats.json").then((r) => r.json());
  const sources = box.querySelector(".formats-sources");
  const caption = box.querySelector(".formats-caption");
  const list = box.querySelector(".formats-list");
  const chips = [];

  function show(entry) {
    for (const chip of chips) chip.setAttribute("aria-selected", String(chip.dataset.from === entry.from));
    const others = entry.targets.filter((t) => t.to !== entry.from);
    const compress = entry.targets.some((t) => t.to === entry.from);
    caption.replaceChildren(el("b", { textContent: entry.from.toUpperCase() }), ` becomes ${others.length} formats${compress ? ", or a smaller " + entry.from.toUpperCase() : ""}`);
    list.replaceChildren(...entry.targets.map((t) => {
      const kind = t.lossless_available ? "lossless" : t.fidelity;
      const label = t.lossless_available && t.fidelity !== "lossless" ? "Lossless available" : FIDELITY[t.fidelity];
      const note = t.to === entry.from ? "Compress" : (t.drops || []).length ? "Drops " + t.drops.join(", ") : t.notes || "";
      return el("li", {}, [
        el("span", { className: "to", textContent: t.to }),
        el("span", { className: "fidelity", textContent: label, dataset: { kind } }),
        el("span", { className: "drops", textContent: note }),
      ]);
    }));
  }

  const byFamily = Object.groupBy ? Object.groupBy(data.pairs, (p) => p.family) : data.pairs.reduce((m, p) => ((m[p.family] ||= []).push(p), m), {});
  for (const [family, entries] of Object.entries(byFamily)) {
    const group = el("div", { className: "formats-group" }, [el("p", { className: "formats-group-label", textContent: FAMILY_NAMES[family] || family })]);
    const row = el("div", { className: "formats-chips" });
    for (const entry of entries) {
      const chip = el("button", { className: "chip", type: "button", textContent: entry.from, role: "tab" });
      chip.dataset.from = entry.from;
      chip.addEventListener("click", () => show(entry));
      chips.push(chip);
      row.append(chip);
    }
    group.append(row);
    sources.append(group);
  }
  show(data.pairs.find((p) => p.from === "mov") || data.pairs[0]);
}

// ---- Benchmarks ----
const fmt = (ms) => (ms >= 1000 ? (ms / 1000).toFixed(ms >= 10000 ? 0 : 1) + " s" : Math.round(ms) + " ms");

async function bench() {
  const body = document.querySelector("[data-bench]");
  const { machine, rows } = await fetch("bench.json").then((r) => r.json());
  if (machine) document.querySelector("#speed .section-head p:not(.section-no) code")?.after(` on ${machine}.`);
  body.replaceChildren(...rows.map((r) => {
    const max = Math.max(r.folio_ms, r.other_ms);
    return el("tr", {}, [
      el("th", { scope: "row", textContent: r.task }),
      el("td", { textContent: fmt(r.folio_ms) }),
      el("td", {}, [fmt(r.other_ms), el("span", { className: "who", textContent: r.other })]),
      el("td", {}, [el("div", { className: "bars", ariaHidden: "true" }, [
        el("div", { className: "bar us", style: `width:${Math.max(1, (r.folio_ms / max) * 100)}%` }),
        el("div", { className: "bar", style: `width:${(r.other_ms / max) * 100}%` }),
      ])]),
    ]);
  }));
}

formatMap().catch(() => document.getElementById("formats").remove());
bench().catch(() => document.getElementById("speed").remove());
