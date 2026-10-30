"use strict";
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const root = path.resolve(__dirname, "..", "report", "www");
const now = new Date().toISOString();
const machine = {
  Key: "a".repeat(64), MachineName: "server-windows-02", ResourceGroup: "rg-servers",
  ArcResourceId: "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-servers/providers/Microsoft.HybridCompute/machines/server-windows-02",
  SubscriptionId: "11111111-1111-1111-1111-111111111111", SubscriptionName: "Demo production", ManagementGroup: "Production Workloads (mg-arc-servers)",
  OS: "Windows", ArcStatus: "Connected", Status: "Verified", Mode: "Audit", Membership: "Present",
  ComputerName: "WINDOWS02", Fqdn: "windows02.example.test", CloudProvider: "AWS",
  MdeDeviceName: "windows02.example.test", MdeDeviceId: "1".repeat(40),
  EntraDeviceId: "44444444-4444-4444-4444-444444444444", EntraObjectId: "55555555-5555-5555-5555-555555555555",
  GroupId: "88888888-8888-8888-8888-888888888888", GroupName: "MDfS-AWS-Windows-Passive-123456789012",
  GroupIds: ["88888888-8888-8888-8888-888888888888"], GroupNames: ["MDfS-AWS-Windows-Passive-123456789012"],
  MemberGroups: [{ Id: "88888888-8888-8888-8888-888888888888", DisplayName: "MDfS-AWS-Windows-Passive-123456789012", CloudType: "AWS", OSCategory: "Windows", GroupMode: "Passive", CloudIdentifier: "123456789012" }],
  GroupAvMode: "Passive", DefaultGroupMode: "Passive", GroupFlags: [], GroupFlagCodes: [], GroupComplianceStatus: "Compliant",
  CloudGroupType: "AWS", CloudGroupOS: "Windows", CloudIdentifier: "123456789012",
  VirtualMachineId: "66666666-6666-6666-6666-666666666666",
  MdeSensorHealth: "Active", MdeOnboardingStatus: "Onboarded", MdeAntivirusMode: "Passive",
  MdeDeviceTags: ["Production", "Tier 1", "Server", "Managed"],
  MdeManualTags: ["Production", "Tier 1"], MdeDynamicTags: ["Server"], MdeRegistryTags: ["Managed"],
  MdeDeviceGroup: "Production servers", AzureTags: { AccountId: "123456789012", Environment: "Production", Owner: "Infrastructure", "Cost center": "123" },
  MdeAntivirusTimestamp: now, MdeAntivirusStatus: "Reported", InventoryStatus: "Collected", InventoryErrors: [],
  ArcExtensions: ["AzureMonitorWindowsAgent (version: 1.0; state: Succeeded)", "MDE.Windows (version: 2.0; state: Succeeded)"],
  DefenderExtensionStatus: "MDE.Windows: Succeeded",
  IPAddresses: ["10.0.0.2", "2001:db8::2"], LastChecked: now, MembershipVerifiedAt: now,
  ArcLastReportedAt: now, ArcAddedAt: "2026-10-01T08:00:00.000Z", FirstSeen: now, MdeLastSeen: now, RunId: "demo-run", Error: ""
};
const activeMismatch = {
  ...machine, Key: "d".repeat(64), MachineName: "server-aws-active-04", ComputerName: "AWSACTIVE04",
  Fqdn: "awsactive04.example.test", MdeDeviceName: "awsactive04.example.test", MdeDeviceId: "4".repeat(40),
  ArcResourceId: machine.ArcResourceId.replace("server-windows-02", "server-aws-active-04"),
  GroupId: "99999999-9999-9999-9999-999999999999", GroupName: "MDfS-AWS-Windows-Active-123456789012",
  GroupIds: ["99999999-9999-9999-9999-999999999999"], GroupNames: ["MDfS-AWS-Windows-Active-123456789012"],
  MemberGroups: [{ Id: "99999999-9999-9999-9999-999999999999", DisplayName: "MDfS-AWS-Windows-Active-123456789012", CloudType: "AWS", OSCategory: "Windows", GroupMode: "Active", CloudIdentifier: "123456789012" }],
  GroupAvMode: "Active", DefaultGroupMode: "Passive", MdeAntivirusMode: "Passive",
  GroupFlags: ["Should be Active: in Active group (MDfS-AWS-Windows-Active-123456789012) but MDE mode is Passive"],
  GroupFlagCodes: ["AvModeMismatchShouldBeActive"], GroupComplianceStatus: "Flagged"
};
const passiveMismatch = {
  ...machine, Key: "e".repeat(64), MachineName: "server-gcp-passive-07", OS: "Linux", ComputerName: "GCPPASSIVE07",
  Fqdn: "gcppassive07.example.test", MdeDeviceName: "gcppassive07.example.test", MdeDeviceId: "5".repeat(40),
  ArcResourceId: machine.ArcResourceId.replace("server-windows-02", "server-gcp-passive-07"),
  CloudProvider: "GCP", CloudGroupType: "GCP", CloudGroupOS: "Linux", CloudIdentifier: "gcp-prod-proj-01",
  GroupId: "aaaaaaaa-1111-2222-3333-444444444444", GroupName: "MDfS-GCP-Linux-Passive-gcp-prod-proj-01",
  GroupIds: ["aaaaaaaa-1111-2222-3333-444444444444"], GroupNames: ["MDfS-GCP-Linux-Passive-gcp-prod-proj-01"],
  MemberGroups: [{ Id: "aaaaaaaa-1111-2222-3333-444444444444", DisplayName: "MDfS-GCP-Linux-Passive-gcp-prod-proj-01", CloudType: "GCP", OSCategory: "Linux", GroupMode: "Passive", CloudIdentifier: "gcp-prod-proj-01" }],
  GroupAvMode: "Passive", DefaultGroupMode: "Passive", MdeAntivirusMode: "Active",
  ArcExtensions: ["MDE.Linux (version: 1.5; state: Succeeded)"], DefenderExtensionStatus: "MDE.Linux: Succeeded",
  AzureTags: { ProjectId: "gcp-prod-proj-01", Environment: "Production" },
  GroupFlags: ["Should be Active: in Passive group (MDfS-GCP-Linux-Passive-gcp-prod-proj-01) but MDE mode is Active"],
  GroupFlagCodes: ["AvModeMismatchShouldBeActive"], GroupComplianceStatus: "Flagged"
};
const multiWrongGroup = {
  ...machine, Key: "f".repeat(64), MachineName: "vm-azure-multi-09", ComputerName: "AZMULTI09",
  Fqdn: "azmulti09.example.test", MdeDeviceName: "azmulti09.example.test", MdeDeviceId: "6".repeat(40),
  ArcResourceId: "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-servers/providers/Microsoft.Compute/virtualMachines/vm-azure-multi-09",
  CloudProvider: "Azure", CloudGroupType: "Azure", CloudGroupOS: "Windows", CloudIdentifier: "Demo production",
  AzureTags: { Environment: "Production", Owner: "Compute" },
  GroupId: "bbbbbbbb-1111-2222-3333-444444444444",
  GroupName: "MDfS-Azure-Windows-Passive-Demo production; MDfS-Azure-Windows-Active-Legacy subscription",
  GroupIds: ["bbbbbbbb-1111-2222-3333-444444444444", "cccccccc-1111-2222-3333-444444444444"],
  GroupNames: ["MDfS-Azure-Windows-Passive-Demo production", "MDfS-Azure-Windows-Active-Legacy subscription"],
  MemberGroups: [
    { Id: "bbbbbbbb-1111-2222-3333-444444444444", DisplayName: "MDfS-Azure-Windows-Passive-Demo production", CloudType: "Azure", OSCategory: "Windows", GroupMode: "Passive", CloudIdentifier: "Demo production" },
    { Id: "cccccccc-1111-2222-3333-444444444444", DisplayName: "MDfS-Azure-Windows-Active-Legacy subscription", CloudType: "Azure", OSCategory: "Windows", GroupMode: "Active", CloudIdentifier: "Legacy subscription" }
  ],
  GroupAvMode: "Multiple", DefaultGroupMode: "Passive", MdeAntivirusMode: "Passive",
  GroupFlags: [
    "Multiple groups (2): MDfS-Azure-Windows-Passive-Demo production, MDfS-Azure-Windows-Active-Legacy subscription",
    "Wrong group (Subscription mismatch): in MDfS-Azure-Windows-Active-Legacy subscription (Legacy subscription) but machine Subscription is Demo production",
    "Should be Active: in Active group (MDfS-Azure-Windows-Active-Legacy subscription) but MDE mode is Passive"
  ],
  GroupFlagCodes: ["MultipleGroups", "WrongGroup", "AvModeMismatchShouldBeActive"], GroupComplianceStatus: "Flagged"
};
const linux = {
  ...machine, Key: "b".repeat(64), MachineName: "server-linux-10", OS: "Linux", ComputerName: "LINUX10",
  Fqdn: "linux10.example.test", MdeDeviceName: "linux10.example.test", MdeDeviceId: "2".repeat(40),
  ArcResourceId: machine.ArcResourceId.replace("server-windows-02", "server-linux-10"),
  CloudProvider: "GCP", EntraDeviceId: "", EntraObjectId: "", GroupId: "", GroupName: "MDfS-GCP-Linux-Passive-gcp-prod-proj-01",
  GroupIds: [], GroupNames: [], MemberGroups: [], GroupFlags: [], GroupFlagCodes: [], GroupComplianceStatus: "NotInGroup",
  CloudGroupType: "GCP", CloudGroupOS: "Linux", CloudIdentifier: "gcp-prod-proj-01",
  Status: "NoEntraDevice", Membership: "Unknown",
  MembershipVerifiedAt: "", MdeSensorHealth: "Inactive", MdeAntivirusMode: "", MdeAntivirusTimestamp: "",
  MdeAntivirusStatus: "NoData", ArcExtensions: ["MDE.Linux (version: 1.5; state: Succeeded)"], DefenderExtensionStatus: "MDE.Linux: Succeeded", IPAddresses: ["10.0.0.10"], InventoryStatus: "Partial",
  InventoryErrors: ["Synthetic demo: no antivirus assessment data was reported."],
  MdeDeviceTags: ["Linux", "Internet facing", "<script>not markup</script>"],
  MdeManualTags: ["Linux", "<script>not markup</script>"], MdeDynamicTags: ["Internet facing"], MdeRegistryTags: [],
  MdeDeviceGroup: "Linux servers", AzureTags: { ProjectId: "gcp-prod-proj-01", Environment: "Development", Owner: "Platform", Untrusted: "<img src=x onerror=alert(1)>" }
};
const legacy = {
  Key: "c".repeat(64), MachineName: "<img src=x onerror=alert(1)>", ResourceGroup: "rg-legacy",
  SubscriptionId: "11111111-1111-1111-1111-111111111111", SubscriptionName: "Demo production", ManagementGroup: "Production Workloads (mg-arc-servers)", OS: "Windows", ArcStatus: "Disconnected",
  GroupId: "", GroupName: "MDfS-Azure-Windows-Passive-Demo production", CloudGroupType: "Azure", CloudGroupOS: "Windows", CloudIdentifier: "Demo production",
  Status: "ArcNotConnected", Membership: "Unknown", Mode: "Audit", LastChecked: now
};
const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  const normalizedPath = url.pathname.replace(/^\/api\/report(\/|$)/i, "/");
  const json = value => { response.setHeader("Content-Type", "application/json"); response.end(JSON.stringify(value)); };
  if (normalizedPath === "/data") return json(url.searchParams.has("cursor") ? { Items: [passiveMismatch, multiWrongGroup, linux, legacy], Cursor: "" } : { Items: [machine, activeMismatch], Cursor: "page-two" });
  if (normalizedPath === "/health") return json({
    FunctionAppName: "arcgroupsync-worker-demo",
    FunctionAppResourceId: "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-arc-entra-sync/providers/Microsoft.Web/sites/arcgroupsync-worker-demo",
    AppInsightsName: "arcgroupsync-insights",
    AppInsightsResourceId: "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-arc-entra-sync/providers/Microsoft.Insights/components/arcgroupsync-insights",
    FunctionAppStatus: "Running",
    Health: "Healthy",
    LastSuccessfulInventory: now,
    MachinesQueued: 6,
    LastRunTime: now,
    LastRunFunction: "Machine",
    LastRunReason: "Event Grid (MDE.Windows / MDE.Linux extension Succeeded)",
    LastRunStatus: "Verified",
    LastRunMessage: "server-windows-02: status=Verified, membership=Present",
    Parameters: {
      SYNC_MODE: "Audit",
      SYNC_DEFAULT_GROUP_MODE: "Passive",
      SYNC_ADMIN_UNIT_ID: "44444444-aaaa-bbbb-cccc-555555555555",
      SYNC_AUTO_CREATE_GROUPS: "true (enabled via SYNC_ADMIN_UNIT_ID)",
      SYNC_SCHEDULE: "0 */30 * * * *",
      SYNC_FRESHNESS_HOURS: "24",
      SYNC_AWS_WINDOWS_GROUP_PREFIX: "MDfS-AWS-Windows-{Passive|Active}-<AccountId> (default: MDfS-AWS-Windows-Passive-<AccountId>)",
      SYNC_AWS_LINUX_GROUP_PREFIX: "MDfS-AWS-Linux-{Passive|Active}-<AccountId> (default: MDfS-AWS-Linux-Passive-<AccountId>)",
      SYNC_GCP_WINDOWS_GROUP_PREFIX: "MDfS-GCP-Windows-{Passive|Active}-<ProjectId> (default: MDfS-GCP-Windows-Passive-<ProjectId>)",
      SYNC_GCP_LINUX_GROUP_PREFIX: "MDfS-GCP-Linux-{Passive|Active}-<ProjectId> (default: MDfS-GCP-Linux-Passive-<ProjectId>)",
      SYNC_AZURE_WINDOWS_GROUP_PREFIX: "MDfS-Azure-Windows-{Passive|Active}-<SubscriptionName> (default: MDfS-Azure-Windows-Passive-<SubscriptionName>)",
      SYNC_AZURE_LINUX_GROUP_PREFIX: "MDfS-Azure-Linux-{Passive|Active}-<SubscriptionName> (default: MDfS-Azure-Linux-Passive-<SubscriptionName>)",
      SYNC_SUBSCRIPTION_IDS: "11111111-1111-1111-1111-111111111111",
      SYNC_MANAGEMENT_GROUP_IDS: "mg-arc-servers",
      SYNC_RESOURCE_GROUP_NAMES: "rg-servers, rg-legacy",
      SYNC_TENANT_ID: "33333333-3333-3333-3333-333333333333",
      SYNC_STORAGE_ACCOUNT: "syncdemostorage",
      ServiceBusNamespace: "arcgroupsync-bus-demo.servicebus.windows.net"
    },
    Catalog: {
      ManagedGroups: [
        { Id: "88888888-8888-8888-8888-888888888888", DisplayName: "MDfS-AWS-Windows-Passive-123456789012", CloudType: "AWS", OSCategory: "Windows", GroupMode: "Passive", CloudIdentifier: "123456789012" },
        { Id: "99999999-9999-9999-9999-999999999999", DisplayName: "MDfS-AWS-Windows-Active-123456789012", CloudType: "AWS", OSCategory: "Windows", GroupMode: "Active", CloudIdentifier: "123456789012" },
        { Id: "dddddd01-1111-2222-3333-444444444444", DisplayName: "MDfS-AWS-Linux-Passive-123456789012", CloudType: "AWS", OSCategory: "Linux", GroupMode: "Passive", CloudIdentifier: "123456789012" },
        { Id: "dddddd02-1111-2222-3333-444444444444", DisplayName: "MDfS-AWS-Windows-Passive-210987654321", CloudType: "AWS", OSCategory: "Windows", GroupMode: "Passive", CloudIdentifier: "210987654321" },
        { Id: "aaaaaaaa-1111-2222-3333-444444444444", DisplayName: "MDfS-GCP-Linux-Passive-gcp-prod-proj-01", CloudType: "GCP", OSCategory: "Linux", GroupMode: "Passive", CloudIdentifier: "gcp-prod-proj-01" },
        { Id: "dddddd03-1111-2222-3333-444444444444", DisplayName: "MDfS-GCP-Linux-Active-gcp-prod-proj-01", CloudType: "GCP", OSCategory: "Linux", GroupMode: "Active", CloudIdentifier: "gcp-prod-proj-01" },
        { Id: "dddddd04-1111-2222-3333-444444444444", DisplayName: "MDfS-GCP-Linux-Passive-gcp-sandbox-empty", CloudType: "GCP", OSCategory: "Linux", GroupMode: "Passive", CloudIdentifier: "gcp-sandbox-empty" },
        { Id: "bbbbbbbb-1111-2222-3333-444444444444", DisplayName: "MDfS-Azure-Windows-Passive-Demo production", CloudType: "Azure", OSCategory: "Windows", GroupMode: "Passive", CloudIdentifier: "Demo production" },
        { Id: "cccccccc-1111-2222-3333-444444444444", DisplayName: "MDfS-Azure-Windows-Active-Legacy subscription", CloudType: "Azure", OSCategory: "Windows", GroupMode: "Active", CloudIdentifier: "Legacy subscription" },
        { Id: "dddddd05-1111-2222-3333-444444444444", DisplayName: "MDfS-Azure-Linux-Passive-Empty Sandbox Subscription", CloudType: "Azure", OSCategory: "Linux", GroupMode: "Passive", CloudIdentifier: "Empty Sandbox Subscription" }
      ],
      CloudScopes: [
        { CloudType: "AWS", CloudIdentifier: "123456789012", SubscriptionId: "", ManagementGroup: "Production Workloads (mg-arc-servers)", Source: "Discovered server inventory" },
        { CloudType: "AWS", CloudIdentifier: "210987654321", SubscriptionId: "", ManagementGroup: "Sandbox Workloads (mg-sandbox)", Source: "Entra ID Group (MDfS-AWS-Windows-Passive-210987654321)" },
        { CloudType: "GCP", CloudIdentifier: "gcp-prod-proj-01", SubscriptionId: "", ManagementGroup: "Production Workloads (mg-arc-servers)", Source: "Discovered server inventory" },
        { CloudType: "GCP", CloudIdentifier: "gcp-sandbox-empty", SubscriptionId: "", ManagementGroup: "Sandbox Workloads (mg-sandbox)", Source: "Entra ID Group (MDfS-GCP-Linux-Passive-gcp-sandbox-empty)" },
        { CloudType: "Azure", CloudIdentifier: "Demo production", SubscriptionId: "11111111-1111-1111-1111-111111111111", ManagementGroup: "Production Workloads (mg-arc-servers)", Source: "Scoped Azure Subscription" },
        { CloudType: "Azure", CloudIdentifier: "Empty Sandbox Subscription", SubscriptionId: "22222222-3333-4444-5555-666666666666", ManagementGroup: "Sandbox Workloads (mg-sandbox)", Source: "Scoped Azure Subscription" }
      ]
    }
  });
  if (normalizedPath === "/permissions") return json({
    CheckedAt: now,
    Source: "WorkerLiveCheck",
    WorkerFunctionName: "arcgroupsync-worker-demo",
    WorkerPrincipalId: "77777777-8888-9999-aaaa-bbbbbbbbbbbb",
    ReportFunctionName: "arcgroupsync-report-demo",
    ReportPrincipalId: "cccccccc-dddd-eeee-ffff-000000000000",
    FunctionAppResourceId: "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-arc-entra-sync/providers/Microsoft.Web/sites/arcgroupsync-worker-demo",
    TenantId: "33333333-3333-3333-3333-333333333333",
    SyncMode: "Audit",
    DefaultGroupMode: "Passive",
    AdminUnitId: "44444444-aaaa-bbbb-cccc-555555555555",
    AutoCreateGroups: true,
    TokenRoles: ["ThreatHunting.Read.All", "Device.Read.All"],
    Checks: [
      { Id: "azure-rbac-reader", Category: "Azure RBAC", Principal: "Worker Managed Identity (77777777-8888-9999-aaaa-bbbbbbbbbbbb)", Permission: "Reader", Scope: "Subscriptions: 11111111-1111-1111-1111-111111111111 | Management Groups: mg-arc-servers", RequiredFor: "All Modes (Azure Resource Graph Discovery)", Status: "Granted", Details: "Verified Azure Reader access across configured scope (1 direct subscription(s), 2 MG subscription(s) visible; 6 server(s) discovered in Azure Resource Graph).", Remediation: "" },
      { Id: "graph-threat-hunting", Category: "Microsoft Graph", Principal: "Worker Managed Identity (77777777-8888-9999-aaaa-bbbbbbbbbbbb)", Permission: "ThreatHunting.Read.All", Scope: "Tenant (33333333-3333-3333-3333-333333333333)", RequiredFor: "All Modes (MDE Advanced Hunting)", Status: "Granted", Details: "Verified ThreatHunting.Read.All application permission (Token claim present: True; /v1.0/security/runHuntingQuery HTTP 200).", Remediation: "" },
      { Id: "graph-device-read", Category: "Microsoft Graph", Principal: "Worker Managed Identity (77777777-8888-9999-aaaa-bbbbbbbbbbbb)", Permission: "Device.Read.All", Scope: "Tenant (33333333-3333-3333-3333-333333333333)", RequiredFor: "All Modes (Entra Device Correlation)", Status: "Granted", Details: "Verified Entra device read access (Token claim present: True; GET /v1.0/devices HTTP 200).", Remediation: "" },
      { Id: "entra-au-autocreate", Category: "Microsoft Entra ID", Principal: "Worker Managed Identity (77777777-8888-9999-aaaa-bbbbbbbbbbbb)", Permission: "Groups Administrator (AU-Scoped)", Scope: "Administrative Unit Defender for Servers AU (44444444-aaaa-bbbb-cccc-555555555555)", RequiredFor: "All Modes (AU Group Lookup, Member Verification & Auto-Create)", Status: "Granted", Details: "Verified Administrative Unit 'Defender for Servers AU' access via AU-scoped Groups Administrator (no tenant-wide GroupMember.Read.All required).", Remediation: "" },
      { Id: "entra-group-write", Category: "Microsoft Entra ID", Principal: "Worker Managed Identity (77777777-8888-9999-aaaa-bbbbbbbbbbbb)", Permission: "Group Member Write (AU Admin / Group Owner)", Scope: "Administrative Unit (44444444-aaaa-bbbb-cccc-555555555555)", RequiredFor: "Enforce Mode (Current: Audit)", Status: "Granted", Details: "Ready for group membership additions via AU-scoped Groups Administrator on SYNC_ADMIN_UNIT_ID (Current SYNC_MODE=Audit).", Remediation: "" },
      { Id: "worker-infra-rbac", Category: "Azure RBAC", Principal: "Worker Managed Identity (77777777-8888-9999-aaaa-bbbbbbbbbbbb)", Permission: "Storage Table Data Contributor & Azure Service Bus Data Sender/Receiver", Scope: "Storage: syncdemostorage | Service Bus: arcgroupsync-bus-demo.servicebus.windows.net", RequiredFor: "All Modes (Queueing & State Persistence)", Status: "Granted", Details: "Verified Worker Managed Identity access to sync storage table 'syncdemostorage/machines' and Service Bus namespace 'arcgroupsync-bus-demo.servicebus.windows.net'.", Remediation: "" },
      { Id: "report-storage-reader", Category: "Report App & User", Principal: "Report Managed Identity (cccccccc-dddd-eeee-ffff-000000000000)", Permission: "Storage Table Data Reader", Scope: "Sync Storage Account (syncdemostorage/machines)", RequiredFor: "Web Portal (Read-Only Inventory & Logs)", Status: "Granted", Details: "Verified live: Report Managed Identity authenticated via Entra ID and read the 'syncdemostorage/machines' table.", Remediation: "" },
      { Id: "report-least-privilege", Category: "Report App & User", Principal: "Report Managed Identity (cccccccc-dddd-eeee-ffff-000000000000)", Permission: "Least-Privilege Isolation (No Graph or Queue Write)", Scope: "Report Function App (arcgroupsync-report-demo)", RequiredFor: "Security Architecture", Status: "Granted", Details: "Verified live: Report Function App has no Service Bus queue access and no Microsoft Graph write credentials.", Remediation: "" },
      { Id: "portal-user-role", Category: "Report App & User", Principal: "Signed-In Portal User", Permission: "Report.Reader (Entra App Role)", Scope: "Tenant (33333333-3333-3333-3333-333333333333)", RequiredFor: "Web Portal Access", Status: "Granted", Details: "Verified live on current HTTP request (X-MS-CLIENT-PRINCIPAL contains aad claim with role Report.Reader in configured tenant).", Remediation: "" }
    ]
  });
  if (normalizedPath === "/logs") return json(url.searchParams.has("cursor") ? {
    Items: [
      {
        Timestamp: now, FunctionName: "Inventory", TriggerReason: "Scheduled timer (NCRONTAB schedule)", Status: "Succeeded", Health: "Healthy",
        Message: "Inventory pass completed: queued 6 machine(s) [ARG Arc/VM rows=5, ARG VMSS rows=1, revisited=0 | Subs=11111111-1111-1111-1111-111111111111, MGs=mg-arc-servers, RGs=rg-servers,rg-legacy].",
        RunId: "demo-inventory-run",
        ScriptOutput: `[${now}][Inventory] === PowerShell execution started ===\n[${now}][ResourceGraph] Executing ARG query [Arc+NativeVMs] page=1\n{"Query":"Resources | extend type = tolower(type) | where type == 'microsoft.hybridcompute/machines' ..."}\n[${now}][ResourceGraph] ARG query [Arc+NativeVMs] page=1 returned 5 row(s)\n{"Data":[{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-servers/providers/Microsoft.HybridCompute/machines/server-windows-02"}]}`
      }
    ],
    Cursor: ""
  } : {
    Items: [
      {
        Timestamp: now, FunctionName: "Machine", TriggerReason: "Event Grid (MDE.Windows / MDE.Linux extension Succeeded)", Status: "Verified", Health: "Healthy",
        Message: "server-windows-02: status=Verified, membership=Present", RunId: "demo-run",
        ScriptOutput: `[${now}][MachineSync] === PowerShell execution started ===\n[${now}][MachineSync] Starting machine sync for ResourceId=/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-servers/providers/Microsoft.HybridCompute/machines/server-windows-02\n[${now}][MDEHunting] DeviceInfo query returned 1 row(s)\n{"Candidates":[{"DeviceId":"1111111111111111111111111111111111111111","DeviceName":"windows02.example.test","AadDeviceId":"44444444-4444-4444-4444-444444444444","OnboardingStatus":"Onboarded"}]}\n[${now}][MachineSync] Completed group evaluation for server-windows-02: status=Verified, membership=Present, groupName=MDfS-AWS-Windows-Passive-123456789012`
      },
      { Timestamp: now, FunctionName: "Machine", TriggerReason: "Scheduled inventory reconciliation", Status: "NoEntraDevice", Health: "Degraded", Message: "server-linux-10: status=NoEntraDevice, membership=Unknown (Synthetic demo: no antivirus assessment data was reported.)", RunId: "demo-linux-run" },
      { Timestamp: now, FunctionName: "ArcEvent", TriggerReason: "Event Grid (MDE.Windows / MDE.Linux extension Succeeded)", Status: "Succeeded", Health: "Healthy", Message: "Queued machine server-windows-02 after MDE extension Succeeded.", RunId: "demo-event-run" }
    ],
    Cursor: "older-logs"
  });
  if (normalizedPath === "/history") {
    const selected = [machine, activeMismatch, passiveMismatch, multiWrongGroup, linux, legacy].find(item => item.Key === url.searchParams.get("key"));
    if (!selected) { response.writeHead(404); return json({ error: "Unknown synthetic machine." }); }
    return json(url.searchParams.has("cursor") ?
      { Items: [{ Timestamp: now, Action: "StateChanged", RunId: "demo-older", TriggerReason: "Scheduled inventory reconciliation", LogMessage: `${selected.MachineName}: status=${selected.Status}, membership=${selected.Membership}`, ScriptOutput: `[${now}][MachineSync] === PowerShell execution started ===\n[${now}][MachineSync] Starting machine sync for ResourceId=${selected.ArcResourceId}\n[${now}][MachineSync] Completed group evaluation for ${selected.MachineName}: status=${selected.Status}, membership=${selected.Membership}`, State: { ...selected, MdeDeviceTags: [], AzureTags: {} } }], Cursor: "" } :
      { Items: [{ Timestamp: now, Action: "StateChanged", RunId: selected.RunId || "demo-run", TriggerReason: "Event Grid (MDE.Windows / MDE.Linux extension Succeeded)", LogMessage: `${selected.MachineName}: status=${selected.Status}, membership=${selected.Membership}`, ScriptOutput: `[${now}][MachineSync] === PowerShell execution started ===\n[${now}][MachineSync] Starting machine sync for ResourceId=${selected.ArcResourceId}\n[${now}][MDEHunting] DeviceInfo query returned 1 row(s)\n[${now}][MachineSync] Completed group evaluation for ${selected.MachineName}: status=${selected.Status}, membership=${selected.Membership}, groupName=${selected.GroupName}`, State: selected }], Cursor: "older" });
  }
  const name = normalizedPath.replace(/^\/+/, "") || "index.html";
  const types = { "index.html": "text/html", "coverage.html": "text/html", "permissions.html": "text/html", "docs.html": "text/html", "style.css": "text/css", "theme.js": "text/javascript", "app.js": "text/javascript", "coverage.js": "text/javascript", "permissions.js": "text/javascript", "docs.js": "text/javascript" };
  if (!Object.hasOwn(types, name)) { response.writeHead(404); response.end(); return; }
  response.setHeader("Content-Type", types[name]);
  response.setHeader("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
  let content = fs.readFileSync(path.join(root, name), "utf8");
  if (name === "index.html" || name === "coverage.html" || name === "permissions.html" || name === "docs.html") content = content.replace("<h1>", "<p class=\"eyebrow\">LOCAL DEMO - SYNTHETIC DATA ONLY</p><h1>");
  response.end(content);
});
server.listen(Number(process.env.PORT || 0), "127.0.0.1", () => {
  console.log(`Synthetic dashboard fixture: http://127.0.0.1:${server.address().port}/api/report/`);
});
