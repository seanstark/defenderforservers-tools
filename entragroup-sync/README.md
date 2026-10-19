# Azure Arc to Entra Security Group Synchronization

Correlates Azure Arc-enabled servers (Windows & Linux) to Microsoft Defender for Endpoint (MDE) and Microsoft Entra ID devices, then adds verified devices to an assigned Entra security group. Includes an authenticated HTML portal for device inventory, correlation history, and Function App logs.

- **Default mode:** `Audit` (observes and reports `WouldAdd` without modifying groups).
- **Add-only safety:** Never deletes Entra devices or removes group members.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2Fentragroup-sync%2Fazuredeploy.json)

## Architecture

![Azure Arc to Entra Security Group Synchronization Architecture](infra/architecture.archify.svg)

1. **Discovery:** Runs on a 30-minute timer (`Inventory`) and on new Arc machine writes (`ArcEvent` via Event Grid), queueing machines to Azure Service Bus.
2. **Correlation:** Queries MDE Advanced Hunting (`DeviceInfo`, `DeviceNetworkInfo`, `DeviceTvmSecureConfigurationAssessment`) via Microsoft Graph and resolves the Entra device object ID.
3. **Group Sync:** Verifies or adds the Entra device to the target security group and writes state, history, and execution logs to Azure Table Storage.
4. **Portal:** A separate read-only Function App (protected by Entra Easy Auth + `Report.Reader` role) serves the inventory UI, history drawer, Function App telemetry, and full API/query reference.

## Quick Start

### 1. Create the Report App Registration

1. In Microsoft Entra ID **App registrations**, create a single-tenant app registration and a client secret.
2. Add an app role with value `Report.Reader` (for **Users/Groups**) and assign your report readers under **Enterprise applications**.

### 2. Deploy

Use the **Deploy to Azure** button above, or deploy infrastructure + Function packages + Event Grid subscriptions with `Deploy.ps1`:

```powershell
$secret = Read-Host 'Report client secret' -AsSecureString
$deployment = .\Deploy.ps1 `
    -ResourceGroupName 'rg-arc-entra-sync' `
    -NamePrefix 'arcgroupsync' `
    -SubscriptionIds @('<subscription-guid>') `
    -ManagementGroupIds @('<optional-mg-id>') `
    -ResourceGroupNames @('<optional-rg-name>') `
    -WindowsTargetGroupId '<windows-entra-group-guid>' `
    -LinuxTargetGroupId '<linux-entra-group-guid>' `
    -ReportClientId '<report-app-client-guid>' `
    -ReportClientSecret $secret
```

*(You can pass a single `-TargetGroupId` for all servers, or separate `-WindowsTargetGroupId` and `-LinuxTargetGroupId` parameters.)*

After deployment, add the returned `ReportRedirectUri` (`https://<report-app>.azurewebsites.net/.auth/login/aad/callback`) as a **Web** redirect URI on the app registration.

### 3. Grant Worker Permissions

```powershell
# Audit mode (read-only)
.\Grant-GraphPermissions.ps1 -WorkerPrincipalId $deployment.WorkerPrincipalId -Mode Audit

# Enforce mode (recommended least-privilege: read-only Graph roles + Owner on the target Windows/Linux groups)
.\Grant-GraphPermissions.ps1 `
    -WorkerPrincipalId $deployment.WorkerPrincipalId `
    -Mode Enforce `
    -AssignGroupOwner `
    -WindowsTargetGroupId '<windows-entra-group-guid>' `
    -LinuxTargetGroupId '<linux-entra-group-guid>'
```

To enable group additions after reviewing audit results, set `SYNC_MODE=Enforce` on the worker Function App (or redeploy with `-SyncMode Enforce`).

## Scope & Configuration Parameters

All active Function App parameters are also displayed live on the portal under **Function App status, health & execution logs**.

| Parameter / App Setting | Description |
| --- | --- |
| `SYNC_SUBSCRIPTION_IDS` (`-SubscriptionIds`) | Comma-separated subscription GUIDs to inventory and accept events from |
| `SYNC_MANAGEMENT_GROUP_IDS` (`-ManagementGroupIds`) | Comma-separated management group IDs (at least one subscription or management group is required) |
| `SYNC_RESOURCE_GROUP_NAMES` (`-ResourceGroupNames`) | Optional comma-separated resource group names to restrict discovery and events |
| `SYNC_GROUP_ID` (`-TargetGroupId`) | Default / fallback Entra ID security group object ID |
| `SYNC_WINDOWS_GROUP_ID` (`-WindowsTargetGroupId`) | Entra ID security group object ID for Windows servers (defaults to `SYNC_GROUP_ID` if omitted) |
| `SYNC_LINUX_GROUP_ID` (`-LinuxTargetGroupId`) | Entra ID security group object ID for Linux servers (defaults to `SYNC_GROUP_ID` if omitted) |
| `SYNC_MODE` (`-SyncMode`) | `Audit` (default) or `Enforce` |
| `SYNC_FRESHNESS_HOURS` (`-FreshnessHours`) | Maximum age of MDE evidence in hours (`1`–`168`, default `24`) |
| `SYNC_SCHEDULE` (`-Schedule`) | Timer NCRONTAB schedule (default `0 */30 * * * *`) |

### How Scope Parameters Combine

- **Management Groups + Subscriptions (`OR` / Union):** When both `SYNC_MANAGEMENT_GROUP_IDS` and `SYNC_SUBSCRIPTION_IDS` are set, a machine is in scope if its subscription is in `SYNC_SUBSCRIPTION_IDS` **or** belongs to any management group in `SYNC_MANAGEMENT_GROUP_IDS` (deduplicated per inventory pass).
- **Resource Groups (`AND` / Filter):** When `SYNC_RESOURCE_GROUP_NAMES` is set, it restricts discovery and Event Grid processing to only those resource group names within the allowed subscriptions/management groups.

| `SYNC_MANAGEMENT_GROUP_IDS` | `SYNC_SUBSCRIPTION_IDS` | `SYNC_RESOURCE_GROUP_NAMES` | Resulting Scope |
| --- | --- | --- | --- |
| Set (`mg-prod`) | Empty | Empty | All Arc machines in any subscription under `mg-prod` |
| Empty | Set (`sub-1`) | Set (`rg-arc`) | Only Arc machines in `rg-arc` within `sub-1` |
| Set (`mg-prod`) | Empty | Set (`rg-arc`) | Only Arc machines in `rg-arc` across any subscription under `mg-prod` |
| Set (`mg-prod`) | Set (`sub-extra`) | Set (`rg-arc`) | Only Arc machines in `rg-arc` inside `sub-extra` **or** any subscription under `mg-prod` |

## Local Validation & Preview

```powershell
# Run the 37 unit/regression tests
.\tests\Test-Solution.ps1

# Start the local synthetic preview portal
node .\tests\Serve-DashboardFixture.cjs
```
