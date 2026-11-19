"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "report", "www", "app.js"), "utf8");
const prefix = source.slice(source.indexOf('  const byId'), source.indexOf('  const columns ='));
const hover = source.slice(source.indexOf('  function entraHoverSpec('), source.indexOf('  function groupHoverSpec('));
const context = vm.createContext({
  window: { location: { pathname: "/" } },
  document: { createElement: tag => ({ tag, textContent: "", className: "" }) },
  appendLink: (element, label) => { element.textContent = label; },
  deviceLink: () => "",
  osNode: value => value
});
vm.runInContext(`${prefix}\n${hover}`, context);

for (const method of ["MdeAadDeviceId", "GuestConfigurationIntuneDeviceId", "MdeSyntheticDeviceId", "MicrosoftSenseHostnameAndOS"]) {
  context.machine = {
    EntraObjectId: "55555555-5555-5555-5555-555555555555",
    EntraDeviceId: "349bf055-2d6c-6d05-3522-c4ee05018601",
    EntraCorrelationPath: method,
    EntraDiagnostic: "Successfully resolved Entra device.",
    Status: "Failed",
    Error: "HTTP 403 during group lookup."
  };
  const rows = vm.runInContext("entraHoverSpec(machine)[1]", context);
  const row = label => rows.find(([key]) => key === label)[1];
  assert.equal(row("Correlation Status").textContent, "Correlated");
  assert.equal(row("Correlation Status").className, "badge good");
  assert.equal(row("Correlation Details"), context.machine.EntraDiagnostic);
  assert.equal(row("Sync Status").textContent, "Failed");
  assert.equal(row("Sync Status").className, "badge bad");
  assert.equal(row("Sync Error"), context.machine.Error);
}
for (const status of ["Verified", "WouldAdd", "Matched", "GroupNotFound", "MissingCloudIdentifier", "GroupNotConfigured"]) {
  context.machine = { EntraDeviceId: "device-id", Status: status };
  assert.equal(vm.runInContext("hasEntraCorrelation(machine)", context), true);
}
for (const status of ["Failed", "PendingMde", "Ambiguous", "EntraDeviceNotFound", "NoEntraDevice", "StaleEvidence"]) {
  context.machine = { EntraDeviceId: "unverified-device-id", Status: status };
  assert.equal(vm.runInContext("hasEntraCorrelation(machine)", context), false);
  const rows = vm.runInContext("entraHoverSpec(machine)[1]", context);
  assert.equal(rows.find(([key]) => key === "Correlation Status")[1].textContent, "Not correlated");
}
context.machine = { EntraObjectId: "disabled-device-object", Status: "EntraDeviceDisabled" };
assert.equal(vm.runInContext("hasEntraCorrelation(machine)", context), true);
assert.match(source, /\["Correlation", correlationBadge\(machine\)\]/);
assert.match(source, /id: "Status", label: "Sync status"/);
console.log("PASS Dashboard separates identity correlation from sync failures.");

context.machine = {
  Status: "Ambiguous", EntraCorrelationPath: "MicrosoftSenseAmbiguous",
  MdeDeviceId: "current-mde", MdeDeviceName: "server01", MdeSensorHealth: "Active",
  MdeLastSeen: "2026-11-05T12:00:00Z", MdeMergedDeviceIds: ["retired-mde"],
  MdeReonboardingDetected: true
};
const reonboardingRows = vm.runInContext("entraHoverSpec(machine)[1]", context);
assert.match(reonboardingRows.find(([key]) => key === "Why Not Found")[1], /re-onboarding.*ID/i);
assert.equal(reonboardingRows.find(([key]) => key === "MDE Device ID")[1], "current-mde");
assert.equal(reonboardingRows.find(([key]) => key === "MDE Merged Device IDs")[1], "retired-mde");
assert.match(reonboardingRows.find(([key]) => key === "MDE Sensor / Last Refreshed")[1], /^Active/);
assert.match(reonboardingRows.find(([key]) => key === "Re-onboarding Detected")[1], /^Yes/);
console.log("PASS Correlation details explain re-onboarding blocks and show selected/merged MDE evidence.");

