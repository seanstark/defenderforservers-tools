# Azure Arc & Azure Virtual Machine to Entra Security Group Synchronization

Correlates Azure Arc-enabled servers and Azure Native Virtual Machines (Windows & Linux) to Microsoft Defender for Endpoint (MDE) and Microsoft Entra ID devices, then adds verified devices to an assigned Entra security group. Includes an authenticated HTML portal for device inventory, correlation history, and Function App logs.

- **Default mode:** `Audit` (observes and reports `WouldAdd` without modifying groups).
- **Add-only safety:** Never deletes Entra devices or removes group members.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2Fentragroup-sync%2Fazuredeploy.json)

## Architecture & Group Evaluation Workflow

![Azure Arc to Entra Security Group Synchronization Architecture](infra/architecture.archify.svg)

### Group Membership Evaluation Flow

![Machine Correlation and Entra ID Group Membership Evaluation Workflow](infra/evaluation.archify.svg)

| Gate | Evaluation Criteria | Pass Outcome | Fail / Stop Outcome (No Group Write) |
| --- | --- | --- | --- |
| **Gate 1: Scope Rule** | Resource is `HybridCompute/machines`, `Compute/virtualMachines`, `ClassicCompute/virtualMachines`, or `virtualMachineScaleSets/virtualMachines` (`!Compute.AKS`), and `(Sub in SUB_IDS OR MG_IDS) AND (RG_NAMES empty OR matching RG)` | Proceed to Gate 2 | Ignored / rejected outside scope |
| **Gate 2: ARM State** | Arc `properties.status == "Connected"` or Azure VM / VMSS `PowerState` is running (not `deallocated` or `stopped`) | Extract OS, `SubscriptionName`, and `AccountId` / `ProjectId` tags | `ArcMissing` (HTTP 404) or `ArcNotConnected` |
| **Gate 3: MDE Match** | Latest `DeviceInfo` row per `DeviceId` (7d) where `AzureResourceId =~ id`, `OnboardingStatus == "Onboarded"`, `MergedToDeviceId == ""`, `Timestamp <= SYNC_FRESHNESS_HOURS` (24h), **count == 1**, and valid GUID `AadDeviceId` | Proceed to Gate 4 with `AadDeviceId` | `PendingMde` (0), `StaleEvidence` (>24h), `Ambiguous` (>1), `NoEntraDevice`, or `InvalidEntraIdentifier` |
| **Gate 4: Entra Check** | `GET /devices?$filter=deviceId eq '{AadDeviceId}'` returns **count == 1** with `accountEnabled == true` | Extract Entra directory **object `id`** | `EntraDeviceNotFound` (0), `Ambiguous` (>1), or `EntraDeviceDisabled` |
| **Gate 5: Cloud, OS & Default Mode** | Resolves OS (`Windows` vs `Linux`), Cloud (`AWS` via `AccountId` tag, `GCP` via `ProjectId` tag, or `Azure` via `SubscriptionName`; AWS & GCP excluded from Azure Subscription groups), and `SYNC_DEFAULT_GROUP_MODE` (`Passive` by default, or `Active`) | Inspect existing group memberships (`GET /devices/{id}/memberOf`); if already in Active when default is Passive (or Passive when default is Active), do not add to counterpart group | `GroupNotConfigured` or `MissingCloudIdentifier` |
| **Gate 6: Per-Account Active/Passive Group & Flags** | **AWS Win / Lin:** `<Prefix>{Passive|Active}-<AccountId>`<br>**GCP Win / Lin:** `<Prefix>{Passive|Active}-<ProjectId>`<br>**Azure Win / Lin:** `<Prefix>{Passive|Active}-<SubscriptionName>` | `Audit` = `WouldAdd`; `Enforce` = `POST /members/$ref` + read-back (`Verified`); evaluates compliance flags (AV mode mismatch `Should be Active`, `Multiple groups`, `Wrong group`) | `GroupNotFound` or `Failed` |

