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
