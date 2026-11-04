[CmdletBinding()]
param(
    [Parameter()]
    [uri] $ContentUri,

    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),

    [Parameter()]
    [uri] $PolicySkeletonUri = 'https://github.com/seanstark/defenderforservers-tools/raw/refs/heads/main/machineConfiguration/mde-defender-mode/output/MdeDefenderModeConfig.zip',

    [Parameter()]
    [string] $ConfigurePolicyOutputPath = (Join-Path $PSScriptRoot '..\..\configureEntraIdDeviceIdLinux.json')
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7. Run it with 'pwsh', not Windows PowerShell ('powershell.exe')."
}

$configurationName = 'entraiddeviceidlinux'
$policyVersion = '1.0.2'
$guestConfigurationRoleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/088ab73d-1256-47ae-bea9-9de8e7131f31'
$configurationPath = Join-Path $PSScriptRoot 'entraid-deviceid-linux.ps1'
$modulePath = Join-Path $PSScriptRoot 'Modules'
$compiledPath = Join-Path $OutputPath 'compiled'
$packagePath = Join-Path $OutputPath "$configurationName.zip"
$policyPath = Join-Path $OutputPath 'policies'

$requiredModules = @(
    @{ Name = 'GuestConfiguration'; MinimumVersion = '3.4.2' }
    @{ Name = 'PSDesiredStateConfiguration'; RequiredVersion = '2.0.7' }
)

foreach ($requiredModule in $requiredModules) {
    $availableModule = Get-Module -ListAvailable -Name $requiredModule.Name |
        Where-Object {
            (-not $requiredModule.MinimumVersion -or $_.Version -ge [version] $requiredModule.MinimumVersion) -and
            (-not $requiredModule.RequiredVersion -or $_.Version -eq [version] $requiredModule.RequiredVersion)
        } |
        Select-Object -First 1

    if (-not $availableModule) {
        throw "Required module '$($requiredModule.Name)' is not available with the required version."
    }
}

New-Item -ItemType Directory -Path $compiledPath -Force | Out-Null
$env:PSModulePath = "$modulePath$([System.IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module PSDesiredStateConfiguration -RequiredVersion 2.0.7
Import-Module GuestConfiguration

