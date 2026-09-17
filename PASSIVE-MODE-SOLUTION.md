# Microsoft Defender for Endpoint mode management

## Solution overview

This solution configures and audits Microsoft Defender for Endpoint active or passive mode across Windows Azure virtual machines, virtual machine scale sets, and Azure Arc-enabled servers. It combines Azure Policy, Azure Machine Configuration, Azure Monitor Agent, Change Tracking and Inventory, a Data Collection Rule (DCR), and an Azure Monitor workbook.

The managed registry value is:

| Setting | Value |
| --- | --- |
| Registry key | `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection` |
| Value name | `ForceDefenderPassiveMode` |
| Value type | `REG_DWORD` |
| Active mode | `0` |
| Passive mode | `1` |

The solution uses two complementary audit paths:

- **Azure Policy and Machine Configuration** report the current compliance state and can configure or autocorrect the registry value.
- **Change Tracking and Inventory** sends registry-change records to Log Analytics, providing historical evidence that can be reviewed in the included workbook.

The subscription-scope ARM template deploys these resources:

| Resource | Purpose |
| --- | --- |
| **Configure Azure Benefits for Windows Arc Machines** policy | Attests and configures Azure benefits for eligible Arc-connected Windows servers with qualifying Windows Server licenses, allowing Change Tracking and Inventory to be used on those Arc-connected machines at no additional service cost. Log Analytics or Microsoft Sentinel data ingestion and retention charges can still apply. |
| **Configure ChangeTracking for Defender Passive Mode Auditing** initiative | Deploys the required identities, extensions, Azure Monitor Agent, and DCR associations for Change Tracking. |
| **Configure Microsoft Defender for Endpoint mode on Windows machines** policy | Audits or configures `ForceDefenderPassiveMode` through Machine Configuration. |
| **DefenderPassiveMode-ChangeTracking-dcr** | Collects changes to the Defender mode registry value. |
| **Defender for Endpoint Passive Mode Monitor** workbook | Displays current mode, policy status, and registry-change history. |

## Table of contents

