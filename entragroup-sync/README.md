# Cloud Server Correlation — Azure Arc & Virtual Machine to Entra ID Security Group Sync

Automatically discovers Azure Arc-enabled servers (AWS, GCP, on-premises), Azure Virtual Machines, and Virtual Machine Scale Set (VMSS) instances, correlates them through Microsoft Defender for Endpoint (MDE) and Azure Machine Configuration to Microsoft Entra ID device objects, and assigns verified devices to per-account Cloud × OS × Active/Passive Entra ID security groups. Includes an authenticated **Cloud Server Correlation** web portal for device inventory, cloud/group coverage, permissions validation, and execution logs.

- **Default mode:** `Audit` (observes and reports `WouldAdd` without modifying groups).
- **Add-only safety:** Never deletes Entra devices or removes group members.

---

## Step-by-Step Deployment Guide

Follow these **6 straightforward steps** to deploy the solution end-to-end.

### Step 1: Create the Entra ID Administrative Unit & Report App Registration

1. **Create an Entra ID Administrative Unit (Recommended):**
   - In the [Microsoft Entra admin center](https://entra.microsoft.com) &rarr; **Identity** &rarr; **Roles & admins** &rarr; **Admin units**, create a new Administrative Unit (e.g., `Defender for Servers Groups`) and copy its **Object ID** (`SYNC_ADMIN_UNIT_ID`).
   - The Function App will only query, create, and manage Cloud × OS security groups inside this Administrative Unit.
2. **Create the Web Portal App Registration:**
   - Go to **Identity** &rarr; **Applications** &rarr; **App registrations** &rarr; **New registration** (Single tenant).
   - Under **Certificates & secrets**, create a new **Client secret** and copy its **Value**.
   - Under **App roles** &rarr; **Create app role**:
     - **Display name:** `Report Reader`
     - **Allowed member types:** `Users/Groups`
     - **Value:** `Report.Reader`
   - Go to **Enterprise applications** &rarr; select your app &rarr; **Users and groups**, and assign your users/groups to the **`Report.Reader`** role.

---

### Step 2: Deploy the Azure Machine Configuration Policies (MDE Entra ID Device ID)

For servers managed via MDE Security Settings Management (`MicrosoftSense` / MDE Attach) that are not domain/Entra-joined, these Azure Machine Configuration policies read the local MDE `intuneDeviceId` (`HKLM\SOFTWARE\Microsoft\SenseCM\EnrollmentPayload` on Windows and `/var/opt/microsoft/mdatp/wdavstate` on Linux) and report it to Azure Resource Graph (`GuestConfigurationResources`).

1. **Deploy Both Windows & Linux Policy Definitions Together (Recommended):**

   | Policy Deployment | ARM Template | Deploy to Azure |
   | --- | --- | --- |
   | **Both Windows & Linux Combined Policies** (`Audit MDE Entra ID Device ID on Windows machines` + `Audit MDE Entra ID Device ID on Linux machines`) | [`configureEntraIdDeviceId.armtemplate.json`](../configureEntraIdDeviceId.armtemplate.json) | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceId.armtemplate.json) |

   *(Or deploy the [4 split Native VM vs. Azure Arc policies](../machineConfiguration/ENTRAID-DEVICEID-SOLUTION.md) individually if you prefer separate assignments for VMs and Arc machines:)*
   - **Windows VMs:** [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdWindowsVM.armtemplate.json) · **Windows Arc:** [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdWindowsArc.armtemplate.json)
   - **Linux VMs:** [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdLinuxVM.armtemplate.json) · **Linux Arc:** [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdLinuxArc.armtemplate.json)

2. **Assign the Policies in Azure Policy:**
   - Open **Azure Policy** &rarr; **Definitions**, select **`Audit MDE Entra ID Device ID on Windows machines`** and **`Audit MDE Entra ID Device ID on Linux machines`**, and click **Assign** at your Management Group or Subscription scope.
   - Check **Create a remediation task** on the **Remediation** tab so existing servers receive the Machine Configuration assignment immediately.