$namedMof = Join-Path $compiledPath "$configurationName.mof"
if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::X64) {
    . $configurationPath
    entraiddeviceidlinux -OutputPath $compiledPath
    $compiledMof = Join-Path $compiledPath 'localhost.mof'
    Move-Item -Path $compiledMof -Destination $namedMof -Force
}
else {
    $genDate = (Get-Date).ToString('MM/dd/yyyy HH:mm:ss')
    $mofText = @"
/*
@TargetNode='localhost'
@GeneratedBy=$env:USERNAME
@GenerationDate=$genDate
@GenerationHost=$env:COMPUTERNAME
*/

instance of EntraIdDeviceIdLinux as `$EntraIdDeviceIdLinux1ref
{
ResourceID = "[EntraIdDeviceIdLinux]$configurationName";
 ModuleVersion = "$policyVersion";
 Name = "wdavstate";
 ModuleName = "EntraIdDeviceIdLinux";
 SourceInfo = "::5::9::EntraIdDeviceIdLinux";
 ConfigurationName = "$configurationName";
};
instance of OMI_ConfigurationDocument
{
 Version="2.0.0";
 MinimumCompatibleVersion = "1.0.0";
 CompatibleVersionAdditionalProperties= {"Omi_BaseResource:ConfigurationName"};
 Author="$env:USERNAME";
 GenerationDate="$genDate";
 GenerationHost="$env:COMPUTERNAME";
 Name="$configurationName";
};
"@
    [System.IO.File]::WriteAllText($namedMof, $mofText, [System.Text.UTF8Encoding]::new($false))
}

New-GuestConfigurationPackage `
    -Name $configurationName `
    -Version $policyVersion `
    -Configuration $namedMof `
    -Path $OutputPath `
    -Type Audit `
    -Force | Out-Host
$packageHash = (Get-FileHash -Path $packagePath -Algorithm SHA256).Hash

if (-not $ContentUri) {
    Write-Host "Package created at '$packagePath' (SHA256: $packageHash)."
    Write-Host 'Publish it to an HTTPS location, then rerun this script with -ContentUri to generate the policies.'
    return
}

if (-not $ContentUri.IsAbsoluteUri -or $ContentUri.Scheme -ne 'https') {
    throw "ContentUri must be an absolute HTTPS URL. Received: '$ContentUri'."
}

Remove-Item -Path $policyPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $policyPath -Force | Out-Null

$commonPolicyParameters = @{
    ContentUri    = $PolicySkeletonUri.AbsoluteUri
    Platform      = 'Linux'
    PolicyVersion = $policyVersion
}

New-GuestConfigurationPolicy @commonPolicyParameters `
    -PolicyId 'c83a51b2-9e47-4c18-a6d3-52f890e14b76' `
    -DisplayName 'Audit MDE Entra ID Device ID on Linux machines' `
    -Description 'Audits the MDE Entra ID Device ID (intuneDeviceId) from wdavstate, falling back to the newest enrollment result in microsoft_defender_enterprise_sensecm.log.' `
    -Path (Join-Path $policyPath 'audit') `
    -Mode Audit | Out-Host

New-GuestConfigurationPolicy @commonPolicyParameters `
    -PolicyId '19d74e6c-5f32-4a89-8b15-73e620c9a4d8' `
    -DisplayName 'Audit MDE Entra ID Device ID on Linux machines' `
    -Description 'Deploys a Linux Audit assignment that reports intuneDeviceId from wdavstate, falling back to the newest enrollment result in microsoft_defender_enterprise_sensecm.log.' `
    -Path (Join-Path $policyPath 'configure') `
    -Mode ApplyAndAutoCorrect | Out-Host

function Update-PolicyValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value
    )

    if ($Value -is [string]) {
        return $Value.
            Replace($PolicySkeletonUri.AbsoluteUri, $ContentUri.AbsoluteUri).
            Replace('MdeDefenderModeConfig', $configurationName).
            Replace($skeletonContentHash, $packageHash)
    }

    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $property.Value = Update-PolicyValue -Value $property.Value
        }
        return $Value
    }

    if ($Value -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $Value[$index] = Update-PolicyValue -Value $Value[$index]
        }
    }

    return $Value
}

$generatedPolicies = @(Get-ChildItem -Path $policyPath -Filter '*.json' -Recurse)
foreach ($generatedPolicy in $generatedPolicies) {
    $policy = Get-Content -Raw $generatedPolicy.FullName | ConvertFrom-Json -Depth 100
    $skeletonContentHash = $policy.properties.metadata.guestConfiguration.contentHash
    $policy = Update-PolicyValue -Value $policy
    $properties = $policy.properties

    $properties.metadata | Add-Member -NotePropertyName version -NotePropertyValue $policyVersion -Force
    $properties | Add-Member -NotePropertyName version -NotePropertyValue $policyVersion -Force
    $properties.metadata.guestConfiguration | Add-Member -NotePropertyName version -NotePropertyValue $policyVersion -Force
    $properties.metadata.guestConfiguration.contentUri = $ContentUri.AbsoluteUri
    $properties.metadata.guestConfiguration.contentHash = $packageHash
    $properties.metadata.guestConfiguration.PSObject.Properties.Remove('enableAutoRemediation')
    $properties.metadata.guestConfiguration.PSObject.Properties.Remove('autoRemediationAssignmentType')
    $properties.parameters.PSObject.Properties.Remove('EnableAutoRemediation')

    $properties.parameters | Add-Member -NotePropertyName tagName -NotePropertyValue ([ordered] @{
        type = 'string'
        metadata = [ordered] @{
            displayName = 'Optional Azure tag name'
            description = 'Name of the Azure resource tag used to filter machines. Leave blank to include all eligible Linux machines.'
        }
        defaultValue = ''
    })
    $properties.parameters | Add-Member -NotePropertyName tagValue -NotePropertyValue ([ordered] @{
        type = 'string'
        metadata = [ordered] @{
            displayName = 'Optional Azure tag value'
            description = 'Required value for the Azure resource tag. Used only when a tag name is provided.'
        }
        defaultValue = ''
    })

    if ($properties.parameters.PSObject.Properties['IncludeArcMachines']) {
        $properties.parameters.IncludeArcMachines.defaultValue = 'true'
    }

    foreach ($parameter in $properties.parameters.PSObject.Properties) {
        $parameterMetadata = $parameter.Value.metadata
        if ($parameterMetadata -is [System.Collections.IDictionary]) {
            $parameterMetadata['portalReview'] = 'true'
        }
        else {
            $parameterMetadata |
                Add-Member -NotePropertyName portalReview -NotePropertyValue 'true' -Force
        }
    }

    $machineEligibility = [ordered] @{
        anyOf = @(
            [ordered] @{
                allOf = @(
                    [ordered] @{
                        anyOf = @(
                            [ordered] @{ field = 'type'; equals = 'Microsoft.Compute/virtualMachines' },
                            [ordered] @{ field = 'type'; equals = 'Microsoft.Compute/virtualMachineScaleSets' }
                        )
                    },
                    [ordered] @{ field = "tags['aks-managed-orchestrator']"; exists = 'false' },
                    [ordered] @{ field = "tags['aks-managed-poolName']"; exists = 'false' },
                    [ordered] @{
                        anyOf = @(
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachines/osProfile.linuxConfiguration'; exists = $true },
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.osType'; like = 'Linux*' },
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachineScaleSets/osProfile.linuxConfiguration'; exists = $true },
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachineScaleSets/virtualMachineProfile.storageProfile.osDisk.osType'; like = 'Linux*' }
                        )
                    }
                )
            },
            [ordered] @{
                allOf = @(
                    [ordered] @{ value = "[parameters('IncludeArcMachines')]"; equals = 'true' },
                    [ordered] @{
                        anyOf = @(
                            [ordered] @{
                                allOf = @(
                                    [ordered] @{ field = 'type'; equals = 'Microsoft.HybridCompute/machines' },
                                    [ordered] @{ field = 'Microsoft.HybridCompute/machines/osType'; like = 'linux*' }
                                )
                            },
                            [ordered] @{
                                allOf = @(
                                    [ordered] @{ field = 'type'; equals = 'Microsoft.ConnectedVMwarevSphere/virtualMachines' },
                                    [ordered] @{ field = 'Microsoft.ConnectedVMwarevSphere/virtualMachines/osProfile.osType'; like = 'linux*' }
                                )
                            }
                        )
                    }
                )
            }
        )
    }
    $properties.policyRule.if = [ordered] @{
        allOf = @(
            $machineEligibility,
            [ordered] @{
                anyOf = @(
                    [ordered] @{
                        value = "[empty(parameters('tagName'))]"
                        equals = $true
                    },
                    [ordered] @{
                        field = "[concat('tags[', parameters('tagName'), ']')]"
                        equals = "[parameters('tagValue')]"
                    }
                )
            }
        )
    }

    $properties.metadata.requiredProviders = @($properties.metadata.requiredProviders)
    if ($properties.policyRule.then.effect -ne 'auditIfNotExists') {
        $properties.policyRule.then.details.roleDefinitionIds = @($guestConfigurationRoleDefinitionId)
        $properties.policyRule.then.details.existenceCondition = [ordered] @{
            field  = 'Microsoft.GuestConfiguration/guestConfigurationAssignments/complianceStatus'
            equals = 'Compliant'
        }
    }

    foreach ($resource in @($properties.policyRule.then.details.deployment.properties.template.resources)) {
        $guestConfiguration = $resource.properties.guestConfiguration
        if ($null -eq $guestConfiguration) {
            continue
        }
        $guestConfiguration |
            Add-Member -NotePropertyName version -NotePropertyValue $policyVersion -Force
        if ($guestConfiguration.PSObject.Properties['assignmentType']) {
            $guestConfiguration.assignmentType = 'Audit'
        }
    }

    $renamedPolicyPath = Join-Path $generatedPolicy.DirectoryName $generatedPolicy.Name.Replace('MdeDefenderModeConfig', $configurationName)
    $policy | ConvertTo-Json -Depth 100 | Set-Content -Path $renamedPolicyPath -Encoding utf8
    if ($renamedPolicyPath -ne $generatedPolicy.FullName) {
        Remove-Item -Path $generatedPolicy.FullName
    }
}

$configurePolicyPath = Join-Path $policyPath "configure\${configurationName}_DeployIfNotExists.json"
$configurePolicyObj = Get-Content -Raw $configurePolicyPath | ConvertFrom-Json -Depth 100
$portalPolicy = [ordered] @{
    mode       = $configurePolicyObj.properties.mode
    version    = $policyVersion
    metadata   = $configurePolicyObj.properties.metadata
    parameters = $configurePolicyObj.properties.parameters
    policyRule = $configurePolicyObj.properties.policyRule
}
$portalPolicy | ConvertTo-Json -Depth 100 | Set-Content -Path $ConfigurePolicyOutputPath -Encoding utf8

# Generate dedicated Native Virtual Machines policy (checks MDE.Linux extension is installed) and dedicated Azure Arc policy (checks MDE.Linux extension is installed)
$vmOnlyPolicy = Get-Content -Raw $configurePolicyPath | ConvertFrom-Json -Depth 100
$vmOnlyPolicy.name = 'c34a0b56-8d39-4e94-af72-5b13a6c4d9e8'
$vmOnlyPolicy.properties.displayName = 'Audit MDE Entra ID Device ID on Linux machines'
$vmOnlyPolicy.properties.description = 'Checks MDE.Linux provisioning on native Azure Linux virtual machines, then deploys an Audit assignment that reads intuneDeviceId from wdavstate with a newest-enrollment SenseCM log fallback.'
$vmOnlyPolicy.properties.parameters.PSObject.Properties.Remove('IncludeArcMachines')
$vmOnlyPolicy.properties.policyRule.if = [ordered] @{
    allOf = @(
        [ordered] @{
            field  = 'type'
            equals = 'Microsoft.Compute/virtualMachines/extensions'
        },
        [ordered] @{
            anyOf = @(
                [ordered] @{
                    field = 'name'
                    like  = '*/MDE.Linux'
                },
                [ordered] @{
                    field  = 'Microsoft.Compute/virtualMachines/extensions/type'
                    equals = 'MDE.Linux'
                }
            )
        },
        [ordered] @{
            field = 'Microsoft.Compute/virtualMachines/extensions/provisioningState'
            in    = @('Succeeded', 'Provisioning succeeded')
        },
        [ordered] @{
            anyOf = @(
                [ordered] @{
                    value  = "[empty(parameters('tagName'))]"
                    equals = $true
                },
                [ordered] @{
                    field  = "[concat('tags[', parameters('tagName'), ']')]"
                    equals = "[parameters('tagValue')]"
                }
            )
        }
    )
}
$vmOnlyPolicy.properties.policyRule.then.details.deployment.properties.parameters.vmName.value = "[first(split(field('name'), '/'))]"
$vmOnlyPolicy.properties.policyRule.then.details.deployment.properties.parameters.type.value = 'Microsoft.Compute/virtualMachines'
$vmOnlyPolicy.properties.policyRule.then.details.deployment.properties.template.resources = @(
    $vmOnlyPolicy.properties.policyRule.then.details.deployment.properties.template.resources |
        Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines/providers/guestConfigurationAssignments' } |
        ForEach-Object {
            $_.PSObject.Properties.Remove('condition')
            $_
        }
)
$vmOnlyPath = Join-Path $policyPath "configure\${configurationName}_VirtualMachines_DeployIfNotExists.json"
$vmOnlyPolicy | ConvertTo-Json -Depth 100 | Set-Content -Path $vmOnlyPath -Encoding utf8

$arcOnlyPolicy = Get-Content -Raw $configurePolicyPath | ConvertFrom-Json -Depth 100
$arcOnlyPolicy.name = 'd45b1c67-9e40-4f05-b083-6c24b7d5e0f9'
$arcOnlyPolicy.properties.displayName = 'Audit MDE Entra ID Device ID on Linux Arc machines'
$arcOnlyPolicy.properties.description = 'Checks MDE.Linux provisioning on Linux Azure Arc-enabled servers, then deploys an Audit assignment that reads intuneDeviceId from wdavstate with a newest-enrollment SenseCM log fallback.'
$arcOnlyPolicy.properties.parameters.PSObject.Properties.Remove('IncludeArcMachines')
$arcOnlyPolicy.properties.policyRule.if = [ordered] @{
    allOf = @(
        [ordered] @{
            field  = 'type'
            equals = 'Microsoft.HybridCompute/machines/extensions'
        },
        [ordered] @{
            anyOf = @(
                [ordered] @{
                    field = 'name'
                    like  = '*/MDE.Linux'
                },
                [ordered] @{
                    field  = 'Microsoft.HybridCompute/machines/extensions/type'
                    equals = 'MDE.Linux'
                }
            )
        },
        [ordered] @{
            field = 'Microsoft.HybridCompute/machines/extensions/provisioningState'
            in    = @('Succeeded', 'Provisioning succeeded')
        },
        [ordered] @{
            anyOf = @(
                [ordered] @{
                    value  = "[empty(parameters('tagName'))]"
                    equals = $true
                },
                [ordered] @{
                    field  = "[concat('tags[', parameters('tagName'), ']')]"
                    equals = "[parameters('tagValue')]"
                }
            )
        }
    )
}
$arcOnlyPolicy.properties.policyRule.then.details.deployment.properties.parameters.vmName.value = "[first(split(field('name'), '/'))]"
$arcOnlyPolicy.properties.policyRule.then.details.deployment.properties.parameters.type.value = 'Microsoft.HybridCompute/machines'
$arcOnlyPolicy.properties.policyRule.then.details.deployment.properties.template.resources = @(
    $arcOnlyPolicy.properties.policyRule.then.details.deployment.properties.template.resources |
        Where-Object { $_.type -eq 'Microsoft.HybridCompute/machines/providers/guestConfigurationAssignments' } |
        ForEach-Object {
            $_.PSObject.Properties.Remove('condition')
            $_
        }
)
$arcOnlyPath = Join-Path $policyPath "configure\${configurationName}_AzureArc_DeployIfNotExists.json"
$arcOnlyPolicy | ConvertTo-Json -Depth 100 | Set-Content -Path $arcOnlyPath -Encoding utf8

function ConvertTo-ArmLiteral {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Value.StartsWith('[') -and $Value.EndsWith(']')) { return "[$Value" }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered] @{}
        foreach ($key in $Value.Keys) {
            $result[$key] = ConvertTo-ArmLiteral -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered] @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-ArmLiteral -Value $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-ArmLiteral -Value $_ })
        Write-Output -NoEnumerate $items
        return
    }
    return $Value
}

function Save-PolicyArmTemplate {
    param(
        [hashtable] $PolicyProps,
        [string] $OutputPath,
        [string] $DefaultName,
        [string] $DefaultDisplayName,
        [string] $Description
    )
    $policyRule = ConvertTo-ArmLiteral -Value $PolicyProps.policyRule
    $roleIds = @($PolicyProps.policyRule.then.details.roleDefinitionIds)
    if ($roleIds.Count -gt 0) {
        $escapedRoleIds = $roleIds | ForEach-Object { "'$($_ -replace "'", "''")'" }
        $policyRule.then.details.roleDefinitionIds = "[createArray($($escapedRoleIds -join ', '))]"
    }
    $armTemplate = [ordered] @{
        '$schema' = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        metadata = [ordered] @{ description = $Description }
        parameters = [ordered] @{
            policyDefinitionName = [ordered] @{
                type = 'string'
                defaultValue = $DefaultName
                metadata = [ordered] @{ description = 'Name of the custom Azure Policy definition.' }
            }
            policyDefinitionDisplayName = [ordered] @{
                type = 'string'
                defaultValue = $DefaultDisplayName
                metadata = [ordered] @{ description = 'Display name of the custom Azure Policy definition.' }
            }
        }
        resources = @(
            [ordered] @{
                type = 'Microsoft.Authorization/policyDefinitions'
                apiVersion = '2023-04-01'
                name = "[parameters('policyDefinitionName')]"
                properties = [ordered] @{
                    policyType = 'Custom'
                    version = $policyVersion
                    mode = $PolicyProps.mode
                    displayName = "[parameters('policyDefinitionDisplayName')]"
                    description = $Description
                    metadata = ConvertTo-ArmLiteral -Value $PolicyProps.metadata
                    parameters = ConvertTo-ArmLiteral -Value $PolicyProps.parameters
                    policyRule = $policyRule
                }
            }
        )
    }
    $armTemplate | ConvertTo-Json -Depth 100 | Set-Content -Path $OutputPath -Encoding utf8
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Save-PolicyArmTemplate -PolicyProps @{
    mode = $vmOnlyPolicy.properties.mode
    metadata = $vmOnlyPolicy.properties.metadata
    parameters = $vmOnlyPolicy.properties.parameters
    policyRule = $vmOnlyPolicy.properties.policyRule
} -OutputPath (Join-Path $repoRoot 'configureEntraIdDeviceIdLinuxVM.armtemplate.json') `
  -DefaultName 'audit-mde-entraid-deviceid-linux-machines' `
  -DefaultDisplayName $vmOnlyPolicy.properties.displayName `
  -Description $vmOnlyPolicy.properties.description

Save-PolicyArmTemplate -PolicyProps @{
    mode = $arcOnlyPolicy.properties.mode
    metadata = $arcOnlyPolicy.properties.metadata
    parameters = $arcOnlyPolicy.properties.parameters
    policyRule = $arcOnlyPolicy.properties.policyRule
} -OutputPath (Join-Path $repoRoot 'configureEntraIdDeviceIdLinuxArc.armtemplate.json') `
  -DefaultName 'audit-mde-entraid-deviceid-linux-arc-machines' `
  -DefaultDisplayName $arcOnlyPolicy.properties.displayName `
  -Description $arcOnlyPolicy.properties.description

Save-PolicyArmTemplate -PolicyProps @{
    mode = $configurePolicyObj.properties.mode
    metadata = $configurePolicyObj.properties.metadata
    parameters = $configurePolicyObj.properties.parameters
    policyRule = $configurePolicyObj.properties.policyRule
} -OutputPath (Join-Path $repoRoot 'configureEntraIdDeviceIdLinux.armtemplate.json') `
  -DefaultName 'audit-mde-entraid-deviceid-linux' `
  -DefaultDisplayName $configurePolicyObj.properties.displayName `
  -Description $configurePolicyObj.properties.description

$winArmPath = Join-Path $repoRoot 'configureEntraIdDeviceIdWindows.armtemplate.json'
if (Test-Path -LiteralPath $winArmPath -PathType Leaf) {
    $winArm = Get-Content -Raw $winArmPath | ConvertFrom-Json -Depth 100
    $linArm = Get-Content -Raw (Join-Path $repoRoot 'configureEntraIdDeviceIdLinux.armtemplate.json') | ConvertFrom-Json -Depth 100
    $winResource = $winArm.resources[0]
    $winResource.name = "[parameters('windowsPolicyDefinitionName')]"
    $winResource.properties.displayName = "[parameters('windowsPolicyDefinitionDisplayName')]"
    $linResource = $linArm.resources[0]
    $linResource.name = "[parameters('linuxPolicyDefinitionName')]"
    $linResource.properties.displayName = "[parameters('linuxPolicyDefinitionDisplayName')]"

    $combinedBothTemplate = [ordered] @{
        '$schema' = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        metadata = [ordered] @{
            description = 'Deploys both the Windows and Linux combined MDE Entra ID Device ID Azure Policy definitions (Audit MDE Entra ID Device ID on Windows machines and Audit MDE Entra ID Device ID on Linux machines).'
        }
        parameters = [ordered] @{
            windowsPolicyDefinitionName = [ordered] @{
                type = 'string'
                defaultValue = 'audit-mde-entraid-deviceid-windows'
                metadata = [ordered] @{ description = 'Name of the Windows custom Azure Policy definition.' }
            }
            windowsPolicyDefinitionDisplayName = [ordered] @{
                type = 'string'
                defaultValue = 'Audit MDE Entra ID Device ID on Windows machines'
                metadata = [ordered] @{ description = 'Display name of the Windows custom Azure Policy definition.' }
            }
            linuxPolicyDefinitionName = [ordered] @{
                type = 'string'
                defaultValue = 'audit-mde-entraid-deviceid-linux'
                metadata = [ordered] @{ description = 'Name of the Linux custom Azure Policy definition.' }
            }
            linuxPolicyDefinitionDisplayName = [ordered] @{
                type = 'string'
                defaultValue = 'Audit MDE Entra ID Device ID on Linux machines'
                metadata = [ordered] @{ description = 'Display name of the Linux custom Azure Policy definition.' }
            }
        }
        resources = @(
            $winResource,
            $linResource
        )
    }
    $combinedBothPath = Join-Path $repoRoot 'configureEntraIdDeviceId.armtemplate.json'
    $combinedBothTemplate | ConvertTo-Json -Depth 100 | Set-Content -Path $combinedBothPath -Encoding utf8
    Write-Host "Combined Windows + Linux ARM template written to '$combinedBothPath'."
}

Write-Host "Policy definitions created under '$policyPath'."
Write-Host "Portal-ready configure policy written to '$ConfigurePolicyOutputPath'."
