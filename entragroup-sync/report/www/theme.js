(() => {
  const param = new URLSearchParams(window.location.search).get("scoutTheme");
  let saved = "";
  try { saved = localStorage.getItem("arc-entra-theme-v2") || ""; } catch {}
  const theme =
    (param === "dark" || param === "light" ? param : "") ||
    (saved === "dark" || saved === "light" ? saved : "") ||
    "light";
  document.documentElement.setAttribute("data-theme", theme);
})();