- [Solution overview](#solution-overview)
- [Prerequisites](#prerequisites)
- [Cost considerations](#cost-considerations)
- [Implementation](#implementation)
	- [Step 1 - Deploy the entire solution](#step-1---deploy-the-entire-solution)
		- [Deploy individual policies](#deploy-individual-policies)
	- [Step 2 - Assign Azure Benefits for Windows Arc](#step-2---assign-azure-benefits-for-windows-arc)
	- [Step 3 - Assign the Change Tracking initiative](#step-3---assign-the-change-tracking-initiative)
	- [Step 4 - Create initiative remediation tasks](#step-4---create-initiative-remediation-tasks)
	- [Step 5 - Assign the Defender mode policy](#step-5---assign-the-defender-mode-policy)
	- [Step 6 - Audit mode and registry changes](#step-6---audit-mode-and-registry-changes)
- [Package availability and updates](#package-availability-and-updates)
- [Package authoring prerequisites](#package-authoring-prerequisites)
- [Build and publish](#build-and-publish)
- [References](#references)

## Prerequisites

- The target resource group already exists.
- The Log Analytics workspace already exists.
- You have permission to create policy definitions and initiatives at subscription scope and DCR/workbook resources in the target resource group. `Resource Policy Contributor` plus `Monitoring Contributor` is sufficient for the template resources.
- You can create policy assignments, managed identities, role assignments, and remediation tasks at the selected assignment scope.
- The `Microsoft.GuestConfiguration` and `Microsoft.Insights` resource providers are registered in the subscription.
- Arc-connected machines are online and target machines meet the prerequisites for Azure Monitor Agent and Machine Configuration.
- Before assigning the Azure Benefits policy, confirm which Windows Arc machines have qualifying Windows Server licenses with active Software Assurance or active subscription licenses.

## Cost considerations

Deploying the policy definitions and initiative does not itself ingest Change Tracking data. Costs begin when the initiative associates machines with the DCR and Azure Monitor Agent sends collected data to the selected workspace.

- **Log Analytics ingestion:** `ConfigurationChange`, `Heartbeat`, and related Change Tracking data are billed according to the workspace pricing tier and the volume ingested.
- **Microsoft Sentinel:** When the destination workspace is enabled for Microsoft Sentinel, applicable data ingestion can also contribute to Microsoft Sentinel billing according to its pricing tier or commitment tier.
- **Retention and archive:** Retaining data beyond the workspace's included retention period, restoring archived data, or running search jobs can add charges.
- **Other collected data:** This DCR targets the Defender mode registry value, but other DCRs and solutions connected to the same machines can generate additional billable data.
- **Azure benefits:** Eligibility for Azure Change Tracking and Inventory through Windows Server Azure benefits does not automatically eliminate Log Analytics or Microsoft Sentinel ingestion, retention, or query-related charges.

Estimate expected machine count and registry-change volume, review the destination workspace's pricing and retention settings, and configure Azure Cost Management budgets or alerts before broad rollout.

## Implementation

### Step 1 - Deploy the entire solution

Use the button to deploy `azuredeploy.json` at subscription scope:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2Fazuredeploy.json)

Required parameters:

| Parameter | Description |
| --- | --- |
| `resourceGroupName` | Existing resource group where the DCR and workbook are deployed. |
| `logAnalyticsWorkspaceResourceId` | Full resource ID of the Log Analytics workspace used by Change Tracking and the workbook. |

The same deployment can be started with Azure CLI:

```powershell
az login
az account set --subscription '<subscription-id>'
az provider register --namespace Microsoft.GuestConfiguration
az provider register --namespace Microsoft.Insights

az deployment sub create `
	--name deploy-mde-passive-mode `
	--location westus2 `
	--template-file ./azuredeploy.json `
	--parameters `
		resourceGroupName='<resource-group-name>' `
		logAnalyticsWorkspaceResourceId='/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

Or with Azure PowerShell:

```powershell
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id>'

Register-AzResourceProvider -ProviderNamespace Microsoft.GuestConfiguration
Register-AzResourceProvider -ProviderNamespace Microsoft.Insights

New-AzSubscriptionDeployment `
	-Name 'deploy-mde-passive-mode' `
	-Location 'westus2' `
	-TemplateFile './azuredeploy.json' `
	-resourceGroupName '<resource-group-name>' `
	-logAnalyticsWorkspaceResourceId '/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

The deployment creates the policy definitions, initiative, DCR, and workbook. It intentionally does not create policy assignments because assignment scope, exclusions, identity, licensing attestation, and remediation permissions require customer review.

#### Deploy individual policies

When the entire solution is not required, deploy either custom policy definition independently. These templates create only the selected policy definition; they do not create assignments, managed identities, role assignments, remediation tasks, the Change Tracking initiative, the DCR, or the workbook.

| Policy | Standalone template | Deployment |
| --- | --- | --- |
| **Configure Microsoft Defender for Endpoint mode on Windows machines** | `configureMDEMode.armtemplate.json` | [![Deploy MDE mode policy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureMDEMode.armtemplate.json) |
| **Configure Azure Benefits for Windows Arc Machines** | `configureazbenefitsforwindowsarc.armtemplate.json` | [![Deploy Azure Benefits policy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2Fconfigureazbenefitsforwindowsarc.armtemplate.json) |

### Step 2 - Assign Azure Benefits for Windows Arc

In **Azure Policy > Definitions**, locate **Configure Azure Benefits for Windows Arc Machines** and create an assignment at the approved scope.

This assignment is an explicit attestation that targeted Arc-connected Windows servers have qualifying Windows Server licenses with active Software Assurance or active subscription licenses. The policy does not validate purchase or entitlement records. Limit the assignment with scope, exclusions, or resource selectors so it applies only to eligible machines.

Configure the assignment as follows:

1. Set `effect` to `DeployIfNotExists`.
2. Enable a system-assigned managed identity for the assignment.
3. Grant the role requested on the **Remediation** tab.
4. Create a remediation task for existing eligible Arc machines.

Use `AuditIfNotExists` first when licensing eligibility or target scope still requires review. Do not use remediation as a substitute for validating licensing eligibility.

### Step 3 - Assign the Change Tracking initiative

Retrieve the DCR resource ID created in Step 1:

```powershell
az monitor data-collection rule show `
	--resource-group '<resource-group-name>' `
	--name 'DefenderPassiveMode-ChangeTracking-dcr' `
	--query id `
	--output tsv
```

In **Azure Policy > Definitions**, locate **Configure ChangeTracking for Defender Passive Mode Auditing** and create an initiative assignment:

1. Use the scope that contains the Windows Azure VMs, Arc-enabled servers, and VM scale sets to monitor.
2. Set **Data Collection Rule** to the DCR resource ID.
3. Enable a system-assigned managed identity.
4. Grant every role requested on the **Remediation** tab.
5. Create the assignment without starting individual remediation tasks yet.

Wait for Azure Policy to complete its initial compliance evaluation. In **Azure Policy > Compliance**, confirm that the initiative displays per-policy and per-resource compliance results before continuing.

### Step 4 - Create initiative remediation tasks

After the initial initiative audit completes, use `create-remediationtasks.ps1` to create one remediation task for each noncompliant `DeployIfNotExists` or `Modify` policy reference. The script skips non-remediable effects and references that already have an active remediation task.

Install the required modules and select the subscription:

```powershell
Install-Module Az.Resources, Az.PolicyInsights -Scope CurrentUser
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id>'
```

Copy the full resource ID of the initiative assignment from **Azure Policy > Assignments**. Preview the actions first:

```powershell
./create-remediationtasks.ps1 `
	-PolicyAssignmentId '/subscriptions/<subscription-id>/providers/Microsoft.Authorization/policyAssignments/<assignment-name>' `
	-WhatIf
```

Remove `-WhatIf` to create the tasks:

```powershell
./create-remediationtasks.ps1 `
	-PolicyAssignmentId '/subscriptions/<subscription-id>/providers/Microsoft.Authorization/policyAssignments/<assignment-name>'
```

Monitor the tasks under **Azure Policy > Remediation**. The script is designed for initiative assignments and requires existing compliance data.

### Step 5 - Assign the Defender mode policy

In **Azure Policy > Definitions**, locate **Configure Microsoft Defender for Endpoint mode on Windows machines** and create an assignment at the required scope.

Configure these parameters:

- `DefenderMode`: `Active` writes DWORD `0`; `Passive` writes DWORD `1`.
- `IncludeArcMachines`: include supported Arc-connected Windows machines when required.
- `EnableAutoRemediation`: enable enforcement and drift correction, or disable it for audit-only rollout.
- `contentUri`: retain the default unless the identical package is hosted at another reachable HTTPS URL.

Enable the assignment's managed identity, grant the role shown on the **Remediation** tab, and create a remediation task for existing machines. New or updated machines are evaluated automatically; remediation prompts existing machines to receive the guest assignment sooner.

### Step 6 - Audit mode and registry changes

Open **Azure Monitor > Workbooks > Defender for Endpoint Passive Mode Monitor**. The deployed workspace is selected by default. Verify that:

- Computers appear in the workbook filter.
- `ConfigurationChange` contains records where `ValueName == "ForceDefenderPassiveMode"`.
- Current mode and change-history visuals return data after Change Tracking completes its first collection cycle.

In **Azure Policy > Compliance**:

- Review the Defender mode assignment for current Machine Configuration compliance and per-resource details.
- Review the Change Tracking initiative assignment for identity, extension, agent, and DCR-association compliance.
- Review remediation task status and investigate resources that remain noncompliant.

Machine Configuration assignment, package download, guest evaluation, Change Tracking collection, and Log Analytics ingestion are asynchronous. Allow at least one evaluation and collection cycle before troubleshooting missing or pending results.

## Package availability and updates

The Machine Configuration ZIP must remain reachable by every target machine at the policy's `contentUri`. The package bytes must match the `contentHash` embedded in the policy definition.

When changing the package:

1. Build and test a new ZIP.
2. Publish it at a versioned HTTPS URL.
3. Regenerate `configureMDEMode.json` so its URI and hash match the new package.
4. Regenerate `azuredeploy.json` with `Build-DeploymentTemplate.ps1`.
5. Redeploy the template and remediate the policy assignment as needed.

## Package authoring prerequisites

Use an **x64 PowerShell 7** process on Windows and install the official authoring modules. ARM64 PowerShell can't compile Windows DSC configurations, even when Windows x64 emulation is available.

```powershell
Install-Module GuestConfiguration -Scope CurrentUser
Install-Module PSDesiredStateConfiguration -RequiredVersion 2.0.7 -Scope CurrentUser
```

Run the build from that same x64 PowerShell 7 process:

```powershell
pwsh -NoProfile -File ./Build-MdeDefenderMode.ps1
```

If module discovery fails, verify the host and module path from the same terminal:

```powershell
$PSVersionTable
[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
Get-Module -ListAvailable GuestConfiguration, PSDesiredStateConfiguration |
	Select-Object Name, Version, Path
$env:PSModulePath -split [System.IO.Path]::PathSeparator
```

## Build and publish

Create the `AuditAndSet` package:

```powershell
pwsh ./Build-MdeDefenderMode.ps1
```

Test the package from an elevated PowerShell 7 session:

```powershell
Get-GuestConfigurationPackageComplianceStatus -Path ./output/MdeDefenderModeConfig.zip
```

Publish `output/MdeDefenderModeConfig.zip` to an HTTPS location accessible by the managed machines. Azure Blob Storage is recommended. Then generate the audit and enforcement definitions with the exact published URI:

```powershell
pwsh ./Build-MdeDefenderMode.ps1 -ContentUri 'https://<account>.blob.core.windows.net/<container>/MdeDefenderModeConfig.zip?<sas>'
```

The generated JSON files are written below `output/policies`. The authoring cmdlet calculates and embeds the package content hash, so regenerate both definitions whenever the package changes.

## References

- [Azure Machine Configuration overview](https://learn.microsoft.com/azure/governance/machine-configuration/overview/01-overview-concepts)
- [Create a custom package](https://learn.microsoft.com/azure/governance/machine-configuration/how-to/develop-custom-package/2-create-package)
- [Create a custom policy definition](https://learn.microsoft.com/azure/governance/machine-configuration/how-to/create-policy-definition)
- [Enable Change Tracking and Inventory at scale by using Azure Policy](https://learn.microsoft.com/azure/azure-change-tracking-inventory/enable-change-tracking-at-scale-policy)
- [Azure Monitor Logs cost calculations and options](https://learn.microsoft.com/azure/azure-monitor/logs/cost-logs)
- [Plan costs and understand Microsoft Sentinel pricing and billing](https://learn.microsoft.com/azure/sentinel/billing)
- [Create and manage Azure budgets](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)