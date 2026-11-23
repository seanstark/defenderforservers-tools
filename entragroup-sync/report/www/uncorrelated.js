"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const base = window.location.pathname.startsWith("/api/report") ? "/api/report/" : "/";
  const missing = "Not available";
  const themePreferenceKey = "arc-entra-theme-v2";
  const pageSizePreferenceKey = "arc-entra-page-size-v1";
  const dataCacheKey = "arc-entra-data-cache-v1";
  const idbDatabaseName = "arc-entra-cache-db";
  const idbStoreName = "snapshots";
  const cacheFreshnessMs = 300000;
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

  let allInventoryMachines = [];
  let uncorrelatedMachines = [];
  let latestHealth = {};
  let busy = false;
  let cardFilterKey = "";
  let currentPage = 1;
  let pageSize = 50;
  let filterDebounceTimer = 0;
  let selectedKey = "";
  let historyCursor = "";
  let historyGeneration = 0;
  let historyBusy = false;
  let historyTrigger = null;
  let historyCount = 0;
  let historyCursors = new Set();
  let activeHoverCell = null;
  let hoverHideTimer = 0;
  let currentModalEntry = null;
  let scriptModalErrorsOnly = false;
  const columnFilters = {};
  let sortState = { id: "MachineName", direction: "asc" };

  const time = value => value ? new Date(value).toLocaleString() : "Not observed";
  const text = (tag, value, className) => {
    const element = document.createElement(tag);
    element.textContent = String(value ?? "");
    if (className) element.className = className;
    return element;
  };
  const joined = value => Array.isArray(value) ? value.join("; ") : String(value ?? "");

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

  function hasEntraCorrelation(machine) {
    return Boolean(machine?.EntraObjectId || (machine?.EntraDeviceId &&
      ["Verified", "WouldAdd", "Matched", "GroupNotFound", "MissingCloudIdentifier", "GroupNotConfigured"].includes(machine?.Status)));
  }

  function isNativeAzureMachine(machine) {
    const id = String(machine?.ArcResourceId || "").toLowerCase();
    return id.includes("/providers/microsoft.compute/") || id.includes("/providers/microsoft.classiccompute/");
  }

  function machineKindLabel(machine) {
    const id = String(machine?.ArcResourceId || "").toLowerCase();
    if (id.includes("/providers/microsoft.compute/virtualmachinescalesets/")) return "Azure VMSS";
    if (isNativeAzureMachine(machine)) return "Azure VM";
    if (isAwsMachine(machine)) return "AWS Arc";
    if (String(machine?.CloudGroupType || "").toUpperCase() === "GCP") return "GCP Arc";
    return "Azure Arc";
  }

  function isAwsMachine(machine) {
    if (isNativeAzureMachine(machine)) return false;
    if (String(machine?.CloudGroupType || "").toUpperCase() === "AWS") return true;
    if (machine?.AzureTags && typeof machine.AzureTags === "object") {
      for (const k of Object.keys(machine.AzureTags)) {
        if (k.toLowerCase() === "accountid" && String(machine.AzureTags[k] || "").trim()) return true;
      }
    }
    return /\b(aws|amazon)\b/i.test(`${machine?.CloudProvider || ""} ${machine?.MdeCloudPlatforms || ""}`);
  }

  function awsAccountFor(machine) {
    if (!isAwsMachine(machine)) return "";
    if (machine?.AzureTags && typeof machine.AzureTags === "object") {
      for (const k of Object.keys(machine.AzureTags)) {
        if (k.toLowerCase() === "accountid" && String(machine.AzureTags[k] || "").trim()) {
          return String(machine.AzureTags[k]).trim();
        }
      }
    }
    if (String(machine?.CloudGroupType || "").toUpperCase() === "AWS" && machine?.CloudIdentifier) {
      return String(machine.CloudIdentifier).trim();
    }
    return "";
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

  function defenderExtensionFor(machine) {
    if (machine.DefenderExtensionStatus) return machine.DefenderExtensionStatus;
    if (!Array.isArray(machine.ArcExtensions)) return "Not installed";
    const matched = machine.ArcExtensions.map(ext => {
      const match = String(ext ?? "").match(/^\s*(MDE\.(?:Windows|Linux))\b(?:.*?\bstate:\s*([^);\s]+))?/i);
      return match ? `${match[1]}: ${match[2] || "Installed"}` : "";
    }).filter(Boolean);
    return matched.length ? [...new Set(matched)].join("; ") : "Not installed";
  }

  function deviceLink(machine, kind) {
    if (kind === "arc" && machine.ArcResourceId) {
      return `https://portal.azure.com/#resource${machine.ArcResourceId.split("/").map(encodeURIComponent).join("/")}`;
    }
    if (kind === "mde" && machine.MdeDeviceId) {
      return `https://security.microsoft.com/machines/${encodeURIComponent(machine.MdeDeviceId)}`;
    }
    if (kind === "entra" && (machine.EntraObjectId || machine.EntraDeviceId)) {
      if (machine.EntraObjectId) {
        return `https://entra.microsoft.com/#view/Microsoft_AAD_Devices/DeviceDetailsMenuBlade/~/Properties/objectId/${encodeURIComponent(machine.EntraObjectId)}`;
      }
      return "https://entra.microsoft.com/#view/Microsoft_AAD_Devices/DevicesMenuBlade/~/Devices/menuId/Devices";
    }
    return "";
  }

  function appendLink(parent, label, url) {
    if (!url) { parent.append(text("span", label)); return; }
    const link = text("a", label);
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    parent.append(link);
  }

  function analyzeUncorrelatedDevice(machine) {
    if (machine._uncorrAnalysis) return machine._uncorrAnalysis;
    const status = String(machine.Status || "").trim();
    const arcStatus = String(machine.ArcStatus || "").trim();
    const defExt = defenderExtensionFor(machine);
    const diag = String(machine.EntraDiagnostic || "").trim();
    const hasMdeId = Boolean(machine.MdeDeviceId);
    const mdeOnboarded = machine.MdeOnboardingStatus === "Onboarded";
    const isDeallocated = /^vm (?:deallocated|stopped)$/i.test(arcStatus);
    const isArcOffline = ["Disconnected", "Offline", "Expired"].includes(arcStatus);
    const excludedByTag = Boolean(machine.AzureTags && Object.entries(machine.AzureTags).some(([k, v]) => /excludemde/i.test(k) && /true/i.test(String(v))));

    const parseTierState = (tierNum, defaultLabel) => {
      if (!hasMdeId || !mdeOnboarded || status === "PendingMde" || status === "StaleEvidence") {
        return { state: "Skipped (No fresh MDE)", tone: "muted" };
      }
      const disabledRegex = new RegExp(`Tier\\s*${tierNum}\\b[^.]*disabled via SYNC_DISABLED_CORRELATION_TIERS`, "i");
      if (disabledRegex.test(diag)) {
        return { state: "Disabled by setting", tone: "attention" };
      }
      if (tierNum === 1) {
        if (/Tier 1[^.]*empty/i.test(diag) || !machine.EntraDeviceId || (machine.MdeSyntheticDeviceId && machine.EntraDeviceId === machine.MdeSyntheticDeviceId)) {
          return { state: "AadDeviceId empty", tone: "muted" };
        }
        return { state: "0 objects in Entra ID", tone: "bad" };
      }
      if (tierNum === 2) {
        if (!machine.GuestConfigEntraDeviceId) {
          return { state: "GC not reported", tone: "muted" };
        }
        return { state: `0 in Entra (${machine.GuestConfigEntraDeviceId.slice(0, 8)}…)`, tone: "bad" };
      }
      if (tierNum === 3) {
        if (!machine.MdeSyntheticDeviceId) {
          return { state: "No 40-hex SenseId", tone: "muted" };
        }
        return { state: `0 in Entra (${machine.MdeSyntheticDeviceId.slice(0, 8)}…)`, tone: "bad" };
      }
      if (tierNum === 4) {
        if (machine.MdeReonboardingDetected || /re-onboarding|merge history/i.test(diag)) {
          return { state: "Blocked (Re-onboarded)", tone: "bad" };
        }
        if (/ambiguous|multiple/i.test(diag)) {
          return { state: "Ambiguous (>1 match)", tone: "bad" };
        }
        return { state: defaultLabel || "0 MicrosoftSense matches", tone: "bad" };
      }
      return { state: defaultLabel, tone: "muted" };
    };

    const tiers = [
      { id: "T1", name: "Tier 1: MDE AadDeviceId", ...parseTierState(1, "Not matched") },
      { id: "T2", name: "Tier 2: Machine Config", ...parseTierState(2, "Not reported") },
      { id: "T3", name: "Tier 3: Synthetic SHA-256", ...parseTierState(3, "Not matched") },
      { id: "T4", name: "Tier 4: Hostname & OS", ...parseTierState(4, "0 MicrosoftSense matches") }
    ];

    let categoryKey = "other";
    let categoryLabel = "Needs Investigation";
    let gateStopped = "Gate 4: Entra Lookup";
    let badgeTone = "attention";
    let whySummary = diag || "Device has not completed correlation.";
    let recommendedAction = "Inspect the device correlation telemetry and verify MDE and Entra ID status.";

    if (status === "PendingMde" || (!hasMdeId && status !== "ArcMissing")) {
      categoryKey = "no-mde";
      categoryLabel = "Not Onboarded to MDE";
      gateStopped = "Gate 3: MDE Onboarding";
      badgeTone = "attention";
      if (machine.MdeOnboardingStatus === "CanBeOnboarded") {
        whySummary = `Server was discovered in Defender XDR with OnboardingStatus='CanBeOnboarded' (not yet onboarded to MDE).`;
        recommendedAction = `Onboard the server to Microsoft Defender for Endpoint (deploy MDE.${String(machine.OS || "").toLowerCase().includes("lin") ? "Linux" : "Windows"} extension).`;
      } else if (isDeallocated) {
        whySummary = `Server is currently '${arcStatus}' and has no onboarded MDE DeviceInfo record in the last 7 days (${defExt === "Not installed" ? "MDE extension not installed" : defExt}).`;
        recommendedAction = `Start the VM so the Defender for Endpoint extension (${defExt}) can provision and report a fresh DeviceInfo record.`;
      } else if (excludedByTag) {
        whySummary = `Server has Azure tag ExcludeMdeAutoProvisioning=True, MDE extension is '${defExt}', and no active MDE record exists.`;
        recommendedAction = `Remove ExcludeMdeAutoProvisioning=True tag or manually onboard the server to Defender for Endpoint.`;
      } else if (defExt === "Not installed" || /Failed/i.test(defExt)) {
        whySummary = `Server is '${arcStatus || "Running"}', but the MDE extension is '${defExt}' and no onboarded MDE DeviceInfo record matched this resource in the last 7 days.`;
        recommendedAction = `Deploy or repair the MDE.${String(machine.OS || "").toLowerCase().includes("lin") ? "Linux" : "Windows"} extension via Defender for Cloud.`;
      } else if (isArcOffline) {
        whySummary = `Arc agent is '${arcStatus}' and no onboarded MDE DeviceInfo record was found within the 7-day lookback window.`;
        recommendedAction = `Restore Azure Arc agent (azcmagent) connectivity and verify the MDE sensor is running on the host.`;
      } else {
        whySummary = `No onboarded, unmerged MDE DeviceInfo record in Defender XDR matched this resource ID or VM ID within the last 7 days.`;
        recommendedAction = `Verify the MDE sensor is running on '${machine.MachineName}' and reporting to Defender XDR (DeviceInfo table).`;
      }
    } else if (status === "StaleEvidence") {
      categoryKey = "stale-mde";
      categoryLabel = "Stale MDE Telemetry (>7d)";
      gateStopped = "Gate 3: MDE Freshness";
      badgeTone = "attention";
      whySummary = `Matched MDE device '${machine.MdeDeviceName || machine.MdeDeviceId}', but its last Defender XDR check-in (${time(machine.MdeLastSeen)}) is older than the configured freshness window (SYNC_FRESHNESS_HOURS).`;
      recommendedAction = `Bring the server online or restart the Defender for Endpoint service (Sense / mdatp) so it sends a fresh heartbeat.`;
    } else if (status === "Ambiguous" || (machine.MdeReonboardingDetected && (status === "NoEntraDevice" || status === "EntraDeviceNotFound"))) {
      categoryKey = "ambiguous";
      categoryLabel = machine.MdeReonboardingDetected && status !== "Ambiguous" ? "Re-Onboarding Blocked" : "Ambiguous Identity";
      gateStopped = status === "Ambiguous" && !hasMdeId ? "Gate 3: Duplicate MDE Records" : "Gate 4: Duplicate / Re-Onboarded";
      badgeTone = "bad";
      if (machine.MdeReonboardingDetected && status !== "Ambiguous") {
        whySummary = `MDE re-onboarding / merge history was detected for SenseId '${machine.MdeDeviceId}'. Hostname-only matching (Tier 4) is blocked for safety, and none of the ID-based tiers (Tiers 1–3) found the new Entra device.`;
        recommendedAction = `Verify the re-onboarded server's synthetic Entra deviceId (${machine.MdeSyntheticDeviceId || "Tier 3"}) or Azure Machine Configuration intuneDeviceId (Tier 2) is registered in Entra ID.`;
      } else {
        whySummary = diag || `Multiple active MDE records or multiple MicrosoftSense Entra device objects matched '${machine.MachineName}', preventing safe correlation.`;
        recommendedAction = `Remove duplicate stale device objects in Microsoft Entra ID or enable Azure Machine Configuration (Tier 2) / Tier 3 Synthetic Device ID to resolve by exact GUID.`;
      }
    } else if (status === "EntraDeviceNotFound" || status === "NoEntraDevice") {
      categoryKey = "no-entra";
      categoryLabel = "Not Found in Entra ID";
      gateStopped = "Gate 4: 4-Tier Entra Lookup";
      badgeTone = "bad";
      const disabledTiers = tiers.filter(t => t.state === "Disabled by setting").map(t => t.id);
      const disabledNote = disabledTiers.length ? ` (${disabledTiers.join(", ")} disabled via SYNC_DISABLED_CORRELATION_TIERS)` : "";
      whySummary = `Server is onboarded to MDE (SenseId '${machine.MdeDeviceId}', sensor '${machine.MdeSensorHealth || "Active"}'), but no matching Microsoft Entra ID device object was found${disabledNote}${machine.MdeSyntheticDeviceId ? `. Derived synthetic Entra deviceId '${machine.MdeSyntheticDeviceId}' returned 0 objects in Entra ID.` : "."}`;
      recommendedAction = `Ensure MDE Security Settings Management (Defender XDR -> Configuration Management -> Enforcement Scope) is enabled for ${machine.OS || "server"} devices so MDE creates the synthetic MicrosoftSense device in Entra ID, or Hybrid/Entra-join the server.${disabledTiers.length ? ` Also check SYNC_DISABLED_CORRELATION_TIERS (${disabledTiers.join(", ")} currently disabled).` : ""}`;
    } else if (status === "EntraDeviceDisabled" || status === "InvalidEntraIdentifier" || status === "ArcMissing" || status === "ArcNotConnected" || status === "Failed") {
      categoryKey = "disabled-or-error";
      categoryLabel = status === "EntraDeviceDisabled" ? "Entra Device Disabled" :
        status === "Failed" ? "Sync Error (Failed)" :
        status === "ArcMissing" ? "Azure Resource Deleted" : status;
      gateStopped = status === "ArcMissing" || status === "ArcNotConnected" ? "Gate 2: ARM Resource State" : "Gate 4: Entra Device State";
      badgeTone = status === "Failed" || status === "EntraDeviceDisabled" ? "bad" : "attention";
      whySummary = machine.Error || diag || `Correlation stopped with status '${status}'.`;
      recommendedAction = status === "EntraDeviceDisabled" ? `Enable the device object (${machine.EntraDeviceId || machine.EntraObjectId}) in Microsoft Entra ID.` :
        status === "Failed" ? `Review the error message and Function App logs; the worker will automatically retry via Service Bus.` :
        `Verify the Azure resource and Entra ID device state.`;
    }

    const analysis = {
      categoryKey,
      categoryLabel,
      gateStopped,
      badgeTone,
      whySummary,
      recommendedAction,
      tiers,
      tierSummaryText: tiers.map(t => `${t.id}: ${t.state}`).join(" · ")
    };
    Object.defineProperty(machine, "_uncorrAnalysis", { value: analysis, enumerable: false, configurable: true });
    return analysis;
  }

  const columns = [
    { id: "MachineName", label: "Server", value: m => m.MachineName || "" },
    { id: "CategoryLabel", label: "Uncorrelated reason", value: m => analyzeUncorrelatedDevice(m).categoryLabel },
    { id: "GateStopped", hidden: true, label: "Pipeline gate stopped", value: m => analyzeUncorrelatedDevice(m).gateStopped },
    { id: "WhySummary", hidden: true, label: "Why it is uncorrelated", value: m => analyzeUncorrelatedDevice(m).whySummary },
    { id: "TierBreakdown", hidden: true, label: "4-Tier correlation check", value: m => analyzeUncorrelatedDevice(m).tierSummaryText },
    { id: "RecommendedAction", label: "Next step", value: m => analyzeUncorrelatedDevice(m).recommendedAction },
    { id: "ArcStatus", hidden: true, label: "Machine status", value: m => m.ArcStatus || "" },
    { id: "DefenderExtensionStatus", hidden: true, label: "Defender extension", value: m => defenderExtensionFor(m) },
    { id: "MdeOnboardingStatus", hidden: true, label: "MDE onboarding / sensor", value: m => `${m.MdeOnboardingStatus || "Not reported"} / ${m.MdeSensorHealth || "No sensor"}` },
    { id: "MdeDeviceName", hidden: true, label: "MDE device & synthetic ID", value: m => `${m.MdeDeviceName || m.MdeDeviceId || "None"} ${m.MdeSyntheticDeviceId || ""}`.trim() },
    { id: "CloudScope", label: "Cloud scope", value: m => { const s = resolveMachineCloudScope(m); return `${s.CloudType}: ${s.CloudIdentifier}`; } },
    { id: "OS", label: "OS", value: m => m.OS || "" },
    { id: "LastChecked", label: "Last checked", type: "date", value: m => m.LastChecked || "" }
  ];
  const tableColumns = columns.filter(column => !column.hidden);
  const columnById = new Map(columns.map(c => [c.id, c]));

  function searchFor(machine, column) {
    if (!machine._uncorrColSearch) {
      Object.defineProperty(machine, "_uncorrColSearch", { value: Object.create(null), enumerable: false, configurable: true });
    }
    const cached = machine._uncorrColSearch[column.id];
    if (cached !== undefined) return cached;
    const raw = String(column.value(machine) ?? "");
    const disp = column.type === "date" ? time(raw) : raw;
    const computed = `${raw} ${disp}`.toLowerCase();
    machine._uncorrColSearch[column.id] = computed;
    return computed;
  }

  function fullSearchTextFor(machine) {
    if (typeof machine._uncorrFullSearch === "string") return machine._uncorrFullSearch;
    const parts = columns.map(col => searchFor(machine, col));
    parts.push(
      String(machine.ArcResourceId || "").toLowerCase(),
      String(machine.MdeDeviceId || "").toLowerCase(),
      String(machine.MdeSyntheticDeviceId || "").toLowerCase(),
      String(machine.GuestConfigEntraDeviceId || "").toLowerCase(),
      String(machine.EntraDiagnostic || "").toLowerCase(),
      String(machine.SubscriptionId || "").toLowerCase(),
      String(machine.ManagementGroup || "").toLowerCase()
    );
    const full = parts.join(" \n ");
    Object.defineProperty(machine, "_uncorrFullSearch", { value: full, enumerable: false, configurable: true });
    return full;
  }

  function osIconSvg(osText) {
    const lower = String(osText || "").toLowerCase();
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 16 16");
    svg.setAttribute("width", "16");
    svg.setAttribute("height", "16");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("class", `os-svg ${lower.includes("win") ? "os-windows" : lower.includes("lin") ? "os-linux" : "os-other"}`);
    if (lower.includes("win")) {
      for (const [x, y] of [[1.5, 2], [8.5, 1.2], [1.5, 8.6], [8.5, 8.6]]) {
        const rect = document.createElementNS(ns, "rect");
        rect.setAttribute("x", String(x));
        rect.setAttribute("y", String(y));
        rect.setAttribute("width", "5.8");
        rect.setAttribute("height", "5.6");
        rect.setAttribute("rx", "0.6");
        rect.setAttribute("fill", "currentColor");
        svg.append(rect);
      }
    } else if (lower.includes("lin")) {
      const path = document.createElementNS(ns, "path");
      path.setAttribute("fill", "currentColor");
      path.setAttribute("d", "M8 1.2c-2.1 0-3.4 1.6-3.4 3.8 0 1.1.3 2 .7 2.7-.8.9-1.5 2.2-1.5 3.6 0 1.9 1.3 3.4 4.2 3.4s4.2-1.5 4.2-3.4c0-1.4-.7-2.7-1.5-3.6.4-.7.7-1.6.7-2.7 0-2.2-1.3-3.8-3.4-3.8zm-1.1 3a.7.7 0 1 1 0 1.4.7.7 0 0 1 0-1.4zm2.2 0a.7.7 0 1 1 0 1.4.7.7 0 0 1 0-1.4zm-1.1 2c.8 0 1.4.3 1.4.7s-.6.7-1.4.7-1.4-.3-1.4-.7.6-.7 1.4-.7zm0 2.3c1.6 0 2.6 1.1 2.6 2.6 0 1.3-.9 2.2-2.6 2.2s-2.6-.9-2.6-2.2c0-1.5 1-2.6 2.6-2.6z");
      svg.append(path);
    } else {
      const circle = document.createElementNS(ns, "circle");
      circle.setAttribute("cx", "8");
      circle.setAttribute("cy", "8");
      circle.setAttribute("r", "5");
      circle.setAttribute("fill", "currentColor");
      svg.append(circle);
    }
    return svg;
  }

  function osNode(osText) {
    const label = osText || missing;
    const wrap = text("span", "", "os-badge");
    if (label !== missing) wrap.append(osIconSvg(label));
    wrap.append(text("span", label));
    return wrap;
  }

  function renderModeBadges(health) {
    const syncBadge = byId("header-sync-mode");
    const groupBadge = byId("header-group-mode");
    if (!syncBadge || !groupBadge || !health || typeof health !== "object") return;
    const rawSyncMode = String(health.SyncMode || health.Parameters?.SYNC_MODE || "").trim();
    const rawGroupMode = String(health.DefaultGroupMode || health.Parameters?.SYNC_DEFAULT_GROUP_MODE || "").trim();
    const syncMode = ["Audit", "Enforce"].includes(rawSyncMode) ? rawSyncMode : "Unknown";
    const groupMode = ["Active", "Passive"].includes(rawGroupMode) ? rawGroupMode : "Unknown";
    syncBadge.textContent = `Sync Mode: ${syncMode}`;
    syncBadge.className = `badge mode-pill ${syncMode === "Enforce" ? "good" : "attention"}`;
    syncBadge.hidden = false;
    groupBadge.textContent = `Default Group: ${groupMode}`;
    groupBadge.className = `badge mode-pill ${groupMode === "Active" ? "good" : "attention"}`;
    groupBadge.hidden = false;
  }

  function clearHoverTimer() {
    if (hoverHideTimer) {
      window.clearTimeout(hoverHideTimer);
      hoverHideTimer = 0;
    }
  }
  function hideHoverPopover() {
    clearHoverTimer();
    activeHoverCell = null;
    const popover = byId("hover-popover");
    if (popover) popover.hidden = true;
  }
  function scheduleHideHoverPopover() {
    clearHoverTimer();
    hoverHideTimer = window.setTimeout(hideHoverPopover, 120);
  }
  function positionHoverPopover(anchor) {
    const popover = byId("hover-popover");
    if (!popover || popover.hidden) return;
    const rect = anchor.getBoundingClientRect();
    const popRect = popover.getBoundingClientRect();
    const margin = 10;
    let top = rect.bottom + 6;
    if (top + popRect.height > window.innerHeight - margin && rect.top - popRect.height - 6 > margin) {
      top = rect.top - popRect.height - 6;
    }
    let left = rect.left;
    if (left + popRect.width > window.innerWidth - margin) {
      left = Math.max(margin, window.innerWidth - popRect.width - margin);
    }
    popover.style.top = `${Math.max(margin, top)}px`;
    popover.style.left = `${Math.max(margin, left)}px`;
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
    try {
      if (typeof indexedDB !== "undefined") {
        const req = indexedDB.open(idbDatabaseName, 1);
        req.onsuccess = () => {
          try {
            const db = req.result;
            if (db.objectStoreNames.contains(idbStoreName)) {
              db.transaction(idbStoreName, "readwrite").objectStore(idbStoreName).delete(dataCacheKey);
            }
            db.close();
          } catch {}
        };
      }
    } catch {}
  }

  function openSnapshotCacheDb() {
    return new Promise((resolve, reject) => {
      if (typeof indexedDB === "undefined") { reject(new Error("IndexedDB unavailable")); return; }
      const req = indexedDB.open(idbDatabaseName, 1);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains(idbStoreName)) {
          db.createObjectStore(idbStoreName);
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error || new Error("IndexedDB open failed"));
    });
  }
  async function readIdbSnapshot() {
    try {
      const db = await openSnapshotCacheDb();
      return await new Promise(resolve => {
        const tx = db.transaction(idbStoreName, "readonly");
        const getReq = tx.objectStore(idbStoreName).get(dataCacheKey);
        getReq.onsuccess = () => { db.close(); resolve(getReq.result || null); };
        getReq.onerror = () => { db.close(); resolve(null); };
      });
    } catch {
      return null;
    }
  }
  async function writeIdbSnapshot(record) {
    try {
      const db = await openSnapshotCacheDb();
      await new Promise(resolve => {
        const tx = db.transaction(idbStoreName, "readwrite");
        tx.objectStore(idbStoreName).put(record, dataCacheKey);
        tx.oncomplete = () => { db.close(); resolve(); };
        tx.onerror = () => { db.close(); resolve(); };
      });
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
      allInventoryMachines = [];
      uncorrelatedMachines = [];
      renderSummary();
      render();
    }
    if (!response.ok) throw new Error(`Report request failed (${response.status}). Check your sign-in, Report.Reader role, and service health.`);
    const result = await response.json();
    if (result.error) throw new Error(result.error);
    return result;
  }

  async function allMachines(forceRefresh = false, onFirstPage = null) {
    const items = [];
    const cursors = new Set();
    let cursor = "";
    let isFirst = true;
    do {
      const topParam = isFirst ? "top=100" : "top=1000";
      const query = cursor ? `?${topParam}&cursor=${encodeURIComponent(cursor)}` : `?${topParam}`;
      const page = await get("data" + query, forceRefresh);
      if (!Array.isArray(page.Items) || typeof page.Cursor !== "string") throw new Error("Invalid inventory response.");
      items.push(...page.Items);
      cursor = page.Cursor;
      if (isFirst && cursor && typeof onFirstPage === "function") {
        onFirstPage([...items]);
      }
      isFirst = false;
      if (cursor && cursors.has(cursor)) throw new Error("Inventory pagination did not advance.");
      cursors.add(cursor);
    } while (cursor);
    return items;
  }

  function updateOptions(id, values, label) {
    const select = byId(id);
    if (!select) return;
    const previous = select.value;
    select.replaceChildren(text("option", label));
    select.firstChild.value = "";
    for (const value of [...new Set(values.filter(Boolean))].sort()) {
      const option = text("option", value);
      option.value = value;
      select.append(option);
    }
    select.value = [...select.options].some(option => option.value === previous) ? previous : "";
  }

  function applyUrlQueryFilters() {
    try {
      const params = new URLSearchParams(window.location.search || "");
      const reason = params.get("reason");
      if (reason && byId("reason-filter")) byId("reason-filter").value = reason;
      const scopeType = params.get("scopeType");
      if (scopeType && byId("cloud-filter")) byId("cloud-filter").value = scopeType;
      const scopeId = params.get("scopeId");
      if (scopeType === "AWS" && scopeId && byId("aws-account-filter")) {
        byId("aws-account-filter").value = scopeId;
      }
      const subId = params.get("subId");
      if (subId && byId("subscription-filter")) {
        byId("subscription-filter").value = subId;
      }
      const searchParam = params.get("q");
      if (searchParam && byId("search")) {
        byId("search").value = searchParam;
      }
    } catch {}
  }

  function applySnapshot(items, health, timestampIso, isCached = false, isPartial = false) {
    allInventoryMachines = Array.isArray(items) ? items : [];
    uncorrelatedMachines = allInventoryMachines.filter(m => !hasEntraCorrelation(m));
    if (health && typeof health === "object") {
      latestHealth = health;
      renderModeBadges(health);
    }
    const prefix = isPartial ? `Loading inventory (${uncorrelatedMachines.length} uncorrelated of ${allInventoryMachines.length} loaded)` : (isCached ? "Cached snapshot" : "Report refreshed");
    byId("updated").textContent = `${prefix}: ${time(timestampIso || new Date().toISOString())}`;

    updateOptions("reason-filter", uncorrelatedMachines.map(m => analyzeUncorrelatedDevice(m).categoryLabel), "All uncorrelated reasons");
    updateOptions("cloud-filter", uncorrelatedMachines.map(m => resolveMachineCloudScope(m).CloudType), "All cloud scopes");
    updateOptions("os-filter", uncorrelatedMachines.map(m => m.OS), "All operating systems");
    updateOptions("arc-status-filter", uncorrelatedMachines.map(m => m.ArcStatus), "All machine statuses");
    updateOptions("aws-account-filter", uncorrelatedMachines.map(awsAccountFor), "All AWS accounts");
    updateOptions("subscription-filter", uncorrelatedMachines.map(m => m.SubscriptionId), "All subscriptions");

    applyUrlQueryFilters();
    renderSummary();
    render();
  }

  function loadCachedSnapshot() {
    try {
      localStorage.removeItem(dataCacheKey);
      const raw = sessionStorage.getItem(dataCacheKey);
      if (!raw) return 0;
      const cached = JSON.parse(raw);
      if (!Array.isArray(cached.items)) return 0;
      applySnapshot(cached.items, cached.health, cached.timestamp, true, false);
      return Number(cached.savedAt) || 0;
    } catch {
      return 0;
    }
  }

  async function loadCachedSnapshotAsync() {
    const syncSavedAt = loadCachedSnapshot();
    if (syncSavedAt > 0) return syncSavedAt;
    const cached = await readIdbSnapshot();
    if (!cached || !Array.isArray(cached.items)) return 0;
    if (!allInventoryMachines.length) {
      applySnapshot(cached.items, cached.health, cached.timestamp, true, false);
    }
    return Number(cached.savedAt) || 0;
  }

  function saveCachedSnapshot(items, health, timestamp) {
    void (async () => {
      const prevIdb = await readIdbSnapshot() || {};
      await writeIdbSnapshot({ ...prevIdb, items, health, timestamp, savedAt: Date.now() });
    })();
    try {
      localStorage.removeItem(dataCacheKey);
      if (Array.isArray(items) && items.length <= 1500) {
        const raw = sessionStorage.getItem(dataCacheKey);
        const prev = raw ? JSON.parse(raw) : {};
        sessionStorage.setItem(dataCacheKey, JSON.stringify({ ...prev, items, health, timestamp, savedAt: Date.now() }));
      } else {
        sessionStorage.removeItem(dataCacheKey);
      }
    } catch {}
  }

  function renderSummary() {
    const totalAll = allInventoryMachines.length;
    const totalUncorr = uncorrelatedMachines.length;
    const pct = totalAll > 0 ? `${Math.round((totalUncorr / totalAll) * 100)}% of ${totalAll} total` : "0 total";

    const cards = [
      {
        key: "all",
        label: `All Uncorrelated (${pct})`,
        count: totalUncorr,
        detail: "Every discovered server in scope that has not yet resolved to an enabled Microsoft Entra ID device object.",
        matches: () => true
      },
      {
        key: "no-mde",
        label: "Gate 3: Not Onboarded to MDE",
        count: uncorrelatedMachines.filter(m => analyzeUncorrelatedDevice(m).categoryKey === "no-mde").length,
        detail: "Servers with no onboarded MDE DeviceInfo record in the last 7 days (e.g., MDE extension missing/failed, VM deallocated, or PendingMde).",
        matches: m => analyzeUncorrelatedDevice(m).categoryKey === "no-mde"
      },
      {
        key: "no-entra",
        label: "Gate 4: Onboarded — Not in Entra ID",
        count: uncorrelatedMachines.filter(m => analyzeUncorrelatedDevice(m).categoryKey === "no-entra").length,
        detail: "Servers actively onboarded to MDE, but none of the enabled correlation tiers (Tier 1 AadDeviceId, Tier 2 Machine Config, Tier 3 Synthetic SHA-256 ID, Tier 4 Hostname+OS) found a matching Entra ID device.",
        matches: m => analyzeUncorrelatedDevice(m).categoryKey === "no-entra"
      },
      {
        key: "stale-mde",
        label: "Gate 3: Stale MDE Telemetry (>7d)",
        count: uncorrelatedMachines.filter(m => analyzeUncorrelatedDevice(m).categoryKey === "stale-mde").length,
        detail: "Servers with an MDE DeviceInfo record whose last check-in timestamp is older than SYNC_FRESHNESS_HOURS (168h / 7 days).",
        matches: m => analyzeUncorrelatedDevice(m).categoryKey === "stale-mde"
      },
      {
        key: "ambiguous",
        label: "Gate 3/4: Ambiguous or Re-Onboarded",
        count: uncorrelatedMachines.filter(m => analyzeUncorrelatedDevice(m).categoryKey === "ambiguous").length,
        detail: "Servers blocked due to duplicate MDE/Entra records or detected MDE re-onboarding where hostname-only matching is disabled for safety.",
        matches: m => analyzeUncorrelatedDevice(m).categoryKey === "ambiguous"
      },
      {
        key: "disabled-or-error",
        label: "Entra Disabled / Sync Error",
        count: uncorrelatedMachines.filter(m => analyzeUncorrelatedDevice(m).categoryKey === "disabled-or-error").length,
        detail: "Servers whose Entra ID device object has accountEnabled == false, or whose last sync encountered an error.",
        matches: m => analyzeUncorrelatedDevice(m).categoryKey === "disabled-or-error"
      }
    ];

    const summaryEl = byId("uncorr-summary");
    summaryEl.replaceChildren(...cards.map(c => {
      const isActive = (c.key === "all" && !cardFilterKey) || cardFilterKey === c.key;
      const btn = text("button", "", `card${isActive ? " is-active" : ""}`);
      btn.type = "button";
      btn.dataset.cardKey = c.key;
      btn.setAttribute("aria-pressed", String(isActive));
      btn.append(text("strong", String(c.count)), text("span", c.label));
      btn.addEventListener("click", () => {
        if (c.key === "all") {
          cardFilterKey = "";
        } else {
          cardFilterKey = cardFilterKey === c.key ? "" : c.key;
        }
        currentPage = 1;
        renderSummary();
        render();
      });
      bindHoverPopover(btn, () => ["UNCORRELATED ROOT CAUSE", [
        ["Category", c.label],
        ["Matching Servers", `${c.count} of ${totalUncorr} uncorrelated servers`],
        ["What It Means", c.detail],
        ["Action", "Click card to filter the table to this root cause."]
      ]]);
      return btn;
    }));
  }

  function renderHeaders() {
    const head = byId("uncorr-head");
    const tr = document.createElement("tr");
    const filterRow = text("tr", "", "column-filters");
    for (const column of tableColumns) {
      const th = document.createElement("th");
      th.scope = "col";
      th.dataset.column = column.id;
      const active = sortState.id === column.id;
      th.setAttribute("aria-sort", active ? (sortState.direction === "asc" ? "ascending" : "descending") : "none");
      const sortBtn = text("button", `${column.label}${active ? (sortState.direction === "asc" ? " [asc]" : " [desc]") : ""}`, "sort-column");
      sortBtn.type = "button";
      sortBtn.addEventListener("click", () => {
        sortState = {
          id: column.id,
          direction: sortState.id === column.id && sortState.direction === "asc" ? "desc" : "asc"
        };
        currentPage = 1;
        renderHeaders();
        render();
      });
      th.append(sortBtn);
      tr.append(th);

      const td = document.createElement("td");
      const input = document.createElement("input");
      input.type = "search";
      input.placeholder = `Filter ${column.label}`;
      input.setAttribute("aria-label", `Filter ${column.label}`);
      input.value = columnFilters[column.id] || "";
      input.addEventListener("input", () => {
        columnFilters[column.id] = input.value;
        scheduleRender(true);
      });
      td.append(input);
      filterRow.append(td);
    }
    head.replaceChildren(tr, filterRow);
  }

  function scheduleRender(resetPage = true) {
    if (resetPage) currentPage = 1;
    if (filterDebounceTimer) window.clearTimeout(filterDebounceTimer);
    filterDebounceTimer = window.setTimeout(() => {
      filterDebounceTimer = 0;
      render();
    }, 120);
  }

  function getFilteredUncorrelated() {
    const searchVal = (byId("search")?.value || "").trim().toLowerCase();
    const reasonVal = byId("reason-filter")?.value || "";
    const cloudVal = byId("cloud-filter")?.value || "";
    const osVal = byId("os-filter")?.value || "";
    const arcVal = byId("arc-status-filter")?.value || "";
    const awsVal = byId("aws-account-filter")?.value || "";
    const subVal = byId("subscription-filter")?.value || "";
    const activeColFilters = Object.entries(columnFilters)
      .filter(([, val]) => val.trim())
      .map(([id, val]) => [columnById.get(id), val.trim().toLowerCase()]);

    const filtered = uncorrelatedMachines.filter(machine => {
      const analysis = analyzeUncorrelatedDevice(machine);
      const scope = resolveMachineCloudScope(machine);
      return (!cardFilterKey || analysis.categoryKey === cardFilterKey) &&
        (!reasonVal || analysis.categoryLabel === reasonVal) &&
        (!cloudVal || scope.CloudType === cloudVal) &&
        (!osVal || machine.OS === osVal) &&
        (!arcVal || machine.ArcStatus === arcVal) &&
        (!awsVal || awsAccountFor(machine) === awsVal) &&
        (!subVal || machine.SubscriptionId === subVal) &&
        (!searchVal || fullSearchTextFor(machine).includes(searchVal)) &&
        activeColFilters.every(([col, lowerVal]) => col && searchFor(machine, col).includes(lowerVal));
    });

    const sortCol = columnById.get(sortState.id) || columns[0];
    filtered.sort((a, b) => {
      const left = String(sortCol.value(a) || "");
      const right = String(sortCol.value(b) || "");
      if (!left || !right) return left ? -1 : right ? 1 : collator.compare(a.Key || "", b.Key || "");
      const cmp = sortCol.type === "date" ? Date.parse(left) - Date.parse(right) : collator.compare(left, right);
      return (sortState.direction === "asc" ? cmp : -cmp) || collator.compare(a.Key || "", b.Key || "");
    });

    return { filtered, activeColFilters };
  }

  function render() {
    const { filtered, activeColFilters } = getFilteredUncorrelated();
    const totalFiltered = filtered.length;
    const totalPages = Math.max(1, Math.ceil(totalFiltered / pageSize));
    if (currentPage > totalPages) currentPage = totalPages;
    if (currentPage < 1) currentPage = 1;
    const startIndex = (currentPage - 1) * pageSize;
    const pageItems = filtered.slice(startIndex, startIndex + pageSize);
    const range = totalFiltered ? `${startIndex + 1}–${startIndex + pageItems.length}` : "0";
    const sortCol = columnById.get(sortState.id) || columns[0];
    byId("count").textContent = `Showing ${range} of ${totalFiltered} servers${totalFiltered !== uncorrelatedMachines.length ? ` (${uncorrelatedMachines.length} uncorrelated total)` : ""}`;
    byId("count").title = `${allInventoryMachines.length} servers in inventory. ${activeColFilters.length} column filters. Sorted by ${sortCol.label} ${sortState.direction}.`;

    if (byId("page-info")) byId("page-info").textContent = `Page ${currentPage} of ${totalPages}`;
    if (byId("page-first")) byId("page-first").disabled = currentPage <= 1;
    if (byId("page-prev")) byId("page-prev").disabled = currentPage <= 1;
    if (byId("page-next")) byId("page-next").disabled = currentPage >= totalPages;
    if (byId("page-last")) byId("page-last").disabled = currentPage >= totalPages;

    hideHoverPopover();
    const body = byId("uncorr-body");
    body.replaceChildren();

    for (const machine of pageItems) {
      const analysis = analyzeUncorrelatedDevice(machine);
      const scope = resolveMachineCloudScope(machine);
      const tr = document.createElement("tr");
      tr.dataset.key = machine.Key;
      tr.classList.toggle("is-selected", machine.Key === selectedKey);

      const serverCell = document.createElement("td");
      serverCell.className = "device-cell";
      const nameWrap = text("span", "", "machine-name-cell");
      appendLink(nameWrap, machine.MachineName || missing, deviceLink(machine, "arc"));
      nameWrap.append(text("span", machineKindLabel(machine), "badge neutral resource-kind-badge"));
      serverCell.append(nameWrap);
      const inspectBtn = text("button", "", "history-action secondary");
      inspectBtn.type = "button";
      inspectBtn.title = `Inspect why ${machine.MachineName} is uncorrelated & view history`;
      inspectBtn.setAttribute("aria-label", `Inspect why ${machine.MachineName} is uncorrelated`);
      inspectBtn.className = "secondary uncorr-inspect";
      inspectBtn.append(text("span", "Details"));
      inspectBtn.addEventListener("click", () => selectMachine(machine, inspectBtn));
      serverCell.append(inspectBtn);
      bindHoverPopover(serverCell, () => ["SERVER RESOURCE DETAILS", [
        ["Machine Name", machine.MachineName || missing],
        ["Resource Type", machineKindLabel(machine)],
        ["Machine Status", machine.ArcStatus || missing],
        ["Subscription", `${machine.SubscriptionName || missing} (${machine.SubscriptionId || missing})`],
        ["Resource Group", machine.ResourceGroup || missing],
        ["Resource ID", machine.ArcResourceId || missing]
      ]]);

      const reasonCell = document.createElement("td");
      reasonCell.className = "uncorr-reason-cell";
      reasonCell.append(
        text("span", analysis.categoryLabel, `badge ${analysis.badgeTone}`),
        text("small", analysis.gateStopped, "uncorr-gate")
      );
      bindHoverPopover(reasonCell, () => ["UNCORRELATED ROOT CAUSE", [
        ["Root Cause", analysis.categoryLabel],
        ["Stopped At", analysis.gateStopped],
        ["Raw Status Code", machine.Status || missing],
        ["Why It Is Uncorrelated", analysis.whySummary],
        ["Recommended Fix", analysis.recommendedAction]
      ]]);

      const fixCell = text("td", "", "uncorr-fix-cell");
      fixCell.title = analysis.recommendedAction;
      fixCell.append(text("div", analysis.recommendedAction, "uncorr-fix-text"));

      const arcTone = ["Connected", "VM running"].includes(machine.ArcStatus) ? "good" : "attention";
      serverCell.append(text("small", machine.ArcStatus || missing, `status-value ${arcTone}`));

      const scopeCell = document.createElement("td");
      scopeCell.append(
        text("small", scope.CloudType, "muted"),
        text("div", scope.CloudIdentifier || missing)
      );

      const osCell = document.createElement("td");
      osCell.append(osNode(machine.OS));

      const checkedCell = text("td", time(machine.LastChecked));

      const cells = [serverCell, reasonCell, fixCell, scopeCell, osCell, checkedCell];
      cells.forEach((cell, index) => { cell.dataset.column = tableColumns[index].id; });
      tr.append(...cells);
      body.append(tr);
    }

    if (!pageItems.length) {
      const emptyRow = document.createElement("tr");
      const cell = text("td", uncorrelatedMachines.length ? "No uncorrelated devices match these filters." : "All discovered servers are currently correlated to Microsoft Entra ID!");
      cell.colSpan = tableColumns.length;
      emptyRow.append(cell);
      body.append(emptyRow);
    }
  }

  function buildGateChecklist(machine) {
    const analysis = analyzeUncorrelatedDevice(machine);
    const hasMde = Boolean(machine.MdeDeviceId && machine.MdeOnboardingStatus === "Onboarded");
    const isFresh = hasMde && machine.Status !== "StaleEvidence";
    const steps = [
      {
        gate: "Gate 1 & Gate 2 — Azure Scope & Resource Readiness",
        state: machine.Status === "ArcMissing" ? "failed" : "passed",
        badge: machine.Status === "ArcMissing" ? "Stopped (404)" : "Passed",
        detail: `Discovered in ${machine.SubscriptionName || machine.SubscriptionId || "subscription"} / ${machine.ResourceGroup || "resource group"} (${machineKindLabel(machine)}, Status: ${machine.ArcStatus || missing}, Defender Extension: ${defenderExtensionFor(machine)}).`
      },
      {
        gate: "Gate 3 — Defender for Endpoint (MDE) DeviceInfo & 7-Day Freshness",
        state: !hasMde ? "failed" : (!isFresh || (machine.Status === "Ambiguous" && !machine.EntraDeviceId)) ? "failed" : "passed",
        badge: !hasMde ? "Stopped (No MDE Record)" : !isFresh ? "Stopped (Stale >7d)" : "Passed",
        detail: hasMde ?
          `Matched MDE Device '${machine.MdeDeviceName || machine.MdeDeviceId}' (SenseId: ${machine.MdeDeviceId}, Sensor: ${machine.MdeSensorHealth || "Unknown"}, Last seen: ${time(machine.MdeLastSeen)}).` :
          analysis.whySummary
      },
      {
        gate: "Gate 4 — 4-Tier Microsoft Entra ID Device Correlation",
        state: hasMde && isFresh ? "failed" : "skipped",
        badge: hasMde && isFresh ? `Stopped (${machine.Status || "Unresolved"})` : "Not Reached (Blocked at Gate 3)",
        detail: hasMde && isFresh ?
          `${analysis.whySummary} (${analysis.tierSummaryText})` :
          "Gate 4 cannot run until Gate 3 selects a single fresh Onboarded MDE DeviceInfo record."
      },
      {
        gate: "Recommended Remediation",
        state: "action",
        badge: "Action Required",
        detail: analysis.recommendedAction
      }
    ];
    return steps;
  }

  function selectMachine(machine, trigger = null) {
    hideHoverPopover();
    selectedKey = machine.Key;
    historyCursor = "";
    historyCount = 0;
    historyCursors = new Set();
    historyGeneration++;
    historyBusy = false;
    historyTrigger = trigger;

    const analysis = analyzeUncorrelatedDevice(machine);
    const scope = resolveMachineCloudScope(machine);
    byId("detail-title").textContent = `${machine.MachineName || "Server"} — ${analysis.categoryLabel}`;

    const summary = byId("detail-summary");
    summary.replaceChildren();
    const chips = [
      ["Root Cause", text("span", analysis.categoryLabel, `badge ${analysis.badgeTone}`)],
      ["Pipeline Gate", text("span", analysis.gateStopped, "status-value attention")],
      ["Machine Status", text("span", machine.ArcStatus || missing)],
      ["Defender Extension", text("span", defenderExtensionFor(machine))],
      ["MDE Onboarding", text("span", `${machine.MdeOnboardingStatus || "Not onboarded"} (${machine.MdeSensorHealth || "No sensor"})`)],
      ["Cloud Scope", text("span", `${scope.CloudType}: ${scope.CloudIdentifier}`)],
      ["Target Entra Group", text("span", machine.GroupName || missing)],
      ["OS", osNode(machine.OS)]
    ];
    for (const [label, node] of chips) {
      const chip = text("div", "", "summary-chip");
      const dd = document.createElement("dd");
      dd.append(node);
      chip.append(text("dt", label), dd);
      summary.append(chip);
    }

    const checklistEl = byId("gate-checklist");
    checklistEl.replaceChildren();
    for (const step of buildGateChecklist(machine)) {
      const li = text("li", "", `gate-step gate-step-${step.state}`);
      const header = text("div", "", "gate-step-header");
      const tone = step.state === "passed" ? "good" : step.state === "failed" ? "bad" : "attention";
      header.append(text("strong", step.gate), text("span", step.badge, `badge ${tone}`));
      li.append(header, text("p", step.detail));
      checklistEl.append(li);
    }

    const detail = byId("identity");
    detail.replaceChildren();
    const fields = [
      ["Server Name", machine.MachineName],
      ["Resource Type", machineKindLabel(machine)],
      ["Raw Sync Status", machine.Status],
      ["Why Uncorrelated", analysis.whySummary],
      ["Recommended Fix", analysis.recommendedAction],
      ["Tier 1 (MDE AadDeviceId)", analysis.tiers[0].state],
      ["Tier 2 (Machine Config intuneDeviceId)", `${analysis.tiers[1].state}${machine.GuestConfigEntraDeviceId ? ` — ${machine.GuestConfigEntraDeviceId}` : ""}`],
      ["Tier 3 (MDE Synthetic SHA-256 ID)", `${analysis.tiers[2].state}${machine.MdeSyntheticDeviceId ? ` — ${machine.MdeSyntheticDeviceId}` : ""}`],
      ["Tier 4 (MicrosoftSense Hostname & OS)", analysis.tiers[3].state],
      ["Full Correlation Diagnostic", machine.EntraDiagnostic || "None"],
      ["MDE Device Name", machine.MdeDeviceName || "Not matched"],
      ["MDE Device ID (SenseId)", machine.MdeDeviceId || "Not matched"],
      ["MDE Last Seen", time(machine.MdeLastSeen)],
      ["MDE Re-onboarding Detected", machine.MdeReonboardingDetected ? "Yes (hostname fallback blocked)" : "No"],
      ["Azure Resource ID", machine.ArcResourceId],
      ["Last Checked", time(machine.LastChecked)]
    ];
    for (const [label, val] of fields) {
      detail.append(text("dt", label), text("dd", val || missing));
    }
    for (const [kind, label] of [["arc", "Azure Portal"], ["mde", "Defender Portal"], ["entra", "Entra ID Portal"]]) {
      detail.append(text("dt", label), document.createElement("dd"));
      appendLink(
        detail.lastChild,
        kind === "arc" ? "Open Azure resource" : kind === "mde" ? (machine.MdeDeviceId ? "Open MDE device" : missing) : "Open Entra devices",
        deviceLink(machine, kind) || (kind === "entra" ? "https://entra.microsoft.com/#view/Microsoft_AAD_Devices/DevicesMenuBlade/~/Devices/menuId/Devices" : "")
      );
    }

    byId("history").replaceChildren();
    byId("more").hidden = true;
    if (!byId("detail").open) byId("detail").show();
    byId("detail").querySelector(".drawer-content").scrollTop = 0;
    for (const row of byId("uncorr-body").rows) row.classList.toggle("is-selected", row.dataset.key === selectedKey);
    void loadHistory();
  }

  function classifyTranscriptLine(line) {
    const textLine = String(line || "");
    if (!textLine.trim()) return "normal";
    if (/^===.*ERRORS & WARNINGS SUMMARY/i.test(textLine) || /\[Error\]/i.test(textLine) ||
        /\b(?:Upstream error HTTP [45]\d\d|HTTP [45]\d\d|Sync failed|Inventory sync failed|Exception|Unhealthy|status=Failed|ArcMissing|EntraDeviceDisabled|GroupNotFound)\b/i.test(textLine)) {
      return "error";
    }
    if (/\[Warning\]/i.test(textLine) ||
        /\b(?:Inventory enrichment failed|warning|Partial|StaleEvidence|PendingMde|Ambiguous|NoEntraDevice|EntraDeviceNotFound|MissingCloudIdentifier|no antivirus assessment)\b/i.test(textLine)) {
      return "warn";
    }
    if (/===/.test(textLine) || /\[(?:API|Correlation|Summary)\]/i.test(textLine) || /\bExecuting (?:ARG|bulk MDE|DeviceInfo)/i.test(textLine)) {
      return "header";
    }
    return "normal";
  }

  function renderHighlightedTranscript(codeEl, rawText, errorsOnly = false) {
    if (!codeEl) return;
    codeEl.replaceChildren();
    const lines = String(rawText || "").split(/\r?\n/);
    let shown = 0;
    for (const line of lines) {
      const kind = classifyTranscriptLine(line);
      if (errorsOnly && kind !== "error" && kind !== "warn") continue;
      shown++;
      codeEl.append(text("span", line + "\n", `transcript-line${kind !== "normal" ? ` transcript-line-${kind}` : ""}`));
    }
    if (errorsOnly && shown === 0) {
      codeEl.append(text("span", "No error or warning lines were detected in this execution transcript.\n", "transcript-line muted"));
    }
  }

  function openScriptOutputModal(entry) {
    const modal = byId("script-output-modal");
    if (!modal) return;
    currentModalEntry = entry;
    byId("script-modal-title").textContent = `${entry.Action || "Device Sync"} — ${time(entry.Timestamp)}`;
    byId("script-modal-meta").textContent = `Trigger: ${entry.TriggerReason || missing} · Run ID: ${entry.RunId || entry.State?.RunId || missing}`;
    renderHighlightedTranscript(byId("script-modal-code"), entry.ScriptOutput || entry.State?.ScriptOutput || "", scriptModalErrorsOnly);
    byId("copy-script-modal").textContent = "Copy output";
    if (!modal.open) modal.showModal();
  }

  async function loadHistory() {
    if (historyBusy || !selectedKey) return;
    historyBusy = true;
    const generation = historyGeneration;
    byId("more").disabled = true;
    byId("history-error").hidden = true;
    byId("history-status").textContent = "Loading history...";
    try {
      const page = await get(`history?key=${encodeURIComponent(selectedKey)}${historyCursor ? `&cursor=${encodeURIComponent(historyCursor)}` : ""}`);
      if (generation !== historyGeneration || !byId("detail").open) return;
      if (!Array.isArray(page.Items) || typeof page.Cursor !== "string") throw new Error("Invalid history response.");
      for (const item of page.Items) {
        const entry = document.createElement("li");
        entry.append(text("strong", `${time(item.Timestamp)} - ${item.Action}`));
        if (item.TriggerReason) entry.append(text("p", `Trigger: ${item.TriggerReason}`, "muted"));
        if (item.LogMessage) entry.append(text("p", item.LogMessage));
        if (item.State?.EntraDiagnostic) entry.append(text("p", item.State.EntraDiagnostic, "muted"));
        const runOutput = item.ScriptOutput || item.State?.ScriptOutput || "";
        if (runOutput) {
          const expandBtn = text("button", "View PowerShell execution transcript", "secondary script-expand-btn");
          expandBtn.type = "button";
          expandBtn.addEventListener("click", () => openScriptOutputModal(item));
          entry.append(expandBtn);
        }
        byId("history").append(entry);
      }
      historyCursor = page.Cursor;
      if (historyCursor) historyCursors.add(historyCursor);
      historyCount += page.Items.length;
      byId("more").hidden = !historyCursor;
      byId("history-status").textContent = historyCount ? `${historyCount} history events loaded.` : "No historical events recorded yet.";
    } catch (error) {
      if (generation !== historyGeneration) return;
      byId("history-error").textContent = error.message;
      byId("history-error").hidden = false;
      byId("history-status").textContent = "History unavailable.";
    } finally {
      if (generation === historyGeneration) {
        historyBusy = false;
        byId("more").disabled = false;
      }
    }
  }

  function csvCell(value) {
    let textValue = String(value ?? "").replace(/\r?\n/g, " ");
    if (/^[\t\r ]*[=+\-@]/.test(textValue)) textValue = `'${textValue}`;
    if (/[",\r\n]/.test(textValue)) return `"${textValue.replace(/"/g, '""')}"`;
    return textValue;
  }

  function exportUncorrelatedCsv() {
    const { filtered } = getFilteredUncorrelated();
    const headers = [
      "Server", "Resource Type", "Uncorrelated Reason", "Pipeline Gate Stopped",
      "Why It Is Uncorrelated", "Tier 1 (MDE AadDeviceId)", "Tier 2 (Machine Config)",
      "Tier 3 (Synthetic SHA-256 ID)", "Tier 4 (Hostname & OS)", "Recommended Fix",
      "Machine Status", "Defender Extension", "MDE Onboarding Status", "MDE Sensor Health",
      "MDE Device ID", "MDE Synthetic Entra Device ID", "Cloud Scope", "Target Group", "OS", "Last Checked", "Resource ID"
    ];
    const rows = [headers.map(csvCell).join(",")];
    for (const m of filtered) {
      const a = analyzeUncorrelatedDevice(m);
      const s = resolveMachineCloudScope(m);
      rows.push([
        m.MachineName,
        machineKindLabel(m),
        a.categoryLabel,
        a.gateStopped,
        a.whySummary,
        a.tiers[0].state,
        a.tiers[1].state,
        a.tiers[2].state,
        a.tiers[3].state,
        a.recommendedAction,
        m.ArcStatus,
        defenderExtensionFor(m),
        m.MdeOnboardingStatus || "Not onboarded",
        m.MdeSensorHealth || "No sensor",
        m.MdeDeviceId || "",
        m.MdeSyntheticDeviceId || "",
        `${s.CloudType}: ${s.CloudIdentifier}`,
        m.GroupName || "",
        m.OS || "",
        m.LastChecked ? time(m.LastChecked) : "",
        m.ArcResourceId || ""
      ].map(csvCell).join(","));
    }
    const blob = new Blob(["\uFEFF" + rows.join("\r\n")], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-");
    link.href = url;
    link.download = `uncorrelated-devices-${stamp}.csv`;
    document.body.append(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function clearFilters() {
    cardFilterKey = "";
    currentPage = 1;
    for (const k of Object.keys(columnFilters)) delete columnFilters[k];
    for (const id of ["search", "reason-filter", "cloud-filter", "os-filter", "arc-status-filter", "aws-account-filter", "subscription-filter"]) {
      const el = byId(id);
      if (el) el.value = "";
    }
    try {
      if (window.location?.search && window.history?.replaceState) {
        window.history.replaceState(null, "", window.location.pathname);
      }
    } catch {}
    renderSummary();
    renderHeaders();
    render();
  }

  async function refresh(forceRefresh = false) {
    if (busy) return;
    busy = true;
    byId("refresh").disabled = true;
    try {
      const showProgressive = forceRefresh || allInventoryMachines.length === 0;
      const [items, health] = await Promise.all([
        allMachines(forceRefresh, firstPageItems => {
          if (showProgressive) {
            applySnapshot(firstPageItems, null, new Date().toISOString(), false, true);
          }
        }),
        get("health", forceRefresh)
      ]);
      const nowIso = new Date().toISOString();
      applySnapshot(items, health, nowIso, false, false);
      saveCachedSnapshot(items, health, nowIso);
      byId("error").hidden = true;
    } catch (error) {
      byId("error").textContent = `${error.message} Displayed results, if any, are from the last successful refresh.`;
      byId("error").hidden = false;
    } finally {
      byId("refresh").disabled = false;
      busy = false;
    }
  }

  byId("search")?.addEventListener("input", () => scheduleRender(true));
  for (const id of ["reason-filter", "cloud-filter", "os-filter", "arc-status-filter", "aws-account-filter", "subscription-filter"]) {
    byId(id)?.addEventListener("input", () => {
      currentPage = 1;
      render();
    });
  }
  try {
    const savedPageSize = Number(localStorage.getItem(pageSizePreferenceKey));
    if ([50, 100, 250, 500].includes(savedPageSize)) {
      pageSize = savedPageSize;
      if (byId("page-size")) byId("page-size").value = String(pageSize);
    }
  } catch {}
  byId("page-size")?.addEventListener("change", () => {
    const nextSize = Number(byId("page-size").value);
    if ([50, 100, 250, 500].includes(nextSize)) {
      pageSize = nextSize;
      currentPage = 1;
      try { localStorage.setItem(pageSizePreferenceKey, String(pageSize)); } catch {}
      render();
    }
  });
  byId("page-first")?.addEventListener("click", () => { if (currentPage > 1) { currentPage = 1; render(); } });
  byId("page-prev")?.addEventListener("click", () => { if (currentPage > 1) { currentPage--; render(); } });
  byId("page-next")?.addEventListener("click", () => { currentPage++; render(); });
  byId("page-last")?.addEventListener("click", () => {
    const { filtered } = getFilteredUncorrelated();
    currentPage = Math.max(1, Math.ceil(filtered.length / pageSize));
    render();
  });
  byId("export-csv")?.addEventListener("click", exportUncorrelatedCsv);
  byId("clear-filters")?.addEventListener("click", clearFilters);
  byId("refresh")?.addEventListener("click", () => refresh(true));
  byId("theme-toggle")?.addEventListener("click", () => setTheme(currentTheme() === "dark" ? "light" : "dark"));
  byId("more")?.addEventListener("click", loadHistory);
  byId("close-detail")?.addEventListener("click", () => byId("detail").close());
  byId("detail").addEventListener("close", () => {
    if (byId("detail").open) return;
    historyGeneration++;
    historyBusy = false;
    const key = selectedKey;
    selectedKey = "";
    for (const row of byId("uncorr-body").rows) row.classList.remove("is-selected");
    const fallback = [...byId("uncorr-body").rows].find(row => row.dataset.key === key)?.querySelector(".uncorr-inspect");
    (historyTrigger?.isConnected ? historyTrigger : fallback || document.querySelector(".table-wrap")).focus();
    historyTrigger = null;
  });
  document.addEventListener("keydown", event => {
    if (event.key !== "Escape" || byId("script-output-modal").open) return;
    if (!byId("hover-popover").hidden) hideHoverPopover();
    else if (byId("detail").open) {
      event.preventDefault();
      byId("detail").close();
    }
  });
  byId("close-script-modal")?.addEventListener("click", () => byId("script-output-modal")?.close());
  byId("filter-script-errors")?.addEventListener("click", () => {
    const btn = byId("filter-script-errors");
    if (!btn) return;
    scriptModalErrorsOnly = !scriptModalErrorsOnly;
    btn.textContent = `Errors & warnings only: ${scriptModalErrorsOnly ? "On" : "Off"}`;
    btn.setAttribute("aria-pressed", String(scriptModalErrorsOnly));
    if (currentModalEntry) {
      renderHighlightedTranscript(byId("script-modal-code"), currentModalEntry.ScriptOutput || currentModalEntry.State?.ScriptOutput || "", scriptModalErrorsOnly);
    }
  });
  byId("wrap-script-modal")?.addEventListener("click", () => {
    const pre = byId("script-modal-pre");
    const btn = byId("wrap-script-modal");
    if (!pre || !btn) return;
    const wrapped = pre.classList.toggle("wrap-lines");
    btn.textContent = `Wrap lines: ${wrapped ? "On" : "Off"}`;
    btn.setAttribute("aria-pressed", String(wrapped));
  });
  byId("copy-script-modal")?.addEventListener("click", async () => {
    const content = currentModalEntry?.ScriptOutput || currentModalEntry?.State?.ScriptOutput || byId("script-modal-code")?.textContent || "";
    try {
      await navigator.clipboard.writeText(content);
      byId("copy-script-modal").textContent = "Copied!";
    } catch {}
  });
  byId("hover-popover").addEventListener("mouseenter", clearHoverTimer);
  byId("hover-popover").addEventListener("mouseleave", event => {
    if (activeHoverCell?.contains(event.relatedTarget)) return;
    scheduleHideHoverPopover();
  });
  document.querySelector(".table-wrap")?.addEventListener("scroll", hideHoverPopover, { passive: true });
  window.addEventListener("scroll", hideHoverPopover, { passive: true });
  window.addEventListener("resize", () => { if (activeHoverCell) positionHoverPopover(activeHoverCell); });

  updateThemeButton();
  renderHeaders();
  void (async () => {
    const savedAt = await loadCachedSnapshotAsync();
    const cachedAgeMs = Date.now() - savedAt;
    if (cachedAgeMs > cacheFreshnessMs) void refresh(false);
  })();
  window.setInterval(() => { if (!document.hidden && byId("hover-popover").hidden) void refresh(false); }, cacheFreshnessMs);
})();