1. **Discovery:** Runs on a 30-minute timer (`Inventory`) and in near-real-time via Event Grid (`ArcEvent`) when the `MDE.Windows` or `MDE.Linux` extension completes installation (`provisioningState == "Succeeded"`), querying/queueing `microsoft.hybridcompute/machines`, running non-AKS Azure Native VMs (`microsoft.compute/virtualmachines`, `microsoft.classiccompute/virtualmachines`), and running non-AKS Virtual Machine Scale Set instances (`microsoft.compute/virtualmachinescalesets/virtualmachines`) to Azure Service Bus.
2. **Correlation:** Queries MDE Advanced Hunting (`DeviceInfo`, `DeviceNetworkInfo`, `DeviceTvmSecureConfigurationAssessment`) via Microsoft Graph and resolves the Entra device object ID.
3. **Group Sync:** Verifies or adds the Entra device to the target security group and writes state, history, and execution logs to Azure Table Storage.
4. **Portal:** A separate read-only Function App (protected by Entra Easy Auth + `Report.Reader` role) serves the inventory UI, history drawer, Function App telemetry, and full API/query reference.

## Quick Start

### 1. Create the Report App Registration

1. In Microsoft Entra ID **App registrations**, create a single-tenant app registration and a client secret.
2. Add an app role with value `Report.Reader` (for **Users/Groups**) and assign your report readers under **Enterprise applications**.

### 2. Deploy

**Option A — Full End-to-End Deployment (`Deploy.ps1`, recommended):**
Deploys the ARM template, builds and publishes the `worker.zip` and `report.zip` PowerShell Function packages, and configures Event Grid subscriptions:

```powershell
$secret = Read-Host 'Report client secret' -AsSecureString
$deployment = .\Deploy.ps1 `
    -ResourceGroupName 'rg-arc-entra-sync' `
    -NamePrefix 'arcgroupsync' `
    -SubscriptionIds @('<subscription-guid>') `
    -ManagementGroupIds @('<optional-mg-id>') `
    -ResourceGroupNames @('<optional-rg-name>') `
    -AwsWindowsGroupPrefix 'MDfS-AWS-Windows-' `
    -AwsLinuxGroupPrefix 'MDfS-AWS-Linux-' `
    -GcpWindowsGroupPrefix 'MDfS-GCP-Windows-' `
    -GcpLinuxGroupPrefix 'MDfS-GCP-Linux-' `
    -AzureWindowsGroupPrefix 'MDfS-Azure-Windows-' `
    -AzureLinuxGroupPrefix 'MDfS-Azure-Linux-' `
    -ReportClientId '<report-app-client-guid>' `
    -ReportClientSecret $secret
```

**Option B — If you deployed using the "Deploy to Azure" button (`azuredeploy.json`):**
The ARM template creates the Azure infrastructure (`worker` and `report` Function Apps, Service Bus, Storage, and Easy Auth), and you then publish the PowerShell Function code packages (`worker.zip` and `report.zip`) to the two Function Apps:

```powershell
$packages = .\Build-Packages.ps1
az functionapp deployment source config-zip --resource-group '<resource-group>' --name '<worker-app-name>' --src ($packages | Where-Object Name -eq 'worker.zip').FullName
az functionapp deployment source config-zip --resource-group '<resource-group>' --name '<report-app-name>' --src ($packages | Where-Object Name -eq 'report.zip').FullName
```

After deployment:
1. Add the returned `ReportRedirectUri` (`https://<report-app>.azurewebsites.net/.auth/login/aad/callback`) as a **Web** redirect URI on the app registration.
2. Open the report portal directly at the root URL **`https://<report-app>.azurewebsites.net/`** (and **`https://<report-app>.azurewebsites.net/coverage.html`** for the Cloud & Group Report page).

### 3. Grant Worker Permissions (Azure `Reader` RBAC + Microsoft Graph)

#### A. Assign Azure `Reader` Role on Target Subscription(s) or Management Group(s)
The **Worker Function App's System-Assigned Managed Identity** **must** have the Azure **`Reader`** role assigned on your target **Subscription(s)** or **Management Group(s)** so it can query **Azure Resource Graph** (`Microsoft.ResourceGraph/resources`) and read Azure Arc, Native VM, and VMSS resources. *(Without `Reader` on the target scope, Azure Resource Graph returns 0 rows instead of an error.)*

- `Deploy.ps1` assigns `Reader` automatically via `infra/subscription.bicep`.
- If you deployed via the **Deploy to Azure** button (`azuredeploy.json`) or added additional subscriptions/management groups, assign `Reader` to the Worker Managed Identity:

```powershell
# Get the Worker Function App's System-Assigned Managed Identity Principal ID
$workerPrincipalId = az functionapp identity show --resource-group '<resource-group>' --name '<worker-app-name>' --query principalId -o tsv

# Option 1: Assign Reader at Subscription scope
az role assignment create --assignee-object-id $workerPrincipalId --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/subscriptions/<subscription-guid>'

# Option 2: Assign Reader at Management Group scope
az role assignment create --assignee-object-id $workerPrincipalId --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/providers/Microsoft.Management/managementGroups/<management-group-id>'
```

#### B. Grant Microsoft Graph & Entra Permissions

```powershell
# Audit mode (read-only)
.\Grant-GraphPermissions.ps1 -WorkerPrincipalId $workerPrincipalId -Mode Audit

# Enforce mode Option A (recommended with Administrative Unit auto-creation: read-only Graph roles + Groups Administrator scoped to the Administrative Unit)
.\Grant-GraphPermissions.ps1 `
    -WorkerPrincipalId $workerPrincipalId `
    -Mode Enforce `
    -AdminUnitId '<entra-administrative-unit-guid>'

# Enforce mode Option B (pre-created groups: read-only Graph roles + Owner on matching Cloud x OS groups)
.\Grant-GraphPermissions.ps1 `
    -WorkerPrincipalId $workerPrincipalId `
    -Mode Enforce `
    -AssignGroupOwner `
    -GroupNamePrefixes @('MDfS-AWS-Windows-', 'MDfS-AWS-Linux-', 'MDfS-GCP-Windows-', 'MDfS-GCP-Linux-', 'MDfS-Azure-Windows-', 'MDfS-Azure-Linux-')