---

### Step 3: Deploy the Sync & Report Function Apps

Choose **Option A** (automated PowerShell deployment) or **Option B** (Azure Portal button + zip upload):

#### Option A: One-Command PowerShell Deployment (`Deploy.ps1` — Recommended)
Deploys the Azure infrastructure, builds and uploads `worker.zip` and `report.zip`, assigns `Reader` RBAC, and creates the Event Grid subscription:

```powershell
cd .\entragroup-sync
$secret = Read-Host 'Report App Client Secret' -AsSecureString

.\Deploy.ps1 `
    -ResourceGroupName 'rg-arc-entra-sync' `
    -NamePrefix 'mdemdcsync' `
    -SubscriptionIds @('<subscription-guid>') `
    -ManagementGroupIds @('<optional-management-group-id>') `
    -AdminUnitId '<entra-administrative-unit-guid>' `
    -AwsWindowsGroupPrefix 'MDfS-AWS-Windows-' `
    -AwsLinuxGroupPrefix 'MDfS-AWS-Linux-' `
    -GcpWindowsGroupPrefix 'MDfS-GCP-Windows-' `
    -GcpLinuxGroupPrefix 'MDfS-GCP-Linux-' `
    -AzureWindowsGroupPrefix 'MDfS-Azure-Windows-' `
    -AzureLinuxGroupPrefix 'MDfS-Azure-Linux-' `
    -ReportClientId '<report-app-client-id>' `
    -ReportClientSecret $secret
```

#### Option B: Deploy via Azure Portal Button + Upload Function Code Packages
1. Click **Deploy to Azure** to provision the Function Apps, Storage Accounts, Service Bus queue, and Application Insights:

   [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2Fentragroup-sync%2Fazuredeploy.json)

2. Upload the pre-built PowerShell Function packages (`packages/worker.zip` and `packages/report.zip`):
   ```powershell
   az functionapp deployment source config-zip --resource-group '<resource-group>' --name '<worker-app-name>' --src .\entragroup-sync\packages\worker.zip
   az functionapp deployment source config-zip --resource-group '<resource-group>' --name '<report-app-name>' --src .\entragroup-sync\packages\report.zip
   ```
3. *(Optional for Option B)* Deploy the Subscription Event Grid trigger & `Reader` role (`infra/subscription.bicep`) so machines sync immediately when `entraiddeviceid` Machine Configuration assignments or `MDE.Windows`/`MDE.Linux` extensions finish:
   ```powershell
   $subId = '<subscription-guid>'
   $rg = '<resource-group>'
   $workerName = '<worker-app-name>'
   $workerPrincipalId = az functionapp identity show -g $rg -n $workerName --query principalId -o tsv
   $workerFuncId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Web/sites/$workerName/functions/ArcEvent"

   az deployment sub create --location eastus --template-file .\entragroup-sync\infra\subscription.bicep `
       --parameters workerPrincipalId=$workerPrincipalId workerFunctionId=$workerFuncId eventSubscriptionName="mdemdcsync-events"
   ```

---

### Step 4: Configure the Web Portal Redirect URI

1. In Microsoft Entra ID &rarr; **App registrations** &rarr; select your Report App registration &rarr; **Authentication**.
2. Click **Add a platform** &rarr; **Web** and add the Redirect URI:
   ```text
   https://<report-app-name>.azurewebsites.net/.auth/login/aad/callback
   ```

---

### Step 5: Grant Permissions to the Worker Managed Identity

The Worker Function App's System-Assigned Managed Identity needs:
1. **Azure `Reader`** on your target Subscription(s) or Management Group(s) so Azure Resource Graph can discover servers and `GuestConfigurationResources`.
2. **Microsoft Graph (`ThreatHunting.Read.All` & `Device.Read.All`) + Administrative Unit `Groups Administrator`** (`Grant-GraphPermissions.ps1`).

