"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const base = "/api/report/";
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
  const columns = [
    { id: "MachineName", label: "Arc Machine", link: "arc" },
    { id: "MdeDeviceName", label: "MDE Device", link: "mde", value: m => m.MdeDeviceName || m.MdeDeviceId },
    { id: "MdeDeviceId", label: "MDE device ID", link: "mde" },
    { id: "EntraDeviceId", label: "Entra ID Device" },
    { id: "ResourceGroup", label: "Arc resource group" },
    { id: "SubscriptionName", label: "Subscription", value: m => m.SubscriptionName ? `${m.SubscriptionName} (${m.SubscriptionId})` : m.SubscriptionId },
    { id: "ComputerName", label: "Computer name" },
    { id: "Fqdn", label: "FQDN" },
    { id: "CloudProvider", label: "Cloud provider" },
    { id: "MdeSensorHealth", label: "MDE sensor health" },
    { id: "ArcStatus", label: "Arc Machine status" },
    { id: "MdeOnboardingStatus", label: "MDE onboarded status" },
    { id: "MdeAntivirusMode", label: "MDE antivirus mode" },
    { id: "VirtualMachineId", label: "Virtual machine ID" },
    { id: "DefenderExtensionStatus", label: "Defender extension status", value: m => defenderExtensionFor(m) },
    { id: "ArcExtensions", label: "Arc machine extensions" },
    { id: "IPAddresses", label: "IP addresses" },
    { id: "MdeDeviceTags", label: "MDE device tags", tags: true, value: m => m.MdeDeviceTags, empty: "No tags" },
    { id: "MdeDeviceGroup", label: "MDE device group membership" },
    { id: "AzureTags", label: "Azure tags", tags: true, value: m => azureTagValues(m.AzureTags), empty: "No tags" },
    { id: "OS", label: "operating system" },
    { id: "Status", label: "Correlation" },
    { id: "Membership", label: "Entra ID Group", value: m => m.Membership === "Present" ?
      m.GroupName || (m.GroupId ? `Name unavailable (${m.GroupId})` : missing) :
      m.Membership === "Absent" ? "Not in group" : "Membership unknown" },
    { id: "Mode", label: "Sync mode" },
    { id: "LastChecked", label: "Last checked", type: "date" },
    { id: "MembershipVerifiedAt", label: "Membership verified", type: "date" },
    { id: "ArcLastReportedAt", label: "Arc Connected Machine last state time", type: "date" },
    { id: "ArcAddedAt", label: "Arc added", type: "date" },
    { id: "MdeLastSeen", label: "MDE last check in time", type: "date" },
    { id: "InventoryStatus", label: "Inventory collection" },
    { id: "InventoryErrors", label: "Inventory warnings", optional: true },
    { id: "MdeAntivirusTimestamp", label: "Antivirus report time", type: "date", optional: true },
    { id: "MdeAntivirusStatus", label: "Antivirus data status", optional: true },
    { id: "MdeCloudPlatforms", label: "MDE cloud platforms", optional: true },
    { id: "MdeAzureVmId", label: "MDE Azure VM ID", optional: true },
    { id: "SubscriptionId", label: "Subscription ID", optional: true },
    { id: "EntraObjectId", label: "Entra object ID", optional: true },
    { id: "ArcResourceId", label: "Arc resource ID", optional: true },
    { id: "Error", label: "Processing error", optional: true }
  ];
  const columnById = new Map(columns.map(column => [column.id, column]));
  const preferenceKey = "arc-entra-table-v2";
  const themePreferenceKey = "arc-entra-theme";
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
    "MachineName", "MdeDeviceName", "EntraDeviceId", "Membership", "MdeOnboardingStatus",
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
    return ["ARC CONNECTED MACHINE", [
      ["Azure Resource ID", machine.ArcResourceId || missing],
      ["Cloud Provider", machine.CloudProvider || missing],
      ["Operating System", osNode(machine.OS)],
      ["Defender extension", defenderStatusNode(machine)],
      ["Resource Group", machine.ResourceGroup || missing],
      ["Subscription Name", machine.SubscriptionName || machine.SubscriptionId || missing],
      ["Arc Connected Machine last state time", time(machine.ArcLastReportedAt)],
      ["Arc added", time(machine.ArcAddedAt || machine.FirstSeen)],
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
    for (const id of ["search", "status", "os", "subscription", "membership"]) byId(id).value = "";
    renderColumnOptions();
    renderHeaders();
    render();
  }
  async function get(path) {
    const response = await fetch(base + path, { credentials: "same-origin", cache: "no-store", redirect: "error" });
    if (!response.ok) throw new Error(`Report request failed (${response.status}). Check your sign-in, Report.Reader role, and service health.`);
    const result = await response.json();
    if (result.error) throw new Error(result.error);
    return result;
  }
  async function allMachines() {
    const items = [];
    const cursors = new Set();
    let cursor = "";
    do {
      const page = await get("data" + (cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""));
      if (!Array.isArray(page.Items) || typeof page.Cursor !== "string") throw new Error("Invalid inventory response.");
      items.push(...page.Items);
      cursor = page.Cursor;
      if (cursor && cursors.has(cursor)) throw new Error("Inventory pagination did not advance.");
      cursors.add(cursor);
    } while (cursor);
    return items;
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
  function render() {
    const search = byId("search").value.toLowerCase();
    const activeFilters = Object.entries(filters).filter(([, value]) => value.trim());
    const filtered = machines.filter(machine =>
      (!cardFilter || cardFilter.matches(machine)) &&
      (!search || columns.some(column => searchFor(machine, column).toLowerCase().includes(search))) &&
      activeFilters.every(([id, value]) => searchFor(machine, columnById.get(id)).toLowerCase().includes(value.trim().toLowerCase())) &&
      (!byId("status").value || machine.Status === byId("status").value) &&
      (!byId("os").value || machine.OS === byId("os").value) &&
      (!byId("subscription").value || machine.SubscriptionId === byId("subscription").value) &&
      (!byId("membership").value || machine.Membership === byId("membership").value)
    );
    const hiddenFilters = activeFilters.filter(([id]) => !layout.visible.includes(id)).length;
    byId("count").textContent = `${filtered.length} of ${machines.length} machines. ${cardFilter ? `Card filter: ${cardFilter.label}. ` : ""}${activeFilters.length} column filters${hiddenFilters ? ` (${hiddenFilters} on hidden columns)` : ""}. Sorted by ${columnById.get(layout.sort.id).label} ${layout.sort.direction}.`;
    updateCardSelection();
    hideHoverPopover();
    const body = byId("machines");
    body.replaceChildren();
    const visible = visibleColumns();
    const historyColumn = visible.find(c => c.id === "MachineName") ||
      visible.find(c => c.id === "MdeDeviceName") || visible[0];
    const sortColumn = columnById.get(layout.sort.id);
    filtered.sort((a, b) => {
      const left = valueFor(a, sortColumn);
      const right = valueFor(b, sortColumn);
      if (!left || !right) return left ? -1 : right ? 1 : collator.compare(a.Key || "", b.Key || "");
      const comparison = sortColumn.type === "date" ? Date.parse(left) - Date.parse(right) : collator.compare(left, right);
      return (layout.sort.direction === "asc" ? comparison : -comparison) || collator.compare(a.Key || "", b.Key || "");
    });
    for (const machine of filtered) {
      const row = document.createElement("tr");
      row.dataset.key = machine.Key;
      row.classList.toggle("is-selected", machine.Key === selectedKey);
      for (const column of visible) {
        const cell = document.createElement("td");
        cell.dataset.column = column.id;
        if (column.id === "Membership") {
          const membership = text("span", "", `status-value ${machine.Membership === "Present" ? "good" : machine.Membership === "Absent" ? "attention" : ""}`);
          appendLink(membership, displayFor(machine, column), machine.Membership === "Present" ? deviceLink(machine, "group") : "");
          cell.append(membership);
          cell.title = `Observed Entra membership: ${machine.Membership || "Unknown"}; verified: ${time(machine.MembershipVerifiedAt)}`;
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
          const tone = ["Present", "Connected", "Onboarded", "Active"].includes(value) ? "good" :
            ["Absent", "Disconnected", "Inactive"].includes(value) ? "attention" : "";
          cell.append(text("span", value, `status-value ${tone}`));
        }
        else cell.textContent = displayFor(machine, column);
        if (column.id === "InventoryStatus" && machine.InventoryErrors?.length) {
          cell.append(text("small", joined(machine.InventoryErrors), "bad"));
        }
        if (column.id === "MdeAntivirusMode") cell.title = `Report time: ${time(machine.MdeAntivirusTimestamp)}; data status: ${machine.MdeAntivirusStatus || missing}`;
        if (column.id === "MachineName") bindHoverPopover(cell, () => arcHoverSpec(machine));
        else if (column.id === "MdeDeviceName") bindHoverPopover(cell, () => mdeHoverSpec(machine));
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
        "Machines blocked from group synchronization due to disconnected/missing Arc state, missing/stale/ambiguous MDE telemetry, or a disabled/missing Entra device.",
        "Status not in ('Verified', 'WouldAdd', 'Failed')."
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
        "disconnected": "The Azure Arc agent has not recently sent a heartbeat to Azure; group changes are paused without removing existing membership.",
        "missing": "The Azure Arc resource was deleted from Azure; historical state is retained without removing existing group membership.",
        "default": "Current Azure Arc Connected Machine agent status reported by Microsoft.HybridCompute/machines."
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
      ["no-entra", "No Entra device", m => ["NoEntraDevice", "EntraDeviceNotFound"].includes(m.Status)],
      ["attention", "Needs attention", m => !["Verified", "WouldAdd", "Failed"].includes(m.Status)],
      ["failed", "Failed", m => m.Status === "Failed"],
      ["not-in-group", "Not in group", m => m.Membership === "Absent"],
      ["membership-unknown", "Membership unknown", m => !m.Membership || m.Membership === "Unknown"]
    ];
    byId("summary").replaceChildren(...stats.map(([key, label, matches]) => makeCard({
      key, label, matches
    })));
    const groups = [
      ["ArcStatus", "Arc Connected Machine Status", ["Connected", "Disconnected"]],
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
      for (const machine of machines) {
        const value = joined(machine[field]).trim();
        if (!buckets.has(value.toLowerCase())) buckets.set(value.toLowerCase(), value || "Not reported");
      }
      if (cardFilter?.field === field && !buckets.has(cardFilter.bucket)) {
        buckets.set(cardFilter.bucket, cardFilter.valueLabel);
      }
      for (const [bucket, valueLabel] of buckets) {
        grid.append(makeCard({
          key: `${field}:${bucket}`, label: `${title}: ${valueLabel}`, valueLabel, field, bucket,
          matches: machine => joined(machine[field]).trim().toLowerCase() === bucket
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
      ["search", "status", "os", "subscription", "membership"].some(id => byId(id).value);
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
      ["Entra ID Group", (() => {
        const groupSpan = text("span", "", `status-value ${machine.Membership === "Present" ? "good" : machine.Membership === "Absent" ? "attention" : ""}`);
        appendLink(groupSpan, displayFor(machine, columnById.get("Membership")), machine.Membership === "Present" ? deviceLink(machine, "group") : "");
        return groupSpan;
      })()],
      ["MDE onboarded status", (() => {
        const value = displayFor(machine, columnById.get("MdeOnboardingStatus"));
        return text("span", value, `status-value ${value === "Onboarded" ? "good" : ""}`);
      })()],
      ["MDE mode", text("span", displayFor(machine, columnById.get("MdeAntivirusMode")))],
      ["Defender extension", defenderStatusNode(machine)],
      ["Arc connected machine status", (() => {
        const value = displayFor(machine, columnById.get("ArcStatus"));
        return text("span", value, `status-value ${value === "Connected" ? "good" : value === "Disconnected" ? "attention" : ""}`);
      })()],
      ["Arc Connected Machine last state time", text("span", time(machine.ArcLastReportedAt))],
      ["MDE last check in time", text("span", time(machine.MdeLastSeen))],
      ["Arc added", text("span", time(machine.ArcAddedAt || machine.FirstSeen))],
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
      ["Arc resource", machine.ArcResourceId], ["Arc status", machine.ArcStatus],
      ["Arc Connected Machine last state time", time(machine.ArcLastReportedAt)], ["Arc added", time(machine.ArcAddedAt || machine.FirstSeen)],
      ["MDE device ID", machine.MdeDeviceId], ["MDE last check in time", time(machine.MdeLastSeen)],
      ["Entra device ID", machine.EntraDeviceId], ["Entra object ID", machine.EntraObjectId],
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
    detail.append(text("dt", "Target Entra ID group"), document.createElement("dd"));
    appendLink(detail.lastChild, machine.GroupName || machine.GroupId || missing, deviceLink(machine, "group"));
    for (const [kind, label] of [["arc", "Azure portal"], ["mde", "Defender portal"]]) {
      detail.append(text("dt", label), document.createElement("dd"));
      appendLink(detail.lastChild, kind === "arc" ? "Open Arc machine" : machine.MdeDeviceId ? "Open MDE device" : missing, deviceLink(machine, kind));
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
  function functionPortalLink(health) {
    if (health?.FunctionAppResourceId) {
      return `https://portal.azure.com/#resource${health.FunctionAppResourceId.split("/").map(encodeURIComponent).join("/")}/overview`;
    }
    return "https://portal.azure.com/#browse/Microsoft.Web%2Fsites/kind/functionapp";
  }
  function renderFunctionHealth(health) {
    byId("health").textContent = health.LastSuccessfulInventory ?
      `Last complete inventory: ${time(health.LastSuccessfulInventory)} (${health.MachinesQueued ?? 0} queued; processing may still be in progress)` :
      "No successful inventory recorded. Check deployment, permissions, and worker logs.";
    const portalUrl = functionPortalLink(health);
    const portalAnchor = byId("function-portal-link");
    portalAnchor.href = portalUrl;
    portalAnchor.textContent = health.FunctionAppName ? `Open ${health.FunctionAppName} in Azure portal` : "Open Function App in Azure portal";
    const statusValue = health.FunctionAppStatus || (health.LastSuccessfulInventory ? "Running" : "Idle");
    const healthValue = health.Health || (health.LastSuccessfulInventory ? "Healthy" : "Unknown");
    const lastRunTime = health.LastRunTime || health.LastSuccessfulInventory;
    const lastReason = health.LastRunReason || (health.LastSuccessfulInventory ? "Scheduled timer (NCRONTAB schedule)" : "No function runs recorded yet");
    const lastFunction = health.LastRunFunction || (health.LastSuccessfulInventory ? "Inventory" : missing);
    const lastStatus = health.LastRunStatus || (health.LastSuccessfulInventory ? "Succeeded" : missing);
    const statusTone = statusValue === "Running" ? "good" : statusValue === "Stopped" || statusValue === "Error" ? "bad" : "attention";
    const healthTone = healthValue === "Healthy" ? "good" : healthValue === "Unhealthy" ? "bad" : "attention";
    const runTone = ["Succeeded", "Verified", "WouldAdd", "Matched"].includes(lastStatus) ? "good" : lastStatus === "Failed" ? "bad" : "attention";
    const statusSpan = text("span", `${statusValue}${health.FunctionAppName ? " (" : ""}`, `status-value ${statusTone}`);
    if (health.FunctionAppName) {
      appendLink(statusSpan, health.FunctionAppName, portalUrl);
      statusSpan.append(text("span", ")"));
    }
    const items = [
      ["Function App status", statusSpan],
      ["Function App health", text("span", healthValue, `badge ${healthTone}`)],
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
      ["SYNC_SCHEDULE", "NCRONTAB timer schedule for full Azure Resource Graph inventory"],
      ["SYNC_FRESHNESS_HOURS", "Maximum age in hours for MDE DeviceInfo telemetry (1–168)"],
      ["SYNC_GROUP_ID", "Default / fallback target Entra ID security group object ID"],
      ["SYNC_WINDOWS_GROUP_ID", "Target Entra ID security group object ID for Windows servers"],
      ["SYNC_LINUX_GROUP_ID", "Target Entra ID security group object ID for Linux servers"],
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
      const rawVal = String(params[key] ?? missing);
      const guidMatch = rawVal.match(/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(.*)$/i);
      if (key.endsWith("GROUP_ID") && guidMatch) {
        appendLink(valCell, guidMatch[1], `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/${encodeURIComponent(guidMatch[1])}`);
        if (guidMatch[2]) valCell.append(text("span", guidMatch[2], "muted"));
      } else {
        valCell.textContent = rawVal;
      }
      row.append(nameCell, valCell, text("td", description, "muted"));
      body.append(row);
    }
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
      row.append(
        text("td", time(entry.Timestamp)),
        text("td", entry.FunctionName || missing),
        text("td", entry.TriggerReason || missing),
        statusCell,
        healthCell,
        text("td", entry.Message || missing),
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
  async function refresh() {
    if (busy) return;
    busy = true;
    byId("refresh").disabled = true;
    try {
      const [items, health, logsPage] = await Promise.all([
        allMachines(),
        get("health"),
        get("logs").catch(() => ({ Items: [], Cursor: "" }))
      ]);
      machines = items;
      renderFunctionHealth(health);
      logsCursor = typeof logsPage.Cursor === "string" ? logsPage.Cursor : "";
      logsCursors = new Set(logsCursor ? [logsCursor] : []);
      const logItems = Array.isArray(logsPage.Items) ? logsPage.Items : [];
      logsCount = logItems.length;
      appendFunctionLogs(logItems, true);
      byId("more-logs").hidden = !logsCursor;
      byId("function-logs-error").hidden = true;
      byId("function-logs-status").textContent = logsCount ? `${logsCount} log entries loaded.` : "No logs recorded yet.";
      byId("updated").textContent = `Report refreshed: ${time(new Date().toISOString())}`;
      updateOptions("status", machines.map(m => m.Status), "All statuses");
      updateOptions("os", machines.map(m => m.OS), "All operating systems");
      updateOptions("subscription", machines.map(m => m.SubscriptionId), "All subscriptions");
      renderSummary();
      render();
      byId("error").hidden = true;
    } catch (error) {
      byId("error").textContent = `${error.message} Displayed results, if any, are from the last successful refresh.`;
      byId("error").hidden = false;
    } finally {
      byId("refresh").disabled = false;
      busy = false;
    }
  }
  for (const id of ["search", "status", "os", "subscription", "membership"]) byId(id).addEventListener("input", render);
  byId("clear-filters").addEventListener("click", clearFilters);
  byId("reset-table").addEventListener("click", () => {
    layout = defaults();
    saveLayout();
    clearFilters();
  });
  byId("column-picker").addEventListener("toggle", () => {
    if (byId("column-picker").open) renderColumnOptions();
  });
  byId("refresh").addEventListener("click", refresh);
  byId("theme-toggle").addEventListener("click", () => setTheme(currentTheme() === "dark" ? "light" : "dark"));
  byId("more").addEventListener("click", loadHistory);
  byId("more-logs").addEventListener("click", loadMoreLogs);
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
  document.querySelector(".table-wrap").addEventListener("scroll", hideHoverPopover, { passive: true });
  window.addEventListener("scroll", hideHoverPopover, { passive: true });
  window.addEventListener("resize", () => { if (activeHoverCell) positionHoverPopover(activeHoverCell); });
  (() => {
    const svg = document.querySelector(".archify-svg");
    const status = byId("archify-inspector-text");
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
      status.textContent = "Select any component node in the Archify diagram above to highlight its connected data flows and view its implementation details.";
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
      status.textContent = `${node.dataset.nodeLabel} (${node.dataset.nodeSublabel || node.dataset.nodeKind || "component"}${node.dataset.nodeTag ? ` · ${node.dataset.nodeTag}` : ""}). ${inText}${outText}`;
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
  })();
  readLayout();
  updateThemeButton();
  renderColumnOptions();
  renderHeaders();
  void refresh();
  window.setInterval(() => { if (!document.hidden && byId("hover-popover").hidden) void refresh(); }, 60000);
})();
