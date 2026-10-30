"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const base = window.location.pathname.startsWith("/api/report") ? "/api/report/" : "/";
  const missing = "Not available";
  const themePreferenceKey = "arc-entra-theme-v2";
  const dataCacheKey = "arc-entra-data-cache-v1";
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  let machines = [];
  let latestHealth = {};
  let busy = false;
  let coverageCloudFilter = "all";
  let coverageGroupFilter = "all";
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
    button.title = `Current theme: ${isDark ? "Dark" : "Light"} mode. Click to switch to ${isDark ? "light" : "dark"} mode.`;
  }
  function setTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    try { localStorage.setItem(themePreferenceKey, theme); } catch {}
    updateThemeButton();
  }
  function groupLinkById(groupId) {
    return groupId ? `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/${encodeURIComponent(groupId)}` : "";
  }
  function appendLink(parent, label, url) {
    if (!url) { parent.append(text("span", label)); return; }
    const link = text("a", label);
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    parent.append(link);
  }
  function osNode(osValue) {
    const value = String(osValue || missing);
    const lower = value.toLowerCase();
    const kind = lower.includes("win") ? "windows" : lower.includes("lin") || lower.includes("ubuntu") || lower.includes("redhat") ? "linux" : "generic";
    const wrap = text("span", "", "os-badge");
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 16 16");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("class", `os-svg os-${kind}`);
    const path = (d, cls) => {
      const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
      p.setAttribute("d", d);
      if (cls) p.setAttribute("class", cls);
      return p;
    };
    if (kind === "windows") {
      svg.append(path("M1.5 2.5h5.8v5.8H1.5zM8.7 2.5h5.8v5.8H8.7zM1.5 9.7h5.8v5.8H1.5zM8.7 9.7h5.8v5.8H8.7z", "os-fill-link"));
    } else if (kind === "linux") {
      svg.append(
        path("M8 1.2C5.7 1.2 4.3 3 4.3 5.5c0 1.2-.9 2.4-1.3 3.9-.4 1.6.3 3.4 1.7 4.2h6.6c1.4-.8 2.1-2.6 1.7-4.2-.4-1.5-1.3-2.7-1.3-3.9C11.7 3 10.3 1.2 8 1.2z", "os-tux-body"),
        path("M8 5.8c-1.6 0-2.6 1.5-2.6 3.5 0 1.8.9 3.1 2.6 3.1s2.6-1.3 2.6-3.1c0-2-1-3.5-2.6-3.5z", "os-tux-belly"),
        path("M6.6 3.9a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5zm2.8 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5z", "os-tux-eye"),
        path("M8 5l-1.5 1.1L8 7l1.5-.9L8 5zM4 13.3l-1.6.9 2.9.6.8-.9-2.1-.6zm8 0l-2.1.6.8.9 2.9-.6-1.6-.9z", "os-tux-beak")
      );
    } else {
      svg.append(path("M2.5 3h11v7H2.5zm3 8.5h5v1.5h-5z", "os-fill-muted"));
    }
    wrap.append(svg, text("span", value));
    return wrap;
  }
  let activeHoverCell = null;
  let hoverHideTimer = 0;
  function clearHoverTimer() {
    if (hoverHideTimer) {
      window.clearTimeout(hoverHideTimer);
      hoverHideTimer = 0;
    }
  }
  function isPopoverPinned() {
    const popover = byId("hover-popover");
    if (!popover || popover.hidden) return false;
    const selection = window.getSelection?.();
    return Boolean(selection && !selection.isCollapsed && popover.contains(selection.anchorNode));
  }
  function scheduleHideHoverPopover() {
    clearHoverTimer();
    hoverHideTimer = window.setTimeout(() => {
      hoverHideTimer = 0;
      const popover = byId("hover-popover");
      if (!popover || popover.matches(":hover") || activeHoverCell?.matches(":hover") || isPopoverPinned()) return;
      hideHoverPopover();
    }, 240);
  }
  function hideHoverPopover() {
    clearHoverTimer();
    activeHoverCell = null;
    const popover = byId("hover-popover");
    if (popover) {
      popover.hidden = true;
      popover.replaceChildren();
    }
  }
  function positionHoverPopover(cell) {
    const popover = byId("hover-popover");
    if (!popover || popover.hidden || !cell?.isConnected) {
      hideHoverPopover();
      return;
    }
    const rect = cell.getBoundingClientRect();
    const popRect = popover.getBoundingClientRect();
    const pad = 8;
    let left = Math.max(pad, Math.min(rect.left, window.innerWidth - popRect.width - pad));
    let top = rect.bottom + 2;
    if (top + popRect.height > window.innerHeight - pad && rect.top - popRect.height - 2 >= 48) {
      top = rect.top - popRect.height - 2;
    } else if (top + popRect.height > window.innerHeight - pad) {
      top = Math.max(52, window.innerHeight - popRect.height - pad);
    }
    popover.style.left = `${Math.round(left)}px`;
    popover.style.top = `${Math.round(top)}px`;
  }
  function showHoverPopover(cell, title, rows) {
    clearHoverTimer();
    activeHoverCell = cell;
    const popover = byId("hover-popover");
    popover.replaceChildren(text("p", title, "eyebrow"));
    const dl = document.createElement("dl");
    for (const [label, content] of rows) {
      const dd = document.createElement("dd");
      dd.append(content instanceof Node ? content : text("span", content || missing));
      dl.append(text("dt", label), dd);
    }
    popover.append(dl);
    popover.hidden = false;
    positionHoverPopover(cell);
  }
  function bindHoverPopover(cell, buildSpec) {
    cell.classList.add("has-hover-card");
    const open = () => {
      const [title, rows] = buildSpec();
      showHoverPopover(cell, title, rows);
    };
    cell.addEventListener("mouseenter", open);
    cell.addEventListener("focusin", open);
    cell.addEventListener("mouseleave", event => {
      const popover = byId("hover-popover");
      if (cell.contains(event.relatedTarget) || popover?.contains(event.relatedTarget)) return;
      scheduleHideHoverPopover();
    });
    cell.addEventListener("focusout", event => {
      const popover = byId("hover-popover");
      if (cell.contains(event.relatedTarget) || popover?.contains(event.relatedTarget)) return;
      scheduleHideHoverPopover();
    });
  }
  function clearCachedSnapshot() {
    try {
      sessionStorage.removeItem(dataCacheKey);
      localStorage.removeItem(dataCacheKey);
    } catch {}
  }
  async function get(path, forceRefresh = false) {
    const sep = path.includes("?") ? "&" : "?";
    const fullPath = forceRefresh ? `${path}${sep}refresh=1` : path;
    const response = await fetch(base + fullPath, {
      credentials: "same-origin",
      cache: forceRefresh ? "no-store" : "default",
      redirect: "error"
    });
    if (response.status === 401 || response.status === 403) {
      clearCachedSnapshot();
      machines = [];
      renderCoverageReport();
    }
    if (!response.ok) throw new Error(`Report request failed (${response.status}). Check your sign-in, Report.Reader role, and service health.`);
    const result = await response.json();
    if (result.error) throw new Error(result.error);
    return result;
  }
  async function allMachines(forceRefresh = false) {
    const items = [];
    const cursors = new Set();
    let cursor = "";
    do {
      const page = await get("data" + (cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""), forceRefresh);
      if (!Array.isArray(page.Items) || typeof page.Cursor !== "string") throw new Error("Invalid inventory response.");
      items.push(...page.Items);
      cursor = page.Cursor;
      if (cursor && cursors.has(cursor)) throw new Error("Inventory pagination did not advance.");
      cursors.add(cursor);
    } while (cursor);
    return items;
  }
  function loadCachedSnapshot() {
    try {
      localStorage.removeItem(dataCacheKey);
      const raw = sessionStorage.getItem(dataCacheKey);
      if (!raw) return 0;
      const cached = JSON.parse(raw);
      if (!Array.isArray(cached.items)) return 0;
      machines = cached.items;
      latestHealth = cached.health || {};
      renderCoverageReport();
      byId("updated").textContent = `Cached snapshot: ${time(cached.timestamp || new Date().toISOString())}`;
      return Number(cached.savedAt) || 0;
    } catch {
      return 0;
    }
  }
  function saveCachedSnapshot(items, health, timestamp) {
    try {
      localStorage.removeItem(dataCacheKey);
      const raw = sessionStorage.getItem(dataCacheKey);
      const prev = raw ? JSON.parse(raw) : {};
      const payload = JSON.stringify({ ...prev, items, health, timestamp, savedAt: Date.now() });
      sessionStorage.setItem(dataCacheKey, payload);
    } catch {}
  }
  function resolveMachineCloudScope(machine) {
    const type = machine.CloudGroupType || (machine.AzureTags?.AccountId || /\b(aws|amazon)\b/i.test(`${machine.CloudProvider || ""} ${machine.MdeCloudPlatforms || ""}`) ? "AWS" :
      machine.AzureTags?.ProjectId || /\b(gcp|google)\b/i.test(`${machine.CloudProvider || ""} ${machine.MdeCloudPlatforms || ""}`) ? "GCP" : "Azure");
    const identifier = machine.CloudIdentifier || (type === "AWS" ? (machine.AzureTags?.AccountId || "Missing AccountId tag") :
      type === "GCP" ? (machine.AzureTags?.ProjectId || "Missing ProjectId tag") :
      (machine.SubscriptionName || machine.SubscriptionId || "Unknown subscription"));
    return {
      CloudType: type,
      CloudIdentifier: identifier,
      SubscriptionId: type === "Azure" ? (machine.SubscriptionId || "") : "",
      ManagementGroup: machine.ManagementGroup || ""
    };
  }
  function isMachineCorrelated(machine) {
    return Boolean(machine.MdeDeviceId && machine.EntraDeviceId && ["Verified", "WouldAdd", "Matched"].includes(machine.Status));
  }
  function buildCoverageData(items, health) {
    const scopeMap = new Map();
    const ensureScope = (cloudType, cloudIdentifier, subscriptionId, source, managementGroup = "") => {
      if (!cloudType || !cloudIdentifier) return null;
      const key = `${cloudType.toLowerCase()}:${cloudIdentifier.toLowerCase()}`;
      if (!scopeMap.has(key)) {
        scopeMap.set(key, {
          Key: key,
          CloudType: cloudType,
          CloudIdentifier: cloudIdentifier,
          SubscriptionId: subscriptionId || "",
          ManagementGroup: managementGroup || "",
          Source: source || "Discovered server inventory",
          TotalServers: 0,
          OnboardedToMde: 0,
          Correlated: 0,
          NotCorrelated: 0,
          ActiveMode: 0,
          PassiveMode: 0,
          ArcConnected: 0,
          ArcDisconnected: 0,
          ArcOther: 0,
          GroupNames: new Set()
        });
      } else {
        const entry = scopeMap.get(key);
        if (!entry.SubscriptionId && subscriptionId) entry.SubscriptionId = subscriptionId;
        if (!entry.ManagementGroup && managementGroup) entry.ManagementGroup = managementGroup;
        if (source && entry.Source === "Discovered server inventory") entry.Source = source;
      }
      return scopeMap.get(key);
    };
    const groupMap = new Map();
    const ensureGroup = (displayName, meta = {}) => {
      if (!displayName) return null;
      const key = displayName.toLowerCase();
      if (!groupMap.has(key)) {
        groupMap.set(key, {
          DisplayName: displayName,
          Id: meta.Id || "",
          CloudType: meta.CloudType || "",
          OSCategory: meta.OSCategory || "",
          GroupMode: meta.GroupMode || "",
          CloudIdentifier: meta.CloudIdentifier || "",
          MemberCount: 0
        });
      } else {
        const g = groupMap.get(key);
        if (!g.Id && meta.Id) g.Id = meta.Id;
        if (!g.CloudType && meta.CloudType) g.CloudType = meta.CloudType;
        if (!g.OSCategory && meta.OSCategory) g.OSCategory = meta.OSCategory;
        if (!g.GroupMode && meta.GroupMode) g.GroupMode = meta.GroupMode;
        if (!g.CloudIdentifier && meta.CloudIdentifier) g.CloudIdentifier = meta.CloudIdentifier;
      }
      return groupMap.get(key);
    };
    for (const scope of health?.Catalog?.CloudScopes || []) {
      ensureScope(scope.CloudType, scope.CloudIdentifier, scope.SubscriptionId, scope.Source, scope.ManagementGroup);
    }
    for (const grp of health?.Catalog?.ManagedGroups || []) {
      ensureGroup(grp.DisplayName, grp);
      const scope = ensureScope(grp.CloudType, grp.CloudIdentifier, "", `Entra ID Group (${grp.DisplayName})`);
      if (scope) scope.GroupNames.add(grp.DisplayName);
    }
    for (const machine of items) {
      const { CloudType, CloudIdentifier, SubscriptionId, ManagementGroup } = resolveMachineCloudScope(machine);
      const scope = ensureScope(CloudType, CloudIdentifier, SubscriptionId, "Discovered server inventory", ManagementGroup);
      if (scope) {
        scope.TotalServers++;
        if (machine.MdeOnboardingStatus === "Onboarded") scope.OnboardedToMde++;
        if (isMachineCorrelated(machine)) scope.Correlated++;
        else scope.NotCorrelated++;
        if (machine.MdeAntivirusMode === "Active") scope.ActiveMode++;
        else if (["Passive", "PassiveAudit"].includes(machine.MdeAntivirusMode)) scope.PassiveMode++;
        if (machine.ArcStatus === "Connected" || /^vm running$/i.test(String(machine.ArcStatus || ""))) scope.ArcConnected++;
        else if (machine.ArcStatus === "Disconnected" || /^vm (stopped|deallocated)$/i.test(String(machine.ArcStatus || ""))) scope.ArcDisconnected++;
        else scope.ArcOther++;
      }
      if (Array.isArray(machine.MemberGroups) && machine.MemberGroups.length) {
        for (const mg of machine.MemberGroups) {
          const g = ensureGroup(mg.DisplayName || mg.Id, {
            Id: mg.Id,
            CloudType: mg.CloudType || CloudType,
            OSCategory: mg.OSCategory || machine.CloudGroupOS || machine.OS,
            GroupMode: mg.GroupMode || machine.GroupAvMode || "Passive",
            CloudIdentifier: mg.CloudIdentifier || CloudIdentifier
          });
          if (g && machine.Membership === "Present") g.MemberCount++;
          const gScope = ensureScope(g.CloudType || CloudType, g.CloudIdentifier || CloudIdentifier, "", `Entra ID Group (${g.DisplayName})`);
          if (gScope) gScope.GroupNames.add(g.DisplayName);
        }
      } else if (machine.GroupName) {
        const g = ensureGroup(machine.GroupName, {
          Id: machine.GroupId || "",
          CloudType,
          OSCategory: machine.CloudGroupOS || machine.OS || "",
          GroupMode: machine.GroupAvMode || "Passive",
          CloudIdentifier
        });
        if (g && machine.Membership === "Present") g.MemberCount++;
        if (scope) scope.GroupNames.add(machine.GroupName);
      }
    }
    const scopes = [...scopeMap.values()].sort((a, b) =>
      collator.compare(a.CloudType, b.CloudType) || collator.compare(a.CloudIdentifier, b.CloudIdentifier)
    );
    const mgMap = new Map();
    const rawMgs = String(health?.Parameters?.SYNC_MANAGEMENT_GROUP_IDS || "")
      .split(",")
      .map(v => v.trim())
      .filter(v => v && v.toLowerCase() !== "none");
    const ensureMg = mgName => {
      if (!mgName) return null;
      const key = mgName.toLowerCase();
      if (!mgMap.has(key)) {
        mgMap.set(key, {
          Key: key,
          CloudType: "Azure Management Group",
          CloudIdentifier: mgName,
          SubscriptionId: "",
          ManagementGroup: mgName,
          ScopeCount: 0,
          TotalServers: 0,
          OnboardedToMde: 0,
          Correlated: 0,
          NotCorrelated: 0,
          ActiveMode: 0,
          PassiveMode: 0,
          ArcConnected: 0,
          ArcDisconnected: 0,
          ArcOther: 0
        });
      }
      return mgMap.get(key);
    };
    for (const mg of rawMgs) ensureMg(mg);
    for (const s of scopes) {
      if (!s.ManagementGroup) continue;
      const mgEntry = ensureMg(s.ManagementGroup);
      if (mgEntry) {
        mgEntry.ScopeCount++;
        mgEntry.TotalServers += s.TotalServers;
        mgEntry.OnboardedToMde += s.OnboardedToMde;
        mgEntry.Correlated += s.Correlated;
        mgEntry.NotCorrelated += s.NotCorrelated;
        mgEntry.ActiveMode += s.ActiveMode;
        mgEntry.PassiveMode += s.PassiveMode;
        mgEntry.ArcConnected += s.ArcConnected;
        mgEntry.ArcDisconnected += s.ArcDisconnected;
        mgEntry.ArcOther += s.ArcOther;
      }
    }
    const managementGroups = [...mgMap.values()].sort((a, b) => collator.compare(a.CloudIdentifier, b.CloudIdentifier));
    const groups = [...groupMap.values()].sort((a, b) =>
      collator.compare(a.CloudType, b.CloudType) || collator.compare(a.DisplayName, b.DisplayName)
    );
    return { scopes, managementGroups, groups };
  }
  function renderCoverageReport() {
    const { scopes, managementGroups, groups } = buildCoverageData(machines, latestHealth);
    const emptyScopes = scopes.filter(s => s.TotalServers === 0);
    const emptyGroups = groups.filter(g => g.MemberCount === 0);
    const populatedGroups = groups.filter(g => g.MemberCount > 0);
    const awsScopes = scopes.filter(s => s.CloudType === "AWS");
    const gcpScopes = scopes.filter(s => s.CloudType === "GCP");
    const azureScopes = scopes.filter(s => s.CloudType === "Azure");
    const totalOnboarded = machines.filter(m => m.MdeOnboardingStatus === "Onboarded").length;
    const totalCorrelated = machines.filter(isMachineCorrelated).length;
    const totalNotCorrelated = machines.length - totalCorrelated;
    const totalActive = machines.filter(m => m.MdeAntivirusMode === "Active").length;
    const totalPassive = machines.filter(m => ["Passive", "PassiveAudit"].includes(m.MdeAntivirusMode)).length;
    const totalConnected = machines.filter(m => m.ArcStatus === "Connected" || /^vm running$/i.test(String(m.ArcStatus || ""))).length;
    const totalDisconnected = machines.filter(m => m.ArcStatus === "Disconnected" || /^vm (stopped|deallocated)$/i.test(String(m.ArcStatus || ""))).length;
    const kpis = [
      ["Total servers", String(machines.length), `${totalConnected} Connected · ${totalDisconnected} Disconnected`],
      ["AWS Accounts", `${awsScopes.length} (${awsScopes.filter(s => s.TotalServers === 0).length} empty)`, `${awsScopes.reduce((n, s) => n + s.TotalServers, 0)} servers across AWS accounts`],
      ["GCP Projects", `${gcpScopes.length} (${gcpScopes.filter(s => s.TotalServers === 0).length} empty)`, `${gcpScopes.reduce((n, s) => n + s.TotalServers, 0)} servers across GCP projects`],
      ["Azure Subscriptions", `${azureScopes.length} (${azureScopes.filter(s => s.TotalServers === 0).length} empty)`, `${azureScopes.reduce((n, s) => n + s.TotalServers, 0)} servers across Azure subscriptions`],
      ["Azure Management Groups", `${managementGroups.length} (${managementGroups.filter(m => m.TotalServers === 0).length} empty)`, `${managementGroups.reduce((n, m) => n + m.TotalServers, 0)} servers across Azure management groups`],
      ["# Onboarded to MDE", String(totalOnboarded), `${machines.length - totalOnboarded} not onboarded`],
      ["# Correlated / Not correlated", `${totalCorrelated} / ${totalNotCorrelated}`, `${totalCorrelated} correlated to Entra ID · ${totalNotCorrelated} not correlated`],
      ["# Active / Passive mode", `${totalActive} / ${totalPassive}`, `${totalActive} Active mode · ${totalPassive} Passive mode`],
      ["Entra ID groups (0 members)", `${emptyGroups.length} of ${groups.length}`, `${populatedGroups.length} with members · ${emptyGroups.length} without any members`],
      ["Cloud scopes with 0 servers", String(emptyScopes.length), `${emptyScopes.length} AWS Account(s), GCP Project(s), or Subscription(s) with no servers`]
    ];
    const summaryEl = byId("coverage-summary");
    summaryEl.replaceChildren(...kpis.map(([label, value, detail]) => {
      const card = text("div", "", "card");
      card.append(text("strong", value), text("span", label));
      bindHoverPopover(card, () => ["COVERAGE METRIC EXPLANATION", [
        ["Metric", label],
        ["Current value", value],
        ["Breakdown", detail]
      ]]);
      return card;
    }));
    const mgSelect = byId("coverage-mg-filter");
    if (mgSelect) {
      const prevMg = mgSelect.value;
      const mgValues = [...new Set(scopes.map(s => s.ManagementGroup).filter(Boolean))].sort();
      mgSelect.replaceChildren(text("option", "All management groups"));
      mgSelect.firstChild.value = "";
      for (const mg of mgValues) {
        const opt = text("option", mg);
        opt.value = mg;
        mgSelect.append(opt);
      }
      mgSelect.value = mgValues.includes(prevMg) ? prevMg : "";
    }
    const selectedMg = byId("coverage-mg-filter")?.value || "";
    const accountSearch = (byId("coverage-account-search")?.value || "").trim().toLowerCase();
    const isMgTab = coverageCloudFilter === "ManagementGroup";
    const sourceRows = isMgTab ? managementGroups : scopes;
    const filteredScopes = sourceRows.filter(s =>
      (isMgTab ? true : coverageCloudFilter === "all" ? true : coverageCloudFilter === "empty" ? s.TotalServers === 0 : s.CloudType === coverageCloudFilter) &&
      (!selectedMg || s.ManagementGroup === selectedMg) &&
      (!accountSearch || `${s.CloudType} ${s.CloudIdentifier} ${s.SubscriptionId} ${s.ManagementGroup}`.toLowerCase().includes(accountSearch))
    );
    byId("coverage-accounts-count").textContent = isMgTab ?
      `${filteredScopes.length} of ${managementGroups.length} Azure Management Groups (${managementGroups.filter(m => m.TotalServers === 0).length} with 0 servers).` :
      `${filteredScopes.length} of ${scopes.length} cloud accounts, projects, and subscriptions (${emptyScopes.length} with 0 servers).`;
    const accountsBody = byId("coverage-accounts-body");
    accountsBody.replaceChildren();
    for (const s of filteredScopes) {
      const row = document.createElement("tr");
      const idLabel = isMgTab ? `${s.CloudIdentifier} (${s.ScopeCount} scope${s.ScopeCount === 1 ? "" : "s"})` : (s.SubscriptionId ? `${s.CloudIdentifier} (${s.SubscriptionId})` : s.CloudIdentifier);
      const totalCell = document.createElement("td");
      totalCell.append(text("span", s.TotalServers === 0 ? "0 (No servers)" : String(s.TotalServers), s.TotalServers === 0 ? "badge attention" : "status-value good"));
      const arcCell = text("td", `Connected: ${s.ArcConnected} · Disconnected: ${s.ArcDisconnected}${s.ArcOther ? ` · Other: ${s.ArcOther}` : ""}`);
      row.append(
        text("td", s.CloudType),
        text("td", idLabel),
        text("td", s.ManagementGroup || missing),
        totalCell,
        text("td", String(s.OnboardedToMde)),
        text("td", String(s.Correlated)),
        text("td", String(s.NotCorrelated)),
        text("td", String(s.ActiveMode)),
        text("td", String(s.PassiveMode)),
        arcCell
      );
      accountsBody.append(row);
    }
    if (!filteredScopes.length) {
      const emptyRow = document.createElement("tr");
      const cell = text("td", "No cloud accounts, projects, or subscriptions match this filter.");
      cell.colSpan = 10;
      emptyRow.append(cell);
      accountsBody.append(emptyRow);
    }
    const groupSearch = (byId("coverage-group-search")?.value || "").trim().toLowerCase();
    const filteredGroups = groups.filter(g =>
      (coverageGroupFilter === "all" ? true : coverageGroupFilter === "empty" ? g.MemberCount === 0 : g.MemberCount > 0) &&
      (!groupSearch || `${g.DisplayName} ${g.CloudType} ${g.OSCategory} ${g.GroupMode} ${g.CloudIdentifier}`.toLowerCase().includes(groupSearch))
    );
    byId("coverage-groups-count").textContent = `${filteredGroups.length} of ${groups.length} Entra ID groups (${populatedGroups.length} with members, ${emptyGroups.length} without any members).`;
    const groupsBody = byId("coverage-groups-body");
    groupsBody.replaceChildren();
    for (const g of filteredGroups) {
      const row = document.createElement("tr");
      const nameCell = document.createElement("td");
      appendLink(nameCell, g.DisplayName, groupLinkById(g.Id));
      const osCell = document.createElement("td");
      osCell.append(osNode(g.OSCategory || missing));
      const statusCell = document.createElement("td");
      statusCell.append(text("span", g.MemberCount === 0 ? "Empty (0 members)" : `${g.MemberCount} member${g.MemberCount === 1 ? "" : "s"}`, `badge ${g.MemberCount === 0 ? "attention" : "good"}`));
      row.append(
        nameCell,
        text("td", g.CloudType || missing),
        osCell,
        text("td", g.GroupMode || missing),
        text("td", g.CloudIdentifier || missing),
        text("td", String(g.MemberCount)),
        statusCell
      );
      groupsBody.append(row);
    }
    if (!filteredGroups.length) {
      const emptyRow = document.createElement("tr");
      const cell = text("td", "No Entra ID groups match this filter.");
      cell.colSpan = 7;
      emptyRow.append(cell);
      groupsBody.append(emptyRow);
    }
    const filteredEmptyScopes = emptyScopes.filter(s => !selectedMg || s.ManagementGroup === selectedMg);
    byId("coverage-empty-scopes-count").textContent = `${filteredEmptyScopes.length} AWS Account(s), GCP Project(s), or Azure Subscription(s) with 0 servers.`;
    const emptyBody = byId("coverage-empty-scopes-body");
    emptyBody.replaceChildren();
    for (const s of filteredEmptyScopes) {
      const row = document.createElement("tr");
      const idLabel = s.SubscriptionId ? `${s.CloudIdentifier} (${s.SubscriptionId})` : s.CloudIdentifier;
      const groupsText = [...s.GroupNames].join(", ") || "None created yet";
      const countCell = document.createElement("td");
      countCell.append(text("span", "0 servers", "badge attention"));
      row.append(
        text("td", s.CloudType),
        text("td", idLabel),
        text("td", s.ManagementGroup || missing),
        text("td", s.Source),
        text("td", groupsText),
        countCell
      );
      emptyBody.append(row);
    }
    if (!filteredEmptyScopes.length) {
      const emptyRow = document.createElement("tr");
      const cell = text("td", "All discovered AWS Accounts, GCP Projects, and Azure Subscriptions currently have at least 1 server.");
      cell.colSpan = 6;
      emptyRow.append(cell);
      emptyBody.append(emptyRow);
    }
  }
  async function refresh(forceRefresh = false) {
    if (busy) return;
    busy = true;
    byId("refresh-coverage").disabled = true;
    try {
      const [items, health] = await Promise.all([allMachines(forceRefresh), get("health", forceRefresh)]);
      machines = items;
      latestHealth = health || {};
      const nowIso = new Date().toISOString();
      renderCoverageReport();
      saveCachedSnapshot(items, latestHealth, nowIso);
      byId("updated").textContent = `Report refreshed: ${time(nowIso)}`;
      byId("error").hidden = true;
    } catch (error) {
      byId("error").textContent = `${error.message} Displayed results, if any, are from the last successful refresh.`;
      byId("error").hidden = false;
    } finally {
      byId("refresh-coverage").disabled = false;
      busy = false;
    }
  }
  byId("refresh-coverage").addEventListener("click", () => refresh(true));
  byId("theme-toggle").addEventListener("click", () => setTheme(currentTheme() === "dark" ? "light" : "dark"));
  byId("coverage-account-search").addEventListener("input", renderCoverageReport);
  byId("coverage-mg-filter")?.addEventListener("input", renderCoverageReport);
  byId("coverage-group-search").addEventListener("input", renderCoverageReport);
  for (const tab of document.querySelectorAll("#coverage-cloud-tabs button[data-cloud-filter]")) {
    tab.addEventListener("click", () => {
      coverageCloudFilter = tab.dataset.cloudFilter;
      for (const btn of document.querySelectorAll("#coverage-cloud-tabs button[data-cloud-filter]")) {
        btn.setAttribute("aria-pressed", String(btn === tab));
      }
      renderCoverageReport();
    });
  }
  for (const tab of document.querySelectorAll("#coverage-group-tabs button[data-group-filter]")) {
    tab.addEventListener("click", () => {
      coverageGroupFilter = tab.dataset.groupFilter;
      for (const btn of document.querySelectorAll("#coverage-group-tabs button[data-group-filter]")) {
        btn.setAttribute("aria-pressed", String(btn === tab));
      }
      renderCoverageReport();
    });
  }
  byId("hover-popover").addEventListener("mouseenter", clearHoverTimer);
  byId("hover-popover").addEventListener("mouseleave", event => {
    if (activeHoverCell?.contains(event.relatedTarget)) return;
    scheduleHideHoverPopover();
  });
  window.addEventListener("scroll", hideHoverPopover, { passive: true });
  window.addEventListener("resize", () => { if (activeHoverCell) positionHoverPopover(activeHoverCell); });
  updateThemeButton();
  const cachedAgeMs = Date.now() - loadCachedSnapshot();
  if (cachedAgeMs > 30000) void refresh(false);
  window.setInterval(() => { if (!document.hidden) void refresh(false); }, 60000);
})();
