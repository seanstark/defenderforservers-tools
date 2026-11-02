"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const base = window.location.pathname.startsWith("/api/report") ? "/api/report/" : "/";
  const themePreferenceKey = "arc-entra-theme-v2";
  const permCacheKey = "arc-entra-perm-cache-v1";
  let reportData = null;
  let activeTab = "all";
  let statusFilter = "";

  const time = value => value ? new Date(value).toLocaleString() : "Not observed";
  const text = (tag, value, className) => {
    const element = document.createElement(tag);
    element.textContent = String(value ?? "");
    if (className) element.className = className;
    return element;
  };

  function currentTheme() {
    return document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light";
  }
  function updateThemeButton() {
    const button = byId("theme-toggle");
    if (!button) return;
    const isDark = currentTheme() === "dark";
    button.textContent = isDark ? "Light mode" : "Dark mode";
    button.setAttribute("aria-label", `Switch to ${isDark ? "light" : "dark"} mode`);
    button.setAttribute("aria-pressed", String(isDark));
  }
  function setTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    try { localStorage.setItem(themePreferenceKey, theme); } catch {}
    updateThemeButton();
  }

  async function get(path, forceRefresh = false) {
    const sep = path.includes("?") ? "&" : "?";
    const fullPath = forceRefresh ? `${path}${sep}refresh=1` : path;
    const response = await fetch(base + fullPath, {
      credentials: "same-origin",
      cache: forceRefresh ? "no-store" : "default",
      redirect: "error"
    });
    if (!response.ok) throw new Error(`Permissions check request failed (${response.status}).`);
    const result = await response.json();
    if (result.error) throw new Error(result.error);
    return result;
  }

  function statusTone(status) {
    if (status === "Granted") return "good";
    if (status === "Missing") return "bad";
    if (status === "Warning") return "attention";
    return "";
  }

  function statusLabel(status) {
    if (status === "Granted") return "Granted / Verified";
    if (status === "Missing") return "Action Required (Missing)";
    if (status === "Warning") return "Warning / Check Scope";
    if (status === "Optional") return "Optional (Audit Mode)";
    if (status === "Pending") return "Pending Worker Run";
    return status || "Unknown";
  }

  function renderSummaryCards(checks) {
    const total = checks.length;
    const granted = checks.filter(c => c.Status === "Granted").length;
    const missing = checks.filter(c => c.Status === "Missing").length;
    const warnings = checks.filter(c => c.Status === "Warning" || c.Status === "Pending").length;
    const optional = checks.filter(c => c.Status === "Optional").length;
    const specs = [
      ["", "Total permission checks", total],
      ["Granted", "Granted & verified", granted],
      ["Missing", "Action required (missing)", missing],
      ["Warning", "Warnings / pending probe", warnings],
      ["Optional", "Optional / audit mode", optional]
    ];
    const container = byId("perm-summary");
    container.replaceChildren();
    for (const [key, label, count] of specs) {
      const btn = text("button", "", `card${statusFilter === key && key !== "" ? " is-active" : ""}`);
      btn.type = "button";
      btn.setAttribute("aria-pressed", String(statusFilter === key && key !== ""));
      btn.append(text("span", label), text("strong", String(count)));
      btn.addEventListener("click", () => {
        statusFilter = (statusFilter === key) ? "" : key;
        render();
      });
      container.append(btn);
    }
  }

  function renderIdentityMetadata(data) {
    const checks = Array.isArray(data.Checks) ? data.Checks : [];
    const missingCount = checks.filter(c => c.Status === "Missing").length;
    const warningCount = checks.filter(c => c.Status === "Warning").length;
    const bannerTitle = byId("perm-banner-title");
    const bannerSub = byId("perm-banner-subtitle");
    if (missingCount > 0) {
      bannerTitle.textContent = `${missingCount} required permission${missingCount === 1 ? " is" : "s are"} missing — action required`;
      bannerSub.textContent = "Review the highlighted rows below and run the pre-filled remediation commands.";
    } else if (warningCount > 0) {
      bannerTitle.textContent = `Core permissions verified with ${warningCount} scope warning${warningCount === 1 ? "" : "s"}`;
      bannerSub.textContent = "Review the warning items below (for example, 0 servers returned in scope if Azure Reader has not been assigned on target subscriptions).";
    } else {
      bannerTitle.textContent = "All required Managed Identity permissions are configured and verified";
      bannerSub.textContent = data.Source === "WorkerLiveCheck" ?
        "Live Worker Managed Identity probes and Report Managed Identity checks passed." :
        "Verified from Worker telemetry and live Report Managed Identity checks.";
    }

    if (data.FunctionAppResourceId && String(data.FunctionAppResourceId).includes("/resourceGroups/")) {
      const link = byId("perm-worker-portal-link");
      const tenant = data.PortalTenant || data.TenantId || "";
      const prefix = tenant ? `https://portal.azure.com/#@${tenant}/resource` : "https://portal.azure.com/#resource";
      link.href = `${prefix}${data.FunctionAppResourceId.split("/").map(encodeURIComponent).join("/")}/appServices`;
      link.textContent = data.WorkerFunctionName ? `Open ${data.WorkerFunctionName} in Portal` : "Open Worker Function App in Portal";
    }

    const rolesList = Array.isArray(data.TokenRoles) && data.TokenRoles.length ? data.TokenRoles.join(", ") : "Probed via Graph API";
    const syncMode = data.SyncMode || "Audit";
    const defaultGroupMode = data.DefaultGroupMode || "Passive";
    const syncBadge = byId("header-sync-mode");
    if (syncBadge) {
      syncBadge.textContent = `Sync Mode: ${syncMode} (${syncMode === "Enforce" ? "Adds to group" : "Observe only"})`;
      syncBadge.className = `badge mode-pill ${syncMode === "Enforce" ? "good" : "attention"}`;
      syncBadge.hidden = false;
    }
    const groupModeBadge = byId("header-group-mode");
    if (groupModeBadge) {
      groupModeBadge.textContent = `Default Group: ${defaultGroupMode}`;
      groupModeBadge.className = "badge mode-pill";
      groupModeBadge.hidden = false;
    }
    const items = [
      ["Overall readiness", text("span", missingCount > 0 ? "Action Required" : warningCount > 0 ? "Review Warnings" : "Ready", `badge ${missingCount > 0 ? "bad" : warningCount > 0 ? "attention" : "good"}`)],
      ["Sync Mode (SYNC_MODE)", text("span", `${syncMode} (${syncMode === "Enforce" ? "Adds to group" : "Audit — observe only"})`, `badge ${syncMode === "Enforce" ? "good" : "attention"}`)],
      ["Default Group Mode", text("span", `${defaultGroupMode} group (<Prefix>${defaultGroupMode}-<Id>)`, "badge")],
      ["Worker Managed Identity", text("span", data.WorkerPrincipalId ? `${data.WorkerFunctionName || "worker"} (${data.WorkerPrincipalId})` : (data.WorkerFunctionName || "worker"))],
      ["Report Managed Identity", text("span", data.ReportPrincipalId ? `${data.ReportFunctionName || "report"} (${data.ReportPrincipalId})` : (data.ReportFunctionName || "report"))],
      ["Granted Graph App Roles (JWT)", text("span", rolesList)],
      ["Validation source", text("span", data.Source === "WorkerLiveCheck" ? "Live Worker + Report probes" : "Worker telemetry + live Report probes")]
    ];
    const dl = byId("perm-identities");
    dl.replaceChildren();
    for (const [label, node] of items) {
      const chip = text("div", "", "summary-chip");
      const dd = document.createElement("dd");
      dd.append(node);
      chip.append(text("dt", label), dd);
      dl.append(chip);
    }

    const workerId = data.WorkerPrincipalId || "<worker-managed-identity-principal-id>";
    const auId = (data.AdminUnitId && !String(data.AdminUnitId).includes("Not configured")) ? data.AdminUnitId : "<entra-administrative-unit-guid>";
    const readerCmd = byId("cmd-azure-reader");
    if (readerCmd) {
      readerCmd.textContent =
`# Assign Azure Reader on target Subscription or Management Group
$workerPrincipalId = '${workerId}'
az role assignment create --assignee-object-id $workerPrincipalId --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/subscriptions/<subscription-guid>'
# Or at Management Group scope:
az role assignment create --assignee-object-id $workerPrincipalId --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/providers/Microsoft.Management/managementGroups/<management-group-id>'`;
    }
    const graphCmd = byId("cmd-graph-perms");
    if (graphCmd) {
      graphCmd.textContent =
`# Administrative Unit scoped (grants ThreatHunting.Read.All, Device.Read.All + AU-scoped Groups Administrator; no GroupMember.Read.All needed)
.\\Grant-GraphPermissions.ps1 -WorkerPrincipalId '${workerId}' -Mode Enforce -AdminUnitId '${auId}'`;
    }
  }

  function render() {
    if (!reportData) return;
    const allChecks = Array.isArray(reportData.Checks) ? reportData.Checks : [];
    renderSummaryCards(allChecks);
    renderIdentityMetadata(reportData);

    for (const tab of document.querySelectorAll("button[data-perm-tab]")) {
      tab.setAttribute("aria-pressed", String(tab.dataset.permTab === activeTab));
    }

    const filtered = allChecks.filter(check => {
      if (statusFilter) {
        if (statusFilter === "Warning" && !["Warning", "Pending"].includes(check.Status)) return false;
        if (statusFilter !== "Warning" && check.Status !== statusFilter) return false;
      }
      if (activeTab === "all") return true;
      if (activeTab === "issues") return ["Missing", "Warning", "Pending"].includes(check.Status);
      return check.Category === activeTab;
    });

    byId("perm-count").textContent = `Showing ${filtered.length} of ${allChecks.length} permission checks.`;
    const tbody = byId("perm-rows");
    tbody.replaceChildren();
    if (!filtered.length) {
      const tr = document.createElement("tr");
      const td = text("td", "No permission checks match the selected filter.");
      td.colSpan = 7;
      tr.append(td);
      tbody.append(tr);
      return;
    }

    for (const check of filtered) {
      const tr = document.createElement("tr");
      const statusTd = document.createElement("td");
      const tone = statusTone(check.Status);
      statusTd.append(text("span", statusLabel(check.Status), `status-value ${tone}`));

      const categoryTd = text("td", check.Category || "");
      const permTd = document.createElement("td");
      permTd.append(text("strong", check.Permission || ""));

      const principalTd = text("td", check.Principal || "");
      const scopeTd = text("td", check.Scope || "");
      const reqTd = text("td", check.RequiredFor || "");

      const detailsTd = document.createElement("td");
      detailsTd.append(text("span", check.Details || ""));
      if (check.Remediation && check.Status !== "Granted") {
        const pre = document.createElement("pre");
        pre.append(text("code", check.Remediation));
        detailsTd.append(pre);
      }

      tr.append(statusTd, categoryTd, permTd, principalTd, scopeTd, reqTd, detailsTd);
      tbody.append(tr);
    }
  }

  async function refresh(forceRefresh = false) {
    byId("perm-refresh").disabled = true;
    byId("perm-error").hidden = true;
    try {
      const data = await get("permissions", forceRefresh);
      reportData = data;
      try {
        sessionStorage.setItem(permCacheKey, JSON.stringify({ data, savedAt: Date.now() }));
      } catch {}
      byId("perm-updated").textContent = `Checked: ${time(data.CheckedAt || new Date().toISOString())}`;
      render();
    } catch (err) {
      byId("perm-error").textContent = err.message;
      byId("perm-error").hidden = false;
    } finally {
      byId("perm-refresh").disabled = false;
    }
  }

  for (const tab of document.querySelectorAll("button[data-perm-tab]")) {
    tab.addEventListener("click", () => {
      activeTab = tab.dataset.permTab;
      render();
    });
  }
  byId("perm-refresh").addEventListener("click", () => refresh(true));
  byId("theme-toggle")?.addEventListener("click", () => setTheme(currentTheme() === "dark" ? "light" : "dark"));

  updateThemeButton();
  try {
    const cachedRaw = sessionStorage.getItem(permCacheKey);
    if (cachedRaw) {
      const cached = JSON.parse(cachedRaw);
      if (cached?.data) {
        reportData = cached.data;
        byId("perm-updated").textContent = `Cached check: ${time(reportData.CheckedAt)}`;
        render();
      }
    }
  } catch {}
  void refresh(false);
})();
