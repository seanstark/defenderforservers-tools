[CmdletBinding()]
param(
    [Parameter()]
    [uri] $ContentUri,

    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),

    [Parameter()]
    [uri] $PolicySkeletonUri = 'https://github.com/seanstark/defenderforservers-tools/raw/refs/heads/main/machineConfiguration/mde-defender-mode/output/MdeDefenderModeConfig.zip',

    [Parameter()]
    [string] $ConfigurePolicyOutputPath = (Join-Path $PSScriptRoot '..\..\configureEntraIdDeviceIdWindows.json')
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7. Run it with 'pwsh', not Windows PowerShell ('powershell.exe')."
}

$configurationName = 'entraiddeviceid'
$packageVersion = '1.0.0'
$guestConfigurationRoleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/088ab73d-1256-47ae-bea9-9de8e7131f31'
$configurationPath = Join-Path $PSScriptRoot 'entraid-deviceid.ps1'
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
    entraiddeviceid -OutputPath $compiledPath
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

instance of EntraIdDeviceId as `$EntraIdDeviceId1ref
{
SourceInfo = "::5::9::EntraIdDeviceId";
 ModuleName = "EntraIdDeviceId";
 Name = "EnrollmentPayload";
 ResourceID = "[EntraIdDeviceId]$configurationName";
 ModuleVersion = "$packageVersion";
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
    -Configuration $namedMof `
    -Version $packageVersion `
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
    Platform      = 'Windows'
    PolicyVersion = $packageVersion
}

New-GuestConfigurationPolicy @commonPolicyParameters `
    -PolicyId 'd41f9b7e-8a24-43c1-b9e0-61c5a4f82e31' `
    -DisplayName 'Audit MDE Entra ID Device ID on Windows machines' `
    -Description 'Audits and reports the MDE Entra ID Device ID (intuneDeviceId) from HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\SenseCM\MemConfiguration\EnrollmentPayload by using Azure Machine Configuration.' `
    -Path (Join-Path $policyPath 'audit') `
    -Mode Audit | Out-Host