```powershell
# 1. Get the Worker Function App's Managed Identity Principal ID
$workerPrincipalId = az functionapp identity show --resource-group '<resource-group>' --name '<worker-app-name>' --query principalId -o tsv

# 2. Assign Azure Reader on your target Subscription or Management Group (if not already assigned by Deploy.ps1)
az role assignment create --assignee-object-id $workerPrincipalId --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/subscriptions/<subscription-guid>'
# Or at Management Group scope:
# az role assignment create --assignee-object-id $workerPrincipalId --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/providers/Microsoft.Management/managementGroups/<management-group-id>'

# 3. Grant Microsoft Graph permissions + Administrative Unit Groups Administrator role
.\entragroup-sync\Grant-GraphPermissions.ps1 `
    -WorkerPrincipalId $workerPrincipalId `
    -Mode Enforce `
    -AdminUnitId '<entra-administrative-unit-guid>'
```

---

### Step 6: Verify in the Web Portal & Switch to `Enforce` Mode

1. **Open the Web Portal:** Navigate to **`https://<report-app-name>.azurewebsites.net/`**.
2. **Verify Permissions (`05 Permissions & readiness`):**
   - Open **`https://<report-app-name>.azurewebsites.net/permissions.html`** to confirm all Azure RBAC, Microsoft Graph, and Administrative Unit checks show **Granted / Verified**.
3. **Review Audit Results (`01 Device inventory` & `02 Cloud & group report`):**
   - Verify discovered servers, their **Correlation method** (`MDE AadDeviceId`, `Machine Configuration (intuneDeviceId)`, or `MicrosoftSense (Hostname & OS)`), and target Entra ID groups (`WouldAdd` / `WouldCreateGroupAndAdd`).
4. **Enable Group Synchronization (`Enforce` Mode):**
   - When ready to automatically create missing Active/Passive groups in your Administrative Unit and add verified devices, set `SYNC_MODE=Enforce`:
   ```powershell
   az functionapp config appsettings set --resource-group '<resource-group>' --name '<worker-app-name>' --settings SYNC_MODE=Enforce
   ```

---

## Architecture & Group Evaluation Workflow

![Azure Arc to Entra Security Group Synchronization Architecture](infra/architecture.archify.svg)

### 3-Tier Microsoft Entra ID Device Correlation Chain

![3-Tier Microsoft Entra ID Device Correlation Chain](infra/correlation.archify.svg)

| Priority | Correlation Method (`Correlation method` column) | How It Works | When It Is Used |
| --- | --- | --- | --- |
| **Tier 1** | **`MDE AadDeviceId`** (`MdeAadDeviceId`) | Reads `AadDeviceId` from MDE Advanced Hunting (`DeviceInfo`) and queries `GET /v1.0/devices?$filter=deviceId eq '{AadDeviceId}'`. | Primary method for Microsoft Entra joined or hybrid joined servers where MDE directly reports `AadDeviceId`. |
| **Tier 2** | **`Machine Configuration (intuneDeviceId)`** (`GuestConfigurationIntuneDeviceId`) | Reads `intuneDeviceId=<guid>` from `GuestConfigurationResources` (`entraiddeviceid` on Windows reading `HKLM\SOFTWARE\Microsoft\SenseCM\EnrollmentPayload`; `entraiddeviceidlinux` on Linux reading `/var/opt/microsoft/mdatp/wdavstate`) and queries `GET /v1.0/devices?$filter=deviceId eq '{intuneDeviceId}'`. | Used when `AadDeviceId` is empty in MDE (workgroup / AWS / GCP / Linux servers enrolled via MDE Security Settings Management) and the Azure Machine Configuration assignment has reported back. |
| **Tier 3** | **`MicrosoftSense (Hostname & OS)`** (`MicrosoftSenseHostnameAndOS`) | Queries `GET /v1.0/devices?$filter=displayName eq '{hostname}'` across candidate hostnames (`ComputerName`, `MdeDeviceName`, `Fqdn`, `MachineName`) and requires a unique match on `operatingSystem` (`Windows` / `Linux`) and `managementType == 'MicrosoftSense'`. | Automatic fallback when `AadDeviceId` is empty and the Machine Configuration assignment has not yet reported. |