for (const [file, inputName] of [["app.js", "health"], ["coverage.js", "latestHealth"], ["permissions.js", "data"]]) {
  const script = fs.readFileSync(path.join(__dirname, "..", "report", "www", file), "utf8");
  const start = script.indexOf("    const syncMode =");
  const modes = script.slice(start, script.indexOf("    const syncBadge =", start));
  for (const [syncMode, defaultGroupMode] of [["Enforce", "Active"], ["Audit", "Passive"]]) {
    const input = file === "permissions.js" ? { SyncMode: syncMode, DefaultGroupMode: defaultGroupMode } : {
      SyncMode: "stale", DefaultGroupMode: "stale",
      Parameters: { SYNC_MODE: syncMode, SYNC_DEFAULT_GROUP_MODE: defaultGroupMode }
    };
    const result = vm.runInNewContext(`${modes}\n({syncMode, defaultGroupMode})`, { [inputName]: input });
    assert.equal(result.syncMode, syncMode, file);
    assert.equal(result.defaultGroupMode, defaultGroupMode, file);
  }
  const unknown = vm.runInNewContext(`${modes}\n({syncMode, defaultGroupMode})`, { [inputName]: {} });
  assert.equal(unknown.syncMode, "Unknown", file);
  assert.equal(unknown.defaultGroupMode, "Unknown", file);
}
console.log("PASS All report pages use authoritative worker modes and show Unknown without telemetry.");

const summaryStart = source.indexOf("  function renderSummary()");
const stats = source.slice(source.indexOf("    const stats = [", summaryStart), source.indexOf('    byId("summary").replaceChildren', summaryStart));
vm.runInContext(`${stats}\nglobalThis.notInGroupFilter = stats.find(([key]) => key === "not-in-group")[2];`, context);
for (const membership of ["Absent", "Unknown", "GroupNotFound", "MissingIdentifier", "NotConfigured", "", undefined]) {
  const machine = {
    Membership: membership, Status: "Failed", GroupId: "target-group", GroupName: "Configured target",
    GroupIds: [], GroupNames: [], MemberGroups: []
  };
  assert.equal(context.notInGroupFilter(machine), true, `${membership}: target metadata must not count as membership.`);
}
assert.equal(context.notInGroupFilter({ Status: "NoEntraDevice" }), true);
for (const machine of [
  { Membership: "Present" },
  { Membership: "Unknown", MemberGroups: [{ Id: "observed-group", DisplayName: "Observed member group" }] },
  { Membership: "Unknown", GroupIds: ["observed-group"] },
  { Membership: "Unknown", GroupNames: ["Observed member group"] },
  { Membership: "Present", GroupFlags: ["Wrong group", "Multiple groups"] }
]) {
  assert.equal(context.notInGroupFilter(machine), false, "Observed members must not appear in Not in group.");
}
assert.equal(context.notInGroupFilter({ MemberGroups: [null, {}], GroupIds: [null, ""], GroupNames: [] }), true);
console.log("PASS Not in group includes unverified devices without mistaking target metadata for membership.");

