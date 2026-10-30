# Microsoft Defender for Endpoint SenseCM Entra ID Device ID Discovery (`entraid-deviceid` & `entraid-deviceid-linux`)

## Overview

When servers (AWS EC2, GCP VMs, on-premises Arc servers, or Azure VMs) are enrolled in **Microsoft Defender for Endpoint Security Settings Management** (`MicrosoftSense` / MDE Attach) without full Microsoft Entra join, Defender for Endpoint creates a synthetic Microsoft Entra ID device object whose Entra `deviceId` is stored locally on the machine as `intuneDeviceId`.

This Azure Machine Configuration solution reads that `intuneDeviceId` from Windows and Linux machines (after verifying that the `MDE.Windows` or `MDE.Linux` extension is installed and provisioned) and reports it in the Azure Machine Configuration compliance payload (`intuneDeviceId=<guid>`) so it can be queried directly from Azure Resource Graph (`GuestConfigurationResources`) and consumed by the [Cloud Server Correlation (`entragroup-sync`)](../entragroup-sync/README.md) Function App.

| Platform | Machine Configuration Package | Source Location on Endpoint | Output in `GuestConfigurationResources` |
| --- | --- | --- | --- |
| **Windows** | `machineConfiguration/entraid-deviceid/output/entraiddeviceid.zip` | Registry key: `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\SenseCM\MemConfiguration`<br>Value name: `EnrollmentPayload` (`REG_SZ` JSON) | `Reasons[0].Phrase`: `intuneDeviceId=<guid>`<br>`IntuneDeviceId`: `<guid>` |
| **Linux** | `machineConfiguration/entraid-deviceid-linux/output/entraiddeviceidlinux.zip` | File path: `/var/opt/microsoft/mdatp/wdavstate`<br>Property: `mEnrollmentPayload` (escaped JSON) | `Reasons[0].Phrase`: `intuneDeviceId=<guid>`<br>`IntuneDeviceId`: `<guid>` |

---

## Deploy and Assign the 4 Azure Policy Definitions

Each of the 4 `DeployIfNotExists` policies checks that the `MDE.Windows` or `MDE.Linux` extension is installed (`provisioningState` in `['Succeeded', 'Provisioning succeeded']`) before deploying the Machine Configuration assignment onto the parent VM or Azure Arc machine.

Deploy each custom policy definition independently at subscription scope:

