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
  for (const link of document.querySelectorAll("a[data-doc-target]")) {
    link.addEventListener("click", () => {
      const target = byId(link.dataset.docTarget);
      if (target) target.open = true;
    });
  }
  const archifyNodeDetails = {
    "work_item": "Criteria: Resource must be HybridCompute/machines, Compute/virtualMachines, ClassicCompute/virtualMachines, or VMSS virtualMachines (excluding Compute.AKS), and satisfy (Subscription in SYNC_SUBSCRIPTION_IDS OR SYNC_MANAGEMENT_GROUP_IDS) AND (SYNC_RESOURCE_GROUP_NAMES is empty OR matches resourceGroup).",
    "arm_check": "Criteria: Calls ARM GET for the resource. Arc requires properties.status == 'Connected'; Azure Native VM / VMSS requires PowerState != 'deallocated' and != 'stopped'. Also extracts OS, SubscriptionName, and Azure resource tags (AccountId / ProjectId).",
    "arc_blocked": "Stop Criteria: HTTP 404 sets Status = 'ArcMissing'; Disconnected Arc agent or deallocated/stopped VM sets Status = 'ArcNotConnected'. No Entra directory lookup or group change is made, and existing group memberships are never removed.",
    "mde_correlate": "Criteria: Queries Defender Advanced Hunting DeviceInfo (7d lookback, arg_max(Timestamp, *) by DeviceId) where AzureResourceId =~ resourceId. Requires OnboardingStatus == 'Onboarded', MergedToDeviceId == '', Timestamp within SYNC_FRESHNESS_HOURS (default 24h), exactly 1 matching device, and a valid GUID in AadDeviceId.",
    "mde_blocked": "Stop Criteria: 0 onboarded rows = 'PendingMde'; rows older than SYNC_FRESHNESS_HOURS = 'StaleEvidence'; >1 fresh unmerged rows = 'Ambiguous'; empty AadDeviceId = 'NoEntraDevice'; non-GUID = 'InvalidEntraIdentifier'.",
    "entra_resolve": "Criteria: Queries Microsoft Graph GET /v1.0/devices?$filter=deviceId eq '{AadDeviceId}'. Requires exactly 1 directory object with accountEnabled == true, and extracts the directory object 'id' (never deviceId) for group membership operations.",
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