const controls = source.slice(source.indexOf("  let syncState ="), source.indexOf("  async function get("));
const elements = new Map();
context.document.getElementById = id => {
  if (!elements.has(id)) elements.set(id, { textContent: "", hidden: true, disabled: true });
  return elements.get(id);
};
context.sessionStorage = { getItem: () => null, setItem: () => {} };
context.AbortSignal = AbortSignal;
context.console = console;
vm.runInContext(controls, context);
context.job = { Status: "Succeeded", IsRunning: false, CanStartSync: true, StartedAt: "2026-01-01T10:00:00Z", CompletedAt: "2026-01-01T10:02:00Z" };
const view = requestedAt => {
  context.requestedAt = requestedAt;
  return vm.runInContext('inventorySyncView(job, requestedAt, Date.parse("2026-01-01T10:05:00Z"))', context);
};
assert.equal(view("").disabled, false);
assert.match(view("").label, /idle.*succeeded/);
assert.match(view("").details, /device processing may still be running/);
assert.equal(view("2026-01-01T10:04:00Z").disabled, true);
assert.match(view("2026-01-01T10:04:00Z").label, /waiting for worker/);
assert.equal(view("2026-01-01T09:59:00Z").disabled, false);
context.job.StartedAt = "";
assert.match(view("2026-01-01T08:30:00Z").label, /did not start/);
assert.equal(view("2026-01-01T08:30:00Z").disabled, false);
context.job.IsRunning = true;
assert.equal(view("").disabled, true);
assert.match(view("").label, /running/);
context.job.IsRunning = false;
context.job.CanStartSync = false;
assert.equal(view("").disabled, true);
context.job = null;
assert.equal(view("").disabled, true);
for (const status of ["Failed", "Interrupted"]) {
  context.job = { Status: status, CanStartSync: true, Message: "Check worker logs." };
  assert.match(view("").label, new RegExp(status.toLowerCase()));
}