```

To enable group additions after reviewing audit results, set `SYNC_MODE=Enforce` on the worker Function App (or redeploy with `-SyncMode Enforce`).

### Required Permissions & RBAC Table

| Principal / Component | Permission / Role | Type | Scope | Assigned By | Purpose |
| --- | --- | --- | --- | --- | --- |
| **Worker Managed Identity** | `Reader` | Azure RBAC | Target Subscription(s) (`SYNC_SUBSCRIPTION_IDS`) or Management Group(s) (`SYNC_MANAGEMENT_GROUP_IDS`) | `Deploy.ps1` (`subscription.bicep`) or manual `az role assignment create` | **Required** to query Azure Resource Graph (`Microsoft.ResourceGraph/resources`), resolve subscription display names, and read Azure Arc, Native VM, VMSS, and `MDE.Windows` / `MDE.Linux` extension resources. *(Without `Reader`, Resource Graph returns 0 rows.)* |
| **Worker Managed Identity** | `ThreatHunting.Read.All` | Microsoft Graph (Application) | Tenant | `Grant-GraphPermissions.ps1` | Run KQL Advanced Hunting queries (`POST /v1.0/security/runHuntingQuery`) against `DeviceInfo`, `DeviceNetworkInfo`, and `DeviceTvmSecureConfigurationAssessment` (`scid-2010`). |
| **Worker Managed Identity** | `Device.Read.All` | Microsoft Graph (Application) | Tenant | `Grant-GraphPermissions.ps1` | Resolve MDE `AadDeviceId` to the Entra device object `id` and inspect `accountEnabled`. |
| **Worker Managed Identity** *(Recommended: Administrative Unit Scoped)* | `Groups Administrator` (`fdd7a751-b60b-444a-984c-02652fe8fa1c`) | Microsoft Entra Directory Role | Administrative Unit (`/administrativeUnits/{SYNC_ADMIN_UNIT_ID}`) | `Grant-GraphPermissions.ps1 -AdminUnitId <guid>` | List and check groups inside the Administrative Unit (`/directory/administrativeUnits/{id}/members/microsoft.graph.group`), automatically create missing Active & Passive Cloud × OS security groups (`Enforce` mode), and verify/add device members without needing tenant-wide `GroupMember.Read.All`. |
| **Worker Managed Identity** *(Alternative when `SYNC_ADMIN_UNIT_ID` is not used)* | `GroupMember.Read.All` + **Group Owner** | Microsoft Graph (Application) + Entra Group Ownership | Tenant (Read) + Target Security Groups (Write) | `Grant-GraphPermissions.ps1 -AssignGroupOwner -GroupNamePrefixes @(...)` | Only needed when `SYNC_ADMIN_UNIT_ID` is not configured and pre-created tenant-wide groups are used instead. |
| **Worker Managed Identity** | `Storage Table Data Contributor`<br>`Azure Service Bus Data Sender`<br>`Azure Service Bus Data Receiver` | Azure RBAC | Sync Storage Account & Service Bus `machines` Queue | Automatic (`infra/main.bicep` / `azuredeploy.json`) | Queue per-machine work items and commit atomic state, change history (`h_`), and execution log (`log_`) rows. |
| **Worker & Report Managed Identities** | `Storage Blob Data Owner`<br>`Storage Queue Data Contributor`<br>`Storage Table Data Contributor` | Azure RBAC | Respective Host Storage Accounts (`worker<suffix>`, `report<suffix>`) | Automatic (`infra/main.bicep` / `azuredeploy.json`) | Identity-based `AzureWebJobsStorage` for the Azure Functions runtime (no storage shared keys used). |
| **Report Managed Identity** | `Storage Table Data Reader` | Azure RBAC | Sync Storage Account (`sync<suffix>`) | Automatic (`infra/main.bicep` / `azuredeploy.json`) | Read-only access to the `machines` table for serving the web portal. Has **no** Microsoft Graph permissions and **no** Service Bus access. |
| **Report Users (Human Sign-In)** | `Report.Reader` | Microsoft Entra App Role | Report App Registration / Enterprise Application | Entra Admin (`Enterprise applications` &rarr; `Users and groups`) | Enforced by App Service Authentication (Easy Auth) and verified on every HTML, JS, CSS, and JSON request. |

## Scope & Configuration Parameters

All active Function App parameters are also displayed live on the portal under **Function App status, health & execution logs**.

| Parameter / App Setting | Description |
| --- | --- |
| `SYNC_SUBSCRIPTION_IDS` (`-SubscriptionIds`) | Comma-separated subscription GUIDs to inventory and accept events from |
| `SYNC_MANAGEMENT_GROUP_IDS` (`-ManagementGroupIds`) | Comma-separated management group IDs (at least one subscription or management group is required) |
| `SYNC_RESOURCE_GROUP_NAMES` (`-ResourceGroupNames`) | Optional comma-separated resource group names to restrict discovery and events |
| `SYNC_DEFAULT_GROUP_MODE` (`-DefaultGroupMode`) | Global default target group mode (`Passive` by default, or `Active`). If set to `Passive` and a device is in an `Active` group, it is not added to `Passive` (and vice versa) |
| `SYNC_ADMIN_UNIT_ID` (`-AdminUnitId`) | Optional Microsoft Entra ID Administrative Unit GUID. When set (with AU-scoped `Groups Administrator` assigned to the worker), missing Active/Passive Cloud × OS groups are automatically created inside the Administrative Unit in `Enforce` mode |
| `SYNC_AUTO_CREATE_GROUPS` (`-AutoCreateGroups`) | Automatically create missing Active & Passive Cloud × OS groups inside `SYNC_ADMIN_UNIT_ID` in `Enforce` mode (defaults to `true` when `SYNC_ADMIN_UNIT_ID` is set) |
| `SYNC_AWS_WINDOWS_GROUP_PREFIX` (`-AwsWindowsGroupPrefix`) | Naming prefix for AWS Windows Active/Passive Entra ID security groups ending in the Arc `AccountId` tag (`<Prefix>{Passive|Active}-<AccountId>`) |
| `SYNC_AWS_LINUX_GROUP_PREFIX` (`-AwsLinuxGroupPrefix`) | Naming prefix for AWS Linux Active/Passive Entra ID security groups ending in the Arc `AccountId` tag (`<Prefix>{Passive|Active}-<AccountId>`) |
| `SYNC_GCP_WINDOWS_GROUP_PREFIX` (`-GcpWindowsGroupPrefix`) | Naming prefix for GCP Windows Active/Passive Entra ID security groups ending in the Arc `ProjectId` tag (`<Prefix>{Passive|Active}-<ProjectId>`) |
| `SYNC_GCP_LINUX_GROUP_PREFIX` (`-GcpLinuxGroupPrefix`) | Naming prefix for GCP Linux Active/Passive Entra ID security groups ending in the Arc `ProjectId` tag (`<Prefix>{Passive|Active}-<ProjectId>`) |
| `SYNC_AZURE_WINDOWS_GROUP_PREFIX` (`-AzureWindowsGroupPrefix`) | Naming prefix for Azure Windows Active/Passive Entra ID security groups ending in the Azure Subscription name (`<Prefix>{Passive|Active}-<SubscriptionName>`; AWS and GCP machines are excluded) |
| `SYNC_AZURE_LINUX_GROUP_PREFIX` (`-AzureLinuxGroupPrefix`) | Naming prefix for Azure Linux Active/Passive Entra ID security groups ending in the Azure Subscription name (`<Prefix>{Passive|Active}-<SubscriptionName>`; AWS and GCP machines are excluded) |
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

## Troubleshooting & Diagnostics

### 1. Application Insights & Log Analytics Trace Queries (KQL)

Every execution of `ScheduledInventory`, `EventTrigger`, and `MachineWorker` writes structured operational traces (including the exact Azure Resource Graph query, MDE Advanced Hunting KQL queries, row counts, and per-machine correlation outcomes) to Application Insights and persists the full transcript in the `ScriptOutput` column of `log_` rows in the `machines` storage table.

#### View Directly in the Web Portal
Open **04 Function App & logs &rarr; Function execution logs** on the Device Inventory page and click **`View script output`** under any log entry's `Details` column to expand the full PowerShell execution transcript, queries, and results inline.

#### Query in Application Insights (`Monitoring` &rarr; `Logs`)
```kusto
// 1. All PowerShell sync transcript output, queries, and per-machine correlation traces
traces
| where timestamp > ago(24h)
| where message startswith "[ScheduledInventory]"
     or message startswith "[EventTrigger]"
     or message startswith "[MachineWorker]"
     or operation_Name in ("ScheduledInventory", "EventTrigger", "MachineWorker", "Dashboard")