| # | Policy Display Name | Target Scope | Extension Checked | ARM Template | Deployment |
| --- | --- | --- | --- | --- | --- |
| **1** | **Audit MDE Entra ID Device ID on Windows machines** | Native Azure Virtual Machines (`Microsoft.Compute/virtualMachines/extensions`) | `MDE.Windows` | `configureEntraIdDeviceIdWindowsVM.armtemplate.json` | [![Deploy Audit MDE Entra ID Device ID on Windows machines to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdWindowsVM.armtemplate.json) |
| **2** | **Audit MDE Entra ID Device ID on Windows Arc machines** | Azure Arc-Enabled Servers (`Microsoft.HybridCompute/machines/extensions`) | `MDE.Windows` | `configureEntraIdDeviceIdWindowsArc.armtemplate.json` | [![Deploy Audit MDE Entra ID Device ID on Windows Arc machines to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdWindowsArc.armtemplate.json) |
| **3** | **Audit MDE Entra ID Device ID on Linux machines** | Native Azure Virtual Machines (`Microsoft.Compute/virtualMachines/extensions`) | `MDE.Linux` | `configureEntraIdDeviceIdLinuxVM.armtemplate.json` | [![Deploy Audit MDE Entra ID Device ID on Linux machines to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdLinuxVM.armtemplate.json) |
| **4** | **Audit MDE Entra ID Device ID on Linux Arc machines** | Azure Arc-Enabled Servers (`Microsoft.HybridCompute/machines/extensions`) | `MDE.Linux` | `configureEntraIdDeviceIdLinuxArc.armtemplate.json` | [![Deploy Audit MDE Entra ID Device ID on Linux Arc machines to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdLinuxArc.armtemplate.json) |

### Combined Policies (Native VMs + Azure Arc in a Single Policy)

| Policy Display Name | ARM Template | Portal Policy JSON | Deployment |
| --- | --- | --- | --- |
| **Audit MDE Entra ID Device ID on Windows machines** | `configureEntraIdDeviceIdWindows.armtemplate.json` | `configureEntraIdDeviceIdWindows.json` | [![Deploy Windows combined policy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdWindows.armtemplate.json) |
| **Audit MDE Entra ID Device ID on Linux machines** | `configureEntraIdDeviceIdLinux.armtemplate.json` | `configureEntraIdDeviceIdLinux.json` | [![Deploy Linux combined policy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fdefenderforservers-tools%2Fmain%2FconfigureEntraIdDeviceIdLinux.armtemplate.json) |

### Portal Policy Definition JSON Paths

| # | Policy Display Name | Portal Policy JSON |
| --- | --- | --- |
| **1** | **Audit MDE Entra ID Device ID on Windows machines** | `machineConfiguration/entraid-deviceid/output/policies/configure/entraiddeviceid_VirtualMachines_DeployIfNotExists.json` |
| **2** | **Audit MDE Entra ID Device ID on Windows Arc machines** | `machineConfiguration/entraid-deviceid/output/policies/configure/entraiddeviceid_AzureArc_DeployIfNotExists.json` |
| **3** | **Audit MDE Entra ID Device ID on Linux machines** | `machineConfiguration/entraid-deviceid-linux/output/policies/configure/entraiddeviceidlinux_VirtualMachines_DeployIfNotExists.json` |
| **4** | **Audit MDE Entra ID Device ID on Linux Arc machines** | `machineConfiguration/entraid-deviceid-linux/output/policies/configure/entraiddeviceidlinux_AzureArc_DeployIfNotExists.json` |

---

## Querying Reported `intuneDeviceId` Values in Azure Resource Graph

```kusto
GuestConfigurationResources
| where type =~ 'microsoft.guestconfiguration/guestconfigurationassignments'
| where tolower(name) startswith 'entraiddeviceid'
| extend machineId = tolower(substring(id, 0, indexof(tolower(id), '/providers/microsoft.guestconfiguration/')))
| extend complianceStatus = tostring(properties.complianceStatus)
| extend reasonPhrase = tostring(properties.latestAssignmentReport.resources[0].reasons[0].phrase)
| parse reasonPhrase with * "intuneDeviceId=" intuneDeviceId
| project machineId, name, complianceStatus, intuneDeviceId, reasonPhrase
```

---

## Integration with `entragroup-sync` Function App

1. **Event Grid Trigger (`ArcEvent`):**
   - `entragroup-sync/infra/subscription.bicep` subscribes to `Microsoft.GuestConfiguration/guestConfigurationAssignments/write` events where `subject` contains `/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceid`.
   - As soon as the Machine Configuration assignment reports back on a server, Event Grid triggers `ArcEvent` &rarr; queues the parent server to Service Bus.
2. **3-Tier Entra ID Device Correlation (`Resolve-EntraDeviceForMachine` in `Sync.psm1`):**
   - **Tier 1 (`MdeAadDeviceId`):** Uses `DeviceInfo.AadDeviceId` from MDE Advanced Hunting when present.
   - **Tier 2 (`GuestConfigurationIntuneDeviceId`):** Uses `gcEntraDeviceId` (`intuneDeviceId` from `GuestConfigurationResources`) to look up `GET /v1.0/devices?$filter=deviceId eq '{intuneDeviceId}'`.
   - **Tier 3 (`MicrosoftSenseHostnameAndOS`):** Falls back to `GET /v1.0/devices?$filter=displayName eq '{hostname}'` matching `operatingSystem` and `managementType == 'MicrosoftSense'`.
