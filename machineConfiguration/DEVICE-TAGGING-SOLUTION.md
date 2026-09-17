# Microsoft Defender for Endpoint device tagging

## Overview

This solution uses Azure Machine Configuration and Azure Policy to audit or configure Microsoft Defender for Endpoint (MDE) device tags on Windows and Linux machines.

| Platform | Managed setting | Supported behavior |
| --- | --- | --- |
| Windows | `HKLM\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging\Group` | Creates or corrects a `REG_SZ` device tag. |
| Linux | `/etc/opt/microsoft/mdatp/managed/mdatp_managed.json` | Merges the `GROUP` tag into valid JSON or overwrites the file. |

Both policies support Azure virtual machines, virtual machine scale sets, Azure Arc-enabled servers, and Azure Arc-enabled VMware vSphere virtual machines for the applicable operating system. AKS-managed virtual machines and scale sets are excluded.

## Table of contents

- [Overview](#overview)
- [Solution structure](#solution-structure)
- [Windows device tagging](#windows-device-tagging)
  - [Windows managed setting](#windows-managed-setting)
  - [Windows compliance states](#windows-compliance-states)
- [Linux device tagging](#linux-device-tagging)
  - [Linux managed setting](#linux-managed-setting)
  - [Linux file update modes](#linux-file-update-modes)
  - [Linux compliance states](#linux-compliance-states)
- [Prerequisites](#prerequisites)
- [Build and publish](#build-and-publish)
  - [Build the Windows package](#build-the-windows-package)
  - [Build the Linux package](#build-the-linux-package)
- [Deploy and assign the policies](#deploy-and-assign-the-policies)
- [Policy parameters](#policy-parameters)
- [Validate the configuration](#validate-the-configuration)
  - [Validate Windows](#validate-windows)
  - [Validate Linux](#validate-linux)
- [Update the solution](#update-the-solution)

## Solution structure

| Path | Purpose |
| --- | --- |
| `devicetagging/` | Windows DSC configuration, resource module, build script, package, and generated policies. |
| `devicetagging-linux/` | Linux DSC configuration, resource module, build script, package, and generated policies. |
| `devicetagging/output/defenderdevicetagging.zip` | Windows Machine Configuration package. |
| `devicetagging-linux/output/devicetagginglinux.zip` | Linux Machine Configuration package. |
| `../configureMDEdevicetagging.json` | Portal-ready Windows configure policy definition. |
| `../configureMDEdevicetaggingLinux.json` | Portal-ready Linux configure policy definition. |

Each platform's `output/policies/audit/` directory contains an `AuditIfNotExists` policy. Its `output/policies/configure/` directory contains a `DeployIfNotExists` policy with auto-correction support.

## Windows device tagging

### Windows managed setting

The Windows DSC resource manages the 64-bit registry view:

| Setting | Value |
| --- | --- |
| Registry key | `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging` |
| Value name | `Group` |
| Value type | `REG_SZ` |
| Value data | Device tag supplied by the policy assignment |

The resource creates the registry key and value when they do not exist. Compliance comparisons are case-sensitive.

### Windows compliance states

| Reason | Meaning |
| --- | --- |
| `KeyNotPresent` | The MDE device-tagging registry key does not exist. |
| `ValueNotPresent` | The `Group` registry value does not exist. |
| `WrongType` | The registry value is not `REG_SZ`. |
| `ReadError` | The registry value could not be read. |
| `ValueMismatch` | The current value differs from the assigned device tag. |
| `Compliant` | The registry value has the expected type and value. |

## Linux device tagging

### Linux managed setting

The Linux DSC resource manages:

```text
/etc/opt/microsoft/mdatp/managed/mdatp_managed.json
```

The expected tag has this structure:

```json
{
  "edr": {
    "tags": [
      {
        "key": "GROUP",
        "value": "<device-tag>"
      }
    ]
  }
}
```

The resource creates the managed directory when necessary and sets the resulting file to mode `640` with owner `root:root`. Tag-key and tag-value comparisons are case-sensitive.

### Linux file update modes

| Mode | Behavior |
| --- | --- |
| `Merge` | Preserves unrelated valid settings and tags, removes existing `GROUP` entries, and adds one `GROUP` tag with the configured value. This is the default. |
| `Overwrite` | Replaces the managed file with a document containing only the configured `GROUP` tag. Compliance requires an exact document match. |

> [!IMPORTANT]
> In `Merge` mode, remediation fails if an existing managed file cannot be read or contains invalid JSON. Repair or remove the invalid file before retrying. In `Overwrite` mode, all other settings in the file are removed.

### Linux compliance states

| Reason | Meaning |
| --- | --- |
| `FileMissing` | The managed JSON file does not exist. |
| `ReadError` | The file cannot be read. |
| `InvalidJson` | The file does not contain valid JSON. |
| `EdrMissing` | The root document has no `edr` object. |
| `TagsMissing` | The `edr` object has no `tags` collection. |
| `GroupTagMissing` | No `GROUP` tag exists. |
| `DuplicateGroupTags` | More than one `GROUP` tag exists. |
| `GroupTagMismatch` | The current tag value differs from the assigned value. |
| `UnexpectedContent` | `Overwrite` mode found content other than the single expected `GROUP` tag. |
| `Compliant` | The managed file matches the assigned configuration. |

## Prerequisites

### Target machines

- Microsoft Defender for Endpoint is installed and onboarded.
- The machine meets Azure Machine Configuration prerequisites.
- The machine can reach the HTTPS location hosting its platform package.
- The `Microsoft.GuestConfiguration` resource provider is registered in the subscription.

### Package authoring

Use PowerShell 7 or later. On Windows, use an x64 PowerShell process.

```powershell
Install-Module GuestConfiguration -MinimumVersion 3.4.2 -Scope CurrentUser
Install-Module PSDesiredStateConfiguration -RequiredVersion 2.0.7 -Scope CurrentUser
```

Confirm that the modules are available:

```powershell
Get-Module -ListAvailable GuestConfiguration, PSDesiredStateConfiguration |
    Select-Object Name, Version, Path
```

## Build and publish

The build process has two stages:

1. Build the Machine Configuration ZIP without `ContentUri`.
2. Publish the unchanged ZIP to a stable, versioned HTTPS location, then rebuild with `ContentUri` to generate policies containing the correct URL and SHA-256 hash.

The package bytes must match the `contentHash` embedded in the policy definition. Regenerate the policies whenever a package changes.

### Build the Windows package

From the `machineConfiguration` directory:

```powershell
pwsh -NoProfile -File ./devicetagging/Build-devicetagging.ps1
```

Publish `devicetagging/output/defenderdevicetagging.zip`, then generate the policies:

```powershell
pwsh -NoProfile -File ./devicetagging/Build-devicetagging.ps1 `
    -ContentUri 'https://<host>/<path>/defenderdevicetagging.zip'
```

The portal-ready configure policy is written to `../configureMDEdevicetagging.json`.

### Build the Linux package

From the `machineConfiguration` directory:

```powershell
pwsh -NoProfile -File ./devicetagging-linux/Build-devicetagginglinux.ps1
```

Publish `devicetagging-linux/output/devicetagginglinux.zip`, then generate the policies:

```powershell
pwsh -NoProfile -File ./devicetagging-linux/Build-devicetagginglinux.ps1 `
    -ContentUri 'https://<host>/<path>/devicetagginglinux.zip'
```

The portal-ready configure policy is written to `../configureMDEdevicetaggingLinux.json`.

Both build scripts also accept these optional parameters:

| Parameter | Description |
| --- | --- |
| `OutputPath` | Package, compiled MOF, and generated-policy output directory. Defaults to the platform's `output` directory. |
| `ConfigurePolicyOutputPath` | Destination for the portal-ready configure policy JSON. |
| `PolicySkeletonUri` | Machine Configuration policy skeleton used during policy generation. |

## Deploy and assign the policies

Create separate custom Azure Policy definitions for Windows and Linux from the generated configure or audit policy JSON files. Assign each definition at the required management group, subscription, or resource group scope.

For a configure policy:

1. Open **Azure Policy > Definitions** and create a custom policy definition.
2. Use the applicable portal-ready JSON file as the policy definition content.
3. Create an assignment at the approved scope.
4. Enable a system-assigned managed identity on the assignment.
5. Grant the role requested on the **Remediation** tab.
6. Review the parameters and create the assignment.
7. Create a remediation task for existing noncompliant machines.

Use the generated audit policies for an audit-only rollout that does not deploy a configuration assignment. Machine Configuration deployment and evaluation are asynchronous, so allow time for guest assignments to reach machines and report compliance.

## Policy parameters

| Parameter | Platform | Default | Description |
| --- | --- | --- | --- |
| `DeviceTag` | Windows and Linux | `DefaultDeviceTag` | MDE device tag value. The generated policies allow no more than 200 characters; the DSC resources require at least one character. |
| `FileMode` | Linux only | `Merge` | Uses `Merge` or `Overwrite` behavior for `mdatp_managed.json`. |
| `IncludeArcMachines` | Windows and Linux | `true` | Includes supported Arc-connected machines for the applicable operating system. Review Azure Arc and Machine Configuration charges. |
| `EnableAutoRemediation` | Windows and Linux | `true` | Applies the desired setting and corrects drift. Set to `false` for audit behavior within the configure policy. |
| `tagName` | Windows and Linux | Empty | Optional Azure resource tag name used to limit applicability. Leave empty to include all otherwise eligible resources. |
| `tagValue` | Windows and Linux | Empty | Required Azure resource tag value when `tagName` is specified. |

Start with `EnableAutoRemediation` set to `false` when validating assignment scope. For Linux, also review existing managed-file content and the impact of the selected `FileMode` before enabling remediation.

## Validate the configuration

After assignment and remediation, review each assignment under **Azure Policy > Compliance**.

### Validate Windows

Run the following in an elevated PowerShell session on a target machine:

```powershell
$path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging'
Get-ItemProperty -Path $path -Name Group
(Get-Item -Path $path).GetValueKind('Group')
```

The `Group` value should contain the assigned tag and its type should be `String`.

### Validate Linux

Run the following on a target machine:

```bash
sudo cat /etc/opt/microsoft/mdatp/managed/mdatp_managed.json
sudo stat -c '%a %U:%G %n' /etc/opt/microsoft/mdatp/managed/mdatp_managed.json
mdatp health --field edr_group_ids
```

The file should contain exactly one `GROUP` tag with the assigned value. Its permissions and ownership should report `640 root:root`.

## Update the solution

When either DSC resource or configuration changes:

1. Update the applicable module and package versions consistently.
2. Build and test a new package.
3. Publish the ZIP at a versioned HTTPS URL.
4. Regenerate the policy definitions with that URL.
5. Redeploy the policy definition.
6. Trigger remediation or wait for the next evaluation cycle.

Do not replace a published package in place while retaining an older policy hash. Target machines reject packages whose content does not match the policy definition.