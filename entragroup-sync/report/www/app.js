"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const base = window.location.pathname.startsWith("/api/report") ? "/api/report/" : "/";
  let machines = [];
  let busy = false;
  let selectedKey = "";
  let historyCursor = "";
  let historyGeneration = 0;
  let historyBusy = false;
  let historyTrigger = null;
  let historyCount = 0;
  let historyCursors = new Set();
  let logsCursor = "";
  let logsCursors = new Set();
  let logsCount = 0;
  let logsBusy = false;
  let cardFilter = null;
  const time = value => value ? new Date(value).toLocaleString() : "Not observed";
  const text = (tag, value, className) => {
    const element = document.createElement(tag);
    element.textContent = String(value ?? "");
    if (className) element.className = className;
    return element;
  };
  const joined = value => Array.isArray(value) ? value.join("; ") : String(value ?? "");
  const azureTagValues = value => value && typeof value === "object" ?
    Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, tag]) => `${key}=${tag}`) : null;
  const defenderExtensionFor = machine => {
    if (machine.DefenderExtensionStatus) return machine.DefenderExtensionStatus;
    if (!Array.isArray(machine.ArcExtensions)) return "";
    const matched = machine.ArcExtensions.map(ext => {
      const match = String(ext ?? "").match(/^\s*(MDE\.(?:Windows|Linux))\b(?:.*?\bstate:\s*([^);\s]+))?/i);
      return match ? `${match[1]}: ${match[2] || "Installed"}` : "";
    }).filter(Boolean);
    return matched.length ? [...new Set(matched)].join("; ") : "Not installed";
  };
  const missing = "Not available";
  function correlationMethodFor(machine) {
    const path = String(machine?.EntraCorrelationPath || "").trim();
    if (path === "MdeAadDeviceId") return "MDE AadDeviceId";
    if (path === "GuestConfigurationIntuneDeviceId") return "Machine Configuration (intuneDeviceId)";
    if (path === "MicrosoftSenseHostnameAndOS") return "MicrosoftSense (Hostname & OS)";
    if (path === "AadDeviceIdAmbiguous") return "Ambiguous (MDE AadDeviceId)";
    if (path === "GuestConfigIntuneDeviceIdAmbiguous") return "Ambiguous (Machine Configuration)";
    if (path === "MicrosoftSenseAmbiguous") return "Ambiguous (MicrosoftSense)";
    const isCorrelated = Boolean(machine?.EntraObjectId || (machine?.EntraDeviceId && ["Verified", "WouldAdd", "Matched", "GroupNotFound", "MissingCloudIdentifier", "GroupNotConfigured"].includes(machine?.Status)));
    if (isCorrelated) {
      if (machine?.GuestConfigEntraDeviceId && String(machine.GuestConfigEntraDeviceId).toLowerCase() === String(machine.EntraDeviceId || "").toLowerCase()) {
        return "Machine Configuration (intuneDeviceId)";
      }
      return "MDE AadDeviceId";
    }
    return "Not correlated";
  }
  const columns = [
    { id: "MachineName", label: "Azure Machine", link: "arc" },
    { id: "MdeDeviceName", label: "MDE Device", link: "mde", value: m => m.MdeDeviceName || m.MdeDeviceId },
    { id: "MdeDeviceId", label: "MDE device ID", link: "mde" },
    { id: "EntraDeviceId", label: "Entra ID Device", link: "entra" },
    { id: "EntraCorrelationPath", label: "Correlation method", value: m => correlationMethodFor(m) },
    { id: "ManagementGroup", label: "Management Group" },
    { id: "ResourceGroup", label: "Resource Group" },
    { id: "SubscriptionName", label: "Subscription", value: m => m.SubscriptionName ? `${m.SubscriptionName} (${m.SubscriptionId})` : m.SubscriptionId },
    { id: "ComputerName", label: "Computer name" },
    { id: "Fqdn", label: "FQDN" },
    { id: "CloudProvider", label: "Cloud provider" },
    { id: "MdeSensorHealth", label: "MDE sensor health" },
    { id: "ArcStatus", label: "Machine Status", value: m => isNativeAzureMachine(m) ? ((!m.ArcStatus || m.ArcStatus === "Connected") ? "VM running" : m.ArcStatus) : m.ArcStatus },
    { id: "MdeOnboardingStatus", label: "MDE onboarded status" },
    { id: "MdeAntivirusMode", label: "MDE antivirus mode" },
    { id: "VirtualMachineId", label: "Virtual machine ID" },
    { id: "DefenderExtensionStatus", label: "Defender extension status", value: m => defenderExtensionFor(m) },
    { id: "ArcExtensions", label: "Machine extensions" },
    { id: "IPAddresses", label: "IP addresses" },
    { id: "MdeDeviceTags", label: "MDE device tags", tags: true, value: m => m.MdeDeviceTags, empty: "No tags" },
    { id: "MdeDeviceGroup", label: "MDE device group membership" },
    { id: "AzureTags", label: "Azure tags", tags: true, value: m => azureTagValues(m.AzureTags), empty: "No tags" },
    { id: "OS", label: "operating system" },
    { id: "Status", label: "Correlation" },
    { id: "Membership", label: "Entra ID Group", value: m => {
      if (Array.isArray(m.MemberGroups) && m.MemberGroups.length) {
        return m.MemberGroups.map(g => g.DisplayName || g.Id).filter(Boolean).join("; ");
      }
      if (Array.isArray(m.GroupNames) && m.GroupNames.length) {
        return m.GroupNames.filter(Boolean).join("; ");
      }
      if (m.Membership === "NotConfigured") return "Not configured";
      if (m.Membership === "MissingIdentifier") return `Missing ${m.CloudGroupType === "AWS" ? "AccountId tag" : m.CloudGroupType === "GCP" ? "ProjectId tag" : "subscription name"}`;
      if (m.Membership === "GroupNotFound") return `Group not found (${m.GroupName || missing})`;
      if (m.Membership === "Present") return m.GroupName || (m.GroupId ? `Name unavailable (${m.GroupId})` : missing);
      if (m.Membership === "Absent") return m.GroupName ? `Not in group (${m.GroupName})` : "Not in group";
      return m.GroupName ? `Membership unknown (${m.GroupName})` : "Membership unknown";
    } },
    { id: "GroupFlags", label: "Group & AV flags", optional: true, value: m => Array.isArray(m.GroupFlags) && m.GroupFlags.length ?
      m.GroupFlags.join("; ") : (m.Membership === "Present" ? `Compliant (${m.GroupAvMode || "Passive"})` : "Not evaluated") },
    { id: "Mode", label: "Sync mode" },
    { id: "LastChecked", label: "Last checked", type: "date" },
    { id: "MembershipVerifiedAt", label: "Membership verified", type: "date" },
    { id: "ArcLastReportedAt", label: "Arc Connected Machine last state time", type: "date", value: m => isNativeAzureMachine(m) ? "N/A" : m.ArcLastReportedAt },
    { id: "ArcAddedAt", label: "Arc added", type: "date", value: m => isNativeAzureMachine(m) ? "N/A" : (m.ArcAddedAt || m.FirstSeen) },
    { id: "MdeLastSeen", label: "MDE last check in time", type: "date" },
    { id: "InventoryStatus", label: "Inventory collection" },
    { id: "InventoryErrors", label: "Inventory warnings", optional: true },
    { id: "MdeAntivirusTimestamp", label: "Antivirus report time", type: "date", optional: true },
    { id: "MdeAntivirusStatus", label: "Antivirus data status", optional: true },
    { id: "MdeCloudPlatforms", label: "MDE cloud platforms", optional: true },
    { id: "MdeAzureVmId", label: "MDE Azure VM ID", optional: true },
    { id: "SubscriptionId", label: "Subscription ID", optional: true },
    { id: "EntraObjectId", label: "Entra object ID", link: "entra", optional: true },
    { id: "ArcResourceId", label: "Resource ID", optional: true },
    { id: "Error", label: "Processing error", optional: true }
  ];
  const columnById = new Map(columns.map(column => [column.id, column]));
  const preferenceKey = "arc-entra-table-v4";
  const dataCacheKey = "arc-entra-data-cache-v1";
  const themePreferenceKey = "arc-entra-theme-v2";
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
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
  const defaultColumns = [
    "MachineName", "MdeDeviceName", "EntraDeviceId", "EntraCorrelationPath", "Membership", "MdeOnboardingStatus",
    "MdeAntivirusMode", "ArcStatus", "ComputerName", "Fqdn", "OS"
  ];
  const defaults = () => ({
    order: [...defaultColumns, ...columns.map(c => c.id).filter(id => !defaultColumns.includes(id))],
    visible: [...defaultColumns],
    sort: { id: "MachineName", direction: "asc" }
  });
  let layout = defaults();
  const filters = {};
  let draggedColumn = "";
  function tableNotice(message) {
    byId("table-notice").textContent = message;
    byId("table-notice").hidden = !message;
  }
  function readLayout() {
    try {
      const raw = localStorage.getItem(preferenceKey);
      if (!raw) return;
      const saved = JSON.parse(raw);
      if (!Array.isArray(saved.order) || !Array.isArray(saved.visible) || !saved.sort) throw new Error("Invalid layout");
      const order = [...new Set(saved.order.filter(id => columnById.has(id)))];
      const visible = [...new Set(saved.visible.filter(id => columnById.has(id)))];
      if (!visible.length || !columnById.has(saved.sort.id) || !["asc", "desc"].includes(saved.sort.direction)) throw new Error("Invalid layout");
      layout = { order: [...order, ...columns.map(c => c.id).filter(id => !order.includes(id))], visible, sort: saved.sort };
    } catch {
      tableNotice("Saved column preferences could not be loaded. The default layout is shown.");
    }
  }
  function saveLayout() {
    try { localStorage.setItem(preferenceKey, JSON.stringify(layout)); }
    catch { tableNotice("Your browser could not save column preferences. Changes still apply to this page."); }
  }
  function valueFor(machine, column) {
    return joined(column.value ? column.value(machine) : machine[column.id]);
  }
  function searchFor(machine, column) {
    return `${valueFor(machine, column)} ${displayFor(machine, column)}${column.id === "Membership" ? ` ${machine.Membership || "Unknown"}` : ""}`;
  }
  function displayFor(machine, column) {
    const value = valueFor(machine, column);
    if (value === "N/A") return "N/A";
    if (!value && column.empty && (column.value ? column.value(machine) : machine[column.id]) != null) return column.empty;
    return column.type === "date" ? time(value) : value || missing;
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
    if (kind === "group" && machine.GroupId) {
      return `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/${encodeURIComponent(machine.GroupId)}`;
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
  function isNativeAzureMachine(machine) {
    const id = String(machine?.ArcResourceId || "").toLowerCase();
    return id.includes("/providers/microsoft.compute/") || id.includes("/providers/microsoft.classiccompute/");
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
  function machineKindLabel(machine) {
    const id = String(machine?.ArcResourceId || "").toLowerCase();
    if (id.includes("/providers/microsoft.compute/virtualmachinescalesets/")) return "Native Azure Machine (VMSS)";
    if (isNativeAzureMachine(machine)) return "Native Azure Machine";
    if (isAwsMachine(machine)) return "Arc Connected Machine (AWS)";
    return "Arc Connected Machine";
  }
  function awsIconNode() {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 24 18");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("class", "machine-type-svg aws-provider-svg");
    const title = document.createElementNS(ns, "title");
    title.textContent = "Amazon Web Services (AWS)";
    svg.append(title);
    const el = (tag, attrs, textValue = "") => {
      const node = document.createElementNS(ns, tag);
      for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
      if (textValue) node.textContent = textValue;
      return node;
    };
    svg.append(
      el("rect", { x: "0.5", y: "0.5", width: "23", height: "17", rx: "2.5", class: "aws-badge-bg" }),
      el("text", { x: "12", y: "10.3", "text-anchor": "middle", "font-size": "7.6", "font-weight": "700", class: "aws-badge-text" }, "aws"),
      el("path", { d: "M4.5 12.6c4.3 2.7 10.7 2.7 15 0", class: "aws-smile-curve" }),
      el("path", { d: "M17.4 11.7l2.5.7-.9 2.3", class: "aws-smile-arrow" })
    );
    return svg;
  }
  function machineTypeIconNode(machine) {
    const native = isNativeAzureMachine(machine);
    const label = machineKindLabel(machine);
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 18 18");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("class", `machine-type-svg ${native ? "machine-type-native" : "machine-type-arc"}`);
    const title = document.createElementNS(ns, "title");
    title.textContent = label;
    svg.append(title);
    const el = (tag, attrs) => {
      const node = document.createElementNS(ns, tag);
      for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
      return node;
    };
    if (native) {
      // Official Azure Virtual Machine icon geometry (az-icons.com/icon/virtual-machine)
      svg.append(
        el("rect", { x: "-0.12", y: "0.21", width: "18", height: "12", rx: "0.6", class: "az-vm-screen" }),
        el("polygon", { points: "11.88 4.46 11.88 7.95 8.88 9.71 8.88 6.21 11.88 4.46", class: "az-vm-cube-right" }),
        el("polygon", { points: "11.88 4.46 8.88 6.22 5.88 4.46 8.88 2.71 11.88 4.46", class: "az-vm-cube-top" }),
        el("polygon", { points: "8.88 6.22 8.88 9.71 5.88 7.95 5.88 4.46 8.88 6.22", class: "az-vm-cube-left" }),
        el("polygon", { points: "5.88 7.95 8.88 6.21 8.88 9.71 5.88 7.95", class: "az-vm-cube-top" }),
        el("polygon", { points: "11.88 7.95 8.88 6.21 8.88 9.71 11.88 7.95", class: "az-vm-cube-left" }),
        el("path", { d: "M12.49,15.84c-1.78-.28-1.85-1.56-1.85-3.63H7.11c0,2.07-.06,3.35-1.84,3.63a1,1,0,0,0-.89,1h9A1,1,0,0,0,12.49,15.84Z", class: "az-vm-stand" })
      );
    } else {
      // Official Azure Arc Machines icon geometry (az-icons.com/icon/arc-machines)
      svg.append(
        el("path", { d: "M17.547,15.2c-.161.7-1.035,1.391-2.617,1.928a21.589,21.589,0,0,1-12.121.017C1.352,16.627.566,15.971.443,15.3c-.021-.118,0-1.966,0-1.966l17.131-.159S17.566,15.11,17.547,15.2Z", class: "az-arc-base-rim" }),
        el("ellipse", { cx: "9.001", cy: "13.295", rx: "8.573", ry: "2.964", transform: "translate(-0.133 0.091) rotate(-0.575)", class: "az-arc-base-top" }),
        el("path", { d: "M13.364,12.978a.482.482,0,0,1-.5.455H5.146a.482.482,0,0,1-.5-.455V.456A.48.48,0,0,1,5.146,0h7.715a.481.481,0,0,1,.5.455Z", class: "az-arc-tower" }),
        el("path", { d: "M11.212,6.791H6.872a1,1,0,0,1-.947-1.044h0A1,1,0,0,1,6.872,4.7h4.34a1,1,0,0,1,.948,1.045A1,1,0,0,1,11.212,6.791ZM12.16,2.64A1,1,0,0,0,11.212,1.6H6.872A1,1,0,0,0,5.925,2.64h0a1,1,0,0,0,.947,1.045h4.34A1,1,0,0,0,12.16,2.64Z", class: "az-arc-slot" }),
        el("path", { d: "M10.94,1.939a.7.7,0,1,1-.7.7A.7.7,0,0,1,10.94,1.939Zm-.7,3.8a.7.7,0,1,0,.7-.7A.7.7,0,0,0,10.239,5.743Z", class: "az-arc-led" })
      );
    }
    return svg;
  }
  function machineNameNode(machine) {
    const wrap = text("span", "", "machine-name-badge");
    wrap.title = machineKindLabel(machine);
    wrap.append(machineTypeIconNode(machine));
    if (isAwsMachine(machine)) wrap.append(awsIconNode());
    appendLink(wrap, displayFor(machine, columnById.get("MachineName")), deviceLink(machine, "arc"));
    return wrap;
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
  function groupLinkById(groupId) {
    return groupId ? `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/${encodeURIComponent(groupId)}` : "";
  }
  function groupMembershipNode(machine) {
    const hasFlags = Array.isArray(machine.GroupFlags) && machine.GroupFlags.length > 0;
    const tone = hasFlags ? "bad" : machine.Membership === "Present" ? "good" : ["Absent", "GroupNotFound", "MissingIdentifier"].includes(machine.Membership) ? "attention" : "";
    const wrap = text("span", "", `status-value group-value ${tone}`);
    const list = text("span", "", "group-links");
    if (Array.isArray(machine.MemberGroups) && machine.MemberGroups.length) {
      for (const g of machine.MemberGroups) {
        const item = text("span", "", "group-link-item");
        appendLink(item, g.DisplayName || g.Id || missing, groupLinkById(g.Id));
        list.append(item);
      }
    } else {
      const item = text("span", "", "group-link-item");
      appendLink(item, displayFor(machine, columnById.get("Membership")), machine.Membership === "Present" ? deviceLink(machine, "group") : "");
      list.append(item);
    }
    wrap.append(list);
    if (hasFlags) {
      const info = text("span", "i", "flag-indicator");
      info.setAttribute("aria-label", `${machine.GroupFlags.length} compliance flag(s) — hover for details`);
      wrap.append(info);
    }
    return wrap;
  }
  function avModeCellNode(machine) {
    const value = displayFor(machine, columnById.get("MdeAntivirusMode"));
    const avMismatch = Array.isArray(machine.GroupFlagCodes) && machine.GroupFlagCodes.includes("AvModeMismatchShouldBeActive");
    if (!avMismatch) return text("span", value);
    const wrap = text("span", value, "status-value bad");
    const info = text("span", "i", "flag-indicator");
    info.setAttribute("aria-label", "MDE antivirus mode mismatch — hover for details");
    wrap.append(info);
    return wrap;
  }
  function groupFlagsNode(machine) {
    if (Array.isArray(machine.GroupFlags) && machine.GroupFlags.length) {
      const list = text("span", "", "tag-list");
      for (const flag of machine.GroupFlags) list.append(text("span", flag, "badge bad"));
      return list;
    }
    if (machine.Membership === "Present") {
      return text("span", `Compliant (${machine.GroupAvMode || "Passive"})`, "badge good");
    }
    return text("span", "Not evaluated", "muted");
  }
  function defenderStatusNode(machine) {
    const value = displayFor(machine, columnById.get("DefenderExtensionStatus"));
    const lower = value.toLowerCase();
    const tone = lower.includes("succeeded") ? "good" : lower.includes("failed") || lower.includes("error") ? "bad" : lower.includes("not installed") ? "attention" : "";
    return text("span", value, `status-value ${tone}`);
  }
  function tagPillsNode(tags, fallback) {
    if (tags?.length) {
      const list = text("span", "", "tag-list");
      for (const tag of tags) list.append(text("span", tag, "tag"));
      return list;
    }
    return text("span", fallback || missing, "muted");
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
  function arcHoverSpec(machine) {
    const native = isNativeAzureMachine(machine);
    const typeBadge = text("span", "", "os-badge");
    typeBadge.append(machineTypeIconNode(machine));
    if (isAwsMachine(machine)) typeBadge.append(awsIconNode());
    typeBadge.append(text("span", machineKindLabel(machine)));
    return [native ? "NATIVE AZURE MACHINE" : "ARC CONNECTED MACHINE", [
      ["Resource Type", typeBadge],
      ["Resource ID", machine.ArcResourceId || missing],
      ["Cloud Provider", machine.CloudProvider || (native ? "Azure" : missing)],
      ["Operating System", osNode(machine.OS)],
      ["Defender extension", defenderStatusNode(machine)],
      ["Resource Group", machine.ResourceGroup || missing],
      ["Subscription Name", machine.SubscriptionName || machine.SubscriptionId || missing],
      ["Management Group", machine.ManagementGroup || missing],
      ["Arc Connected Machine last state time", displayFor(machine, columnById.get("ArcLastReportedAt"))],
      ["Arc added", displayFor(machine, columnById.get("ArcAddedAt"))],
      ["Azure Tags", tagPillsNode(azureTagValues(machine.AzureTags), displayFor(machine, columnById.get("AzureTags")))]
    ]];
  }
  function mdeHoverSpec(machine) {
    return ["MICROSOFT DEFENDER FOR ENDPOINT", [
      ["MDE Device ID", machine.MdeDeviceId || missing],
      ["MDE Cloud Platforms", machine.MdeCloudPlatforms || machine.CloudProvider || missing],
      ["Operating System", osNode(machine.OS)],
      ["MDE Device Group", machine.MdeDeviceGroup || missing],
      ["Sensor Health / Onboarding", `${machine.MdeSensorHealth || missing} / ${machine.MdeOnboardingStatus || missing}`],
      ["Antivirus Mode", machine.MdeAntivirusMode || missing],
      ["MDE last check in time", time(machine.MdeLastSeen)],
      ["MDE Device Tags", tagPillsNode(machine.MdeDeviceTags, displayFor(machine, columnById.get("MdeDeviceTags")))]
    ]];
  }
  function entraHoverSpec(machine) {
    const isFound = Boolean(machine.EntraObjectId || (machine.EntraDeviceId && ["Verified", "WouldAdd", "Matched", "GroupNotFound", "MissingCloudIdentifier", "GroupNotConfigured"].includes(machine.Status)));
    const statusBadge = text(
      "span",
      isFound ? `Correlated (${machine.Status || "Matched"})` : `Not Found (${machine.Status || "Unresolved"})`,
      `badge ${isFound ? "good" : machine.Status === "Failed" ? "bad" : "attention"}`
    );
    const candidateHosts = [];
    for (const raw of [machine.ComputerName, machine.MdeDeviceName, machine.Fqdn, machine.MachineName]) {
      const clean = String(raw || "").trim();
      if (clean && !candidateHosts.includes(clean)) candidateHosts.push(clean);
      if (clean.includes(".")) {
        const short = clean.split(".")[0].trim();
        if (short && !candidateHosts.includes(short)) candidateHosts.push(short);
      }
    }
    const hostListText = candidateHosts.length ? candidateHosts.join(", ") : missing;
    let reason = machine.EntraDiagnostic || "";
    if (!reason) {
      if (isFound) {
        reason = machine.EntraCorrelationPath === "GuestConfigurationIntuneDeviceId" ?
          `Correlated via Azure Machine Configuration intuneDeviceId (${machine.GuestConfigEntraDeviceId || machine.EntraDeviceId || missing}) matching Entra ID deviceId.` :
          machine.EntraCorrelationPath === "MicrosoftSenseHostnameAndOS" ?
          `Correlated via MicrosoftSense synthetic Entra device matching hostname (${hostListText}) and OS (${machine.OS || missing}).` :
          `Correlated via MDE DeviceInfo.AadDeviceId (${machine.EntraDeviceId || missing}) matching Entra ID deviceId.`;
      } else if (machine.Status === "PendingMde" || !machine.MdeDeviceId) {
        reason = `Blocked at Step 1 (MDE Hunting): No onboarded MDE DeviceInfo record matched Resource ID '${machine.ArcResourceId || missing}'${machine.VirtualMachineId ? ` or VM ID '${machine.VirtualMachineId}'` : ""} within the 7-day hunting window. Entra ID lookup cannot run until the server is onboarded to MDE.`;
      } else if (machine.Status === "StaleEvidence") {
        reason = `Blocked at Step 1 (Stale MDE Telemetry): MDE DeviceInfo matched '${machine.MdeDeviceName || machine.MdeDeviceId}', but its last check-in (${time(machine.MdeLastSeen)}) is older than the configured freshness window (SYNC_FRESHNESS_HOURS).`;
      } else if (machine.Status === "NoEntraDevice") {
        reason = `1. MDE AadDeviceId check: MDE DeviceInfo for '${machine.MdeDeviceName || machine.MdeDeviceId}' reported an empty AadDeviceId. 2. Machine Configuration check: ${machine.GuestConfigEntraDeviceId ? `intuneDeviceId '${machine.GuestConfigEntraDeviceId}' did not match an Entra device` : "No entraiddeviceid / entraiddeviceidlinux Guest Configuration intuneDeviceId reported yet"}. 3. MicrosoftSense fallback check: Queried Entra ID (/v1.0/devices) for displayName in [${hostListText}] with operatingSystem='${machine.OS || missing}' and managementType='MicrosoftSense', and 0 Entra device objects matched.`;
      } else if (machine.Status === "EntraDeviceNotFound") {
        reason = `1. MDE AadDeviceId check: '${machine.EntraDeviceId || missing}' returned 0 objects in Entra ID. 2. Machine Configuration check: '${machine.GuestConfigEntraDeviceId || "Not reported"}' returned 0 objects in Entra ID. 3. MicrosoftSense fallback check: No MicrosoftSense Entra device matched displayName in [${hostListText}] with OS '${machine.OS || missing}'.`;
      } else if (machine.Status === "EntraDeviceDisabled") {
        reason = `Entra ID device object (${machine.EntraObjectId || machine.EntraDeviceId || missing}) was found, but accountEnabled is false in Microsoft Entra ID.`;
      } else if (machine.Status === "Ambiguous") {
        reason = `Multiple active MDE records or multiple MicrosoftSense Entra device objects matched [${hostListText}]. Synchronization failed closed to avoid ambiguity.`;
      } else if (machine.Status === "ArcNotConnected") {
        reason = `Machine status is '${displayFor(machine, columnById.get("ArcStatus"))}' (not connected/running); Entra correlation was skipped.`;
      } else if (machine.Status === "Failed") {
        reason = machine.Error || "Worker encountered an error while querying Microsoft Graph /v1.0/devices.";
      } else {
        reason = "No matching Microsoft Entra ID device object was found via MDE AadDeviceId, Machine Configuration intuneDeviceId, or MicrosoftSense hostname/OS fallback.";
      }
    }
    const devIdWrap = document.createElement("span");
    appendLink(devIdWrap, machine.EntraDeviceId || "Not available", deviceLink(machine, "entra"));
    const rows = [
      ["Correlation Status", statusBadge],
      [isFound ? "Correlation Details" : "Why Not Found", reason],
      ["Entra Device ID", devIdWrap],
      ["Entra Object ID", machine.EntraObjectId || "Not resolved"],
      ["Machine Config intuneDeviceId", machine.GuestConfigEntraDeviceId || "Not reported"],
      ["Correlation Method", correlationMethodFor(machine)],
      ["Hostnames Checked", hostListText],
      ["Expected OS", osNode(machine.OS)],
      ["MDE Device / Status", machine.MdeDeviceId ? `${machine.MdeDeviceName || machine.MdeDeviceId} (${machine.MdeOnboardingStatus || "Onboarded"})` : "No MDE match (PendingMde)"]
    ];
    return ["MICROSOFT ENTRA ID DEVICE CORRELATION", rows];
  }
  function groupHoverSpec(machine) {
    const hasFlags = Array.isArray(machine.GroupFlags) && machine.GroupFlags.length > 0;
    const statusBadge = text(
      "span",
      hasFlags ? `Flagged (${machine.GroupFlags.length} issue${machine.GroupFlags.length === 1 ? "" : "s"})` : (machine.Membership === "Present" ? `Compliant (${machine.GroupAvMode || "Passive"} group)` : (machine.Membership || "Not evaluated")),
      `badge ${hasFlags ? "bad" : machine.Membership === "Present" ? "good" : "attention"}`
    );
    const groupsWrap = document.createElement("span");
    if (Array.isArray(machine.MemberGroups) && machine.MemberGroups.length) {
      machine.MemberGroups.forEach((g, idx) => {
        if (idx > 0) groupsWrap.append(text("span", ", "));
        appendLink(groupsWrap, g.DisplayName || g.Id || missing, groupLinkById(g.Id));
      });
    } else {
      appendLink(groupsWrap, displayFor(machine, columnById.get("Membership")), machine.Membership === "Present" ? deviceLink(machine, "group") : "");
    }
    const rows = [
      ["Compliance Status", statusBadge],
      ["Entra ID Group(s)", groupsWrap],
      ["Expected Cloud Scope", machine.CloudGroupType ? `${machine.CloudGroupType} (${machine.CloudGroupOS || machine.OS || missing}) — ${machine.CloudIdentifier || missing}` : missing],
      ["Group Mode / Global Default", `${machine.GroupAvMode || missing} (Default: ${machine.DefaultGroupMode || "Passive"})`],
      ["MDE Antivirus Mode", `${machine.MdeAntivirusMode || missing} (reported: ${time(machine.MdeAntivirusTimestamp)})`],
      ["Membership Verified", time(machine.MembershipVerifiedAt)]
    ];
    if (hasFlags) {
      rows.splice(1, 0, ["Flag Details", groupFlagsNode(machine)]);
    }
    return ["ENTRA ID GROUP & AV MODE COMPLIANCE", rows];
  }
  function visibleColumns() {
    return layout.order.filter(id => layout.visible.includes(id)).map(id => columnById.get(id));
  }
  function moveColumn(id, targetId) {
    const from = layout.order.indexOf(id);
    const to = layout.order.indexOf(targetId);
    if (from < 0 || to < 0 || from === to) return;
    layout.order.splice(from, 1);
    layout.order.splice(to, 0, id);
    saveLayout();
    renderColumnOptions();
    byId("column-options").querySelector(`[data-column="${id}"] input`)?.focus();
    renderHeaders();
    render();
  }
  function dragHandle(id) {
    const handle = text("span", "", "drag-handle");
    handle.draggable = true;
    handle.title = `Reorder ${columnById.get(id).label}`;
    handle.setAttribute("aria-hidden", "true");
    handle.addEventListener("dragstart", event => {
      draggedColumn = id;
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", id);
    });
    handle.addEventListener("dragend", () => { draggedColumn = ""; });
    return handle;
  }
  function dropTarget(element, id) {
    element.addEventListener("dragover", event => {
      if (draggedColumn) { event.preventDefault(); event.dataTransfer.dropEffect = "move"; }
    });
    element.addEventListener("drop", event => {
      event.preventDefault();
      const source = draggedColumn;
      draggedColumn = "";
      if (columnById.has(source)) moveColumn(source, id);
    });
  }
  function renderColumnOptions() {
    const container = byId("column-options");
    container.replaceChildren();
    layout.order.forEach((id, index) => {
      const column = columnById.get(id);
      const option = text("div", "", "column-option");
      option.dataset.column = id;
      dropTarget(option, id);
      const label = text("label", "", "column-check");
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = layout.visible.includes(id);
      checkbox.disabled = checkbox.checked && layout.visible.length === 1;
      checkbox.addEventListener("change", () => {
        layout.visible = checkbox.checked ? [...layout.visible, id] : layout.visible.filter(key => key !== id);
        saveLayout();
        renderColumnOptions();
        renderHeaders();
        render();
      });
      label.append(checkbox, text("span", column.label + (filters[id] ? " (filtered)" : "")));
      option.append(dragHandle(id), label);
      for (const [direction, offset] of [["Earlier", -1], ["Later", 1]]) {
        const button = text("button", direction, "secondary move-column");
        button.type = "button";
        button.setAttribute("aria-label", `Move ${column.label} ${direction.toLowerCase()}`);
        button.disabled = index + offset < 0 || index + offset >= layout.order.length;
        button.addEventListener("click", () => {
          const target = layout.order[index + offset];
          moveColumn(id, target);
          byId("column-options").querySelector(`[data-column="${id}"] .move-column`)?.focus();
        });
        option.append(button);
      }
      container.append(option);
    });
  }
  function updateSortHeaders() {
    for (const header of byId("machine-head").querySelectorAll("th[data-column]")) {
      const active = header.dataset.column === layout.sort.id;
      header.setAttribute("aria-sort", active ? (layout.sort.direction === "asc" ? "ascending" : "descending") : "none");
      const column = columnById.get(header.dataset.column);
      header.querySelector(".sort-column").textContent = `${column.label}${active ? (layout.sort.direction === "asc" ? " [asc]" : " [desc]") : ""}`;
    }
  }
  function renderHeaders() {
    const heading = document.createElement("tr");
    const filterRow = text("tr", "", "column-filters");
    for (const column of visibleColumns()) {
      const header = document.createElement("th");
      header.scope = "col";
      header.dataset.column = column.id;
      const sort = text("button", column.label, "sort-column");
      sort.type = "button";
      sort.setAttribute("aria-label", `Sort by ${column.label}`);
      sort.addEventListener("click", () => {
        layout.sort = { id: column.id, direction: layout.sort.id === column.id && layout.sort.direction === "asc" ? "desc" : "asc" };
        saveLayout();
        updateSortHeaders();
        render();
      });
      header.append(dragHandle(column.id), sort);
      dropTarget(header, column.id);
      heading.append(header);
      const filterCell = document.createElement("td");
      const input = document.createElement("input");
      input.type = "search";
      input.placeholder = `Filter ${column.label}`;
      input.setAttribute("aria-label", `Filter ${column.label}`);
      input.dataset.column = column.id;
      input.value = filters[column.id] || "";
      input.addEventListener("input", () => {
        filters[column.id] = input.value;
        render();
      });
      filterCell.append(input);
      filterRow.append(filterCell);
    }
    byId("machine-head").replaceChildren(heading, filterRow);
    updateSortHeaders();
  }
  function clearFilters() {
    cardFilter = null;
    for (const key of Object.keys(filters)) delete filters[key];
    for (const id of ["search", "status", "os", "management-group", "subscription", "membership"]) byId(id).value = "";
    renderColumnOptions();
    renderHeaders();
    render();
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
      renderSummary();
      render();
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
  function applySnapshot(items, health, logsPage, timestampIso, isCached = false) {
    machines = Array.isArray(items) ? items : [];
    if (health && typeof health === "object") renderFunctionHealth(health);
    if (logsPage && typeof logsPage === "object") {
      logsCursor = typeof logsPage.Cursor === "string" ? logsPage.Cursor : "";
      logsCursors = new Set(logsCursor ? [logsCursor] : []);
      const logItems = Array.isArray(logsPage.Items) ? logsPage.Items : [];
      logsCount = logItems.length;
      appendFunctionLogs(logItems, true);
      byId("more-logs").hidden = !logsCursor;
      byId("function-logs-error").hidden = true;
      byId("function-logs-status").textContent = logsCount ? `${logsCount} log entries loaded.` : "No logs recorded yet.";
    }
    byId("updated").textContent = `${isCached ? "Cached snapshot" : "Report refreshed"}: ${time(timestampIso || new Date().toISOString())}`;
    updateOptions("status", machines.map(m => m.Status), "All statuses");
    updateOptions("os", machines.map(m => m.OS), "All operating systems");
    updateOptions("management-group", machines.map(m => m.ManagementGroup), "All management groups");
    updateOptions("subscription", machines.map(m => m.SubscriptionId), "All subscriptions");
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
      applySnapshot(cached.items, cached.health, cached.logsPage, cached.timestamp, true);
      return Number(cached.savedAt) || 0;
    } catch {
      return 0;
    }
  }
  function saveCachedSnapshot(items, health, logsPage, timestamp) {
    try {
      localStorage.removeItem(dataCacheKey);
      const payload = JSON.stringify({ items, health, logsPage, timestamp, savedAt: Date.now() });
      sessionStorage.setItem(dataCacheKey, payload);
    } catch {}
  }
  function updateOptions(id, values, label) {
    const select = byId(id);
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
  function getFilteredMachines() {
    const search = byId("search").value.toLowerCase();
    const activeFilters = Object.entries(filters).filter(([, value]) => value.trim());
    const filtered = machines.filter(machine =>
      (!cardFilter || cardFilter.matches(machine)) &&
      (!search || columns.some(column => searchFor(machine, column).toLowerCase().includes(search))) &&
      activeFilters.every(([id, value]) => searchFor(machine, columnById.get(id)).toLowerCase().includes(value.trim().toLowerCase())) &&
      (!byId("status").value || machine.Status === byId("status").value) &&
      (!byId("os").value || machine.OS === byId("os").value) &&
      (!byId("management-group").value || machine.ManagementGroup === byId("management-group").value) &&
      (!byId("subscription").value || machine.SubscriptionId === byId("subscription").value) &&
      (!byId("membership").value || machine.Membership === byId("membership").value)
    );
    const sortColumn = columnById.get(layout.sort.id);
    filtered.sort((a, b) => {
      const rawLeft = valueFor(a, sortColumn);
      const rawRight = valueFor(b, sortColumn);
      const left = sortColumn.type === "date" && rawLeft === "N/A" ? "" : rawLeft;
      const right = sortColumn.type === "date" && rawRight === "N/A" ? "" : rawRight;
      if (!left || !right) return left ? -1 : right ? 1 : collator.compare(a.Key || "", b.Key || "");
      const comparison = sortColumn.type === "date" ? Date.parse(left) - Date.parse(right) : collator.compare(left, right);
      return (layout.sort.direction === "asc" ? comparison : -comparison) || collator.compare(a.Key || "", b.Key || "");
    });
    return { filtered, activeFilters };
  }
  function csvCell(value) {
    let textValue = String(value ?? "").replace(/\r?\n/g, " ");
    if (/^[\t\r ]*[=+\-@]/.test(textValue)) {
      textValue = `'${textValue}`;
    }
    if (/[",\r\n]/.test(textValue)) {
      return `"${textValue.replace(/"/g, '""')}"`;
    }
    return textValue;
  }
  function exportInventoryCsv() {
    const { filtered } = getFilteredMachines();
    const orderedColumns = [
      ...visibleColumns(),
      ...layout.order.filter(id => !layout.visible.includes(id)).map(id => columnById.get(id)).filter(Boolean)
    ];
    const headers = [];
    for (const column of orderedColumns) {
      headers.push(column.label);
      if (column.id === "MachineName") headers.push("Resource Type");
    }
    const rows = [headers.map(csvCell).join(",")];
    for (const machine of filtered) {
      const rowValues = [];
      for (const column of orderedColumns) {
        const raw = valueFor(machine, column);
        const val = raw === "N/A" ? "N/A" : column.type === "date" ? (raw ? time(raw) : "") : (raw || (column.id === "GroupFlags" || column.id === "Membership" ? displayFor(machine, column) : ""));
        rowValues.push(csvCell(val));
        if (column.id === "MachineName") {
          rowValues.push(csvCell(machineKindLabel(machine)));
        }
      }
      rows.push(rowValues.join(","));
    }
    const csvContent = "\uFEFF" + rows.join("\r\n");
    const blob = new Blob([csvContent], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-");
    link.href = url;
    link.download = `device-inventory-${stamp}.csv`;
    document.body.append(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function render() {
    const { filtered, activeFilters } = getFilteredMachines();
    const hiddenFilters = activeFilters.filter(([id]) => !layout.visible.includes(id)).length;
    byId("count").textContent = `${filtered.length} of ${machines.length} machines. ${cardFilter ? `Card filter: ${cardFilter.label}. ` : ""}${activeFilters.length} column filters${hiddenFilters ? ` (${hiddenFilters} on hidden columns)` : ""}. Sorted by ${columnById.get(layout.sort.id).label} ${layout.sort.direction}.`;
    updateCardSelection();
    hideHoverPopover();
    const body = byId("machines");
    body.replaceChildren();
    const visible = visibleColumns();
    const historyColumn = visible.find(c => c.id === "MachineName") ||
      visible.find(c => c.id === "MdeDeviceName") || visible[0];
    for (const machine of filtered) {
      const row = document.createElement("tr");
      row.dataset.key = machine.Key;
      row.classList.toggle("is-selected", machine.Key === selectedKey);
      for (const column of visible) {
        const cell = document.createElement("td");
        cell.dataset.column = column.id;
        if (column.id === "Membership") {
          cell.append(groupMembershipNode(machine));
          bindHoverPopover(cell, () => groupHoverSpec(machine));
        }
        else if (column.id === "MdeAntivirusMode") {
          cell.append(avModeCellNode(machine));
          bindHoverPopover(cell, () => groupHoverSpec(machine));
        }
        else if (column.id === "GroupFlags") {
          cell.append(groupFlagsNode(machine));
        }
        else if (column.id === "MachineName") {
          cell.append(machineNameNode(machine));
        }
        else if (column.link) appendLink(cell, displayFor(machine, column), deviceLink(machine, column.link));
        else if (column.id === "OS") cell.append(osNode(displayFor(machine, column)));
        else if (column.id === "DefenderExtensionStatus") cell.append(defenderStatusNode(machine));
        else if (column.tags) {
          const tags = column.value(machine);
          cell.append(tagPillsNode(tags, displayFor(machine, column)));
        }
        else if (column.id === "Status") cell.append(text("span", displayFor(machine, column), `badge ${machine.Status === "Failed" ? "bad" : machine.Status === "Verified" ? "good" : "attention"}`));
        else if (["ArcStatus", "MdeOnboardingStatus", "MdeSensorHealth"].includes(column.id)) {
          const value = displayFor(machine, column);
          const tone = ["Present", "Connected", "VM running", "Onboarded", "Active"].includes(value) ? "good" :
            ["Absent", "Disconnected", "VM stopped", "VM deallocated", "Stopped", "Deallocated", "Inactive"].includes(value) ? "attention" : "";
          cell.append(text("span", value, `status-value ${tone}`));
        }
        else cell.textContent = displayFor(machine, column);
        if (column.id === "InventoryStatus" && machine.InventoryErrors?.length) {
          cell.append(text("small", joined(machine.InventoryErrors), "bad"));
        }
        if (column.id === "MachineName") bindHoverPopover(cell, () => arcHoverSpec(machine));
        else if (column.id === "MdeDeviceName" || column.id === "MdeDeviceId") bindHoverPopover(cell, () => mdeHoverSpec(machine));
        else if (column.id === "EntraDeviceId" || column.id === "EntraObjectId" || column.id === "EntraCorrelationPath") bindHoverPopover(cell, () => entraHoverSpec(machine));
        if (column === historyColumn) {
          cell.classList.add("device-cell");
          const button = text("button", "", "history-action secondary");
          button.type = "button";
          button.title = `View history for ${machine.MachineName}`;
          button.setAttribute("aria-label", `View history for ${machine.MachineName}`);
          button.append(text("span", "", "history-icon"), text("span", `View history for ${machine.MachineName}`, "sr-only"));
          button.addEventListener("click", () => selectMachine(machine, button));
          cell.append(button);
        }
        row.append(cell);
      }
      body.append(row);
    }
    if (!filtered.length) {
      const row = document.createElement("tr");
      const cell = text("td", machines.length ? "No machines match these filters." : "No machine results yet. Check inventory health above.");
      cell.colSpan = visible.length;
      row.append(cell);
      body.append(row);
    }
  }
  function statusCardHoverSpec(filter, count) {
    const summaryDescriptions = {
      "all": [
        "Total Azure Arc-enabled servers discovered across your configured Management Group, Subscription, and Resource Group scope.",
        "Any persisted state row in the machines table (click to clear all active filters)."
      ],
      "verified": [
        "Devices with a valid Arc-to-MDE-to-Entra correlation whose direct membership in the target Entra ID security group has been confirmed in Microsoft Graph.",
        "Status == 'Verified' and Membership == 'Present'."
      ],
      "would-add": [
        "Eligible, correlated devices that are not yet members of the target Entra ID security group while the Function App is running in Audit mode.",
        "Status == 'WouldAdd' (Membership == 'Absent', Mode == 'Audit')."
      ],
      "no-entra": [
        "Servers onboarded to MDE that either do not report an Entra device ID (AadDeviceId) or whose AadDeviceId was not found in Microsoft Entra ID.",
        "Status in ('NoEntraDevice', 'EntraDeviceNotFound')."
      ],
      "attention": [
        "Machines blocked from group synchronization or flagged for group/AV mode mismatches, multiple group memberships, or wrong AWS Account / GCP Project / Subscription group.",
        "Status not in ('Verified', 'WouldAdd', 'Failed') or GroupFlags is non-empty."
      ],
      "group-flags": [
        "Devices with group compliance flags: Active/Passive MDE antivirus mode mismatch ('Should be Active'), membership in multiple Cloud × OS groups, or membership in a group whose AWS Account ID, GCP Project, or Azure Subscription does not match.",
        "GroupFlags.length > 0."
      ],
      "failed": [
        "Machines whose most recent synchronization run encountered an API, permission, or validation error and was returned for retry.",
        "Status == 'Failed'."
      ],
      "not-in-group": [
        "Correlated Entra devices where Microsoft Graph confirmed the device is currently not a direct member of the target security group.",
        "Membership == 'Absent' (excludes devices with unknown membership or no Entra identity)."
      ],
      "membership-unknown": [
        "Machines where Entra group membership could not be checked because correlation did not reach a valid, enabled Entra device or a run failed.",
        "Membership is empty or 'Unknown'."
      ]
    };
    const breakdownDescriptions = {
      "ArcStatus": {
        "connected": "The Azure Arc Connected Machine agent is actively connected and reporting to Azure Resource Manager.",
        "vm running": "The native Azure virtual machine powerState.displayStatus is 'VM running'.",
        "disconnected": "The Azure Arc agent has not recently sent a heartbeat to Azure; group changes are paused without removing existing membership.",
        "missing": "The machine resource was deleted from Azure; historical state is retained without removing existing group membership.",
        "default": "Current Azure Arc agent status or native Azure VM powerState.displayStatus."
      },
      "MdeOnboardingStatus": {
        "onboarded": "The server is actively onboarded to Microsoft Defender for Endpoint (DeviceInfo.OnboardingStatus == 'Onboarded').",
        "canbeonboarded": "The device was discovered by Defender but is not yet onboarded to MDE.",
        "not reported": "No current MDE DeviceInfo onboarding status has been collected for this Arc resource.",
        "default": "Defender for Endpoint onboarding state reported in the DeviceInfo hunting table."
      },
      "MdeAntivirusMode": {
        "active": "Microsoft Defender Antivirus is running as the primary active antivirus on the server (scid-2010 code 0).",
        "passive": "Microsoft Defender Antivirus is running in passive mode alongside another antivirus product (scid-2010 code 1).",
        "disabled": "Microsoft Defender Antivirus is disabled on the server (scid-2010 code 2).",
        "other": "Microsoft Defender Antivirus reported mode code 3 (Other) in DeviceTvmSecureConfigurationAssessment.",
        "edrblocked": "Endpoint Detection and Response (EDR) in block mode is active (scid-2010 code 4).",
        "passiveaudit": "Microsoft Defender Antivirus is running in Passive Audit mode (scid-2010 code 5).",
        "not reported": "No scid-2010 antivirus configuration assessment was reported in Defender XDR within the 7-day lookback window.",
        "default": "Antivirus mode extracted from DeviceTvmSecureConfigurationAssessment (ConfigurationId == 'scid-2010')."
      },
      "OS": {
        "windows": "Windows Server machines routed to the configured Windows Entra ID security group (SYNC_WINDOWS_GROUP_ID / SYNC_GROUP_ID).",
        "linux": "Linux servers routed to the configured Linux Entra ID security group (SYNC_LINUX_GROUP_ID / SYNC_GROUP_ID).",
        "default": "Operating system type reported by the Azure Arc machine resource (properties.osType)."
      },
      "MdeSensorHealth": {
        "active": "The Defender for Endpoint EDR sensor on the device is healthy and actively communicating (SensorHealthState == 'Active').",
        "inactive": "The Defender for Endpoint sensor has stopped communicating or is unhealthy (SensorHealthState == 'Inactive').",
        "not reported": "No MDE sensor health state was reported for this machine.",
        "default": "EDR sensor health state from the latest DeviceInfo row in Defender XDR Advanced Hunting."
      }
    };
    let meaning = "Filters the device inventory table to matching machines.";
    let criteria = filter.label;
    if (summaryDescriptions[filter.key]) {
      [meaning, criteria] = summaryDescriptions[filter.key];
    } else if (filter.field && breakdownDescriptions[filter.field]) {
      const groupMap = breakdownDescriptions[filter.field];
      meaning = groupMap[filter.bucket] || groupMap.default;
      criteria = `${filter.field} == '${filter.valueLabel === "Not reported" ? "" : filter.valueLabel}'`;
    }
    return ["STATUS CARD EXPLANATION", [
      ["Metric", filter.label],
      ["Matching devices", `${count} of ${machines.length} total machines`],
      ["What it means", meaning],
      ["Filter rule", criteria],
      ["Action", filter.key === "all" ? "Click to clear all active filters." : "Click to filter table; click again to clear."]
    ]];
  }
  function renderSummary() {
    const stats = [
      ["all", "Arc machines", () => true],
      ["verified", "Verified members", m => m.Status === "Verified" && m.Membership === "Present"],
      ["would-add", "Would add", m => m.Status === "WouldAdd"],
      ["group-flags", "Group / AV flags", m => Array.isArray(m.GroupFlags) && m.GroupFlags.length > 0],
      ["no-entra", "No Entra device", m => ["NoEntraDevice", "EntraDeviceNotFound"].includes(m.Status)],
      ["attention", "Needs attention", m => !["Verified", "WouldAdd", "Failed"].includes(m.Status) || (Array.isArray(m.GroupFlags) && m.GroupFlags.length > 0)],
      ["failed", "Failed", m => m.Status === "Failed"],
      ["not-in-group", "Not in group", m => m.Membership === "Absent"],
      ["membership-unknown", "Membership unknown", m => !m.Membership || m.Membership === "Unknown"]
    ];
    byId("summary").replaceChildren(...stats.map(([key, label, matches]) => makeCard({
      key, label, matches
    })));
    const groups = [
      ["ArcStatus", "Machine Status", ["Connected", "VM running", "Disconnected"]],
      ["MdeOnboardingStatus", "MDE onboarded status", ["Onboarded"]],
      ["MdeAntivirusMode", "MDE antivirus mode", ["Active", "Passive", "Disabled", "Other", "EDRBlocked", "PassiveAudit"]],
      ["OS", "Operating System", ["Windows", "Linux"]],
      ["MdeSensorHealth", "MDE sensor health", ["Active", "Inactive"]]
    ];
    byId("status-summary").replaceChildren(...groups.map(([field, title, baseline]) => {
      const group = text("section", "", "status-group");
      group.setAttribute("aria-label", title);
      group.append(text("h3", title));
      const grid = text("div", "", "cards");
      const buckets = new Map(baseline.map(value => [value.toLowerCase(), value]));
      const statusCol = columnById.get("ArcStatus");
      for (const machine of machines) {
        const value = field === "ArcStatus" ? valueFor(machine, statusCol).trim() : joined(machine[field]).trim();
        if (!buckets.has(value.toLowerCase())) buckets.set(value.toLowerCase(), value || "Not reported");
      }
      if (cardFilter?.field === field && !buckets.has(cardFilter.bucket)) {
        buckets.set(cardFilter.bucket, cardFilter.valueLabel);
      }
      for (const [bucket, valueLabel] of buckets) {
        grid.append(makeCard({
          key: `${field}:${bucket}`, label: `${title}: ${valueLabel}`, valueLabel, field, bucket,
          matches: machine => (field === "ArcStatus" ? valueFor(machine, statusCol).trim().toLowerCase() : joined(machine[field]).trim().toLowerCase()) === bucket
        }));
      }
      group.append(grid);
      return group;
    }));
    updateCardSelection();
  }
  function makeCard(filter) {
    const count = machines.filter(filter.matches).length;
    const card = text("button", "", "card");
    card.type = "button";
    card.dataset.card = filter.key;
    card.setAttribute("aria-label", `${filter.label}: ${count} devices`);
    card.append(text("strong", count), text("span", filter.valueLabel || filter.label));
    bindHoverPopover(card, () => statusCardHoverSpec(filter, machines.filter(filter.matches).length));
    card.addEventListener("click", () => {
      if (filter.key === "all") { clearFilters(); return; }
      cardFilter = cardFilter?.key === filter.key ? null : filter;
      render();
    });
    return card;
  }
  function updateCardSelection() {
    const hasOtherFilters = Object.values(filters).some(value => value.trim()) ||
      ["search", "status", "os", "management-group", "subscription", "membership"].some(id => byId(id).value);
    for (const card of document.querySelectorAll("button[data-card]")) {
      const selected = card.dataset.card === "all" ? !cardFilter && !hasOtherFilters : card.dataset.card === cardFilter?.key;
      card.setAttribute("aria-pressed", String(selected));
      card.classList.toggle("is-active", selected);
    }
    for (const tab of document.querySelectorAll("button[data-card-target]")) {
      const selected = tab.dataset.cardTarget === "all" ? !cardFilter : tab.dataset.cardTarget === cardFilter?.key;
      tab.setAttribute("aria-pressed", String(selected));
    }
  }
  function selectMachine(machine, trigger) {
    selectedKey = machine.Key;
    historyTrigger = trigger;
    historyCount = 0;
    historyCursors = new Set();
    historyCursor = "";
    historyGeneration++;
    historyBusy = false;
    byId("detail-title").textContent = machine.MachineName;
    const summary = byId("detail-summary");
    summary.replaceChildren();
    const correlated = Boolean(machine.MdeDeviceId && machine.EntraDeviceId && ["Verified", "WouldAdd", "Matched"].includes(machine.Status));
    const summaryItems = [
      ["Correlated", text("span", `${correlated ? "Yes" : "No"} (${machine.Status || missing})`, `badge ${machine.Status === "Failed" ? "bad" : correlated ? "good" : "attention"}`)],
      ["Correlation method", text("span", correlationMethodFor(machine))],
      ["Entra ID Group", groupMembershipNode(machine)],
      ["Group & AV flags", groupFlagsNode(machine)],
      ["MDE onboarded status", (() => {
        const value = displayFor(machine, columnById.get("MdeOnboardingStatus"));
        return text("span", value, `status-value ${value === "Onboarded" ? "good" : ""}`);
      })()],
      ["MDE mode", text("span", displayFor(machine, columnById.get("MdeAntivirusMode")))],
      ["Defender extension", defenderStatusNode(machine)],
      ["Machine Status", (() => {
        const value = displayFor(machine, columnById.get("ArcStatus"));
        return text("span", value, `status-value ${["Connected", "VM running"].includes(value) ? "good" : ["Disconnected", "VM stopped", "VM deallocated"].includes(value) ? "attention" : ""}`);
      })()],
      ["Arc Connected Machine last state time", text("span", displayFor(machine, columnById.get("ArcLastReportedAt")))],
      ["MDE last check in time", text("span", time(machine.MdeLastSeen))],
      ["Arc added", text("span", displayFor(machine, columnById.get("ArcAddedAt")))],
      ["Azure Tags", tagPillsNode(azureTagValues(machine.AzureTags), displayFor(machine, columnById.get("AzureTags")))],
      ["MDE Device Tags", tagPillsNode(machine.MdeDeviceTags, displayFor(machine, columnById.get("MdeDeviceTags")))]
    ];
    for (const [label, node] of summaryItems) {
      const item = text("div", "", `summary-chip${label.endsWith("Tags") ? " summary-chip-wide" : ""}`);
      const dd = document.createElement("dd");
      dd.append(node);
      item.append(text("dt", label), dd);
      summary.append(item);
    }
    const fields = [
      ["Resource ID", machine.ArcResourceId], ["Machine Status", displayFor(machine, columnById.get("ArcStatus"))],
      ["Arc Connected Machine last state time", displayFor(machine, columnById.get("ArcLastReportedAt"))], ["Arc added", displayFor(machine, columnById.get("ArcAddedAt"))],
      ["MDE device ID", machine.MdeDeviceId], ["MDE last check in time", time(machine.MdeLastSeen)],
      ["Entra device ID", machine.EntraDeviceId], ["Entra object ID", machine.EntraObjectId],
      ["Correlation method", correlationMethodFor(machine)],
      ["Machine Config intuneDeviceId", machine.GuestConfigEntraDeviceId || "Not reported"],
      ["Target group ID", machine.GroupId], ["Mode / status", `${machine.Mode} / ${machine.Status}`],
      ["Observed Entra membership", machine.Membership], ["Membership verified", time(machine.MembershipVerifiedAt)],
      ["Snapshot checked", time(machine.LastChecked)], ["First discovered", time(machine.FirstSeen)], ["Latest error", machine.Error || "None"]
    ];
    for (const column of columns.filter(c => ["ComputerName", "Fqdn", "CloudProvider", "MdeSensorHealth", "MdeOnboardingStatus",
      "MdeAntivirusMode", "MdeAntivirusTimestamp", "MdeAntivirusStatus", "VirtualMachineId", "DefenderExtensionStatus", "ArcExtensions", "IPAddresses",
      "SubscriptionName", "InventoryStatus", "InventoryErrors", "MdeDeviceTags", "MdeDeviceGroup", "AzureTags"].includes(c.id))) {
      fields.push([column.label, displayFor(machine, column)]);
    }
    for (const [field, label] of [["MdeManualTags", "MDE manual tags"], ["MdeDynamicTags", "MDE dynamic tags"], ["MdeRegistryTags", "MDE registry tags"]]) {
      fields.push([label, machine[field] == null ? missing : joined(machine[field]) || "No tags"]);
    }
    const detail = byId("identity");
    detail.replaceChildren();
    for (const [label, value] of fields) detail.append(text("dt", label), text("dd", value || "Not available"));
    detail.append(text("dt", "Cloud group scope"), text("dd", machine.CloudGroupType ? `${machine.CloudGroupType} (${machine.CloudGroupOS || machine.OS || missing}) — ${machine.CloudIdentifier || missing}` : missing));
    detail.append(text("dt", "Target Entra ID group"), document.createElement("dd"));
    appendLink(detail.lastChild, displayFor(machine, columnById.get("Membership")), deviceLink(machine, "group"));
    for (const [kind, label] of [["arc", "Azure portal"], ["mde", "Defender portal"], ["entra", "Entra portal"]]) {
      detail.append(text("dt", label), document.createElement("dd"));
      appendLink(
        detail.lastChild,
        kind === "arc" ? "Open Azure resource" : kind === "mde" ? (machine.MdeDeviceId ? "Open MDE device" : missing) : ((machine.EntraObjectId || machine.EntraDeviceId) ? "Open Entra device" : missing),
        deviceLink(machine, kind)
      );
    }
    byId("history").replaceChildren();
    byId("more").hidden = true;
    byId("detail").querySelector(".identity-section").open = false;
    if (!byId("detail").open) byId("detail").show();
    for (const row of byId("machines").rows) row.classList.toggle("is-selected", row.dataset.key === selectedKey);
    void loadHistory();
  }
  async function loadHistory() {
    if (historyBusy || !selectedKey) return;
    historyBusy = true;
    const generation = historyGeneration;
    byId("more").disabled = true;
    byId("history-error").hidden = true;
    byId("history-status").textContent = "Loading history...";
    byId("more").textContent = "Load earlier history";
    try {
      const page = await get(`history?key=${encodeURIComponent(selectedKey)}${historyCursor ? `&cursor=${encodeURIComponent(historyCursor)}` : ""}`);
      if (generation !== historyGeneration || !byId("detail").open) return;
      if (!Array.isArray(page.Items) || typeof page.Cursor !== "string") throw new Error("Invalid history response.");
      if (page.Cursor && historyCursors.has(page.Cursor)) throw new Error("History pagination did not advance.");
      for (const item of page.Items) {
        const entry = document.createElement("li");
        entry.append(text("strong", `${time(item.Timestamp)} - ${item.Action}`));
        if (item.TriggerReason) entry.append(text("p", `Trigger: ${item.TriggerReason}`, "muted"));
        if (item.LogMessage) entry.append(text("p", item.LogMessage));
        if (item.State) entry.append(text("p", `${item.State.Status}; Entra membership: ${item.State.Membership}; mode: ${item.State.Mode}`),
          text("p", `Entra object: ${item.State.EntraObjectId || "None"}`));
        const group = item.State || item;
        if (group.GroupId) {
          const target = text("p", "Target Entra ID group: ");
          appendLink(target, group.GroupName || group.GroupId, deviceLink(group, "group"));
          entry.append(target);
        }
        if (item.State?.Error) entry.append(text("p", item.State.Error, "bad"));
        if (item.State?.InventoryErrors?.length) entry.append(text("p", joined(item.State.InventoryErrors), "bad"));
        if (item.State) {
          const snapshot = document.createElement("details");
          snapshot.append(text("summary", "Inventory metadata"));
          const values = document.createElement("dl");
          for (const id of ["MdeDeviceGroup", "MdeDeviceTags", "AzureTags"]) {
            const column = columnById.get(id);
            values.append(text("dt", column.label), text("dd", displayFor(item.State, column)));
          }
          for (const [field, label] of [["MdeManualTags", "Manual tags"], ["MdeDynamicTags", "Dynamic tags"], ["MdeRegistryTags", "Registry tags"]]) {
            values.append(text("dt", label), text("dd", item.State[field] == null ? missing : joined(item.State[field]) || "No tags"));
          }
          snapshot.append(values);
          entry.append(snapshot);
        }
        const runOutput = item.ScriptOutput || item.State?.ScriptOutput || "";
        if (runOutput) {
          const runLogDetails = document.createElement("details");
          runLogDetails.className = "script-output-details";
          const summary = document.createElement("summary");
          summary.append(text("span", "View run PowerShell script output & query results"));
          const expandBtn = text("button", "Expand window", "secondary script-expand-btn");
          expandBtn.type = "button";
          expandBtn.title = "Open full PowerShell script output and query results in an expanded window";
          expandBtn.addEventListener("click", event => {
            event.preventDefault();
            event.stopPropagation();
            openScriptOutputModal({
              FunctionName: item.FunctionName || "Machine",
              Status: item.State?.Status || item.Action || "Completed",
              Timestamp: item.Timestamp,
              TriggerReason: item.TriggerReason || item.State?.Source || "Machine sync",
              RunId: item.RunId || item.State?.RunId || "",
              ScriptOutput: runOutput
            });
          });
          summary.append(expandBtn);
          runLogDetails.append(summary);
          const pre = document.createElement("pre");
          pre.className = "script-inline-pre";
          pre.append(text("code", runOutput));
          runLogDetails.append(pre);
          entry.append(runLogDetails);
        }
        entry.append(text("small", `Run: ${item.RunId || item.State?.RunId || "Not available"}`));
        byId("history").append(entry);
      }
      historyCursor = page.Cursor;
      if (historyCursor) historyCursors.add(historyCursor);
      historyCount += page.Items.length;
      byId("more").hidden = !historyCursor;
      byId("history-status").textContent = historyCount ? `${historyCount} historical events loaded.` : "No history recorded yet.";
    } catch (error) {
      if (generation !== historyGeneration || !byId("detail").open) return;
      byId("history-error").textContent = error.message;
      byId("history-error").hidden = false;
      byId("more").hidden = false;
      byId("more").textContent = "Retry history";
      byId("history-status").textContent = "History could not be loaded.";
    } finally {
      if (generation === historyGeneration) {
        historyBusy = false;
        byId("more").disabled = false;
      }
    }
  }
  function portalPrefix(health) {
    const tenant = health?.PortalTenant || health?.Parameters?.SYNC_TENANT_ID || "";
    return tenant ? `https://portal.azure.com/#@${tenant}/resource` : "https://portal.azure.com/#resource";
  }
  function functionPortalLink(health) {
    if (health?.FunctionAppResourceId && String(health.FunctionAppResourceId).includes("/resourceGroups/")) {
      return `${portalPrefix(health)}${health.FunctionAppResourceId.split("/").map(encodeURIComponent).join("/")}/appServices`;
    }
    return "https://portal.azure.com/#browse/Microsoft.Web%2Fsites/kind/functionapp";
  }
  function resolveAppInsightsInfo(health) {
    let resourceId = health?.AppInsightsResourceId || "";
    if ((!resourceId || !resourceId.includes("/resourceGroups/")) && health?.FunctionAppResourceId) {
      const m = String(health.FunctionAppResourceId).match(/^(\/subscriptions\/[^/]+\/resourceGroups\/[^/]+)\/providers\/Microsoft\.Web\/sites\/(.+?)-(?:worker|report)-[a-z0-9]+$/i);
      if (m) resourceId = `${m[1]}/providers/microsoft.insights/components/${m[2]}-insights`;
    }
    if (resourceId) {
      resourceId = resourceId.replace(/\/providers\/Microsoft\.Insights\/components\//i, "/providers/microsoft.insights/components/");
    }
    const name = health?.AppInsightsName || (resourceId ? resourceId.split("/").pop() : "");
    const searchUrl = (resourceId && resourceId.includes("/resourceGroups/")) ?
      `${portalPrefix(health)}${resourceId.split("/").map(encodeURIComponent).join("/")}/searchV1` :
      "https://portal.azure.com/#browse/microsoft.insights%2Fcomponents";
    return { resourceId, name, searchUrl };
  }
  function renderFunctionHealth(health) {
    byId("health").textContent = health.LastSuccessfulInventory ?
      `Last complete inventory: ${time(health.LastSuccessfulInventory)} (${health.MachinesQueued ?? 0} queued; processing may still be in progress)` :
      "No successful inventory recorded. Check deployment, permissions, and worker logs.";
    const portalUrl = functionPortalLink(health);
    const portalAnchor = byId("function-portal-link");
    portalAnchor.href = portalUrl;
    portalAnchor.textContent = health.FunctionAppName ? `Open ${health.FunctionAppName} in Azure portal` : "Open Function App in Azure portal";
    const aiInfo = resolveAppInsightsInfo(health);
    const aiAnchor = byId("appinsights-search-link");
    if (aiAnchor) {
      aiAnchor.href = aiInfo.searchUrl;
      aiAnchor.textContent = aiInfo.name ? `Open ${aiInfo.name} Search` : "Open App Insights Transaction Search";
    }
    const statusValue = health.FunctionAppStatus || (health.LastSuccessfulInventory ? "Running" : "Idle");
    const healthValue = health.Health || (health.LastSuccessfulInventory ? "Healthy" : "Unknown");
    const lastRunTime = health.LastRunTime || health.LastSuccessfulInventory;
    const lastReason = health.LastRunReason || (health.LastSuccessfulInventory ? "Scheduled timer (NCRONTAB schedule)" : "No function runs recorded yet");
    const lastFunction = health.LastRunFunction || (health.LastSuccessfulInventory ? "Inventory" : missing);
    const lastStatus = health.LastRunStatus || (health.LastSuccessfulInventory ? "Succeeded" : missing);
    const syncMode = health.SyncMode || health.Parameters?.SYNC_MODE || "Audit";
    const defaultGroupMode = health.Parameters?.SYNC_DEFAULT_GROUP_MODE || "Passive";
    const syncModeTone = syncMode === "Enforce" ? "good" : "attention";
    const syncBadge = byId("header-sync-mode");
    if (syncBadge) {
      syncBadge.textContent = `Sync Mode: ${syncMode} (${syncMode === "Enforce" ? "Adds to group" : "Observe only"})`;
      syncBadge.className = `badge mode-pill ${syncModeTone}`;
      syncBadge.title = syncMode === "Enforce" ?
        "SYNC_MODE is Enforce: verified devices are automatically added to their target Entra ID security group." :
        "SYNC_MODE is Audit: devices are evaluated and reported as WouldAdd without modifying Entra ID groups.";
      syncBadge.hidden = false;
    }
    const groupModeBadge = byId("header-group-mode");
    if (groupModeBadge) {
      groupModeBadge.textContent = `Default Group: ${defaultGroupMode}`;
      groupModeBadge.className = "badge mode-pill";
      groupModeBadge.title = `SYNC_DEFAULT_GROUP_MODE is ${defaultGroupMode}: correlated devices target <Prefix>${defaultGroupMode}-<AccountId|ProjectId|SubscriptionName> by default (unless already in the counterpart group).`;
      groupModeBadge.hidden = false;
    }
    const statusTone = statusValue === "Running" ? "good" : statusValue === "Stopped" || statusValue === "Error" ? "bad" : "attention";
    const healthTone = healthValue === "Healthy" ? "good" : healthValue === "Unhealthy" ? "bad" : "attention";
    const runTone = ["Succeeded", "Verified", "WouldAdd", "Matched"].includes(lastStatus) ? "good" : lastStatus === "Failed" ? "bad" : "attention";
    const statusSpan = text("span", "", `status-value ${statusTone}`);
    const statusText = text("span", statusValue);
    if (health.FunctionAppName) {
      statusText.append(text("span", " ("));
      appendLink(statusText, health.FunctionAppName, portalUrl);
      statusText.append(text("span", ")"));
    }
    statusSpan.append(statusText);
    const aiSpan = document.createElement("span");
    appendLink(aiSpan, aiInfo.name ? `${aiInfo.name} (Search)` : "Open Transaction Search", aiInfo.searchUrl);
    const syncModeSpan = text("span", `${syncMode} (${syncMode === "Enforce" ? "Enforcing group additions" : "Audit — observe only"})`, `badge ${syncModeTone}`);
    const groupModeSpan = text("span", `${defaultGroupMode} group (<Prefix>${defaultGroupMode}-<Id>)`, "badge");
    const items = [
      ["Function App status", statusSpan],
      ["Function App health", text("span", healthValue, `badge ${healthTone}`)],
      ["Sync mode (SYNC_MODE)", syncModeSpan],
      ["Default group mode", groupModeSpan],
      ["Application Insights", aiSpan],
      ["Last run time", text("span", time(lastRunTime))],
      ["Why it ran", text("span", lastReason)],
      ["Last function & result", text("span", `${lastFunction}: ${lastStatus}`, `status-value ${runTone}`)],
      ["Machines queued (last inventory)", text("span", String(health.MachinesQueued ?? 0))]
    ];
    const container = byId("function-metrics");
    container.replaceChildren();
    for (const [label, node] of items) {
      const chip = text("div", "", "summary-chip");
      const dd = document.createElement("dd");
      dd.append(node);
      chip.append(text("dt", label), dd);
      container.append(chip);
    }
    renderFunctionParameters(health.Parameters || {});
  }
  function renderFunctionParameters(params) {
    const body = byId("function-parameters");
    if (!body) return;
    body.replaceChildren();
    const specs = [
      ["SYNC_MODE", "Synchronization mode (Audit observes only; Enforce adds verified devices to group)"],
      ["SYNC_DEFAULT_GROUP_MODE", "Global default target group mode (Passive or Active; defaults to Passive and skips adding if already in counterpart group)"],
      ["SYNC_ADMIN_UNIT_ID", "Microsoft Entra ID Administrative Unit GUID for AU-scoped automatic security group creation and management"],
      ["SYNC_AUTO_CREATE_GROUPS", "Automatically create missing Active/Passive Cloud × OS groups inside SYNC_ADMIN_UNIT_ID in Enforce mode"],
      ["SYNC_SCHEDULE", "NCRONTAB timer schedule for full Azure Resource Graph inventory"],
      ["SYNC_FRESHNESS_HOURS", "Maximum age in hours for MDE DeviceInfo telemetry (1–168)"],
      ["SYNC_AWS_WINDOWS_GROUP_PREFIX", "Naming prefix for AWS Windows Active/Passive Entra ID groups (ends in AWS AccountId tag)"],
      ["SYNC_AWS_LINUX_GROUP_PREFIX", "Naming prefix for AWS Linux Active/Passive Entra ID groups (ends in AWS AccountId tag)"],
      ["SYNC_GCP_WINDOWS_GROUP_PREFIX", "Naming prefix for GCP Windows Active/Passive Entra ID groups (ends in GCP ProjectId tag)"],
      ["SYNC_GCP_LINUX_GROUP_PREFIX", "Naming prefix for GCP Linux Active/Passive Entra ID groups (ends in GCP ProjectId tag)"],
      ["SYNC_AZURE_WINDOWS_GROUP_PREFIX", "Naming prefix for Azure Windows Active/Passive Entra ID groups (ends in Azure Subscription name; excludes AWS & GCP machines)"],
      ["SYNC_AZURE_LINUX_GROUP_PREFIX", "Naming prefix for Azure Linux Active/Passive Entra ID groups (ends in Azure Subscription name; excludes AWS & GCP machines)"],
      ["SYNC_SUBSCRIPTION_IDS", "Scoped Azure subscription GUIDs"],
      ["SYNC_MANAGEMENT_GROUP_IDS", "Scoped Azure management group IDs"],
      ["SYNC_RESOURCE_GROUP_NAMES", "Scoped Azure resource group names"],
      ["SYNC_TENANT_ID", "Authorized Microsoft Entra tenant ID"],
      ["SYNC_STORAGE_ACCOUNT", "Azure Storage account storing state, history, and execution logs"],
      ["ServiceBusNamespace", "Azure Service Bus namespace for the machines work queue"]
    ];
    for (const [key, description] of specs) {
      const row = document.createElement("tr");
      const nameCell = document.createElement("td");
      nameCell.append(text("code", key));
      const valCell = document.createElement("td");
      valCell.textContent = String(params[key] ?? missing);
      row.append(nameCell, valCell, text("td", description, "muted"));
      body.append(row);
    }
  }
  function openScriptOutputModal(entry) {
    const modal = byId("script-output-modal");
    if (!modal) return;
    byId("script-modal-title").textContent = `${entry.FunctionName || "Function"} — ${entry.Status || "Completed"}`;
    byId("script-modal-meta").textContent = `${time(entry.Timestamp)} · Trigger: ${entry.TriggerReason || missing} · Run ID: ${entry.RunId || missing}`;
    byId("script-modal-code").textContent = entry.ScriptOutput || "";
    byId("copy-script-modal").textContent = "Copy output";
    if (!modal.open) modal.showModal();
  }
  function appendFunctionLogs(items, reset) {
    const body = byId("function-logs");
    if (reset) body.replaceChildren();
    for (const entry of items) {
      const row = document.createElement("tr");
      const status = entry.Status || missing;
      const health = entry.Health || "Healthy";
      const statusTone = ["Succeeded", "Verified", "WouldAdd", "Matched"].includes(status) ? "good" : status === "Failed" ? "bad" : "attention";
      const healthTone = health === "Healthy" ? "good" : health === "Unhealthy" ? "bad" : "attention";
      const statusCell = document.createElement("td");
      statusCell.append(text("span", status, `status-value ${statusTone}`));
      const healthCell = document.createElement("td");
      healthCell.append(text("span", health, `badge ${healthTone}`));
      const msgCell = document.createElement("td");
      msgCell.className = "log-msg-cell";
      msgCell.append(text("div", entry.Message || missing));
      if (entry.ScriptOutput) {
        const details = document.createElement("details");
        details.className = "script-output-details";
        const summary = document.createElement("summary");
        summary.append(text("span", "View full PowerShell script output & query results"));
        const expandBtn = text("button", "Expand window", "secondary script-expand-btn");
        expandBtn.type = "button";
        expandBtn.title = "Open full PowerShell script output and query results in an expanded window";
        expandBtn.addEventListener("click", event => {
          event.preventDefault();
          event.stopPropagation();
          openScriptOutputModal(entry);
        });
        summary.append(expandBtn);
        details.append(summary);
        const pre = document.createElement("pre");
        pre.className = "script-inline-pre";
        pre.append(text("code", entry.ScriptOutput));
        details.append(pre);
        msgCell.append(details);
      }
      row.append(
        text("td", time(entry.Timestamp)),
        text("td", entry.FunctionName || missing),
        text("td", entry.TriggerReason || missing),
        statusCell,
        healthCell,
        msgCell,
        text("td", entry.RunId || missing)
      );
      body.append(row);
    }
    if (!body.children.length) {
      const empty = document.createElement("tr");
      const cell = text("td", "No function execution logs recorded yet.");
      cell.colSpan = 7;
      empty.append(cell);
      body.append(empty);
    }
  }
  async function loadMoreLogs() {
    if (logsBusy || !logsCursor) return;
    logsBusy = true;
    byId("more-logs").disabled = true;
    byId("function-logs-error").hidden = true;
    try {
      const page = await get(`logs?cursor=${encodeURIComponent(logsCursor)}`);
      if (!Array.isArray(page.Items) || typeof page.Cursor !== "string") throw new Error("Invalid function logs response.");
      if (page.Cursor && logsCursors.has(page.Cursor)) throw new Error("Function logs pagination did not advance.");
      appendFunctionLogs(page.Items, false);
      logsCursor = page.Cursor;
      if (logsCursor) logsCursors.add(logsCursor);
      logsCount += page.Items.length;
      byId("more-logs").hidden = !logsCursor;
      byId("function-logs-status").textContent = `${logsCount} log entries loaded.`;
    } catch (error) {
      byId("function-logs-error").textContent = error.message;
      byId("function-logs-error").hidden = false;
    } finally {
      logsBusy = false;
      byId("more-logs").disabled = false;
    }
  }
  async function refresh(forceRefresh = false) {
    if (busy) return;
    busy = true;
    byId("refresh").disabled = true;
    try {
      const [items, health, logsPage] = await Promise.all([
        allMachines(forceRefresh),
        get("health", forceRefresh),
        get("logs", forceRefresh).catch(() => ({ Items: [], Cursor: "" }))
      ]);
      const nowIso = new Date().toISOString();
      applySnapshot(items, health, logsPage, nowIso, false);
      saveCachedSnapshot(items, health, logsPage, nowIso);
      byId("error").hidden = true;
    } catch (error) {
      byId("error").textContent = `${error.message} Displayed results, if any, are from the last successful refresh.`;
      byId("error").hidden = false;
    } finally {
      byId("refresh").disabled = false;
      busy = false;
    }
  }
  for (const id of ["search", "status", "os", "management-group", "subscription", "membership"]) byId(id).addEventListener("input", render);
  byId("export-csv")?.addEventListener("click", exportInventoryCsv);
  byId("clear-filters").addEventListener("click", clearFilters);
  byId("reset-table").addEventListener("click", () => {
    layout = defaults();
    saveLayout();
    clearFilters();
  });
  byId("column-picker").addEventListener("toggle", () => {
    if (byId("column-picker").open) renderColumnOptions();
  });
  byId("refresh").addEventListener("click", () => refresh(true));
  byId("theme-toggle").addEventListener("click", () => setTheme(currentTheme() === "dark" ? "light" : "dark"));
  byId("more").addEventListener("click", loadHistory);
  byId("more-logs").addEventListener("click", loadMoreLogs);
  byId("toggle-logs-size")?.addEventListener("click", () => {
    const wrap = byId("logs-table-wrap");
    const btn = byId("toggle-logs-size");
    if (!wrap || !btn) return;
    const expanded = wrap.classList.toggle("is-expanded");
    btn.textContent = expanded ? "Collapse logs table" : "Expand logs table";
    btn.setAttribute("aria-pressed", String(expanded));
  });
  byId("close-script-modal")?.addEventListener("click", () => byId("script-output-modal")?.close());
  byId("copy-script-modal")?.addEventListener("click", async () => {
    const content = byId("script-modal-code")?.textContent || "";
    try {
      await navigator.clipboard.writeText(content);
      byId("copy-script-modal").textContent = "Copied!";
    } catch {}
  });
  byId("wrap-script-modal")?.addEventListener("click", () => {
    const pre = byId("script-modal-pre");
    const btn = byId("wrap-script-modal");
    if (!pre || !btn) return;
    const wrapped = pre.classList.toggle("wrap-lines");
    btn.textContent = `Wrap lines: ${wrapped ? "On" : "Off"}`;
    btn.setAttribute("aria-pressed", String(wrapped));
  });
  byId("close-detail").addEventListener("click", () => byId("detail").close());
  byId("detail").addEventListener("close", () => {
    if (byId("detail").open) return;
    historyGeneration++;
    historyBusy = false;
    const key = selectedKey;
    selectedKey = "";
    for (const row of byId("machines").rows) row.classList.remove("is-selected");
    const fallback = [...byId("machines").rows].find(row => row.dataset.key === key)?.querySelector(".history-action");
    (historyTrigger?.isConnected ? historyTrigger : fallback || document.querySelector(".table-wrap")).focus();
    historyTrigger = null;
  });
  document.addEventListener("keydown", event => {
    if (event.key === "Escape") {
      if (!byId("hover-popover").hidden) hideHoverPopover();
      else if (byId("detail").open) { event.preventDefault(); byId("detail").close(); }
      else if (byId("column-picker").open) { byId("column-picker").open = false; byId("column-picker").querySelector("summary").focus(); }
    }
  });
  document.addEventListener("click", event => {
    if (!byId("column-picker").contains(event.target)) byId("column-picker").open = false;
    const popover = byId("hover-popover");
    if (!popover.hidden && !popover.contains(event.target) && !activeHoverCell?.contains(event.target)) {
      hideHoverPopover();
    }
  });
  byId("hover-popover").addEventListener("mouseenter", clearHoverTimer);
  byId("hover-popover").addEventListener("mouseleave", event => {
    if (activeHoverCell?.contains(event.relatedTarget)) return;
    scheduleHideHoverPopover();
  });
  byId("status-navigation").addEventListener("click", () => { byId("device-status").open = true; });
  for (const link of document.querySelectorAll("a[data-doc-target]")) {
    link.addEventListener("click", () => {
      const target = byId(link.dataset.docTarget);
      if (target) target.open = true;
    });
  }
  for (const tab of document.querySelectorAll("button[data-card-target]")) {
    tab.addEventListener("click", () => {
      [...document.querySelectorAll("button[data-card]")].find(card => card.dataset.card === tab.dataset.cardTarget)?.click();
    });
  }
  for (const link of document.querySelectorAll('a[href="/.auth/logout"]')) {
    link.addEventListener("click", clearCachedSnapshot);
  }
  document.querySelector(".table-wrap").addEventListener("scroll", hideHoverPopover, { passive: true });
  window.addEventListener("scroll", hideHoverPopover, { passive: true });
  window.addEventListener("resize", () => { if (activeHoverCell) positionHoverPopover(activeHoverCell); });
  readLayout();
  updateThemeButton();
  renderColumnOptions();
  renderHeaders();
  const cachedAgeMs = Date.now() - loadCachedSnapshot();
  if (cachedAgeMs > 30000) void refresh(false);
  window.setInterval(() => { if (!document.hidden && byId("hover-popover").hidden) void refresh(false); }, 60000);
})();
