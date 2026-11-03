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

for (const method of ["MdeAadDeviceId", "GuestConfigurationIntuneDeviceId", "MicrosoftSenseHostnameAndOS"]) {
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
assert.match(view("2026-01-01T09:30:00Z").label, /did not start/);
assert.equal(view("2026-01-01T09:30:00Z").disabled, false);
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
}
testLiveControls().catch(error => { console.error(error); process.exitCode = 1; });