New-GuestConfigurationPolicy @commonPolicyParameters `
    -PolicyId '7a92c4e1-3b58-4d62-9f14-82e7b5c30d94' `
    -DisplayName 'Audit MDE Entra ID Device ID on Windows machines' `
    -Description 'Deploys the Azure Machine Configuration assignment that audits and reports the MDE Entra ID Device ID (intuneDeviceId) from HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\SenseCM\MemConfiguration\EnrollmentPayload on Windows machines.' `
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

    $properties.metadata.guestConfiguration.contentUri = $ContentUri.AbsoluteUri
    $properties.metadata.guestConfiguration.contentHash = $packageHash
    $properties.metadata.guestConfiguration |
        Add-Member -NotePropertyName version -NotePropertyValue $packageVersion -Force
    $properties.metadata.guestConfiguration.PSObject.Properties.Remove('enableAutoRemediation')
    $properties.metadata.guestConfiguration.PSObject.Properties.Remove('autoRemediationAssignmentType')
    $properties.parameters.PSObject.Properties.Remove('EnableAutoRemediation')

    $properties.parameters | Add-Member -NotePropertyName tagName -NotePropertyValue ([ordered] @{
        type = 'string'
        metadata = [ordered] @{
            displayName = 'Optional Azure tag name'
            description = 'Name of the Azure resource tag used to filter machines. Leave blank to include all eligible Windows machines.'
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
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachines/osProfile.windowsConfiguration'; exists = $true },
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.osType'; like = 'Windows*' },
                            [ordered] @{ field = 'Microsoft.Compute/VirtualMachineScaleSets/osProfile.windowsConfiguration'; exists = $true },
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachineScaleSets/virtualMachineProfile.storageProfile.osDisk.osType'; like = 'Windows*' }
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
                                    [ordered] @{ field = 'Microsoft.HybridCompute/machines/osType'; like = 'windows*' }
                                )
                            },
                            [ordered] @{
                                allOf = @(
                                    [ordered] @{ field = 'type'; equals = 'Microsoft.ConnectedVMwarevSphere/virtualMachines' },
                                    [ordered] @{ field = 'Microsoft.ConnectedVMwarevSphere/virtualMachines/osProfile.osType'; like = 'windows*' }
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
            Add-Member -NotePropertyName version -NotePropertyValue $packageVersion -Force
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
    metadata   = $configurePolicyObj.properties.metadata
    parameters = $configurePolicyObj.properties.parameters
    policyRule = $configurePolicyObj.properties.policyRule
}
$portalPolicy | ConvertTo-Json -Depth 100 | Set-Content -Path $ConfigurePolicyOutputPath -Encoding utf8

# Generate dedicated Native Virtual Machines policy (checks MDE.Windows extension is installed) and dedicated Azure Arc policy (checks MDE.Windows extension is installed)
$vmOnlyPolicy = Get-Content -Raw $configurePolicyPath | ConvertFrom-Json -Depth 100
$vmOnlyPolicy.name = 'a12e8f34-6b19-4c72-8d50-3f91e4a2b7c6'
$vmOnlyPolicy.properties.displayName = 'Audit MDE Entra ID Device ID on Windows machines'
$vmOnlyPolicy.properties.description = 'Checks that the MDE.Windows extension is installed and provisioned on native Azure Windows virtual machines, then deploys the entraiddeviceid Azure Machine Configuration assignment to audit and report the MDE Entra ID Device ID (intuneDeviceId) from HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\SenseCM\MemConfiguration\EnrollmentPayload.'
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
                    like  = '*/MDE.Windows'
                },
                [ordered] @{
                    field  = 'Microsoft.Compute/virtualMachines/extensions/type'
                    equals = 'MDE.Windows'
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
$arcOnlyPolicy.name = 'b23f9a45-7c28-4d83-9e61-4a02f5b3c8d7'
$arcOnlyPolicy.properties.displayName = 'Audit MDE Entra ID Device ID on Windows Arc machines'
$arcOnlyPolicy.properties.description = 'Checks that the MDE.Windows extension is installed and provisioned on Windows Azure Arc-enabled servers, then deploys the entraiddeviceid Azure Machine Configuration assignment to audit and report the MDE Entra ID Device ID (intuneDeviceId) from HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\SenseCM\MemConfiguration\EnrollmentPayload.'
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
                    like  = '*/MDE.Windows'
                },
                [ordered] @{
                    field  = 'Microsoft.HybridCompute/machines/extensions/type'
                    equals = 'MDE.Windows'
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
} -OutputPath (Join-Path $repoRoot 'configureEntraIdDeviceIdWindowsVM.armtemplate.json') `
  -DefaultName 'audit-mde-entraid-deviceid-windows-machines' `
  -DefaultDisplayName $vmOnlyPolicy.properties.displayName `
  -Description $vmOnlyPolicy.properties.description

Save-PolicyArmTemplate -PolicyProps @{
    mode = $arcOnlyPolicy.properties.mode
    metadata = $arcOnlyPolicy.properties.metadata
    parameters = $arcOnlyPolicy.properties.parameters
    policyRule = $arcOnlyPolicy.properties.policyRule
} -OutputPath (Join-Path $repoRoot 'configureEntraIdDeviceIdWindowsArc.armtemplate.json') `
  -DefaultName 'audit-mde-entraid-deviceid-windows-arc-machines' `
  -DefaultDisplayName $arcOnlyPolicy.properties.displayName `
  -Description $arcOnlyPolicy.properties.description

Save-PolicyArmTemplate -PolicyProps @{
    mode = $configurePolicyObj.properties.mode
    metadata = $configurePolicyObj.properties.metadata
    parameters = $configurePolicyObj.properties.parameters
    policyRule = $configurePolicyObj.properties.policyRule
} -OutputPath (Join-Path $repoRoot 'configureEntraIdDeviceIdWindows.armtemplate.json') `
  -DefaultName 'audit-mde-entraid-deviceid-windows' `
  -DefaultDisplayName $configurePolicyObj.properties.displayName `
  -Description $configurePolicyObj.properties.description

Write-Host "Policy definitions created under '$policyPath'."
Write-Host "Portal-ready configure policy written to '$ConfigurePolicyOutputPath'."