### Group Membership Evaluation Flow

![Machine Correlation and Entra ID Group Membership Evaluation Workflow](infra/evaluation.archify.svg)

| Gate | Evaluation Criteria | Pass Outcome | Fail / Stop Outcome (No Group Write) |
| --- | --- | --- | --- |
| **Gate 1: Scope Rule** | Resource is `HybridCompute/machines`, `Compute/virtualMachines`, `ClassicCompute/virtualMachines`, or `virtualMachineScaleSets/virtualMachines` (`!Compute.AKS`), and `(Sub in SUB_IDS OR MG_IDS) AND (RG_NAMES empty OR matching RG)` | Proceed to Gate 2 | Ignored / rejected outside scope |
| **Gate 2: ARM State** | Arc `properties.status == "Connected"` or Azure VM / VMSS `PowerState` is running (not `deallocated` or `stopped`) | Extract OS, `SubscriptionName`, `GuestConfigEntraDeviceId`, and `AccountId` / `ProjectId` tags | `ArcMissing` (HTTP 404) or `ArcNotConnected` |
| **Gate 3: MDE Match** | Latest `DeviceInfo` row per `DeviceId` (7d) where `AzureResourceId =~ id` (or `AzureVmId =~ vmId`), `OnboardingStatus == "Onboarded"`, `MergedToDeviceId == ""`, `Timestamp <= SYNC_FRESHNESS_HOURS` (24h), and **count == 1** | Proceed to Gate 4 (even if `AadDeviceId` is empty on MDE-managed servers) | `PendingMde` (0), `StaleEvidence` (>24h), `Ambiguous` (>1), or `InvalidEntraIdentifier` |
| **Gate 4: 3-Tier Entra ID Correlation** | **Tier 1 (`MdeAadDeviceId`):** `GET /devices?$filter=deviceId eq '{AadDeviceId}'`<br>**Tier 2 (`GuestConfigurationIntuneDeviceId`):** Joins `GuestConfigurationResources` (`entraiddeviceid` / `entraiddeviceidlinux` assignment reason `intuneDeviceId=<guid>`) &rarr; `GET /devices?$filter=deviceId eq '{intuneDeviceId}'`<br>**Tier 3 (`MicrosoftSenseHostnameAndOS`):** `GET /devices?$filter=displayName eq '{hostname}'` matching `operatingSystem` and `managementType == "MicrosoftSense"` | Extract Entra directory **object `id`** (`accountEnabled == true`) | `NoEntraDevice`, `EntraDeviceNotFound` (0), `Ambiguous` (>1), or `EntraDeviceDisabled` |
| **Gate 5: Cloud, OS & Default Mode** | Resolves OS (`Windows` vs `Linux`), Cloud (`AWS` via `AccountId` tag, `GCP` via `ProjectId` tag, or `Azure` via `SubscriptionName`; AWS & GCP excluded from Azure Subscription groups), and `SYNC_DEFAULT_GROUP_MODE` (`Passive` by default, or `Active`) | Inspect existing group memberships (inside `SYNC_ADMIN_UNIT_ID` when configured); if already in Active when default is Passive (or Passive when default is Active), do not add to counterpart group | `GroupNotConfigured` or `MissingCloudIdentifier` |
| **Gate 6: Per-Account Active/Passive Group & Flags** | **AWS Win / Lin:** `<Prefix>{Passive|Active}-<AccountId>`<br>**GCP Win / Lin:** `<Prefix>{Passive|Active}-<ProjectId>`<br>**Azure Win / Lin:** `<Prefix>{Passive|Active}-<SubscriptionName>` | `Audit` = `WouldAdd`; `Enforce` = `POST /members/$ref` + read-back (`Verified`); evaluates compliance flags (AV mode mismatch `Should be Active`, `Multiple groups`, `Wrong group`) | `GroupNotFound` or `Failed` |

