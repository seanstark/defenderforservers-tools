(() => {
  const param = new URLSearchParams(window.location.search).get("scoutTheme");
  let saved = "";
  try { saved = localStorage.getItem("arc-entra-theme") || ""; } catch {}
  const theme =
    (param === "dark" || param === "light" ? param : "") ||
    (saved === "dark" || saved === "light" ? saved : "") ||
    (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  document.documentElement.setAttribute("data-theme", theme);
})();