async function testLiveControls() {
  const jsonResponse = (status, data) => new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
  let requests = 0;
  context.fetch = async (url, options) => {
    requests++;
    assert.equal(url, "/sync-status");
    assert.equal(options.cache, "no-store");
    return jsonResponse(200, { Status: "Unknown", IsRunning: false, CanStartSync: true });
  };
  await vm.runInContext("pollInventorySync()", context);
  assert.equal(elements.get("start-sync").disabled, false);
  context.fetch = async (url, options) => {
    requests++;
    assert.equal(url, "/sync");
    assert.equal(options.method, "POST");
    assert.equal(options.headers["X-Sync-Action"], "start");
    assert.equal(options.referrerPolicy, "same-origin");
    return jsonResponse(202, { RequestId: "request-1", RequestedAt: new Date().toISOString() });
  };
  await vm.runInContext("startInventorySync()", context);
  assert.equal(elements.get("start-sync").disabled, true);
  assert.match(elements.get("sync-status").textContent, /waiting for worker/);
  await vm.runInContext("startInventorySync()", context);
  assert.equal(requests, 2, "Queued request must suppress repeat clicks.");
  context.fetch = async () => { throw new Error("Status endpoint unavailable"); };
  await vm.runInContext("pollInventorySync()", context);
  assert.equal(elements.get("start-sync").disabled, true);
  assert.equal(elements.get("sync-error").hidden, false);
  assert.match(elements.get("sync-status").textContent, /unavailable/);
  assert.match(elements.get("sync-error").textContent, /endpoint unavailable/);
  assert.match(elements.get("sync-access").textContent, /Report.Reader/);
  console.log("PASS Dashboard live status, reader access, queued requests, and failure handling.");

  for (const [status, type, body, expected] of [
    [403, "text/plain", "You do not have permission to view this directory or page.", /HTTP 403.*You do not have permission/],
    [403, "text/html", "<html>You do not have permission</html>", /HTTP 403.*App Service authentication/],
    [401, "text/plain", "Sign-in required.", /HTTP 401.*Sign-in required/],
    [405, "application/json", '{"error":"Method not allowed."}', /HTTP 405.*Method not allowed/],
    [409, "application/json", '{"error":"An inventory sync is already running."}', /HTTP 409.*already running/],
    [503, "application/json", '{"error":"Manual sync is not configured."}', /HTTP 503.*not configured/],
    [502, "text/html", "<html>Bad gateway</html>", /HTTP 502/],
    [500, "application/json", "invalid JSON", /HTTP 500.*invalid JSON error response/],
    [202, "application/json", "invalid JSON", /invalid JSON \(HTTP 202\)/],
    [202, "text/html", "<html>Sign in</html>", /non-JSON \(HTTP 202\)/],
    [202, "application/json", "null", /Unexpected sync response/],
    [200, "text/html", "<html>Sign in</html>", /non-JSON \(HTTP 200\)/]
  ]) {
    vm.runInContext('pendingSync = ""; syncStatusError = ""; syncState = { Status: "Unknown", IsRunning: false, CanStartSync: true };', context);
    context.fetch = async () => new Response(body, { status, headers: { "Content-Type": type } });
    await vm.runInContext("startInventorySync()", context);
    const message = elements.get("sync-error").textContent;
    assert.equal(elements.get("sync-error").hidden, false);
    assert.match(message, expected);
    assert.doesNotMatch(message, /Unexpected token/);
    if (status >= 400 && status < 500) assert.doesNotMatch(message, /Delivery could not be confirmed/);
    assert.equal(vm.runInContext("pendingSync", context), "", "A rejected/malformed response must not be recorded as accepted.");
    context.fetch = async () => jsonResponse(200, { Status: "Unknown", IsRunning: false, CanStartSync: true });
    await vm.runInContext("pollInventorySync()", context);
    assert.equal(elements.get("sync-error").hidden, false, "Successful status polling must not erase a sync request failure.");
    assert.equal(elements.get("sync-error").textContent, message);
  }
  context.fetch = async () => jsonResponse(200, {
    Status: "Unknown", IsRunning: false, CanStartSync: false, StartSyncUnavailableReason: "Manual sync is not configured. Deploy the updated infrastructure."
  });
  await vm.runInContext("pollInventorySync()", context);
  assert.equal(elements.get("start-sync").disabled, true);
  assert.match(elements.get("sync-access").textContent, /updated infrastructure/);
  context.fetch = async () => new Response("You do not have permission", { status: 403, headers: { "Content-Type": "text/plain" } });
  await vm.runInContext("pollInventorySync()", context);
  assert.match(elements.get("sync-error").textContent, /Live sync status failed \(HTTP 403\)/);
  assert.doesNotMatch(elements.get("sync-error").textContent, /Unexpected token/);
  console.log("PASS Sync handles plain-text/HTML rejection, malformed JSON, missing configuration, and persistent errors.");

  for (const htmlFile of ["index.html", "coverage.html", "permissions.html", "docs.html"]) {
    const html = fs.readFileSync(path.join(__dirname, "..", "report", "www", htmlFile), "utf8");
    assert.match(html, />02<\/span>Reports<\/a>/, `${htmlFile} must use 'Reports' navigation label`);
    assert.match(html, /#coverage-mde-summary">Overview<\/a>/, `${htmlFile} must use 'Overview' sub-navigation label`);
    assert.match(html, /#coverage-groups">Entra ID Group Summary<\/a>/, `${htmlFile} must use 'Entra ID Group Summary' sub-navigation label`);
    assert.match(html, /class="section-card-tabs"/, `${htmlFile} must have card tabs for its sections`);
    assert.match(html, /class="section-card-tab is-active"[^>]*data-section-tab=/, `${htmlFile} must have an active default card tab`);
    assert.doesNotMatch(html, /Cloud &amp; group report/i, `${htmlFile} must not use old 'Cloud & group report' label`);
  }
  const indexHtml = fs.readFileSync(path.join(__dirname, "..", "report", "www", "index.html"), "utf8");
  assert.match(indexHtml, /<select id="aws-account"><option value="">All AWS accounts<\/option><\/select>/);
  const awsHelpers = source.slice(source.indexOf("  function isNativeAzureMachine("), source.indexOf("  function awsIconNode("));
  context.URLSearchParams = URLSearchParams;
  context.Set = Set;
  vm.runInContext(awsHelpers, context);
  assert.equal(vm.runInContext('awsAccountFor({ ArcResourceId: "/subscriptions/1/resourceGroups/rg/providers/Microsoft.HybridCompute/machines/m1", AzureTags: { AccountId: "123456789012" } })', context), "123456789012");
  assert.equal(vm.runInContext('awsAccountFor({ ArcResourceId: "/subscriptions/1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1", AzureTags: { AccountId: "123456789012" } })', context), "");
  const drill = vm.runInContext('parseReportDrillFilter("?scopeType=AWS&scopeId=123456789012&mde=Onboarded&arc=Disconnected")', context);
  assert.equal(drill.matches({ CloudGroupType: "AWS", CloudIdentifier: "123456789012", MdeOnboardingStatus: "Onboarded", ArcStatus: "Disconnected" }), true);
  assert.equal(drill.matches({ CloudGroupType: "AWS", CloudIdentifier: "123456789012", MdeOnboardingStatus: "Onboarded", ArcStatus: "Connected" }), false);
  const corrDrill = vm.runInContext('parseReportDrillFilter("?mg=mg-prod&corr=Correlated")', context);
  assert.equal(corrDrill.matches({ ManagementGroup: "mg-prod", EntraObjectId: "obj-1", Status: "Verified" }), true);
  assert.equal(corrDrill.matches({ ManagementGroup: "mg-prod", EntraObjectId: "", Status: "NoEntraDevice" }), false);
  const bothGroupsDrill = vm.runInContext('parseReportDrillFilter("?groupFilter=BothActiveAndPassive")', context);
  assert.equal(bothGroupsDrill.matches({ Membership: "Present", MemberGroups: [{ DisplayName: "dfs-aws-1-windows-active", GroupMode: "Active" }, { DisplayName: "dfs-aws-1-windows-passive", GroupMode: "Passive" }] }), true);
  assert.equal(bothGroupsDrill.matches({ Membership: "Present", MemberGroups: [{ DisplayName: "dfs-aws-1-windows-active", GroupMode: "Active" }] }), false);
  const passiveMdeActiveDrill = vm.runInContext('parseReportDrillFilter("?groupFilter=PassiveGroupMdeActive")', context);
  assert.equal(passiveMdeActiveDrill.matches({ Membership: "Present", MemberGroups: [{ DisplayName: "dfs-aws-1-windows-passive", GroupMode: "Passive" }], MdeAntivirusMode: "Active" }), true);
  assert.equal(passiveMdeActiveDrill.matches({ Membership: "Present", MemberGroups: [{ DisplayName: "dfs-aws-1-windows-passive", GroupMode: "Passive" }], MdeAntivirusMode: "Passive" }), false);
  const activeMdePassiveDrill = vm.runInContext('parseReportDrillFilter("?groupFilter=ActiveGroupMdePassive")', context);
  assert.equal(activeMdePassiveDrill.matches({ Membership: "Present", MemberGroups: [{ DisplayName: "dfs-aws-1-windows-active", GroupMode: "Active" }], MdeAntivirusMode: "Passive" }), true);

  const coverageHtml = fs.readFileSync(path.join(__dirname, "..", "report", "www", "coverage.html"), "utf8");
  assert.match(coverageHtml, /id="coverage-mde-summary"/);
  assert.match(coverageHtml, /Overview — Servers by AWS Account, GCP Project, Azure Subscription &amp; Azure Management Group/);
  assert.match(coverageHtml, /<th scope="col">MDE Onboarded<\/th>/);
  assert.match(coverageHtml, /<th scope="col">MDE Sensor Health<\/th>/);
  assert.match(coverageHtml, /<th scope="col">Correlated<\/th>/);
  assert.match(coverageHtml, /<th scope="col">Not Correlated<\/th>/);
  assert.match(coverageHtml, /<th scope="col">Active Mode<\/th>/);
  assert.match(coverageHtml, /<th scope="col">Passive Mode<\/th>/);
  assert.match(coverageHtml, /<th scope="col">MDE Onboarded \(Arc Disconnected\)<\/th>/);
  assert.doesNotMatch(coverageHtml, /<th[^>]*>#/, "Overview and Report tables must not have '#' in column names");
  assert.match(coverageHtml, /<h2 id="coverage-groups-heading">Entra ID Group Summary<\/h2>/);
  assert.match(coverageHtml, /<th scope="col">Both Active &amp; Passive<\/th>/);
  assert.match(coverageHtml, /<th scope="col">Passive Group \(MDE Active\)<\/th>/);
  assert.match(coverageHtml, /<th scope="col">Active Group \(MDE Passive\)<\/th>/);
  assert.match(coverageHtml, /id="coverage-group-members-body"/);
  assert.match(source, /"MdeOnboardingStatus",\s*"MdeSensorHealth",\s*"MdeAntivirusMode"/);

  const coverageSource = fs.readFileSync(path.join(__dirname, "..", "report", "www", "coverage.js"), "utf8");
  assert.match(coverageSource, /inventoryLinkCell\(String\(r\.TotalServers\)/);
  assert.match(coverageSource, /inventoryLinkCell\(String\(r\.Correlated\), \{ \.\.\.baseParams, corr: "Correlated" \}\)/);
  assert.match(coverageSource, /inventoryLinkCell\(String\(r\.NotCorrelated\), \{ \.\.\.baseParams, corr: "NotCorrelated" \}\)/);
  assert.match(coverageSource, /renderGroupMembersTable\(g\)/);
  const buildSlice = coverageSource.slice(coverageSource.indexOf("  function resolveMachineCloudScope("), coverageSource.indexOf("  function renderGroupMembersTable("));
  const covCtx = vm.createContext({
    collator: new Intl.Collator(undefined, { numeric: true, sensitivity: "base" }),
    Map, Set, Array, String
  });
  vm.runInContext(buildSlice, covCtx);
  covCtx.sampleItems = [
    {
      MachineName: "aws-srv-1", CloudGroupType: "AWS", CloudIdentifier: "123456789012", ManagementGroup: "mg-prod",
      MdeOnboardingStatus: "Onboarded", MdeSensorHealth: "Active", MdeAntivirusMode: "Active", ArcStatus: "Connected",
      MdeDeviceId: "m1", EntraDeviceId: "e1", Status: "Verified", Membership: "Present",
      MemberGroups: [
        { Id: "g-pass", DisplayName: "dfs-aws-123456789012-windows-passive", CloudType: "AWS", OSCategory: "Windows", GroupMode: "Passive", CloudIdentifier: "123456789012" },
        { Id: "g-act", DisplayName: "dfs-aws-123456789012-windows-active", CloudType: "AWS", OSCategory: "Windows", GroupMode: "Active", CloudIdentifier: "123456789012" }
      ]
    },
    {
      MachineName: "aws-srv-2", CloudGroupType: "AWS", CloudIdentifier: "123456789012", ManagementGroup: "mg-prod",
      MdeOnboardingStatus: "Onboarded", MdeSensorHealth: "Inactive", MdeAntivirusMode: "Passive", ArcStatus: "Disconnected",
      MdeDeviceId: "m2", EntraDeviceId: "e2", Status: "Verified", Membership: "Present",
      MemberGroups: [
        { Id: "g-act", DisplayName: "dfs-aws-123456789012-windows-active", CloudType: "AWS", OSCategory: "Windows", GroupMode: "Active", CloudIdentifier: "123456789012" }
      ]
    },
    { CloudGroupType: "GCP", CloudIdentifier: "gcp-proj-1", ManagementGroup: "mg-prod", MdeOnboardingStatus: "Onboarded", MdeSensorHealth: "Inactive", MdeAntivirusMode: "Active", ArcStatus: "Disconnected", MdeDeviceId: "m3", EntraDeviceId: "", Status: "NoEntraDevice" },
    { CloudGroupType: "Azure", CloudIdentifier: "Prod Sub", SubscriptionId: "sub-1", ManagementGroup: "mg-prod", MdeOnboardingStatus: "CanBeOnboarded", MdeSensorHealth: "NoSensorData", MdeAntivirusMode: "", ArcStatus: "Disconnected" }
  ];
  const built = vm.runInContext("buildCoverageData(sampleItems, {})", covCtx);
  assert.equal(built.groupSummary.inActiveGroups, 2);
  assert.equal(built.groupSummary.inPassiveGroups, 1);
  assert.equal(built.groupSummary.inBothActiveAndPassive, 1);
  assert.equal(built.groupSummary.passiveGroupMdeActive, 1);
  assert.equal(built.groupSummary.activeGroupMdePassive, 1);
  const actGrp = built.groups.find(g => g.DisplayName === "dfs-aws-123456789012-windows-active");
  assert.equal(actGrp.MemberCount, 2);
  assert.equal(actGrp.Members.length, 2);
  assert.equal(actGrp.BothActiveAndPassiveCount, 1);
  assert.equal(actGrp.ActiveGroupMdePassiveCount, 1);
  const passGrp = built.groups.find(g => g.DisplayName === "dfs-aws-123456789012-windows-passive");
  assert.equal(passGrp.MemberCount, 1);
  assert.equal(passGrp.Members.length, 1);
  assert.equal(passGrp.BothActiveAndPassiveCount, 1);
  assert.equal(passGrp.PassiveGroupMdeActiveCount, 1);
  const awsScope = built.scopes.find(s => s.CloudType === "AWS" && s.CloudIdentifier === "123456789012");
  assert.equal(awsScope.TotalServers, 2);
  assert.equal(awsScope.OnboardedToMde, 2);
  assert.equal(awsScope.SensorActive, 1);
  assert.equal(awsScope.SensorInactive, 1);
  assert.equal(awsScope.SensorOther, 0);
  assert.equal(awsScope.Correlated, 2);
  assert.equal(awsScope.NotCorrelated, 0);
  assert.equal(awsScope.ActiveMode, 1);
  assert.equal(awsScope.PassiveMode, 1);
  assert.equal(awsScope.OnboardedArcDisconnected, 1);
  const gcpScope = built.scopes.find(s => s.CloudType === "GCP" && s.CloudIdentifier === "gcp-proj-1");
  assert.equal(gcpScope.OnboardedToMde, 1);
  assert.equal(gcpScope.SensorInactive, 1);
  assert.equal(gcpScope.Correlated, 0);
  assert.equal(gcpScope.NotCorrelated, 1);
  assert.equal(gcpScope.OnboardedArcDisconnected, 1);
  const azScope = built.scopes.find(s => s.CloudType === "Azure" && s.CloudIdentifier === "Prod Sub");
  assert.equal(azScope.OnboardedToMde, 0);
  assert.equal(azScope.SensorOther, 1);
  assert.equal(azScope.Correlated, 0);
  assert.equal(azScope.NotCorrelated, 1);
  assert.equal(azScope.OnboardedArcDisconnected, 0);
  const mgRow = built.managementGroups.find(m => m.CloudIdentifier === "mg-prod");
  assert.equal(mgRow.TotalServers, 4);
  assert.equal(mgRow.OnboardedToMde, 3);
  assert.equal(mgRow.SensorActive, 1);
  assert.equal(mgRow.SensorInactive, 2);
  assert.equal(mgRow.SensorOther, 1);
  assert.equal(mgRow.Correlated, 2);
  assert.equal(mgRow.NotCorrelated, 2);
  assert.equal(mgRow.ActiveMode, 2);
  assert.equal(mgRow.PassiveMode, 1);
  assert.equal(mgRow.OnboardedArcDisconnected, 2);

  const transcriptHelpers = source.slice(source.indexOf("  function classifyTranscriptLine("), source.indexOf("  function openScriptOutputModal("));
  vm.runInContext(transcriptHelpers, context);
  assert.equal(vm.runInContext('classifyTranscriptLine("[2026-11-18T00:00:00Z][Error] Sync failed: HTTP 403")', context), "error");
  assert.equal(vm.runInContext('classifyTranscriptLine("[2026-11-18T00:00:00Z][Warning] Inventory enrichment failed")', context), "warn");
  assert.equal(vm.runInContext('classifyTranscriptLine("[2026-11-18T00:00:00Z][Inventory] === PowerShell execution started ===")', context), "header");
  const issues = vm.runInContext('summarizeTranscriptIssues("[Error] HTTP 500\\n[Warning] StaleEvidence\\nNormal line")', context);
  assert.equal(issues.errors.length, 1);
  assert.equal(issues.warnings.length, 1);
  console.log("PASS AWS Account inventory filter, Reports rename, and MDE/Active/Passive/Arc-disconnected report summary.");
}
testLiveControls().catch(error => { console.error(error); process.exitCode = 1; });
