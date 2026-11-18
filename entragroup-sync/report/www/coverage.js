"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const base = window.location.pathname.startsWith("/api/report") ? "/api/report/" : "/";
  const missing = "Not available";
  const themePreferenceKey = "arc-entra-theme-v2";
  const dataCacheKey = "arc-entra-data-cache-v1";
  const drillFilterStorageKey = "arc-entra-drill-filter-v1";
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  let machines = [];
  let latestHealth = {};
  let busy = false;
  let mdeReportFilter = "all";
  let coverageCloudFilter = "all";
  let coverageGroupFilter = "all";
  let selectedGroupKey = "";
  let coverageCardKey = "";
  let mdeCardKey = "";
  let groupCardKey = "";
  function applyTableColumnFilters(table) {
    if (!table) return;
    const filterRow = table.querySelector("thead tr.column-filters");
    const tbody = table.querySelector("tbody");
    if (!filterRow || !tbody) return;
    const inputs = [...filterRow.querySelectorAll("input")];
    const active = inputs.map((inp, idx) => [idx, (inp.value || "").trim().toLowerCase()]).filter(([, val]) => val);
    for (const row of tbody.rows) {
      if (row.cells.length === 1 && row.cells[0].colSpan > 1) continue;
      const visible = active.every(([idx, val]) => String(row.cells[idx]?.textContent || "").toLowerCase().includes(val));
      row.hidden = !visible;
    }
  }
  function initTableColumnFilters() {
    for (const table of document.querySelectorAll("table")) {
      const thead = table.querySelector("thead");
      if (!thead || thead.querySelector("tr.column-filters")) continue;
      const headerRow = thead.querySelector("tr");
      if (!headerRow) continue;
      const filterRow = document.createElement("tr");
      filterRow.className = "column-filters";
      for (const th of headerRow.children) {
        const label = (th.textContent || "").trim() || "column";
        const td = document.createElement("td");
        const input = document.createElement("input");
        input.type = "search";
        input.placeholder = `Filter ${label}`;
        input.setAttribute("aria-label", `Filter ${label}`);
        input.addEventListener("input", () => applyTableColumnFilters(table));
        td.append(input);
        filterRow.append(td);
      }
      thead.append(filterRow);
    }
  }
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
  function inventoryHref(params = {}) {
    const query = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) {
      if (v !== undefined && v !== null && String(v) !== "") query.set(k, String(v));
    }
    const qs = query.toString();
    return qs ? `${base}?${qs}#inventory` : `${base}#inventory`;
  }
  function inventoryLinkNode(label, params = {}, className = "") {
    const cls = ["report-drill-link", className].filter(Boolean).join(" ");
    const link = text("a", String(label ?? ""), cls);
    const href = inventoryHref(params);
    link.href = href;
    link.title = "View matching servers in Device inventory";
    link.addEventListener("click", event => {
      event.stopPropagation();
      try {
        const query = new URLSearchParams();
        for (const [k, v] of Object.entries(params)) {
          if (v !== undefined && v !== null && String(v) !== "") query.set(k, String(v));
        }
        sessionStorage.setItem(drillFilterStorageKey, query.toString());
      } catch {}
    });
    return link;
  }
  function inventoryLinkCell(label, params = {}, className = "") {
    const td = document.createElement("td");
    td.className = "report-drill-cell";
    const link = inventoryLinkNode(label, params, className);
    td.append(link);
    td.addEventListener("click", event => {
      if (event.target === td) {
        event.stopPropagation();
        link.click();
      }
    });
    return td;
  }
  function scopeFilterParams(row) {
    if (!row) return {};
    if (row.CloudType === "Azure Management Group") {
      return { mg: row.CloudIdentifier };
    }
    const params = { scopeType: row.CloudType, scopeId: row.CloudIdentifier };
    if (row.SubscriptionId) params.subscriptionId = row.SubscriptionId;
    return params;
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
    return Boolean(machine?.EntraObjectId || (machine?.EntraDeviceId &&
      ["Verified", "WouldAdd", "Matched", "GroupNotFound", "MissingCloudIdentifier", "GroupNotConfigured"].includes(machine?.Status)));
  }
  function isArcDisconnected(machine) {
    const status = String(machine?.ArcStatus || "").trim();
    return ["Disconnected", "Offline", "Expired"].includes(status) || /^vm (stopped|deallocated)$/i.test(status);
  }
  function isOnboardedArcDisconnected(machine) {
    return machine?.MdeOnboardingStatus === "Onboarded" && isArcDisconnected(machine);
  }
  function inferGroupModeFromName(name, fallback = "") {
    const raw = String(name || "");
    if (/(?:^|[-_\s])active(?:[-_\s]|$)/i.test(raw)) return "Active";
    if (/(?:^|[-_\s])passive(?:[-_\s]|$)/i.test(raw)) return "Passive";
    return fallback;
  }
  function machinePresentGroupInfo(machine) {
    const modes = new Set();
    const present = machine?.Membership === "Present" ||
      (Array.isArray(machine?.MemberGroups) && machine.MemberGroups.some(g => g?.DisplayName || g?.Id));
    if (present) {
      if (Array.isArray(machine?.MemberGroups) && machine.MemberGroups.length) {
        for (const mg of machine.MemberGroups) {
          const mode = mg?.GroupMode || inferGroupModeFromName(mg?.DisplayName, machine?.GroupAvMode || "Passive");
          if (mode === "Active" || mode === "Passive") modes.add(mode);
        }
      } else if (machine?.GroupName) {
        for (const part of String(machine.GroupName).split(";").map(s => s.trim()).filter(Boolean)) {
          const mode = inferGroupModeFromName(part, machine?.GroupAvMode || "Passive");
          if (mode === "Active" || mode === "Passive") modes.add(mode);
        }
      } else if (machine?.GroupAvMode === "Active" || machine?.GroupAvMode === "Passive") {
        modes.add(machine.GroupAvMode);
      }
    }
    const inActiveGroup = modes.has("Active");
    const inPassiveGroup = modes.has("Passive");
    const inBothActiveAndPassive = inActiveGroup && inPassiveGroup;
    const isMdeActive = machine?.MdeAntivirusMode === "Active";
    const isMdePassive = ["Passive", "PassiveAudit"].includes(machine?.MdeAntivirusMode);
    return {
      inActiveGroup,
      inPassiveGroup,
      inBothActiveAndPassive,
      passiveGroupMdeActive: inPassiveGroup && isMdeActive,
      activeGroupMdePassive: inActiveGroup && isMdePassive
    };
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
          SensorActive: 0,
          SensorInactive: 0,
          SensorOther: 0,
          Correlated: 0,
          NotCorrelated: 0,
          ActiveMode: 0,
          PassiveMode: 0,
          OnboardedArcDisconnected: 0,
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
          Key: key,
          DisplayName: displayName,
          Id: meta.Id || "",
          CloudType: meta.CloudType || "",
          OSCategory: meta.OSCategory || "",
          GroupMode: meta.GroupMode || inferGroupModeFromName(displayName, ""),
          CloudIdentifier: meta.CloudIdentifier || "",
          MemberCount: 0,
          BothActiveAndPassiveCount: 0,
          PassiveGroupMdeActiveCount: 0,
          ActiveGroupMdePassiveCount: 0,
          Members: []
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
    let inActiveGroups = 0;
    let inPassiveGroups = 0;
    let inBothActiveAndPassive = 0;
    let passiveGroupMdeActive = 0;
    let activeGroupMdePassive = 0;
    const recordGroupMember = (g, machine, gInfo) => {
      if (!g) return;
      g.MemberCount++;
      g.Members.push(machine);
      if (gInfo.inBothActiveAndPassive) g.BothActiveAndPassiveCount++;
      if (g.GroupMode === "Passive" && machine.MdeAntivirusMode === "Active") g.PassiveGroupMdeActiveCount++;
      if (g.GroupMode === "Active" && ["Passive", "PassiveAudit"].includes(machine.MdeAntivirusMode)) g.ActiveGroupMdePassiveCount++;
    };
    for (const machine of items) {
      const { CloudType, CloudIdentifier, SubscriptionId, ManagementGroup } = resolveMachineCloudScope(machine);
      const gInfo = machinePresentGroupInfo(machine);
      if (gInfo.inActiveGroup) inActiveGroups++;
      if (gInfo.inPassiveGroup) inPassiveGroups++;
      if (gInfo.inBothActiveAndPassive) inBothActiveAndPassive++;
      if (gInfo.passiveGroupMdeActive) passiveGroupMdeActive++;
      if (gInfo.activeGroupMdePassive) activeGroupMdePassive++;
      const scope = ensureScope(CloudType, CloudIdentifier, SubscriptionId, "Discovered server inventory", ManagementGroup);
      if (scope) {
        scope.TotalServers++;
        if (machine.MdeOnboardingStatus === "Onboarded") scope.OnboardedToMde++;
        if (machine.MdeSensorHealth === "Active") scope.SensorActive++;
        else if (machine.MdeSensorHealth === "Inactive") scope.SensorInactive++;
        else if (machine.MdeSensorHealth) scope.SensorOther++;
        if (isMachineCorrelated(machine)) scope.Correlated++;
        else scope.NotCorrelated++;
        if (machine.MdeAntivirusMode === "Active") scope.ActiveMode++;
        else if (["Passive", "PassiveAudit"].includes(machine.MdeAntivirusMode)) scope.PassiveMode++;
        if (isOnboardedArcDisconnected(machine)) scope.OnboardedArcDisconnected++;
        if (machine.ArcStatus === "Connected" || /^vm running$/i.test(String(machine.ArcStatus || ""))) scope.ArcConnected++;
        else if (isArcDisconnected(machine)) scope.ArcDisconnected++;
        else scope.ArcOther++;
      }
      if (Array.isArray(machine.MemberGroups) && machine.MemberGroups.length) {
        for (const mg of machine.MemberGroups) {
          const g = ensureGroup(mg.DisplayName || mg.Id, {
            Id: mg.Id,
            CloudType: mg.CloudType || CloudType,
            OSCategory: mg.OSCategory || machine.CloudGroupOS || machine.OS,
            GroupMode: mg.GroupMode || inferGroupModeFromName(mg.DisplayName, machine.GroupAvMode || "Passive"),
            CloudIdentifier: mg.CloudIdentifier || CloudIdentifier
          });
          if (g && machine.Membership === "Present") recordGroupMember(g, machine, gInfo);
          const gScope = ensureScope(g.CloudType || CloudType, g.CloudIdentifier || CloudIdentifier, "", `Entra ID Group (${g.DisplayName})`);
          if (gScope) gScope.GroupNames.add(g.DisplayName);
        }
      } else if (machine.GroupName) {
        const g = ensureGroup(machine.GroupName, {
          Id: machine.GroupId || "",
          CloudType,
          OSCategory: machine.CloudGroupOS || machine.OS || "",
          GroupMode: machine.GroupAvMode || inferGroupModeFromName(machine.GroupName, "Passive"),
          CloudIdentifier
        });
        if (g && machine.Membership === "Present") recordGroupMember(g, machine, gInfo);
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
    const findExistingMgKey = mgName => {
      const lower = String(mgName || "").toLowerCase();
      if (mgMap.has(lower)) return lower;
      for (const [k, val] of mgMap.entries()) {
        const idLower = String(val.CloudIdentifier || "").toLowerCase();
        if (idLower.endsWith(`(${lower})`) || lower.endsWith(`(${idLower})`)) return k;
      }
      return lower;
    };
    const ensureMg = mgName => {
      if (!mgName) return null;
      const key = findExistingMgKey(mgName);
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
          SensorActive: 0,
          SensorInactive: 0,
          SensorOther: 0,
          Correlated: 0,
          NotCorrelated: 0,
          ActiveMode: 0,
          PassiveMode: 0,
          OnboardedArcDisconnected: 0,
          ArcConnected: 0,
          ArcDisconnected: 0,
          ArcOther: 0
        });
      } else {
        const existing = mgMap.get(key);
        if (String(mgName).includes("(") && !String(existing.CloudIdentifier).includes("(")) {
          existing.CloudIdentifier = mgName;
          existing.ManagementGroup = mgName;
        }
      }
      return mgMap.get(key);
    };
    for (const s of scopes) {
      if (s.ManagementGroup) {
        const mgEntry = ensureMg(s.ManagementGroup);
        if (mgEntry) mgEntry.ScopeCount++;
      }
    }
    for (const mg of rawMgs) ensureMg(mg);
    for (const machine of items) {
      const { ManagementGroup } = resolveMachineCloudScope(machine);
      if (!ManagementGroup) continue;
      const mgEntry = ensureMg(ManagementGroup);
      if (mgEntry) {
        mgEntry.TotalServers++;
        if (machine.MdeOnboardingStatus === "Onboarded") mgEntry.OnboardedToMde++;
        if (machine.MdeSensorHealth === "Active") mgEntry.SensorActive++;
        else if (machine.MdeSensorHealth === "Inactive") mgEntry.SensorInactive++;
        else if (machine.MdeSensorHealth) mgEntry.SensorOther++;
        if (isMachineCorrelated(machine)) mgEntry.Correlated++;
        else mgEntry.NotCorrelated++;
        if (machine.MdeAntivirusMode === "Active") mgEntry.ActiveMode++;
        else if (["Passive", "PassiveAudit"].includes(machine.MdeAntivirusMode)) mgEntry.PassiveMode++;
        if (isOnboardedArcDisconnected(machine)) mgEntry.OnboardedArcDisconnected++;
        if (machine.ArcStatus === "Connected" || /^vm running$/i.test(String(machine.ArcStatus || ""))) mgEntry.ArcConnected++;
        else if (isArcDisconnected(machine)) mgEntry.ArcDisconnected++;
        else mgEntry.ArcOther++;
      }
    }
    const managementGroups = [...mgMap.values()].sort((a, b) => collator.compare(a.CloudIdentifier, b.CloudIdentifier));
    const groups = [...groupMap.values()].sort((a, b) =>
      collator.compare(a.CloudType, b.CloudType) || collator.compare(a.DisplayName, b.DisplayName)
    );
    const groupSummary = {
      inActiveGroups,
      inPassiveGroups,
      inBothActiveAndPassive,
      passiveGroupMdeActive,
      activeGroupMdePassive
    };
    return { scopes, managementGroups, groups, groupSummary };
  }
  function renderGroupMembersTable(selectedGroup) {
    const heading = byId("coverage-group-members-heading");
    const countEl = byId("coverage-group-members-count");
    const body = byId("coverage-group-members-body");
    if (!body) return;
    body.replaceChildren();
    if (!selectedGroup) {
      if (heading) heading.textContent = "Selected Entra ID Group Members";
      if (countEl) countEl.textContent = "Select any Entra ID group row above to view its server members.";
      const emptyRow = document.createElement("tr");
      const cell = text("td", "Click any Entra ID group row in the table above to view its server members.");
      cell.colSpan = 10;
      emptyRow.append(cell);
      body.append(emptyRow);
      return;
    }
    const members = Array.isArray(selectedGroup.Members) ? selectedGroup.Members : [];
    if (heading) heading.textContent = `Group Members — ${selectedGroup.DisplayName}`;
    if (countEl) countEl.textContent = `${members.length} server member${members.length === 1 ? "" : "s"} in ${selectedGroup.DisplayName}.`;
    if (!members.length) {
      const emptyRow = document.createElement("tr");
      const cell = text("td", `No servers are currently members of ${selectedGroup.DisplayName}.`);
      cell.colSpan = 10;
      emptyRow.append(cell);
      body.append(emptyRow);
      return;
    }
    for (const m of members) {
      const tr = document.createElement("tr");
      const { CloudType, CloudIdentifier } = resolveMachineCloudScope(m);
      const nameCell = document.createElement("td");
      nameCell.append(inventoryLinkNode(m.MachineName || m.ComputerName || missing, { group: selectedGroup.DisplayName, membership: "Present" }));
      const osCell = document.createElement("td");
      osCell.append(osNode(m.OS || selectedGroup.OSCategory || missing));
      const groupsLabel = Array.isArray(m.MemberGroups) && m.MemberGroups.length ?
        m.MemberGroups.map(g => g.DisplayName || g.Id).filter(Boolean).join("; ") :
        (m.GroupName || selectedGroup.DisplayName);
      const flagsLabel = Array.isArray(m.GroupFlags) && m.GroupFlags.length ? m.GroupFlags.join("; ") : "Compliant";
      const flagsCell = document.createElement("td");
      flagsCell.append(text("span", flagsLabel, Array.isArray(m.GroupFlags) && m.GroupFlags.length ? "badge attention" : "status-value good"));
      tr.append(
        nameCell,
        text("td", CloudType || selectedGroup.CloudType || missing),
        text("td", CloudIdentifier || selectedGroup.CloudIdentifier || missing),
        osCell,
        text("td", m.MdeOnboardingStatus || missing),
        text("td", m.MdeSensorHealth || missing),
        text("td", m.MdeAntivirusMode || missing),
        text("td", m.ArcStatus || missing),
        text("td", groupsLabel),
        flagsCell
      );
      body.append(tr);
    }
  }
  function renderCoverageReport() {
    const { scopes, managementGroups, groups, groupSummary } = buildCoverageData(machines, latestHealth);
    const emptyScopes = scopes.filter(s => s.TotalServers === 0);
    const emptyGroups = groups.filter(g => g.MemberCount === 0);
    const populatedGroups = groups.filter(g => g.MemberCount > 0);
    const awsScopes = scopes.filter(s => s.CloudType === "AWS");
    const gcpScopes = scopes.filter(s => s.CloudType === "GCP");
    const azureScopes = scopes.filter(s => s.CloudType === "Azure");
    const totalOnboarded = machines.filter(m => m.MdeOnboardingStatus === "Onboarded").length;
    const totalSensorActive = machines.filter(m => m.MdeSensorHealth === "Active").length;
    const totalSensorInactive = machines.filter(m => m.MdeSensorHealth === "Inactive").length;
    const totalSensorOther = machines.filter(m => m.MdeSensorHealth && !["Active", "Inactive"].includes(m.MdeSensorHealth)).length;
    const totalCorrelated = machines.filter(isMachineCorrelated).length;
    const totalNotCorrelated = machines.length - totalCorrelated;
    const totalActive = machines.filter(m => m.MdeAntivirusMode === "Active").length;
    const totalPassive = machines.filter(m => ["Passive", "PassiveAudit"].includes(m.MdeAntivirusMode)).length;
    const totalOnboardedArcDisconnected = machines.filter(isOnboardedArcDisconnected).length;
    const totalConnected = machines.filter(m => m.ArcStatus === "Connected" || /^vm running$/i.test(String(m.ArcStatus || ""))).length;
    const totalDisconnected = machines.filter(isArcDisconnected).length;
    const syncMode = latestHealth?.Parameters?.SYNC_MODE || latestHealth?.SyncMode || "Unknown";
    const defaultGroupMode = latestHealth?.Parameters?.SYNC_DEFAULT_GROUP_MODE || latestHealth?.DefaultGroupMode || "Unknown";
    const syncBadge = byId("header-sync-mode");
    if (syncBadge) {
      syncBadge.textContent = `Sync Mode: ${syncMode} (${syncMode === "Enforce" ? "Adds to group" : syncMode === "Audit" ? "Observe only" : "Awaiting worker settings"})`;
      syncBadge.className = `badge mode-pill ${syncMode === "Enforce" ? "good" : "attention"}`;
      syncBadge.hidden = false;
    }
    const groupModeBadge = byId("header-group-mode");
    if (groupModeBadge) {
      groupModeBadge.textContent = `Default Group: ${defaultGroupMode}`;
      groupModeBadge.className = "badge mode-pill";
      groupModeBadge.hidden = false;
    }
    const kpis = [
      ["all", "Total servers", String(machines.length), `${totalConnected} Connected · ${totalDisconnected} Disconnected`],
      ["AWS", "AWS Accounts", `${awsScopes.length} (${awsScopes.filter(s => s.TotalServers === 0).length} empty)`, `${awsScopes.reduce((n, s) => n + s.TotalServers, 0)} servers across AWS accounts`],
      ["GCP", "GCP Projects", `${gcpScopes.length} (${gcpScopes.filter(s => s.TotalServers === 0).length} empty)`, `${gcpScopes.reduce((n, s) => n + s.TotalServers, 0)} servers across GCP projects`],
      ["Azure", "Azure Subscriptions", `${azureScopes.length} (${azureScopes.filter(s => s.TotalServers === 0).length} empty)`, `${azureScopes.reduce((n, s) => n + s.TotalServers, 0)} servers across Azure subscriptions`],
      ["Azure Management Group", "Azure Management Groups", `${managementGroups.length} (${managementGroups.filter(m => m.TotalServers === 0).length} empty)`, `${managementGroups.reduce((n, m) => n + m.TotalServers, 0)} servers across Azure management groups`],
      ["mde-onboarded", "Onboarded to MDE", String(totalOnboarded), `${machines.length - totalOnboarded} not onboarded`],
      ["mde-arc-disconnected", "Onboarded (Arc Disconnected)", String(totalOnboardedArcDisconnected), `${totalOnboardedArcDisconnected} server(s) onboarded to MDE but disconnected from Azure Arc`],
      ["correlated", "Correlated / Not correlated", `${totalCorrelated} / ${totalNotCorrelated}`, `${totalCorrelated} correlated to Entra ID · ${totalNotCorrelated} not correlated`],
      ["active-passive", "Active / Passive mode", `${totalActive} / ${totalPassive}`, `${totalActive} Active mode · ${totalPassive} Passive mode`],
      ["empty-groups", "Entra ID groups (0 members)", `${emptyGroups.length} of ${groups.length}`, `${populatedGroups.length} with members · ${emptyGroups.length} without any members`],
      ["empty-scopes", "Cloud scopes with 0 servers", String(emptyScopes.length), `${emptyScopes.length} AWS Account(s), GCP Project(s), or Subscription(s) with no servers`]
    ];
    const summaryEl = byId("coverage-summary");
    summaryEl.replaceChildren(...kpis.map(([key, label, value, detail]) => {
      const active = coverageCardKey === key;
      const card = text("button", "", `card${active ? " is-active" : ""}`);
      card.type = "button";
      card.dataset.coverageCard = key;
      card.setAttribute("aria-pressed", String(active));
      card.append(text("strong", value), text("span", label));
      card.addEventListener("click", () => {
        if (key === "all") {
          coverageCardKey = "";
          mdeCardKey = "";
          mdeReportFilter = "all";
          coverageCloudFilter = "all";
          coverageGroupFilter = "all";
          groupCardKey = "";
          selectCoverageSection("coverage-mde-summary");
          renderCoverageReport();
          return;
        }
        coverageCardKey = coverageCardKey === key ? "" : key;
        if (key === "empty-groups") {
          coverageGroupFilter = coverageCardKey ? "empty" : "all";
          for (const btn of document.querySelectorAll("#coverage-group-tabs button[data-group-filter]")) {
            btn.setAttribute("aria-pressed", String(btn.dataset.groupFilter === coverageGroupFilter));
          }
          selectCoverageSection("coverage-groups");
        } else if (key === "empty-scopes") {
          selectCoverageSection("coverage-empty-scopes");
        } else if (["AWS", "GCP", "Azure", "Azure Management Group"].includes(key)) {
          mdeReportFilter = coverageCardKey ? key : "all";
          coverageCloudFilter = coverageCardKey ? (key === "Azure Management Group" ? "ManagementGroup" : key) : "all";
          for (const btn of document.querySelectorAll("#mde-report-tabs button[data-mde-filter]")) {
            btn.setAttribute("aria-pressed", String(btn.dataset.mdeFilter === mdeReportFilter));
          }
          for (const btn of document.querySelectorAll("#coverage-cloud-tabs button[data-cloud-filter]")) {
            btn.setAttribute("aria-pressed", String(btn.dataset.cloudFilter === coverageCloudFilter));
          }
          selectCoverageSection("coverage-mde-summary");
        } else {
          mdeCardKey = coverageCardKey;
          selectCoverageSection("coverage-mde-summary");
        }
        renderCoverageReport();
      });
      bindHoverPopover(card, () => ["COVERAGE METRIC EXPLANATION", [
        ["Metric", label],
        ["Current value", value],
        ["Breakdown", detail],
        ["Action", "Click to filter the corresponding report table"]
      ]]);
      return card;
    }));
    const mdeSummaryEl = byId("mde-report-summary");
    if (mdeSummaryEl) {
      const mdeKpis = [
        ["all", "Total servers", () => { const s = document.createElement("strong"); s.append(inventoryLinkNode(String(machines.length), { all: "1" })); return s; }, `${awsScopes.length} AWS Account(s) · ${gcpScopes.length} GCP Project(s) · ${azureScopes.length} Azure Subscription(s) · ${managementGroups.length} Management Group(s)`],
        ["mde-onboarded", "Onboarded to MDE", () => { const s = document.createElement("strong"); s.append(inventoryLinkNode(String(totalOnboarded), { mde: "Onboarded" })); return s; }, `${machines.length - totalOnboarded} not onboarded to MDE`],
        ["sensor-health", "MDE Sensor Health (Active / Inactive)", () => { const s = document.createElement("strong"); s.append(inventoryLinkNode(String(totalSensorActive), { sensor: "Active" }), text("span", " / "), inventoryLinkNode(String(totalSensorInactive), { sensor: "Inactive" })); return s; }, `${totalSensorActive} Active · ${totalSensorInactive} Inactive${totalSensorOther ? ` · ${totalSensorOther} Other` : ""}`],
        ["correlated", "Correlated / Not correlated", () => { const s = document.createElement("strong"); s.append(inventoryLinkNode(String(totalCorrelated), { corr: "Correlated" }), text("span", " / "), inventoryLinkNode(String(totalNotCorrelated), { corr: "NotCorrelated" })); return s; }, `${totalCorrelated} correlated to Entra ID · ${totalNotCorrelated} not correlated`],
        ["active-mode", "In Active mode", () => { const s = document.createElement("strong"); s.append(inventoryLinkNode(String(totalActive), { av: "Active" })); return s; }, "Servers reporting MDE antivirus mode = Active (scid-2010)"],
        ["passive-mode", "In Passive mode", () => { const s = document.createElement("strong"); s.append(inventoryLinkNode(String(totalPassive), { av: "Passive" })); return s; }, "Servers reporting MDE antivirus mode = Passive / PassiveAudit (scid-2010)"],
        ["mde-arc-disconnected", "Onboarded to MDE, Disconnected from Azure Arc", () => { const s = document.createElement("strong"); s.append(inventoryLinkNode(String(totalOnboardedArcDisconnected), { mde: "Onboarded", arc: "Disconnected" })); return s; }, "Servers with MdeOnboardingStatus == 'Onboarded' whose Arc / VM connectivity status is Disconnected, Offline, Expired, or Stopped/Deallocated"]
      ];
      mdeSummaryEl.replaceChildren(...mdeKpis.map(([key, label, buildStrong, detail]) => {
        const active = mdeCardKey === key && key !== "all";
        const card = text("button", "", `card${active ? " is-active" : ""}`);
        card.type = "button";
        card.dataset.mdeCard = key;
        card.setAttribute("aria-pressed", String(active));
        const strongNode = buildStrong();
        card.append(strongNode, text("span", label));
        card.addEventListener("click", event => {
          if (event.target?.closest("a")) return;
          mdeCardKey = (key === "all" || mdeCardKey === key) ? "" : key;
          renderCoverageReport();
        });
        bindHoverPopover(card, () => ["OVERVIEW REPORT SUMMARY", [
          ["Metric", label],
          ["Count", strongNode.textContent],
          ["Definition", detail],
          ["Action", "Click card to filter Overview table · Click number to open Device Inventory"]
        ]]);
        return card;
      }));
    }
    const matchesMdeCard = r => {
      if (!mdeCardKey) return true;
      if (mdeCardKey === "mde-onboarded") return r.OnboardedToMde > 0;
      if (mdeCardKey === "sensor-health") return (r.SensorActive + r.SensorInactive + r.SensorOther) > 0;
      if (mdeCardKey === "correlated") return r.Correlated > 0;
      if (mdeCardKey === "active-passive") return (r.ActiveMode + r.PassiveMode) > 0;
      if (mdeCardKey === "active-mode") return r.ActiveMode > 0;
      if (mdeCardKey === "passive-mode") return r.PassiveMode > 0;
      if (mdeCardKey === "mde-arc-disconnected") return (r.OnboardedArcDisconnected || 0) > 0;
      return true;
    };
    const mdeBody = byId("mde-report-body");
    if (mdeBody) {
      const scopeTypeLabel = cloudType =>
        cloudType === "AWS" ? "AWS Account" :
        cloudType === "GCP" ? "GCP Project" :
        cloudType === "Azure" ? "Azure Subscription" : "Azure Management Group";
      const allMdeRows = [...scopes, ...managementGroups];
      const mdeSearch = (byId("mde-report-search")?.value || "").trim().toLowerCase();
      const filteredMdeRows = allMdeRows.filter(r =>
        (mdeReportFilter === "all" ? true : r.CloudType === mdeReportFilter) &&
        matchesMdeCard(r) &&
        (!mdeSearch || `${scopeTypeLabel(r.CloudType)} ${r.CloudType} ${r.CloudIdentifier} ${r.SubscriptionId} ${r.ManagementGroup}`.toLowerCase().includes(mdeSearch))
      );
      if (byId("mde-report-count")) {
        byId("mde-report-count").textContent = `${filteredMdeRows.length} of ${allMdeRows.length} scopes (${awsScopes.length} AWS Accounts, ${gcpScopes.length} GCP Projects, ${azureScopes.length} Azure Subscriptions, ${managementGroups.length} Azure Management Groups).`;
      }
      mdeBody.replaceChildren();
      for (const r of filteredMdeRows) {
        const tr = document.createElement("tr");
        const baseParams = scopeFilterParams(r);
        const idLabel = r.CloudType === "Azure Management Group" ?
          `${r.CloudIdentifier} (${r.ScopeCount} scope${r.ScopeCount === 1 ? "" : "s"})` :
          (r.SubscriptionId ? `${r.CloudIdentifier} (${r.SubscriptionId})` : r.CloudIdentifier);
        const sensorCell = document.createElement("td");
        sensorCell.append(
          inventoryLinkNode(`Active: ${r.SensorActive || 0}`, { ...baseParams, sensor: "Active" }),
          text("span", " · "),
          inventoryLinkNode(`Inactive: ${r.SensorInactive || 0}`, { ...baseParams, sensor: "Inactive" })
        );
        if (r.SensorOther) {
          sensorCell.append(
            text("span", " · "),
            inventoryLinkNode(`Other: ${r.SensorOther}`, { ...baseParams, sensor: "Other" })
          );
        }
        tr.append(
          text("td", scopeTypeLabel(r.CloudType)),
          text("td", idLabel),
          inventoryLinkCell(String(r.TotalServers), baseParams, r.TotalServers === 0 ? "badge attention" : "status-value good"),
          inventoryLinkCell(String(r.OnboardedToMde), { ...baseParams, mde: "Onboarded" }),
          sensorCell,
          inventoryLinkCell(String(r.Correlated), { ...baseParams, corr: "Correlated" }),
          inventoryLinkCell(String(r.NotCorrelated), { ...baseParams, corr: "NotCorrelated" }),
          inventoryLinkCell(String(r.ActiveMode), { ...baseParams, av: "Active" }),
          inventoryLinkCell(String(r.PassiveMode), { ...baseParams, av: "Passive" }),
          inventoryLinkCell(String(r.OnboardedArcDisconnected || 0), { ...baseParams, mde: "Onboarded", arc: "Disconnected" }, (r.OnboardedArcDisconnected || 0) > 0 ? "badge attention" : "status-value good")
        );
        mdeBody.append(tr);
      }
      if (!filteredMdeRows.length) {
        const emptyRow = document.createElement("tr");
        const cell = text("td", "No AWS Accounts, GCP Projects, Azure Subscriptions, or Azure Management Groups match this filter.");
        cell.colSpan = 10;
        emptyRow.append(cell);
        mdeBody.append(emptyRow);
      }
    }
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
      const baseParams = scopeFilterParams(s);
      const idLabel = isMgTab ? `${s.CloudIdentifier} (${s.ScopeCount} scope${s.ScopeCount === 1 ? "" : "s"})` : (s.SubscriptionId ? `${s.CloudIdentifier} (${s.SubscriptionId})` : s.CloudIdentifier);
      const arcCell = document.createElement("td");
      arcCell.append(
        inventoryLinkNode(`Connected: ${s.ArcConnected}`, { ...baseParams, arc: "Connected" }),
        text("span", " · "),
        inventoryLinkNode(`Disconnected: ${s.ArcDisconnected}`, { ...baseParams, arc: "Disconnected" })
      );
      if (s.ArcOther) {
        arcCell.append(
          text("span", " · "),
          inventoryLinkNode(`Other: ${s.ArcOther}`, { ...baseParams, arc: "Other" })
        );
      }
      row.append(
        text("td", s.CloudType),
        text("td", idLabel),
        text("td", s.ManagementGroup || missing),
        inventoryLinkCell(s.TotalServers === 0 ? "0 (No servers)" : String(s.TotalServers), baseParams, s.TotalServers === 0 ? "badge attention" : "status-value good"),
        inventoryLinkCell(String(s.OnboardedToMde), { ...baseParams, mde: "Onboarded" }),
        inventoryLinkCell(String(s.Correlated), { ...baseParams, corr: "Correlated" }),
        inventoryLinkCell(String(s.NotCorrelated), { ...baseParams, corr: "NotCorrelated" }),
        inventoryLinkCell(String(s.ActiveMode), { ...baseParams, av: "Active" }),
        inventoryLinkCell(String(s.PassiveMode), { ...baseParams, av: "Passive" }),
        inventoryLinkCell(String(s.OnboardedArcDisconnected || 0), { ...baseParams, mde: "Onboarded", arc: "Disconnected" }),
        arcCell
      );
      accountsBody.append(row);
    }
    if (!filteredScopes.length) {
      const emptyRow = document.createElement("tr");
      const cell = text("td", "No cloud accounts, projects, or subscriptions match this filter.");
      cell.colSpan = 11;
      emptyRow.append(cell);
      accountsBody.append(emptyRow);
    }
    const groupSummaryEl = byId("coverage-groups-summary");
    if (groupSummaryEl && groupSummary) {
      const groupKpis = [
        [
          "active-passive",
          "Servers in Active / Passive Groups",
          () => {
            const strong = document.createElement("strong");
            strong.append(
              inventoryLinkNode(`${groupSummary.inActiveGroups} Active`, { groupFilter: "ActiveGroup" }),
              text("span", " / "),
              inventoryLinkNode(`${groupSummary.inPassiveGroups} Passive`, { groupFilter: "PassiveGroup" })
            );
            return strong;
          },
          `${groupSummary.inActiveGroups} in Active groups · ${groupSummary.inPassiveGroups} in Passive groups`
        ],
        [
          "both-groups",
          "Servers in Both Active & Passive Groups",
          () => {
            const strong = document.createElement("strong");
            strong.append(inventoryLinkNode(String(groupSummary.inBothActiveAndPassive), { groupFilter: "BothActiveAndPassive" }));
            return strong;
          },
          "Servers that are members of both an Active and a Passive Entra ID security group simultaneously"
        ],
        [
          "passive-mde-active",
          "In Passive Group (MDE in Active Mode)",
          () => {
            const strong = document.createElement("strong");
            strong.append(inventoryLinkNode(String(groupSummary.passiveGroupMdeActive), { groupFilter: "PassiveGroupMdeActive" }));
            return strong;
          },
          "Servers in a Passive Entra ID security group whose MDE Antivirus mode is Active"
        ],
        [
          "active-mde-passive",
          "In Active Group (MDE in Passive Mode)",
          () => {
            const strong = document.createElement("strong");
            strong.append(inventoryLinkNode(String(groupSummary.activeGroupMdePassive), { groupFilter: "ActiveGroupMdePassive" }));
            return strong;
          },
          "Servers in an Active Entra ID security group whose MDE Antivirus mode is Passive / PassiveAudit"
        ]
      ];
      groupSummaryEl.replaceChildren(...groupKpis.map(([key, label, buildStrong, detail]) => {
        const active = groupCardKey === key;
        const card = text("button", "", `card${active ? " is-active" : ""}`);
        card.type = "button";
        card.dataset.groupCard = key;
        card.setAttribute("aria-pressed", String(active));
        const strongNode = buildStrong();
        card.append(strongNode, text("span", label));
        card.addEventListener("click", event => {
          if (event.target?.closest("a")) return;
          groupCardKey = groupCardKey === key ? "" : key;
          selectedGroupKey = "";
          renderCoverageReport();
        });
        bindHoverPopover(card, () => ["ENTRA ID GROUP SUMMARY", [
          ["Metric", label],
          ["Count", strongNode.textContent],
          ["Definition", detail],
          ["Action", "Click card to filter Group Summary table · Click number to open Device Inventory"]
        ]]);
        return card;
      }));
    }
    const matchesGroupCard = g => {
      if (!groupCardKey) return true;
      if (groupCardKey === "active-passive") return g.MemberCount > 0;
      if (groupCardKey === "both-groups") return (g.BothActiveAndPassiveCount || 0) > 0;
      if (groupCardKey === "passive-mde-active") return (g.PassiveGroupMdeActiveCount || 0) > 0;
      if (groupCardKey === "active-mde-passive") return (g.ActiveGroupMdePassiveCount || 0) > 0;
      return true;
    };
    const groupSearch = (byId("coverage-group-search")?.value || "").trim().toLowerCase();
    const filteredGroups = groups.filter(g =>
      (coverageGroupFilter === "all" ? true : coverageGroupFilter === "empty" ? g.MemberCount === 0 : g.MemberCount > 0) &&
      matchesGroupCard(g) &&
      (!groupSearch || `${g.DisplayName} ${g.CloudType} ${g.OSCategory} ${g.GroupMode} ${g.CloudIdentifier}`.toLowerCase().includes(groupSearch))
    );
    byId("coverage-groups-count").textContent = `${filteredGroups.length} of ${groups.length} Entra ID groups (${populatedGroups.length} with members, ${emptyGroups.length} without any members).`;
    const groupsBody = byId("coverage-groups-body");
    groupsBody.replaceChildren();
    if (!selectedGroupKey && filteredGroups.length) {
      const firstPopulated = filteredGroups.find(g => g.MemberCount > 0) || filteredGroups[0];
      selectedGroupKey = firstPopulated.Key;
    }
    for (const g of filteredGroups) {
      const row = document.createElement("tr");
      row.dataset.groupKey = g.Key;
      row.tabIndex = 0;
      row.style.cursor = "pointer";
      const isSelected = g.Key === selectedGroupKey;
      row.classList.toggle("is-selected", isSelected);
      row.setAttribute("aria-selected", String(isSelected));
      const selectRow = event => {
        if (event.target?.closest("a")) return;
        selectedGroupKey = g.Key;
        for (const tr of groupsBody.rows) {
          const active = tr.dataset.groupKey === selectedGroupKey;
          tr.classList.toggle("is-selected", active);
          tr.setAttribute("aria-selected", String(active));
        }
        renderGroupMembersTable(g);
      };
      row.addEventListener("click", selectRow);
      row.addEventListener("keydown", event => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          selectRow(event);
        }
      });
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
        inventoryLinkCell(String(g.MemberCount), { group: g.DisplayName, membership: "Present" }),
        inventoryLinkCell(String(g.BothActiveAndPassiveCount || 0), { group: g.DisplayName, membership: "Present", groupFilter: "BothActiveAndPassive" }, (g.BothActiveAndPassiveCount || 0) > 0 ? "badge attention" : ""),
        inventoryLinkCell(String(g.PassiveGroupMdeActiveCount || 0), { group: g.DisplayName, membership: "Present", groupFilter: "PassiveGroupMdeActive" }, (g.PassiveGroupMdeActiveCount || 0) > 0 ? "badge attention" : ""),
        inventoryLinkCell(String(g.ActiveGroupMdePassiveCount || 0), { group: g.DisplayName, membership: "Present", groupFilter: "ActiveGroupMdePassive" }, (g.ActiveGroupMdePassiveCount || 0) > 0 ? "badge attention" : ""),
        statusCell
      );
      groupsBody.append(row);
    }
    if (!filteredGroups.length) {
      const emptyRow = document.createElement("tr");
      const cell = text("td", "No Entra ID groups match this filter.");
      cell.colSpan = 10;
      emptyRow.append(cell);
      groupsBody.append(emptyRow);
    }
    renderGroupMembersTable(groups.find(g => g.Key === selectedGroupKey) || null);
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
    for (const table of document.querySelectorAll("table")) applyTableColumnFilters(table);
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
  byId("mde-report-search")?.addEventListener("input", renderCoverageReport);
  byId("coverage-account-search").addEventListener("input", renderCoverageReport);
  byId("coverage-mg-filter")?.addEventListener("input", renderCoverageReport);
  byId("coverage-group-search").addEventListener("input", renderCoverageReport);
  for (const tab of document.querySelectorAll("#mde-report-tabs button[data-mde-filter]")) {
    tab.addEventListener("click", () => {
      mdeReportFilter = tab.dataset.mdeFilter;
      for (const btn of document.querySelectorAll("#mde-report-tabs button[data-mde-filter]")) {
        btn.setAttribute("aria-pressed", String(btn === tab));
      }
      renderCoverageReport();
    });
  }
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
  function selectCoverageSection(targetId) {
    const ids = ["coverage-mde-summary", "coverage-accounts", "coverage-groups", "coverage-empty-scopes"];
    const activeId = ids.includes(targetId) ? targetId : "coverage-mde-summary";
    for (const id of ids) {
      const el = byId(id);
      if (el) el.hidden = id !== activeId;
    }
    for (const btn of document.querySelectorAll("#coverage-section-tabs button[data-section-tab]")) {
      const active = btn.dataset.sectionTab === activeId;
      btn.classList.toggle("is-active", active);
      btn.setAttribute("aria-selected", String(active));
    }
  }
  for (const btn of document.querySelectorAll("#coverage-section-tabs button[data-section-tab]")) {
    btn.addEventListener("click", () => selectCoverageSection(btn.dataset.sectionTab));
  }
  for (const link of document.querySelectorAll('.sidebar a[href*="#coverage-"]')) {
    link.addEventListener("click", event => {
      const hash = (link.getAttribute("href") || "").split("#")[1];
      if (hash && byId(hash)) {
        event.preventDefault();
        selectCoverageSection(hash);
      }
    });
  }
  window.addEventListener("hashchange", () => {
    const hashId = String(window.location.hash || "").replace(/^#/, "");
    if (hashId && byId(hashId)) selectCoverageSection(hashId);
  });
  const initialCoverageHash = String(window.location.hash || "").replace(/^#/, "");
  selectCoverageSection(initialCoverageHash && byId(initialCoverageHash) ? initialCoverageHash : "coverage-mde-summary");
  byId("hover-popover").addEventListener("mouseenter", clearHoverTimer);
  byId("hover-popover").addEventListener("mouseleave", event => {
    if (activeHoverCell?.contains(event.relatedTarget)) return;
    scheduleHideHoverPopover();
  });
  window.addEventListener("scroll", hideHoverPopover, { passive: true });
  window.addEventListener("resize", () => { if (activeHoverCell) positionHoverPopover(activeHoverCell); });
  initTableColumnFilters();
  updateThemeButton();
  const cachedAgeMs = Date.now() - loadCachedSnapshot();
  if (cachedAgeMs > 30000) void refresh(false);
  window.setInterval(() => { if (!document.hidden) void refresh(false); }, 60000);
})();
