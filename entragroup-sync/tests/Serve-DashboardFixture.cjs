"use strict";
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const root = path.resolve(__dirname, "..", "report", "www");
const now = new Date().toISOString();
const machine = {
  Key: "a".repeat(64), MachineName: "server-windows-02", ResourceGroup: "rg-servers",
  ArcResourceId: "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-servers/providers/Microsoft.HybridCompute/machines/server-windows-02",
  SubscriptionId: "11111111-1111-1111-1111-111111111111", SubscriptionName: "Demo production",
  OS: "Windows", ArcStatus: "Connected", Status: "Verified", Mode: "Audit", Membership: "Present",
  ComputerName: "WINDOWS02", Fqdn: "windows02.example.test", CloudProvider: "AWS",
  MdeDeviceName: "windows02.example.test", MdeDeviceId: "1".repeat(40),
  EntraDeviceId: "44444444-4444-4444-4444-444444444444", EntraObjectId: "55555555-5555-5555-5555-555555555555",
  GroupId: "22222222-2222-2222-2222-222222222222", GroupName: "Arc servers", VirtualMachineId: "66666666-6666-6666-6666-666666666666",
  MdeSensorHealth: "Active", MdeOnboardingStatus: "Onboarded", MdeAntivirusMode: "Passive",
  MdeDeviceTags: ["Production", "Tier 1", "Server", "Managed"],
  MdeManualTags: ["Production", "Tier 1"], MdeDynamicTags: ["Server"], MdeRegistryTags: ["Managed"],
  MdeDeviceGroup: "Production servers", AzureTags: { Environment: "Production", Owner: "Infrastructure", "Cost center": "123" },
  MdeAntivirusTimestamp: now, MdeAntivirusStatus: "Reported", InventoryStatus: "Collected", InventoryErrors: [],
  ArcExtensions: ["AzureMonitorWindowsAgent (version: 1.0; state: Succeeded)", "MDE.Windows (version: 2.0; state: Succeeded)"],
  DefenderExtensionStatus: "MDE.Windows: Succeeded",
  IPAddresses: ["10.0.0.2", "2001:db8::2"], LastChecked: now, MembershipVerifiedAt: now,
  ArcLastReportedAt: now, ArcAddedAt: "2026-10-01T08:00:00.000Z", FirstSeen: now, MdeLastSeen: now, RunId: "demo-run", Error: ""
};
const linux = {
  ...machine, Key: "b".repeat(64), MachineName: "server-linux-10", OS: "Linux", ComputerName: "LINUX10",
  Fqdn: "linux10.example.test", MdeDeviceName: "linux10.example.test", MdeDeviceId: "2".repeat(40),
  ArcResourceId: machine.ArcResourceId.replace("server-windows-02", "server-linux-10"),
  CloudProvider: "GCP", EntraDeviceId: "", EntraObjectId: "", GroupId: "77777777-7777-7777-7777-777777777777", GroupName: "Arc Linux servers", Status: "NoEntraDevice", Membership: "Unknown",
  MembershipVerifiedAt: "", MdeSensorHealth: "Inactive", MdeAntivirusMode: "", MdeAntivirusTimestamp: "",
  MdeAntivirusStatus: "NoData", ArcExtensions: ["MDE.Linux (version: 1.5; state: Succeeded)"], DefenderExtensionStatus: "MDE.Linux: Succeeded", IPAddresses: ["10.0.0.10"], InventoryStatus: "Partial",
  InventoryErrors: ["Synthetic demo: no antivirus assessment data was reported."],
  MdeDeviceTags: ["Linux", "Internet facing", "<script>not markup</script>"],
  MdeManualTags: ["Linux", "<script>not markup</script>"], MdeDynamicTags: ["Internet facing"], MdeRegistryTags: [],
  MdeDeviceGroup: "Linux servers", AzureTags: { Environment: "Development", Owner: "Platform", Untrusted: "<img src=x onerror=alert(1)>" }
};
const legacy = {
  Key: "c".repeat(64), MachineName: "<img src=x onerror=alert(1)>", ResourceGroup: "rg-legacy",
  SubscriptionId: "11111111-1111-1111-1111-111111111111", OS: "Windows", ArcStatus: "Disconnected",
  Status: "ArcNotConnected", Membership: "Unknown", Mode: "Audit", LastChecked: now
};
const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  const json = value => { response.setHeader("Content-Type", "application/json"); response.end(JSON.stringify(value)); };
  if (url.pathname === "/api/report/data") return json(url.searchParams.has("cursor") ? { Items: [linux, legacy], Cursor: "" } : { Items: [machine], Cursor: "page-two" });
  if (url.pathname === "/api/report/health") return json({
    FunctionAppName: "arcgroupsync-worker-demo",
    FunctionAppResourceId: "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-arc-entra-sync/providers/Microsoft.Web/sites/arcgroupsync-worker-demo",
    FunctionAppStatus: "Running",
    Health: "Healthy",
    LastSuccessfulInventory: now,
    MachinesQueued: 3,
    LastRunTime: now,
    LastRunFunction: "Machine",
    LastRunReason: "Event Grid (Arc machine connected/updated)",
    LastRunStatus: "Verified",
    LastRunMessage: "server-windows-02: status=Verified, membership=Present",
    Parameters: {
      SYNC_MODE: "Audit",
      SYNC_SCHEDULE: "0 */30 * * * *",
      SYNC_FRESHNESS_HOURS: "24",
      SYNC_GROUP_ID: "22222222-2222-2222-2222-222222222222",
      SYNC_WINDOWS_GROUP_ID: "22222222-2222-2222-2222-222222222222",
      SYNC_LINUX_GROUP_ID: "77777777-7777-7777-7777-777777777777",
      SYNC_SUBSCRIPTION_IDS: "11111111-1111-1111-1111-111111111111",
      SYNC_MANAGEMENT_GROUP_IDS: "mg-arc-servers",
      SYNC_RESOURCE_GROUP_NAMES: "rg-servers, rg-legacy",
      SYNC_TENANT_ID: "33333333-3333-3333-3333-333333333333",
      SYNC_STORAGE_ACCOUNT: "syncdemostorage",
      ServiceBusNamespace: "arcgroupsync-bus-demo.servicebus.windows.net"
    }
  });
  if (url.pathname === "/api/report/logs") return json(url.searchParams.has("cursor") ? {
    Items: [
      { Timestamp: now, FunctionName: "Inventory", TriggerReason: "Scheduled timer (NCRONTAB schedule)", Status: "Succeeded", Health: "Healthy", Message: "Inventory pass completed: queued 3 machine(s).", RunId: "demo-inventory-run" }
    ],
    Cursor: ""
  } : {
    Items: [
      { Timestamp: now, FunctionName: "Machine", TriggerReason: "Event Grid (Arc machine connected/updated)", Status: "Verified", Health: "Healthy", Message: "server-windows-02: status=Verified, membership=Present", RunId: "demo-run" },
      { Timestamp: now, FunctionName: "Machine", TriggerReason: "Scheduled inventory reconciliation", Status: "NoEntraDevice", Health: "Degraded", Message: "server-linux-10: status=NoEntraDevice, membership=Unknown (Synthetic demo: no antivirus assessment data was reported.)", RunId: "demo-linux-run" },
      { Timestamp: now, FunctionName: "ArcEvent", TriggerReason: "Event Grid (Microsoft.HybridCompute/machines/write)", Status: "Succeeded", Health: "Healthy", Message: "Queued Arc machine event for server-windows-02.", RunId: "demo-event-run" }
    ],
    Cursor: "older-logs"
  });
  if (url.pathname === "/api/report/history") {
    const selected = [machine, linux, legacy].find(item => item.Key === url.searchParams.get("key"));
    if (!selected) { response.writeHead(404); return json({ error: "Unknown synthetic machine." }); }
    return json(url.searchParams.has("cursor") ?
      { Items: [{ Timestamp: now, Action: "StateChanged", RunId: "demo-older", State: { ...selected, MdeDeviceTags: [], AzureTags: {} } }], Cursor: "" } :
      { Items: [{ Timestamp: now, Action: "StateChanged", State: selected }], Cursor: "older" });
  }
  const name = url.pathname.split("/").pop() || "index.html";
  const types = { "index.html": "text/html", "style.css": "text/css", "theme.js": "text/javascript", "app.js": "text/javascript" };
  if (!Object.hasOwn(types, name)) { response.writeHead(404); response.end(); return; }
  response.setHeader("Content-Type", types[name]);
  response.setHeader("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
  let content = fs.readFileSync(path.join(root, name), "utf8");
  if (name === "index.html") content = content.replace("<h1>", "<p class=\"eyebrow\">LOCAL DEMO - SYNTHETIC DATA ONLY</p><h1>");
  response.end(content);
});
server.listen(Number(process.env.PORT || 0), "127.0.0.1", () => {
  console.log(`Synthetic dashboard fixture: http://127.0.0.1:${server.address().port}/api/report/`);
});