---

## Estimated Monthly Azure Cost

The solution is designed to run on lightweight Azure resources. Below is the estimated monthly cost in **East US (Pay-As-You-Go USD)** for a typical environment (e.g., **100 to 1,000 servers** synced every 30 minutes):

### 1. Core Infrastructure Cost (`entragroup-sync/azuredeploy.json`)

| Azure Resource | Default SKU / Tier | Estimated Monthly Cost (USD) | Notes |
| --- | --- | --- | --- |
| **App Service Plan** (`<prefix>-plan`, hosts both `worker` & `report` Function Apps) | **`B1` (Basic, 1 instance)** *(default)*<br>*(Optional: `S1` Standard or `P1v3` Premium)* | **~$54.75 / mo**<br>*(or ~$73/mo on `S1`, ~$138/mo on `P1v3`)* | Both the Worker and Report Function Apps share the same single App Service Plan (`serverFarmId`) at no extra per-app compute charge. |
| **Azure Service Bus** (`<prefix>-bus`, `machines` queue) | **Standard** | **~$10.00 / mo** | ~$9.81 base fee + $0.05 per million messaging operations (1,000 servers × 48 runs/day ≈ 1.4M ops/mo ≈ $0.01). |
| **3 × Azure Storage Accounts** (`sync<suffix>`, `worker<suffix>`, `report<suffix>`) | **Standard LRS (`StorageV2`)** | **~$0.50 – $2.00 / mo** | Table Storage (`machines` state, history, and logs) + Function host leases cost fractions of a cent per GB and ~$0.00036 per 10,000 transactions. |
| **Application Insights & Log Analytics** (`<prefix>-insights`, `<prefix>-logs`) | **Pay-As-You-Go (`PerGB2018`, 30-day retention)** | **$0.00 – $5.00 / mo** | The first **5 GB/month** of Log Analytics ingestion per billing account is **free**; typical worker trace volume is <1–2 GB/month. |
| **Azure Event Grid** (`Microsoft.EventGrid/eventSubscriptions`) | **System Topic** | **$0.00 / mo** | First **100,000 operations/month** are **free** ($0.60 per million after). |
| **Microsoft Graph & Azure Resource Graph APIs** | **Included** | **$0.00 / mo** | No per-query charges for Azure Resource Graph, Defender Advanced Hunting, or Entra ID Graph API calls. |
| **Total Core Infrastructure** | **Default (`B1` Plan)** | **~$65 – $72 / month** | Fixed baseline cost for the entire synchronization and reporting platform. |

### 2. Azure Machine Configuration (Guest Configuration) Cost (`entraiddeviceid` / `entraiddeviceidlinux`)

| Server Type | Azure Machine Configuration Pricing | Notes |
| --- | --- | --- |
| **Azure Native Virtual Machines & VMSS** | **$0.00 / mo (Included)** | Azure Machine Configuration is **free** for native Azure Virtual Machines and Virtual Machine Scale Sets. |
| **Azure Arc-Enabled Servers** *(with Microsoft Defender for Servers Plan 2)* | **$0.00 / mo (Included)** | Included at no additional charge when **Microsoft Defender for Servers Plan 2** (or Azure Automanage / Windows Server Pay-As-You-Go / Software Assurance with Azure Hybrid Benefit) is enabled on the Arc server. |
| **Azure Arc-Enabled Servers** *(without Defender for Servers Plan 2 or SA/AHB)* | **~$6.00 / server / mo** *(if `IncludeArcMachines = true`)* | Standard Azure Machine Configuration price for Arc-enabled servers when not covered by Defender for Servers Plan 2 or Windows Server SA/AHB. *(If you do not want to use Machine Configuration on Arc servers, Tier 1 `MDE AadDeviceId` and Tier 3 `MicrosoftSense (Hostname & OS)` fallback correlate Arc servers at **$0/mo** without Guest Configuration.)* |

---

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
