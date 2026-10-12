// Helper bersama WebUI agentbox. Halaman memanggil CLI `agentbox` (satu sumber logika), tidak menduplikasinya.
(() => {
  "use strict";
  const MOD = "/data/adb/modules/agentbox";
  let seq = 0;

  // ksu.exec (API WebUI KernelSU) -> Promise {errno, stdout, stderr}
  function run(cmd) {
    return new Promise((resolve) => {
      if (typeof ksu === "undefined" || typeof ksu.exec !== "function") {
        resolve({ errno: -1, stdout: "", stderr: "API KernelSU tidak tersedia. Buka dari KernelSU Manager." });
        return;
      }
      const cb = "__ab_cb_" + Date.now() + "_" + (seq++);
      window[cb] = (errno, stdout, stderr) => {
        delete window[cb];
        resolve({ errno: Number(errno), stdout: stdout || "", stderr: stderr || "" });
      };
      try { ksu.exec(cmd, "{}", cb); } catch (e) { delete window[cb]; resolve({ errno: -1, stdout: "", stderr: String(e) }); }
    });
  }

  // Jalankan CLI agentbox dan parse JSON-nya; null bila gagal.
  async function cliJson(args) {
    const r = await run(`sh ${MOD}/system/bin/agentbox ${args}`);
    if (r.errno !== 0) return null;
    try { return JSON.parse(r.stdout); } catch (_) { return null; }
  }

  function toast(msg) {
    try { ksu.toast(msg); } catch (_) { /* di luar KernelSU */ }
  }

  // Buka link di browser bawaan Android (intent VIEW), bukan di WebView. Hanya http/https, selalu dikutip.
  async function openUrl(uri) {
    let url;
    try { url = new URL(uri); } catch (_) { toast("Link tidak valid"); return; }
    if (url.protocol !== "http:" && url.protocol !== "https:") { toast("Hanya link http/https"); return; }
    const quoted = "'" + url.href.replace(/'/g, "'\\''") + "'";
    toast("Membuka di browser…");
    const r = await run(`am start -a android.intent.action.VIEW -d ${quoted} >/dev/null 2>&1`);
    if (r.errno !== 0) toast("Gagal membuka browser");
  }

  // Salin teks ke clipboard; fallback execCommand untuk WebView tanpa Clipboard API.
  async function copyText(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch (_) { /* fallback */ }
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (_) { ok = false; }
    ta.remove();
    return ok;
  }

  // Escape teks untuk disisipkan ke HTML.
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  // ---- navigasi bawah, dibuat di sini agar markup-nya satu sumber untuk semua halaman.
  // body[data-page] = tab aktif; body[data-nav="inline"] = nav ikut alur flex (halaman Terminal).
  const ICON = (d) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
  const NAV = [
    { page: "status", href: "index.html", label: "Status", icon: ICON('<path d="M3 12h4l3-8 4 16 3-8h4"/>') },
    { page: "gateway", href: "gateway.html", label: "Gateway", icon: ICON('<path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4z"/>') },
    { page: "tty", href: "tty.html", label: "Terminal", icon: ICON('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3"/><path d="M13 15h4"/>') },
    { page: "config", href: "config.html", label: "Konfigurasi", icon: ICON('<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>') },
  ];
  function buildNav() {
    const body = document.body;
    const nav = document.createElement("nav");
    nav.className = "bnav" + (body.dataset.nav === "inline" ? " inline" : "");
    nav.setAttribute("aria-label", "Navigasi");
    nav.innerHTML = NAV.map((n) =>
      `<a href="${n.href}" data-page="${n.page}"${n.page === body.dataset.page ? ' aria-current="page"' : ""}>${n.icon}<span>${n.label}</span></a>`
    ).join("");
    body.appendChild(nav);
    if (body.dataset.nav !== "inline") body.classList.add("has-bnav");
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", buildNav);
  else buildNav();

  window.AB = { MOD, run, cliJson, toast, esc, openUrl, copyText };
})();
