// Folio landing page: theme toggle, copy buttons, and the hero screenshot swap.

// ---- Theme toggle ----
// The saved choice lives in localStorage["theme"] ("light" | "dark"); with none saved the
// page follows the system. The inline script in <head> applies it before first paint.
const root = document.documentElement;
const toggle = document.getElementById("theme-toggle");
const systemDark = matchMedia("(prefers-color-scheme: dark)");

function currentTheme() {
  return root.dataset.theme || (systemDark.matches ? "dark" : "light");
}

function syncToggle() {
  const next = currentTheme() === "dark" ? "light" : "dark";
  toggle.dataset.next = next;
  toggle.setAttribute("aria-label", `Switch to ${next} theme`);
  toggle.title = `Switch to ${next} theme`;
}

toggle.addEventListener("click", () => {
  const next = currentTheme() === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  try { localStorage.setItem("theme", next); } catch {}
  syncToggle();
});
systemDark.addEventListener("change", syncToggle);
syncToggle();

// ---- Copy buttons ----
for (const button of document.querySelectorAll("[data-copy]")) {
  const label = button.querySelector(".copy-label");
  let timer;
  const reset = () => {
    delete button.dataset.copied;
    label.textContent = "Copy";
  };
  button.addEventListener("click", async () => {
    clearTimeout(timer);
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.dataset.copied = "";
      label.textContent = "Copied";
    } catch {
      // Clipboard blocked (insecure origin or permission): select the commands instead.
      const range = document.createRange();
      range.selectNodeContents(button.closest(".code-card").querySelector("pre"));
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      label.textContent = "Press ⌘C";
    }
    timer = setTimeout(reset, 2000);
  });
}

// ---- Hero screenshot ----
// Drop a real screenshot at assets/hero.png and it replaces the HTML mock. Until then the
// request 404s quietly and the mock stays.
const heroImage = new Image();
heroImage.onload = () => {
  heroImage.alt = "The Folio workspace: a sidebar with Home, Recent, Favorites and the library, new-file tiles, and a grid of recent files with previews.";
  heroImage.width = heroImage.naturalWidth;
  heroImage.height = heroImage.naturalHeight;
  document.getElementById("hero-visual").replaceChildren(heroImage);
};
heroImage.src = "assets/hero.png";