| project timestamp, operation_Name, severityLevel, message
| order by timestamp desc
```

```kusto
// 2. Inspect Azure Resource Graph & MDE Advanced Hunting queries and returned row counts
traces
| where timestamp > ago(24h)
| where message has_any ("ARG query:", "ARG page returned", "MDE query", "MDE DeviceInfo rows", "Completed:")
| project timestamp, operation_Name, message
| order by timestamp desc
```

```kusto
// 3. Find Function execution warnings, errors, or unhandled exceptions
union traces, exceptions
| where timestamp > ago(24h)
| where severityLevel >= 2 or itemType == "exception"
| project timestamp, itemType, operation_Name, severityLevel, message, outerMessage, details
| order by timestamp desc
```

#### Query in Log Analytics Workspace (`Logs` blade)
```kusto
// Equivalent query when running from the Log Analytics Workspace table schema
AppTraces
| where TimeGenerated > ago(24h)
| where Message startswith "[ScheduledInventory]"
     or Message startswith "[EventTrigger]"
     or Message startswith "[MachineWorker]"
     or OperationName in ("ScheduledInventory", "EventTrigger", "MachineWorker", "Dashboard")
| project TimeGenerated, OperationName, SeverityLevel, Message
| order by TimeGenerated desc
```

---

### 2. Common Status Codes, Flags & Remediation

| Symptom / Status | Cause | Resolution |
| --- | --- | --- |
| **`InventorySync` discovers `0` machines** (`Queued 0 machines across ...`) | The Worker Function App's System-Assigned Managed Identity lacks the Azure `Reader` role on the target Subscription(s) (`SYNC_SUBSCRIPTION_IDS`) or Management Group(s) (`SYNC_MANAGEMENT_GROUP_IDS`), or `SYNC_RESOURCE_GROUP_NAMES` does not match the machines' resource groups. | Assign the Azure `Reader` role to the Worker Managed Identity at the Subscription or Management Group scope (see [A. Assign Azure `Reader` Role](#a-assign-azure-reader-role-for-azure-resource-graph-discovery)) and check `SYNC_RESOURCE_GROUP_NAMES`. |
| **`NoMdeMatch`** | No onboarded MDE `DeviceInfo` record matched the Azure Resource ID (`MdeAzureVmId`) or `vmId` (`LoggedOnUsers` / `DeviceName`) within the 30-day lookback window. | Verify the `MDE.Windows` or `MDE.Linux` extension is installed and provisioned on the machine and that `OnboardingStatus == 'Onboarded'` in Defender for Endpoint. |
| **`StaleMde`** | The machine matched an MDE record, but its latest `DeviceInfo.Timestamp` is older than `SYNC_FRESHNESS_HOURS` (default `24` hours). | Check the MDE sensor health on the endpoint (`MdeSensorHealth`), or increase `SYNC_FRESHNESS_HOURS` (up to `168` hours). |
| **`AmbiguousMde`** | Multiple distinct MDE `DeviceId` records matched the same server within the freshness window. | Group changes are paused by design (`Add-Only` fail-closed safety) until duplicate MDE records age out past `SYNC_FRESHNESS_HOURS` or are offboarded/merged in Defender XDR. |
| **`NoEntraDevice`** | MDE `DeviceInfo` matched the server, but `AadDeviceId` is empty. | Ensure the server is Microsoft Entra joined / hybrid joined (or Arc-enabled server Entra identity is registered with MDE) so MDE reports `AadDeviceId`. |
| **`EntraDeviceNotFound`** | MDE reported an `AadDeviceId`, but `GET /v1.0/devices?$filter=deviceId eq '{AadDeviceId}'` returned no device object in Entra ID. | Verify the device has not been deleted in Microsoft Entra ID and belongs to the same Entra tenant. |
| **`EntraDeviceDisabled`** | The correlated Microsoft Entra device object has `accountEnabled == false`. | Re-enable the device in Microsoft Entra ID if the server is still active; disabled devices are never added to security groups. |
| **`MissingIdentifier`** | Missing cloud account/project identifier required to build the target group name (`AccountId` tag for AWS Arc machines, `ProjectId` tag for GCP Arc machines, or Subscription `displayName` for Azure machines). | Tag AWS Arc machines with `AccountId=<12-digit-account-id>`, tag GCP Arc machines with `ProjectId=<gcp-project-id>`, and ensure the Worker Managed Identity has `Reader` on the Azure Subscription. |
| **`GroupNotFound`** | The target Entra ID security group `<Prefix>{Passive\|Active}-<Identifier>` does not exist in Entra ID, and automatic group creation is not enabled. | Either pre-create the security group in Entra ID, or configure `SYNC_ADMIN_UNIT_ID` with `SYNC_AUTO_CREATE_GROUPS=true` and grant AU-scoped `Groups Administrator` via `Grant-GraphPermissions.ps1`. |
| **`WouldCreateGroupAndAdd`** | The target group does not exist yet, `SYNC_ADMIN_UNIT_ID` is configured, and the worker is running in `Audit` mode. | Review the target group name in the portal. When ready, set `SYNC_MODE=Enforce` so the worker creates the `Passive` and `Active` groups in the Administrative Unit and adds the device. |
| **Flag (`i` icon): `Should be Active`** | Device is in an `Active` group while MDE Antivirus mode (`scid-2010`) is `Passive`, or in a `Passive` group while MDE Antivirus mode is `Active`. | Hover over the `i` indicator in the `Entra ID Group` or `MDE antivirus mode` column to see the exact mismatch and move the device to the matching Active/Passive group or update its Defender AV configuration. |
| **Flag (`i` icon): Multiple or Wrong Groups** | Device is a member of more than one Cloud × OS group (`MemberGroups.length > 1`) or belongs to a group whose AWS Account, GCP Project, or Azure Subscription does not match the machine. | Hover over the `i` indicator in the `Entra ID Group` column to inspect all current Cloud × OS groups and remove stale group memberships in Microsoft Entra ID. |
| **Graph `403 Forbidden` in Worker Logs** | Missing Microsoft Graph application permissions, AU role assignment, or group ownership. | Re-run `.\Grant-GraphPermissions.ps1` for your chosen mode (`Audit`, `Enforce -AdminUnitId <guid>`, or `Enforce -AssignGroupOwner`). |
| **Portal `401` / `403` or Stale Data** | Signed-in user lacks the `Report.Reader` app role, or browser/server cache is serving a recent snapshot. | Assign the user/group the `Report.Reader` role on the Report Enterprise Application in Entra ID. Click **Refresh inventory** in the portal toolbar to bypass the 15s server cache and 30s browser cache (`?refresh=1`). |

## Local Validation & Preview

```powershell
# Run the 40 unit/regression tests
.\tests\Test-Solution.ps1

# Start the local synthetic preview portal
node .\tests\Serve-DashboardFixture.cjs
```
