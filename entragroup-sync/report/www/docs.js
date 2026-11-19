"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const themePreferenceKey = "arc-entra-theme-v2";
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
  byId("theme-toggle")?.addEventListener("click", () => setTheme(currentTheme() === "dark" ? "light" : "dark"));
  const docSections = [...document.querySelectorAll("details.doc-section")];
  function selectDocSection(targetId) {
    const id = targetId && byId(targetId) ? targetId : (docSections[0]?.id || "doc-archify");
    for (const sec of docSections) {
      const active = sec.id === id;
      sec.hidden = !active;
      if (active) sec.open = true;
    }
    for (const btn of document.querySelectorAll("#docs-section-tabs button[data-section-tab]")) {
      const active = btn.dataset.sectionTab === id;
      btn.classList.toggle("is-active", active);
      btn.setAttribute("aria-selected", String(active));
    }
  }
  for (const btn of document.querySelectorAll("#docs-section-tabs button[data-section-tab]")) {
    btn.addEventListener("click", () => selectDocSection(btn.dataset.sectionTab));
  }
  for (const link of document.querySelectorAll("a[data-doc-target]")) {
    link.addEventListener("click", event => {
      event.preventDefault();
      selectDocSection(link.dataset.docTarget);
    });
  }
  window.addEventListener("hashchange", () => {
    const hashId = String(window.location.hash || "").replace(/^#/, "");
    if (hashId && byId(hashId)) selectDocSection(hashId);
  });
  const initialDocHash = String(window.location.hash || "").replace(/^#/, "");
  selectDocSection(initialDocHash && byId(initialDocHash) ? initialDocHash : "doc-archify");
  for (const table of document.querySelectorAll("table")) {
    const thead = table.querySelector("thead");
    const tbody = table.querySelector("tbody");
    if (!thead || !tbody || thead.querySelector("tr.column-filters")) continue;
    const headerRow = thead.querySelector("tr");
    if (!headerRow) continue;
    const filterRow = document.createElement("tr");
    filterRow.className = "column-filters";
    const apply = () => {
      const inputs = [...filterRow.querySelectorAll("input")];
      const active = inputs.map((inp, idx) => [idx, (inp.value || "").trim().toLowerCase()]).filter(([, val]) => val);
      for (const row of tbody.rows) {
        if (row.cells.length === 1 && row.cells[0].colSpan > 1) continue;
        row.hidden = !active.every(([idx, val]) => String(row.cells[idx]?.textContent || "").toLowerCase().includes(val));
      }
    };
    for (const th of headerRow.children) {
      const label = (th.textContent || "").trim() || "column";
      const td = document.createElement("td");
      const input = document.createElement("input");
      input.type = "search";
      input.placeholder = `Filter ${label}`;
      input.setAttribute("aria-label", `Filter ${label}`);
      input.addEventListener("input", apply);
      td.append(input);
      filterRow.append(td);
    }
    thead.append(filterRow);
  }
  const archifyNodeDetails = {
    "work_item": "Criteria: Resource must be HybridCompute/machines, Compute/virtualMachines, ClassicCompute/virtualMachines, or VMSS virtualMachines (excluding Compute.AKS), and satisfy (Subscription in SYNC_SUBSCRIPTION_IDS OR SYNC_MANAGEMENT_GROUP_IDS) AND (SYNC_RESOURCE_GROUP_NAMES is empty OR matches resourceGroup).",
    "arm_check": "Criteria: Calls ARM GET for the resource to inspect Arc/VM state, OS, SubscriptionName, and Azure resource tags (AccountId / ProjectId). Offline Arc machines and stopped/deallocated VMs are still correlated to support ephemeral workloads.",
    "arc_blocked": "Stop Criteria: HTTP 404 sets Status = 'ArcMissing'. Offline or stopped/deallocated machines still proceed through correlation; existing group memberships are never removed.",
    "mde_correlate": "Criteria: Latest DeviceInfo per DeviceId (7d), matched by AzureResourceId or AzureVmId. Excludes MergedToDeviceId records and predecessors listed in MergedDeviceIds before freshness checks. Requires a unique Onboarded record within SYNC_FRESHNESS_HOURS (168h / 7d by default), with at most 5 minutes future skew (or a single Active sensor when multiple unmerged records exist). Empty AadDeviceId permits the guarded fallback paths.",
    "mde_blocked": "Stop Criteria: No onboarded unmerged record = PendingMde; stale/invalid Timestamp = StaleEvidence; merge conflict or multiple fresh records without a unique Active sensor = Ambiguous. Known re-onboarding requires MDE AadDeviceId, Machine Configuration intuneDeviceId, or MDE Synthetic Device ID; hostname-only matching is blocked. Existing group memberships are never removed.",
    "entra_resolve": "Criteria (4-Tier Correlation): Evaluates Tier 1 MdeAadDeviceId -> Tier 2 GuestConfigurationIntuneDeviceId -> Tier 3 MdeSyntheticDeviceId (SHA-256 folded from MDE DeviceId) -> Tier 4 MicrosoftSenseHostnameAndOS via Microsoft Graph GET /v1.0/devices. Requires exactly 1 directory object with accountEnabled == true, and extracts the directory object 'id' (never deviceId) for group membership operations.",
    "entra_blocked": "Stop Criteria: 0 matching devices = 'EntraDeviceNotFound'; >1 matching devices = 'Ambiguous'; accountEnabled != true = 'EntraDeviceDisabled'.",
    "os_group": "Criteria (Gate 5 — Cloud, OS & Active/Passive Mode): Resolves OS (Windows vs Linux), Cloud Scope (AWS via AccountId tag, GCP via ProjectId tag, Azure via SubscriptionName with AWS/GCP excluded), and global default group mode (SYNC_DEFAULT_GROUP_MODE = Passive by default, or Active). Inspects existing Entra group memberships via /devices/{id}/memberOf: if global flag is Passive and device is in an Active group, it is NOT added to Passive; if global flag is Active and device is in a Passive group, it is NOT added to Active.",
    "cloud_group": "Criteria (Gate 6 — Per-Account Active/Passive Group, AU Auto-Create & Compliance Flags): Resolves <Prefix>{Passive|Active}-<AccountId|ProjectId|SubscriptionName> in Entra ID. If missing and SYNC_ADMIN_UNIT_ID + SYNC_AUTO_CREATE_GROUPS are configured, Enforce mode auto-creates both the Passive and Active groups inside the Administrative Unit (POST /directory/administrativeUnits/{auId}/members with #microsoft.graph.group). Flags devices in the table when: (1) in Active group but MDE mode is Passive ('Should be Active'), (2) in Passive group but MDE mode is Active ('Should be Active'), (3) in multiple groups, or (4) in a group whose AWS Account ID, GCP Project, or Azure Subscription does not match.",
    "persist": "Criteria: Rechecks ARM Connected state before writing. Audit mode sets Status = 'WouldAdd' if absent; Enforce mode writes a durable mutation intent, POSTs /groups/{id}/members/$ref, verifies direct membership read-back, and commits state + h_ history + log_ rows in an atomic Table batch."
  };
  const bindArchifyDiagram = (svgSelector, statusId, emptyText) => {
    const svg = document.querySelector(svgSelector);
    const status = byId(statusId);
    if (!svg || !status) return;
    const nodes = [...svg.querySelectorAll("[data-node-id]")];
    const edges = [...svg.querySelectorAll("[data-edge-from]")];
    let selectedId = "";
    const clearFocus = () => {
      selectedId = "";
      svg.classList.remove("has-focus");
      for (const node of nodes) {
        node.classList.remove("is-active", "is-related");
        node.setAttribute("aria-pressed", "false");
      }
      for (const edge of edges) edge.classList.remove("is-related");
      status.textContent = emptyText;
    };
    const focusNode = node => {
      const id = node.dataset.nodeId;
      if (selectedId === id) { clearFocus(); return; }
      selectedId = id;
      svg.classList.add("has-focus");
      const relatedNodes = new Set([id]);
      const inbound = [];
      const outbound = [];
      for (const edge of edges) {
        const from = edge.dataset.edgeFrom;
        const to = edge.dataset.edgeTo;
        const match = from === id || to === id;
        edge.classList.toggle("is-related", match);
        if (from === id && to && edge.tagName.toLowerCase() === "path") outbound.push(to);
        if (to === id && from && edge.tagName.toLowerCase() === "path") inbound.push(from);
        if (match) {
          if (from) relatedNodes.add(from);
          if (to) relatedNodes.add(to);
        }
      }
      for (const item of nodes) {
        const active = item.dataset.nodeId === id;
        item.classList.toggle("is-active", active);
        item.classList.toggle("is-related", relatedNodes.has(item.dataset.nodeId));
        item.setAttribute("aria-pressed", String(active));
      }
      const labelFor = key => nodes.find(n => n.dataset.nodeId === key)?.dataset.nodeLabel || key;
      const inText = inbound.length ? `Upstream: ${[...new Set(inbound)].map(labelFor).join(", ")}. ` : "";
      const outText = outbound.length ? `Downstream: ${[...new Set(outbound)].map(labelFor).join(", ")}.` : "";
      const criteria = archifyNodeDetails[id] ? ` ${archifyNodeDetails[id]} ` : " ";
      status.textContent = `${node.dataset.nodeLabel} (${node.dataset.nodeSublabel || node.dataset.nodeKind || "component"}${node.dataset.nodeTag ? ` · ${node.dataset.nodeTag}` : ""}).${criteria}${inText}${outText}`;
    };
    for (const node of nodes) {
      node.addEventListener("click", () => focusNode(node));
      node.addEventListener("keydown", event => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          focusNode(node);
        }
      });
    }
  };
  bindArchifyDiagram("#doc-archify .archify-svg", "archify-inspector-text", "Select any component node in the Archify diagram above to highlight its connected data flows and view its implementation details.");
  bindArchifyDiagram("#doc-architecture .archify-workflow-svg", "archify-workflow-inspector-text", "Select any gate or safety-stop node above to inspect the exact evaluation criteria, fields checked, and failure status.");
  updateThemeButton();
})();
