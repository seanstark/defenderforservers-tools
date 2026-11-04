[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$parseFailures = @()
Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object Extension -in '.ps1', '.psm1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    $parseFailures += $errors
}
if ($parseFailures.Count) { throw ($parseFailures | Out-String) }
Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' | ForEach-Object {
    $null = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
}

$names = @('SYNC_SUBSCRIPTION_IDS', 'SYNC_MANAGEMENT_GROUP_IDS', 'SYNC_RESOURCE_GROUP_NAMES', 'SYNC_DEFAULT_GROUP_MODE', 'SYNC_ADMIN_UNIT_ID', 'SYNC_AUTO_CREATE_GROUPS', 'SYNC_AWS_WINDOWS_GROUP_PREFIX', 'SYNC_AWS_LINUX_GROUP_PREFIX', 'SYNC_GCP_WINDOWS_GROUP_PREFIX', 'SYNC_GCP_LINUX_GROUP_PREFIX', 'SYNC_AZURE_WINDOWS_GROUP_PREFIX', 'SYNC_AZURE_LINUX_GROUP_PREFIX', 'SYNC_MODE', 'SYNC_TENANT_ID', 'SYNC_FRESHNESS_HOURS', 'WEBSITE_HOSTNAME', 'ServiceBusConnection__fullyQualifiedNamespace', 'AzureFunctionsJobHost__functionTimeout')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$env:SYNC_SUBSCRIPTION_IDS = '11111111-1111-1111-1111-111111111111'
$env:SYNC_MANAGEMENT_GROUP_IDS = ''
$env:SYNC_RESOURCE_GROUP_NAMES = ''
$env:SYNC_DEFAULT_GROUP_MODE = 'Passive'
$env:SYNC_ADMIN_UNIT_ID = ''
$env:SYNC_AUTO_CREATE_GROUPS = ''
$env:SYNC_AWS_WINDOWS_GROUP_PREFIX = 'MDfS-AWS-Windows-'
$env:SYNC_AWS_LINUX_GROUP_PREFIX = 'MDfS-AWS-Linux-'
$env:SYNC_GCP_WINDOWS_GROUP_PREFIX = 'MDfS-GCP-Windows-'
$env:SYNC_GCP_LINUX_GROUP_PREFIX = 'MDfS-GCP-Linux-'
$env:SYNC_AZURE_WINDOWS_GROUP_PREFIX = 'MDfS-Azure-Windows-'
$env:SYNC_AZURE_LINUX_GROUP_PREFIX = 'MDfS-Azure-Linux-'
$env:SYNC_MODE = 'Audit'
$env:SYNC_TENANT_ID = '33333333-3333-3333-3333-333333333333'
$env:SYNC_FRESHNESS_HOURS = '24'
$module = Import-Module "$root\shared\Sync.psm1" -Force -PassThru
try {
    & $module {
        $script:Passed = 0
        $script:Failed = 0
        $originals = @{}
        foreach ($name in @('Invoke-CloudRequest', 'Invoke-Graph', 'Invoke-Table', 'Get-MachineState', 'Save-MachineState',
            'Get-MdeCandidates', 'Test-Group', 'Resolve-GroupByDisplayName', 'Get-DeviceCloudGroups', 'Test-DirectMembership', 'Write-MutationIntent', 'Get-TableBase', 'Get-TablePage',
            'Send-MachineWork', 'Get-AccessToken', 'Invoke-WebRequest', 'Start-Sleep',
            'Get-SubscriptionName', 'Get-ArcExtensions', 'Get-MdeNetworkAddresses', 'Get-MdeAntivirus', 'Get-ManagementGroupSubscriptions', 'Write-FunctionLog',
            'Get-SharedAdminUnitGroups', 'Save-SharedAdminUnitGroups', 'New-AdminUnitSecurityGroup', 'Initialize-InventoryGroups',
            'Start-InventoryJob', 'Complete-InventoryJob', 'Invoke-InventoryRun', 'Get-InventoryJobStatus', 'New-ReportSyncRequest',
            'Get-GuestConfigurationRefreshBody', 'Request-GuestConfigurationRefresh', 'Get-TokenClaims')) {
            $command = Get-Command $name -ErrorAction SilentlyContinue
            $originals[$name] = if ($command -and $command.CommandType -eq 'Function') { $command.ScriptBlock } else { $null }
        }
        function Assert-Equal($Actual, $Expected) {
            if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
        }
        function Assert-True($Value) { if (-not $Value) { throw 'Expected true.' } }
        function Assert-Throws([scriptblock]$Action) {
            $thrown = $false
            try { & $Action } catch { $thrown = $true }
            if (-not $thrown) { throw 'Expected an exception.' }
        }
        function Test-Case([string]$Name, [scriptblock]$Action) {
            try {
                function script:Get-SharedAdminUnitGroups { return $null }
                function script:Start-InventoryJob { @{ RunId = [guid]::NewGuid().ToString() } }
                function script:Complete-InventoryJob {
                    param($RunId, $Status, $Message)
                    $script:LastJobCompletion = @{ RunId = $RunId; Status = $Status; Message = $Message }
                }
                & $Action
                $script:Passed++
                Write-Host "PASS $Name"
            }
            catch {
                $script:Failed++
                Write-Host "FAIL $Name`: $($_.Exception.Message)"
            }
            finally {
                $env:SYNC_SUBSCRIPTION_IDS = '11111111-1111-1111-1111-111111111111'
                $env:SYNC_MANAGEMENT_GROUP_IDS = ''
                $env:SYNC_RESOURCE_GROUP_NAMES = ''
                $env:SYNC_DEFAULT_GROUP_MODE = 'Passive'
                $env:WEBSITE_HOSTNAME = ''
                $env:ServiceBusConnection__fullyQualifiedNamespace = ''
                $env:AzureFunctionsJobHost__functionTimeout = ''
                $env:SYNC_AWS_WINDOWS_GROUP_PREFIX = 'MDfS-AWS-Windows-'
                $env:SYNC_AWS_LINUX_GROUP_PREFIX = 'MDfS-AWS-Linux-'
                $env:SYNC_GCP_WINDOWS_GROUP_PREFIX = 'MDfS-GCP-Windows-'
                $env:SYNC_GCP_LINUX_GROUP_PREFIX = 'MDfS-GCP-Linux-'
                $env:SYNC_AZURE_WINDOWS_GROUP_PREFIX = 'MDfS-Azure-Windows-'
                $env:SYNC_AZURE_LINUX_GROUP_PREFIX = 'MDfS-Azure-Linux-'
                $script:ManagementGroupSubscriptions = @{}
                $script:ManagementGroupCacheExpires = [datetimeoffset]::MinValue
                $script:GroupByNameCache = @{}
                $script:AdminUnitGroupsCache = @{}
                $script:AdminUnitGroupsExpires = @{}
                $script:SharedAdminUnitGroups = @{}
                foreach ($entry in $originals.GetEnumerator()) {
                    if ($entry.Value) { Set-Item -Path "Function:script:$($entry.Key)" -Value $entry.Value }
                    else { Remove-Item -Path "Function:script:$($entry.Key)" -ErrorAction SilentlyContinue }
                }
            }
        }
        $id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.HybridCompute/machines/Server01'
        $now = [datetimeoffset]::UtcNow
        $candidate = @{
            Timestamp = $now.ToString('o'); DeviceId = 'mde1'; DeviceName = 'server01.example.com'
            AadDeviceId = '44444444-4444-4444-4444-444444444444'
            OnboardingStatus = 'Onboarded'; MergedToDeviceId = ''
            SensorHealthState = 'Active'; CloudPlatforms = 'Azure Arc'; AzureVmId = 'mde-vm-id'; PublicIP = '203.0.113.10'
            DeviceManualTags = '["Production","Tier 1"]'; DeviceDynamicTags = '["Production","Server"]'
            RegistryDeviceTag = 'Managed'; MachineGroup = 'Production servers'
        }
        Test-Case 'Arc ID normalization and stable key' {
            Assert-Equal (ConvertTo-ArcId $id) $id.ToLowerInvariant()
            $vmId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.Compute/virtualMachines/Vm01'
            $classicVmId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.ClassicCompute/virtualMachines/ClassicVm01'
            $vmssInstanceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.Compute/virtualMachineScaleSets/ScaleSet01/virtualMachines/0'
            Assert-Equal (ConvertTo-ArcId $vmId) $vmId.ToLowerInvariant()
            Assert-Equal (ConvertTo-ArcId $classicVmId) $classicVmId.ToLowerInvariant()
            Assert-Equal (ConvertTo-ArcId $vmssInstanceId) $vmssInstanceId.ToLowerInvariant()
            Assert-Equal (Get-ResourceKind $vmId) 'AzureVm'
            Assert-Equal (Get-ResourceKind $classicVmId) 'ClassicVm'
            Assert-Equal (Get-ResourceKind $vmssInstanceId) 'VmssVm'
            Assert-Equal (Get-MachineDisplayName $vmssInstanceId.ToLowerInvariant()) 'scaleset01_0'
            Assert-Equal (Get-ResourceKind $id) 'Arc'
            $vmMeta = Resolve-MachineStatusAndOS -ResourceId $vmId -Resource @{
                properties = @{
                    storageProfile = @{ osDisk = @{ osType = 'Windows' } }
                    instanceView = @{ statuses = @(@{ code = 'PowerState/running'; displayStatus = 'VM running' }) }
                }
            }
            Assert-Equal $vmMeta.Status 'VM running'
            Assert-Equal $vmMeta.OS 'Windows'
            $deallocMeta = Resolve-MachineStatusAndOS -ResourceId $vmId -Resource @{
                properties = @{
                    storageProfile = @{ osDisk = @{ osType = 'Linux' } }
                    instanceView = @{ statuses = @(@{ code = 'PowerState/deallocated'; displayStatus = 'VM deallocated' }) }
                }
            }
            Assert-Equal $deallocMeta.Status 'VM deallocated'
            Assert-Equal $deallocMeta.OS 'Linux'
            Assert-Equal (Get-MachineKey $id) (Get-MachineKey $id.ToUpperInvariant())
            Assert-Equal (Get-MachineKey $id).Length 64
        }
        Test-Case 'Reject out-of-scope and malformed resource IDs' {
            Assert-Throws { ConvertTo-ArcId ($id.Replace('11111111', '99999999')) }
            Assert-Throws { ConvertTo-ArcId "$id?api-version=bad" }
            Assert-Throws { ConvertTo-ArcId "$id/extensions/test" }
        }
        Test-Case 'Resource group and management group scoping validate and query Resource Graph' {
            $env:SYNC_RESOURCE_GROUP_NAMES = 'Servers,rg-prod'
            Assert-Equal (ConvertTo-ArcId $id) $id.ToLowerInvariant()
            Assert-Throws { ConvertTo-ArcId ($id.Replace('/resourceGroups/Servers/', '/resourceGroups/OtherRg/')) }
            $env:SYNC_SUBSCRIPTION_IDS = ''
            $env:SYNC_MANAGEMENT_GROUP_IDS = 'mg-servers'
            function script:Get-ManagementGroupSubscriptions { @('88888888-8888-8888-8888-888888888888') }
            $mgId = '/subscriptions/88888888-8888-8888-8888-888888888888/resourceGroups/rg-prod/providers/Microsoft.HybridCompute/machines/Server02'
            Assert-Equal (ConvertTo-ArcId $mgId) $mgId.ToLowerInvariant()
            Assert-Throws { ConvertTo-ArcId ($mgId.Replace('/resourceGroups/rg-prod/', '/resourceGroups/unscoped/')) }
            Assert-Throws { ConvertTo-ArcId $id }
            $script:GraphBodies = @()
            $script:Queued = @()
            $script:InventorySteps = @()
            function script:Initialize-InventoryGroups {
                param($Config, $WorkItems, $MdeMap)
                Assert-Equal $WorkItems.Count 2
                $script:InventorySteps += 'GroupsReady'
                @{ Existing = 0; Created = 0; WouldCreate = 0; Missing = 0 }
            }
            function script:Invoke-CloudRequest {
                param($Uri, $Resource, $Method, $Body)
                if ($Body -and $Body['query']) {
                    $script:GraphBodies += $Body
                }
                if ($Body -and $Body['query'] -and $Body.query.Contains('virtualmachinescalesets/virtualmachines')) {
                    $vmssVm = '/subscriptions/88888888-8888-8888-8888-888888888888/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachineScaleSets/vmss01/virtualMachines/0'
                    return @{ Content = (@{ data = @(@{ id = $vmssVm }); resultTruncated = 'false' } | ConvertTo-Json -Compress) }
                }
                @{ Content = (@{ data = @(@{ id = $mgId }); resultTruncated = 'false' } | ConvertTo-Json -Compress) }
            }
            function script:Get-TablePage { @{ Items = @(); Cursor = '' } }
            function script:Write-FunctionLog {
                param($Entry)
                $script:LastFunctionLog = $Entry
            }
            function script:Send-MachineWork {
                param($ResourceId)
                Assert-Equal $script:InventorySteps[0] 'GroupsReady'
                $script:InventorySteps += 'MachineQueued'
                $script:Queued += $ResourceId
            }
            Invoke-InventorySync -TriggerReason 'Scheduled timer (NCRONTAB schedule)'
            Assert-Equal $script:GraphBodies.Count 2
            Assert-Equal ($script:GraphBodies[0].managementGroups -join ',') 'mg-servers'
            Assert-True ($script:GraphBodies[0].query.Contains("type in ('microsoft.compute/virtualmachines', 'microsoft.classiccompute/virtualmachines')"))
            Assert-True ($script:GraphBodies[0].query.Contains("!contains 'deallocated'"))
            Assert-True ($script:GraphBodies[0].query.Contains("!contains 'Compute.AKS'"))
            Assert-True ($script:GraphBodies[0].query.Contains('tolower(resourceGroup) in ("rg-prod", "servers")'))
            Assert-True ($script:GraphBodies[1].query.Contains("type == 'microsoft.compute/virtualmachinescalesets'"))
            Assert-True ($script:GraphBodies[1].query.Contains('microsoft.compute/virtualmachinescalesets/virtualmachines'))
            Assert-Equal $script:Queued.Count 2
            Assert-Equal $script:LastFunctionLog.FunctionName 'Inventory'
            Assert-Equal $script:LastFunctionLog.TriggerReason 'Scheduled timer (NCRONTAB schedule)'
            Assert-Equal $script:LastFunctionLog.Status 'Succeeded'
            Assert-Equal $script:LastFunctionLog.Health 'Healthy'
            $script:Queued = @()
            function script:Initialize-InventoryGroups { throw 'Group catalog could not be published.' }
            Assert-Throws { Invoke-InventorySync }
            Assert-Equal $script:Queued.Count 0
            Assert-Equal $script:LastFunctionLog.Status 'Failed'
            $env:SYNC_MANAGEMENT_GROUP_IDS = ''
            Assert-Throws { Get-SyncConfig }
        }
        Test-Case 'Unique fresh onboarded device correlates' {
            Assert-Equal (Get-Correlation @($candidate) 24 $now).Status 'Matched'
        }
        Test-Case 'Missing optional hostname does not break ID-based inventory correlation' {
            $withoutName = $candidate.Clone()
            $withoutName.DeviceName = $null
            $state = @{ IPAddresses = @(); CloudProvider = ''; Fqdn = ''; ComputerName = '' }
            Set-MdeInventory $state $withoutName
            Assert-Equal $state.MdeDeviceId 'mde1'
            Assert-Equal $state.ComputerName ''
            Assert-Equal $state.Fqdn ''
            Assert-Equal (Get-Correlation @($withoutName) 24 $now).Status 'Matched'
        }
        Test-Case 'MDE-only Linux device is not eligible for a group' {
            $linux = $candidate.Clone(); $linux.AadDeviceId = ''
            Assert-Equal (Get-Correlation @($linux) 24 $now).Status 'NoEntraDevice'
        }
        Test-Case 'Missing, stale, merged, ambiguous and invalid candidates are blocked' {
            Assert-Equal (Get-Correlation @() 24 $now).Status 'PendingMde'
            $stale = $candidate.Clone(); $stale.Timestamp = $now.AddHours(-25).ToString('o')
            Assert-Equal (Get-Correlation @($stale) 24 $now).Status 'StaleEvidence'
            $merged = $candidate.Clone(); $merged.MergedToDeviceId = 'new-device'
            Assert-Equal (Get-Correlation @($merged) 24 $now).Status 'PendingMde'
            Assert-Equal (Get-Correlation @($candidate, $candidate.Clone()) 24 $now).Status 'Ambiguous'
            $invalid = $candidate.Clone(); $invalid.AadDeviceId = 'not-a-guid'
            Assert-Equal (Get-Correlation @($invalid) 24 $now).Status 'InvalidEntraIdentifier'
            $future = $candidate.Clone(); $future.Timestamp = $now.AddHours(1).ToString('o')
            Assert-Equal (Get-Correlation @($future) 24 $now).Status 'StaleEvidence'
        }
        Test-Case 'Hunting query selects latest identity before matching resource and has bounded output' {
            function script:Invoke-Graph {
                param($Path, $Method, $Body)
                Assert-Equal $Path '/security/runHuntingQuery'
                Assert-True ($Body.Query.IndexOf('summarize arg_max') -lt $Body.Query.IndexOf('where AzureResourceId'))
                Assert-True ($Body.Query.Contains('take 101'))
                foreach ($field in @('SensorHealthState', 'CloudPlatforms', 'AzureVmId', 'PublicIP',
                    'DeviceManualTags', 'DeviceDynamicTags', 'RegistryDeviceTag', 'MachineGroup')) {
                    Assert-True ($Body.Query.Contains($field))
                }
                @{ Content = '{"results":[]}' }
            }
            Assert-Equal @(Get-MdeCandidates $id).Count 0
        }
        Test-Case 'Audit mode never writes group membership' {
            function script:Test-Group { @{ displayName = 'Arc servers' } }
            function script:Test-DirectMembership { $false }
            function script:Invoke-Graph { throw 'Unexpected write.' }
            $state = @{ GroupId = 'g'; EntraObjectId = 'd'; Mode = 'Audit'; Membership = 'Unknown' }
            Set-VerifiedMembership $state
            Assert-Equal $state.Status 'WouldAdd'
            Assert-Equal $state.Membership 'Absent'
            Assert-Equal $state.GroupName 'Arc servers'
        }
        Test-Case 'Already present members are not re-added' {
            function script:Test-Group { @{ displayName = 'Arc servers' } }
            function script:Test-DirectMembership { $true }
            function script:Invoke-Graph { throw 'Unexpected write.' }
            $state = @{ GroupId = 'g'; EntraObjectId = 'd'; Mode = 'Enforce'; Membership = 'Unknown' }
            Set-VerifiedMembership $state
            Assert-Equal $state.Status 'Verified'
            Assert-Equal $state.GroupName 'Arc servers'
            Assert-True ([bool]$state.MembershipVerifiedAt)
        }
        Test-Case 'Enforce persists intent before POST and verifies object-ID membership' {
            $script:Checks = 0; $script:Intent = $false
            function script:Test-Group { @{ displayName = 'Arc servers' } }
            function script:Test-DirectMembership { $script:Checks++; return $script:Checks -gt 1 }
            function script:Write-MutationIntent { $script:Intent = $true }
            function script:Invoke-Graph {
                param($Path, $Method, $Body)
                Assert-True $script:Intent
                Assert-Equal $Path '/groups/g/members/$ref'
                Assert-Equal $Body.'@odata.id' 'https://graph.microsoft.com/v1.0/directoryObjects/object-id'
                @{ Status = 204 }
            }
            $state = @{ Key = 'k'; GroupId = 'g'; EntraObjectId = 'object-id'; Mode = 'Enforce' }
            Set-VerifiedMembership $state
            Assert-Equal $state.Action 'AddedAndVerified'
            Assert-Equal $state.Membership 'Present'
        }
        Test-Case 'Unverified writes fail rather than report success' {
            function script:Test-Group { @{ displayName = 'Arc servers' } }
            function script:Test-DirectMembership { $false }
            function script:Write-MutationIntent {}
            function script:Invoke-Graph { @{ Status = 204 } }
            function script:Start-Sleep {}
            Assert-Throws { Set-VerifiedMembership @{ Key = 'k'; GroupId = 'g'; EntraObjectId = 'd'; Mode = 'Enforce' } }
        }
        Test-Case 'Concurrent duplicate addition is accepted only after read-back' {
            $script:Checks = 0
            function script:Test-Group { @{ displayName = 'Arc servers' } }
            function script:Test-DirectMembership { $script:Checks++; $script:Checks -gt 1 }
            function script:Write-MutationIntent {}
            function script:Invoke-Graph { @{ Status = 400 } }
            $state = @{ Key = 'k'; GroupId = 'g'; EntraObjectId = 'd'; Mode = 'Enforce' }
            Set-VerifiedMembership $state
            Assert-Equal $state.Action 'PresentAfterConcurrentWrite'
        }
        Test-Case 'Reject dynamic, synchronized, role-assignable and Microsoft 365 groups' {
            $script:Group = @{ displayName = 'Arc servers'; securityEnabled = $true; groupTypes = @(); onPremisesSyncEnabled = $false; isAssignableToRole = $false }
            function script:Invoke-Graph {
                param($Path)
                Assert-True ($Path.Contains('displayName'))
                @{ Content = ($script:Group | ConvertTo-Json -Compress) }
            }
            Assert-Equal (Test-Group 'g').displayName 'Arc servers'
            $script:Group.groupTypes = @('DynamicMembership'); Assert-Throws { Test-Group 'g' }
            $script:Group.groupTypes = @('Unified'); Assert-Throws { Test-Group 'g' }
            $script:Group.groupTypes = @(); $script:Group.onPremisesSyncEnabled = $true; Assert-Throws { Test-Group 'g' }
            $script:Group.onPremisesSyncEnabled = $false; $script:Group.isAssignableToRole = $true; Assert-Throws { Test-Group 'g' }
            $script:Group.isAssignableToRole = $false; $script:Group.displayName = ''; Assert-Throws { Test-Group 'g' }
        }
        Test-Case 'Missing Arc resource is recorded without a Graph call' {
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest { @{ Status = 404 } }
            function script:Invoke-Graph { throw 'Graph must not be called.' }
            function script:Save-MachineState { param($State) $script:Saved = $State }
            function script:Write-FunctionLog { param($Entry) $script:LoggedRun = $Entry }
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'EventGrid' }
            Assert-Equal $script:Saved.Status 'ArcMissing'
            Assert-Equal $script:Saved.Membership 'Unknown'
            Assert-Equal $script:LoggedRun.FunctionName 'Machine'
            Assert-Equal $script:LoggedRun.TriggerReason 'Event Grid (Compliant Machine Configuration assignment or succeeded MDE extension)'
            Assert-Equal $script:LoggedRun.Status 'ArcMissing'
        }
        Test-Case 'Event Grid MDE extension trigger queues parent machine only when provisioningState is Succeeded' {
            $script:QueuedParent = @()
            function script:Send-MachineWork { param($ResourceId, $Source) $script:QueuedParent += "$Source`:$ResourceId" }
            function script:Invoke-CloudRequest {
                param($Uri)
                if ($Uri.Contains('MDE.Windows')) {
                    return @{ Status = 200; Content = '{"properties":{"provisioningState":"Succeeded"}}' }
                }
                return @{ Status = 200; Content = '{"properties":{"provisioningState":"Creating"}}' }
            }
            $winExt = "$id/extensions/MDE.Windows"
            $linExt = "$id/extensions/MDE.Linux"
            $gcSubj = "$id/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceid"
            Assert-Equal (Invoke-MdeExtensionEvent -Subject $winExt) 1
            Assert-Equal $script:QueuedParent.Count 1
            Assert-Equal $script:QueuedParent[0] "EventGrid:$($id.ToLowerInvariant())"
            Assert-Equal (Invoke-MdeExtensionEvent -Subject $linExt) 0
            Assert-Equal $script:QueuedParent.Count 1
            function script:Invoke-CloudRequest {
                param($Uri)
                if ($Uri.Contains('guestConfigurationAssignments/entraiddeviceid')) {
                    return @{ Status = 200; Content = '{"properties":{"provisioningState":"Succeeded","complianceStatus":"Compliant"}}' }
                }
                return @{ Status = 404 }
            }
            Assert-Equal (Invoke-MdeExtensionEvent -Subject $gcSubj) 1
            Assert-Equal $script:QueuedParent.Count 2
            Assert-Throws { Invoke-MdeExtensionEvent -Subject "$id/extensions/AzureMonitorWindowsAgent" }
        }
        Test-Case 'Guest Configuration events queue only explicitly Compliant assignments' {
            $script:QueuedParent = @()
            $script:GuestAssignment = @{ properties = @{ provisioningState = 'Succeeded' } }
            function script:Send-MachineWork { param($ResourceId, $Source) $script:QueuedParent += "$Source`:$ResourceId" }
            function script:Invoke-CloudRequest {
                param($Uri)
                Assert-True ($Uri.Contains('/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/'))
                @{ Status = 200; Content = ($script:GuestAssignment | ConvertTo-Json -Depth 5 -Compress) }
            }
            $parents = @(
                $id
                '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.Compute/virtualMachines/vm01'
                '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.Compute/virtualMachineScaleSets/set01/virtualMachines/0'
            )
            foreach ($status in @('NonCompliant', 'Pending', 'Unknown', '', $null)) {
                $script:GuestAssignment.properties = @{ provisioningState = 'Succeeded' }
                if ($null -ne $status) { $script:GuestAssignment.properties.complianceStatus = $status }
                foreach ($parent in $parents) {
                    Assert-Equal (Invoke-MdeExtensionEvent "$parent/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceidlinux") 0
                }
            }
            Assert-Equal $script:QueuedParent.Count 0
            foreach ($status in @('Compliant', 'compliant')) {
                $script:GuestAssignment.properties.complianceStatus = $status
                foreach ($parent in $parents) {
                    Assert-Equal (Invoke-MdeExtensionEvent "$parent/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceid") 1
                }
            }
            Assert-Equal $script:QueuedParent.Count 6
            $script:GuestAssignment.properties.provisioningState = 'Creating'
            Assert-Equal (Invoke-MdeExtensionEvent "$id/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceid") 0
            Assert-Equal $script:QueuedParent.Count 6
        }
        Test-Case 'Guest Configuration compliance gates VMSS fan-out before Resource Graph discovery' {
            $vmss = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.Compute/virtualMachineScaleSets/set01'
            $subject = "$vmss/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceidlinux"
            $script:QueuedParent = @()
            $script:VmssCompliance = 'NonCompliant'
            $script:VmssDiscoveryCalls = 0
            function script:Send-MachineWork { param($ResourceId, $Source) $script:QueuedParent += "$Source`:$ResourceId" }
            function script:Invoke-CloudRequest {
                param($Uri, $Method, $Body)
                if ($Uri.Contains('/guestConfigurationAssignments/')) {
                    return @{ Status = 200; Content = (@{ properties = @{ provisioningState = 'Succeeded'; complianceStatus = $script:VmssCompliance } } | ConvertTo-Json -Compress) }
                }
                Assert-True ($Uri.Contains('/providers/Microsoft.ResourceGraph/resources'))
                Assert-Equal $Method 'POST'
                $script:VmssDiscoveryCalls++
                @{ Status = 200; Content = (@{ data = @(@{ id = "$vmss/virtualMachines/0" }, @{ id = "$vmss/virtualMachines/1" }) } | ConvertTo-Json -Compress) }
            }
            Assert-Equal (Invoke-MdeExtensionEvent $subject) 0
            Assert-Equal $script:VmssDiscoveryCalls 0
            Assert-Equal $script:QueuedParent.Count 0
            $script:VmssCompliance = 'Compliant'
            Assert-Equal (Invoke-MdeExtensionEvent $subject) 2
            Assert-Equal $script:VmssDiscoveryCalls 1
            Assert-Equal $script:QueuedParent.Count 2
            Assert-Equal $script:QueuedParent[0] "EventGrid:$vmss/virtualMachines/0"
        }
        Test-Case 'MDE events request Guest Configuration refresh only after successful provisioning' {
            $env:SYNC_MODE = 'Enforce'
            $script:RefreshCalls = @()
            $script:EventQueued = 0
            $script:ExtensionState = 'Succeeded'
            function script:Request-GuestConfigurationRefresh {
                param($ResourceId, $ExtensionName, $EventId, $Config)
                Assert-Equal $ResourceId $id.ToLowerInvariant()
                Assert-Equal $Config.Mode 'Enforce'
                $script:RefreshCalls += "$ExtensionName/$EventId"
            }
            function script:Send-MachineWork { $script:EventQueued++ }
            function script:Invoke-CloudRequest {
                param($Uri)
                if ($Uri.Contains('/guestConfigurationAssignments/')) {
                    return @{ Status = 200; Content = '{"properties":{"complianceStatus":"Compliant"}}' }
                }
                @{ Status = 200; Content = (@{ properties = @{ provisioningState = $script:ExtensionState } } | ConvertTo-Json -Compress) }
            }
            Assert-Equal (Invoke-MdeExtensionEvent "$id/extensions/MDE.Windows" -EventId 'event-win') 1
            Assert-Equal (Invoke-MdeExtensionEvent "$id/extensions/MDE.Linux" -EventId 'event-linux') 1
            Assert-Equal $script:RefreshCalls[0] 'MDE.Windows/event-win'
            Assert-Equal $script:RefreshCalls[1] 'MDE.Linux/event-linux'
            $script:ExtensionState = 'Creating'
            Assert-Equal (Invoke-MdeExtensionEvent "$id/extensions/MDE.Linux" -EventId 'not-ready') 0
            Assert-Equal (Invoke-MdeExtensionEvent "$id/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceid") 1
            Assert-Equal $script:RefreshCalls.Count 2
            Assert-Equal $script:EventQueued 3
            $env:SYNC_MODE = 'Audit'
        }
        Test-Case 'MDE refresh targets native VMs and VMSS instances including scale-set fan-out' {
            $env:SYNC_MODE = 'Enforce'
            $vm = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.Compute/virtualMachines/vm01'
            $vmss = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/Servers/providers/Microsoft.Compute/virtualMachineScaleSets/set01'
            $script:RefreshTargets = @()
            $script:EventQueued = 0
            function script:Request-GuestConfigurationRefresh {
                param($ResourceId, $ExtensionName, $EventId, $Config)
                Assert-Equal $ExtensionName 'MDE.Linux'
                Assert-Equal $EventId 'event-linux'
                $script:RefreshTargets += $ResourceId.ToLowerInvariant()
            }
            function script:Send-MachineWork { $script:EventQueued++ }
            function script:Invoke-CloudRequest {
                param($Uri)
                if ($Uri.Contains('/Microsoft.ResourceGraph/')) {
                    return @{ Status = 200; Content = (@{ data = @(@{ id = "$vmss/virtualMachines/0" }, @{ id = "$vmss/virtualMachines/1" }) } | ConvertTo-Json -Compress) }
                }
                @{ Status = 200; Content = '{"properties":{"provisioningState":"Succeeded"}}' }
            }
            Assert-Equal (Invoke-MdeExtensionEvent "$vm/extensions/MDE.Linux" -EventId 'event-linux') 1
            Assert-Equal (Invoke-MdeExtensionEvent "$vmss/virtualMachines/2/extensions/MDE.Linux" -EventId 'event-linux') 1
            Assert-Equal (Invoke-MdeExtensionEvent "$vmss/extensions/MDE.Linux" -EventId 'event-linux') 2
            Assert-Equal ($script:RefreshTargets -join ',') (@($vm,"$vmss/virtualMachines/2","$vmss/virtualMachines/0","$vmss/virtualMachines/1").ToLowerInvariant() -join ',')
            Assert-True ($vmss.ToLowerInvariant() -notin $script:RefreshTargets)
            Assert-Equal $script:EventQueued 4
            $env:SYNC_MODE = 'Audit'
        }
        Test-Case 'Guest Configuration refresh preserves Audit package settings and rejects unsafe assignments' {
            function script:Invoke-CloudRequest { throw 'A known package URI must not query policy definitions.' }
            $assignment = @{
                location = 'westus2'
                properties = @{
                    context = 'AzurePolicy'
                    complianceStatus = 'Compliant'
                    guestConfiguration = @{
                        name = 'entraiddeviceidlinux'; assignmentType = 'Audit'; contentType = 'Custom'
                        contentHash = ('A' * 64); contentUri = 'https://example.test/audit.zip'
                        version = '1.0.1'; configurationParameter = @(@{ name = 'Value'; value = 'keep' })
                    }
                }
            }
            $body = Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111'
            Assert-Equal $body.properties.guestConfiguration.assignmentType 'Audit'
            Assert-Equal $body.properties.guestConfiguration.configurationParameter[0].value 'keep'
            Assert-Equal $body.properties.context 'AzurePolicy'
            Assert-True (-not $body.properties.ContainsKey('complianceStatus'))
            $assignment.properties.guestConfiguration.assignmentType = 'ApplyAndMonitor'
            Assert-Throws { Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111' }
            $assignment.properties.guestConfiguration.assignmentType = 'Audit'
            $assignment.properties.guestConfiguration.configurationProtectedParameter = @(@{ name = 'Hidden'; value = $null })
            Assert-Throws { Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111' }
            $assignment.properties.guestConfiguration.Remove('configurationProtectedParameter')
            $assignment.properties.guestConfiguration.contentUri = 'http://example.test/audit.zip'
            Assert-Throws { Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111' }
            $assignment.properties.guestConfiguration.contentUri = 'https://example.test/audit.zip'
            $assignment.properties.guestConfiguration.name = 'entraiddeviceidlinux_1.0.2'
            Assert-Throws { Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111' }
            $assignment.properties.guestConfiguration.version = '1.0.2'
            $body = Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111'
            Assert-Equal $body.properties.guestConfiguration.name 'entraiddeviceidlinux_1.0.2'
            $assignment.properties.guestConfiguration.name = 'entraiddeviceidlinux_untrusted'
            Assert-Throws { Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111' }
        }
        Test-Case 'Hidden custom package URIs resolve only from hash-matched paginated policy definitions' {
            $script:PolicyLookups = 0
            $script:PolicyUris = @('https://example.test/original.zip')
            function script:Invoke-CloudRequest {
                param($Uri, $Method, $Body)
                Assert-True ($Uri.Contains('/Microsoft.ResourceGraph/resources'))
                Assert-Equal $Method 'POST'
                Assert-True ($Body.query.Contains('A' * 64))
                $script:PolicyLookups++
                if ($script:PolicyLookups -eq 1) {
                    return @{ Content = '{"data":[],"$skipToken":"next"}' }
                }
                Assert-Equal $Body.options['$skipToken'] 'next'
                $resources = @($script:PolicyUris | ForEach-Object { @{
                    properties = @{ guestConfiguration = @{
                        name = 'entraiddeviceidlinux'; assignmentType = 'Audit'; contentHash = ('A' * 64); contentUri = $_
                    } }
                } })
                @{ Content = (@{ data = @(@{ policyRule = @{ then = @{ details = @{ deployment = @{ properties = @{ template = @{ resources = $resources } } } } } } }) } | ConvertTo-Json -Depth 20 -Compress) }
            }
            $assignment = @{ location = 'westus2'; properties = @{ guestConfiguration = @{
                name = 'entraiddeviceidlinux'; assignmentType = 'Audit'; contentType = 'Custom'; contentHash = ('A' * 64); contentUri = $null
            } } }
            $body = Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111'
            Assert-Equal $script:PolicyLookups 2
            Assert-Equal $body.properties.guestConfiguration.contentUri 'https://example.test/original.zip'
            Assert-True ($null -eq $assignment.properties.guestConfiguration.contentUri)
            $script:PolicyLookups = 0
            $script:PolicyUris += 'https://example.test/ambiguous.zip'
            Assert-Throws { Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111' }
            $script:PolicyLookups = 0
            $script:PolicyUris = @()
            Assert-Throws { Get-GuestConfigurationRefreshBody $assignment '11111111-1111-1111-1111-111111111111' }
        }
        Test-Case 'Audit mode and missing assignments never cause Guest Configuration writes' {
            function script:Invoke-CloudRequest { throw 'Audit mode must not request assignment changes.' }
            function script:Invoke-Table { throw 'No refresh reservations should be written.' }
            Assert-Equal (Request-GuestConfigurationRefresh $id 'MDE.Linux' '' @{ Mode = 'Audit' }) 0
            Assert-Throws { Request-GuestConfigurationRefresh $id 'MDE.Linux' '' @{ Mode = 'Enforce' } }
            function script:Invoke-CloudRequest { @{ Status = 200; Content = '{"value":[]}' } }
            Assert-Equal (Request-GuestConfigurationRefresh $id 'MDE.Linux' 'missing' @{ Mode = 'Enforce' }) 0
            function script:Invoke-CloudRequest { @{ Status = 404 } }
            Assert-Equal (Request-GuestConfigurationRefresh $id 'MDE.Linux' 'missing' @{ Mode = 'Enforce' }) 0
        }
        Test-Case 'Linux refresh prefers the newest versioned package across pages and retains legacy assignments' {
            $script:VersionedPuts = 0
            $script:VersionedRecords = @(
                foreach ($name in @('entraiddeviceidlinux', 'entraiddeviceidlinux_1.0.1', 'entraiddeviceidlinux_1.0.2')) {
                    @{ id = "$id/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/$name"; location = 'westus2'; properties = @{
                        guestConfiguration = @{
                            name = $name; assignmentType = 'Audit'; contentType = 'Custom'
                            version = if ($name -eq 'entraiddeviceidlinux') { '1.0.0' } else { $name.Substring('entraiddeviceidlinux_'.Length) }
                            contentHash = ('A' * 64); contentUri = 'https://example.test/versioned.zip'
                        }
                    } }
                }
            )
            function script:Invoke-CloudRequest {
                param($Uri, $Method = 'GET', $Body)
                if ($Uri.Contains('/guestConfigurationAssignments?')) {
                    if ($Uri.Contains('$skiptoken=')) {
                        return @{ Status = 200; Content = (@{ value = @($script:VersionedRecords[1], $script:VersionedRecords[2]) } | ConvertTo-Json -Depth 10 -Compress) }
                    }
                    return @{ Status = 200; Content = (@{ value = @($script:VersionedRecords[0]); nextLink = "$Uri&`$skiptoken=next" } | ConvertTo-Json -Depth 10 -Compress) }
                }
                Assert-True ($Uri.Contains('/entraiddeviceidlinux_1.0.2?'))
                if ($Method -eq 'PUT') {
                    $script:VersionedPuts++
                    Assert-Equal $Body.properties.guestConfiguration.name 'entraiddeviceidlinux_1.0.2'
                }
                @{ Status = 200; Content = ($script:VersionedRecords[2] | ConvertTo-Json -Depth 10 -Compress) }
            }
            function script:Invoke-Table {
                param($Method = 'GET')
                @{ Status = if ($Method -eq 'GET') { 404 } else { 204 } }
            }
            Assert-Equal (Request-GuestConfigurationRefresh $id 'MDE.Linux' 'versioned-release' @{ Mode = 'Enforce' }) 1
            Assert-Equal $script:VersionedPuts 1
        }
        Test-Case 'Guest refresh reservations suppress duplicate and uncertain event deliveries' {
            $script:RefreshAssignmentId = "$($id.ToLowerInvariant())/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/entraiddeviceidlinux-test"
            $script:RefreshClaims = @{}
            $script:GuestPuts = 0
            $script:GuestPutFails = $false
            $script:GuestReservationConflict = $false
            $script:GuestListCalls = 0
            $script:BadGuestNext = $false
            $script:AuditAssignment = @{ id = $script:RefreshAssignmentId; location = 'westus2'; properties = @{
                latestReportId = 'previous-report'
                lastComplianceStatusChecked = '2026-11-03T22:14:03Z'
                guestConfiguration = @{
                    name = 'entraiddeviceidlinux'; assignmentType = 'Audit'; contentType = 'Custom'
                    contentHash = ('A' * 64); contentUri = 'https://example.test/audit.zip'
                }
            } }
            function script:Invoke-CloudRequest {
                param($Uri, $Method = 'GET', $Body, $Headers, [switch]$DisableRetry)
                if ($Method -eq 'PUT') {
                    $script:GuestPuts++
                    Assert-True $DisableRetry
                    Assert-Equal $Headers['If-Match'] 'assignment-etag'
                    Assert-Equal $Body.properties.guestConfiguration.assignmentType 'Audit'
                    if ($script:GuestPutFails) { throw 'Refresh response was lost.' }
                    return @{ Status = 200; Content = ($script:AuditAssignment | ConvertTo-Json -Depth 10 -Compress) }
                }
                if ($Uri.Contains('/guestConfigurationAssignments?')) {
                    $script:GuestListCalls++
                    if (-not $Uri.Contains('$skiptoken=')) {
                        $next = if ($script:BadGuestNext) { 'https://management.azure.com/another-machine/guestConfigurationAssignments?api-version=2024-04-05' } else { "$Uri&`$skiptoken=page-two" }
                        return @{ Status = 200; Content = (@{ value = @(); nextLink = $next } | ConvertTo-Json -Compress) }
                    }
                    return @{ Status = 200; Content = (@{ value = @($script:AuditAssignment) } | ConvertTo-Json -Depth 10 -Compress) }
                }
                @{ Status = 200; Headers = @{ ETag = 'assignment-etag' }; Content = ($script:AuditAssignment | ConvertTo-Json -Depth 10 -Compress) }
            }
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Body, $Headers, $AllowStatus)
                $key = if ($Method -eq 'POST') { $Body.RowKey } else { [regex]::Match($Path, "RowKey='([^']+)'").Groups[1].Value }
                if ($Method -eq 'GET') {
                    if (-not $script:RefreshClaims.ContainsKey($key)) { return @{ Status = 404 } }
                    return @{ Status = 200; Content = ($script:RefreshClaims[$key] | ConvertTo-Json -Compress) }
                }
                if ($Method -eq 'POST' -and ($script:GuestReservationConflict -or $script:RefreshClaims.ContainsKey($key))) { return @{ Status = 409 } }
                $script:RefreshClaims[$key] = $Body.Clone()
                @{ Status = 204 }
            }
            Assert-Equal (Request-GuestConfigurationRefresh $id 'MDE.Linux' 'event-one' @{ Mode = 'Enforce' }) 1
            Assert-Equal $script:GuestListCalls 2
            Assert-Equal $script:RefreshClaims[(Get-MachineKey "event-one`n$($script:RefreshAssignmentId)")].PreviousCheckedAt '2026-11-03T22:14:03.0000000+00:00'
            Assert-Equal (Request-GuestConfigurationRefresh $id 'MDE.Linux' 'event-one' @{ Mode = 'Enforce' }) 0
            Assert-Equal $script:GuestPuts 1
            $script:GuestPutFails = $true
            Assert-Throws { Request-GuestConfigurationRefresh $id 'MDE.Linux' 'uncertain-event' @{ Mode = 'Enforce' } }
            Assert-Throws { Request-GuestConfigurationRefresh $id 'MDE.Linux' 'uncertain-event' @{ Mode = 'Enforce' } }
            Assert-Equal $script:GuestPuts 2
            $script:GuestPutFails = $false
            $script:GuestReservationConflict = $true
            Assert-Throws { Request-GuestConfigurationRefresh $id 'MDE.Linux' 'racing-event' @{ Mode = 'Enforce' } }
            Assert-Equal $script:GuestPuts 2
            $script:BadGuestNext = $true
            Assert-Throws { Request-GuestConfigurationRefresh $id 'MDE.Linux' 'invalid-page' @{ Mode = 'Enforce' } }
            Assert-Equal $script:GuestPuts 2
        }
        Test-Case 'Full machine workflow resolves deviceId to object ID in Audit' {
            $script:Candidates = @($candidate)
            $script:ResolvedObject = ''
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest {
                @{ Status = 200; Content = '{"tags":{"AccountId":"123456789012","Environment":"Production","Cost center":"123"},"systemData":{"createdAt":"2026-10-01T08:00:00Z","lastModifiedAt":"2026-10-19T11:30:00Z"},"properties":{"status":"Connected","lastStatusChange":"2026-10-19T11:55:00Z","osType":"Windows","dnsFqdn":"server01.example.com","osProfile":{"computerName":"SERVER01"},"cloudMetadata":{"provider":"AWS"},"vmId":"arc-vm-id","networkProfile":{"networkInterfaces":[{"ipAddresses":[{"address":"10.0.0.4"}]}]}}}' }
            }
            function script:Get-SubscriptionName { 'Production subscription' }
            function script:Get-ArcExtensions { @('AzureMonitorWindowsAgent (version: 1.0; state: Succeeded)', 'MDE.Windows (version: 2.0; state: Succeeded)') }
            function script:Get-MdeNetworkAddresses { @('10.0.0.4', '2001:db8::4') }
            function script:Get-MdeAntivirus { @{ Mode = 'Passive'; Timestamp = '2026-10-19T12:00:00Z'; Status = 'Reported' } }
            function script:Get-MdeCandidates { $script:Candidates }
            function script:Invoke-Graph {
                param($Path)
                if ($Path.StartsWith('/devices?')) {
                    Assert-True ($Path.Contains('44444444-4444-4444-4444-444444444444'))
                    return @{ Content = '{"value":[{"id":"55555555-5555-5555-5555-555555555555","deviceId":"44444444-4444-4444-4444-444444444444","accountEnabled":true}]}' }
                }
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[]}' }
                }
                throw "Unexpected Graph request $Path"
            }
            function script:Resolve-GroupByDisplayName {
                param($DisplayName)
                Assert-Equal $DisplayName 'MDfS-AWS-Windows-Passive-123456789012'
                @{ Id = '22222222-2222-2222-2222-222222222222'; DisplayName = 'MDfS-AWS-Windows-Passive-123456789012' }
            }
            function script:Test-DirectMembership {
                param($GroupId, $ObjectId)
                $script:ResolvedObject = $ObjectId
                $false
            }
            function script:Save-MachineState { param($State) $script:Saved = $State }
            function script:Write-FunctionLog { param($Entry) $script:LoggedRun = $Entry }
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Schedule' }
            Assert-Equal $script:LoggedRun.TriggerReason 'Scheduled inventory reconciliation'
            Assert-Equal $script:LoggedRun.Health 'Healthy'
            Assert-Equal $script:Saved.Status 'WouldAdd'
            Assert-Equal $script:Saved.GroupName 'MDfS-AWS-Windows-Passive-123456789012'
            Assert-Equal $script:Saved.CloudGroupType 'AWS'
            Assert-Equal $script:Saved.CloudGroupOS 'Windows'
            Assert-Equal $script:Saved.CloudIdentifier '123456789012'
            Assert-Equal $script:Saved.EntraDeviceId '44444444-4444-4444-4444-444444444444'
            Assert-Equal $script:ResolvedObject '55555555-5555-5555-5555-555555555555'
            Assert-Equal $script:Saved.ComputerName 'SERVER01'
            Assert-Equal $script:Saved.Fqdn 'server01.example.com'
            Assert-Equal $script:Saved.CloudProvider 'AWS'
            Assert-Equal $script:Saved.SubscriptionName 'Production subscription'
            Assert-Equal $script:Saved.VirtualMachineId 'arc-vm-id'
            Assert-Equal $script:Saved.ArcLastReportedAt '2026-10-19T11:55:00.0000000+00:00'
            Assert-Equal $script:Saved.ArcAddedAt '2026-10-01T08:00:00.0000000+00:00'
            Assert-Equal $script:Saved.MdeLastSeen $candidate.Timestamp
            Assert-Equal $script:Saved.MdeSensorHealth 'Active'
            Assert-Equal $script:Saved.MdeOnboardingStatus 'Onboarded'
            Assert-Equal $script:Saved.MdeAntivirusMode 'Passive'
            Assert-Equal $script:Saved.MdeDeviceGroup 'Production servers'
            Assert-Equal $script:Saved.MdeDeviceTags.Count 4
            Assert-Equal $script:Saved.MdeManualTags.Count 2
            Assert-Equal $script:Saved.AzureTags.Environment 'Production'
            Assert-Equal $script:Saved.AzureTags['Cost center'] '123'
            Assert-Equal $script:Saved.ArcExtensions.Count 2
            Assert-Equal $script:Saved.DefenderExtensionStatus 'MDE.Windows: Succeeded'
            Assert-Equal (Get-DefenderExtensionStatus @('MDE.Linux (version: 1.2; state: Succeeded)')) 'MDE.Linux: Succeeded'
            Assert-Equal (Get-DefenderExtensionStatus @('AzureMonitorLinuxAgent (version: 1.0; state: Succeeded)')) 'Not installed'
            Assert-Equal $script:Saved.IPAddresses.Count 3
            Assert-True ('203.0.113.10' -in $script:Saved.IPAddresses)
            Assert-Equal $script:Saved.InventoryStatus 'Collected'
            $script:Candidates = @($candidate.Clone())
            $script:Candidates[0].DeviceManualTags = '[malformed'
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.Status 'WouldAdd'
            Assert-Equal $script:Saved.InventoryStatus 'Partial'
            Assert-True ($null -eq $script:Saved.MdeDeviceTags)
            Assert-Equal $script:Saved.MdeDeviceGroup 'Production servers'
            Assert-True ($script:Saved.InventoryErrors[0].StartsWith('MDE device tags:'))
            $script:Candidates = @($candidate)
            function script:Get-MdeAntivirus { throw 'HTTP 403 from graph.microsoft.com for POST request.' }
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.Status 'WouldAdd'
            Assert-Equal $script:Saved.InventoryStatus 'Partial'
            Assert-Equal $script:Saved.MdeAntivirusStatus 'Failed'
            Assert-Equal $script:Saved.MdeAntivirusMode ''
        }
        Test-Case 'MDE-only device falls back to MicrosoftSense Entra lookup and correlates only when unique' {
            $script:Linux = $candidate.Clone(); $script:Linux.AadDeviceId = ''
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest { @{ Status = 200; Content = '{"properties":{"status":"Connected","osType":"Linux","osProfile":{"computerName":"SERVER01"}}}' } }
            function script:Get-MdeCandidates { @($script:Linux) }
            function script:Get-SubscriptionName { 'Production subscription' }
            function script:Get-ArcExtensions { @() }
            function script:Get-MdeNetworkAddresses { @() }
            function script:Get-MdeAntivirus { @{ Mode = ''; Timestamp = ''; Status = 'NoData' } }
            function script:Invoke-Graph {
                param($Path)
                if ($Path.StartsWith('/devices?$filter=')) {
                    return @{ Content = '{"value":[]}' }
                }
                throw "Unexpected Graph call when no MicrosoftSense device exists: $Path"
            }
            function script:Save-MachineState { param($State) $script:Saved = $State }
            function script:Write-FunctionLog {}
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.Status 'NoEntraDevice'
            Assert-Equal $script:Saved.Membership 'Unknown'

            # Now return a unique MicrosoftSense Entra device matching SERVER01 + Linux
            function script:Invoke-Graph {
                param($Path)
                if ($Path.StartsWith('/devices?$filter=')) {
                    return @{ Content = '{"value":[{"id":"66666666-6666-6666-6666-666666666666","deviceId":"77777777-7777-7777-7777-777777777777","displayName":"SERVER01","operatingSystem":"Linux","managementType":"MicrosoftSense","accountEnabled":true}]}' }
                }
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[]}' }
                }
                throw "Unexpected Graph call in MicrosoftSense correlation: $Path"
            }
            function script:Resolve-GroupByDisplayName {
                param($DisplayName)
                @{ Id = '22222222-2222-2222-2222-222222222222'; DisplayName = $DisplayName }
            }
            function script:Test-DirectMembership { $false }
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.Status 'WouldAdd'
            Assert-Equal $script:Saved.EntraObjectId '66666666-6666-6666-6666-666666666666'
            Assert-Equal $script:Saved.EntraDeviceId '77777777-7777-7777-7777-777777777777'
            Assert-Equal $script:Saved.GroupName 'MDfS-Azure-Linux-Passive-Production subscription'

            # Verify Option 2: Machine Configuration (GuestConfigurationResources) intuneDeviceId correlation takes precedence before hostname fallback
            function script:Invoke-Graph {
                param($Path)
                if ($Path.Contains("deviceId%20eq%20%278d6e3dd1-4cc4-6d14-e0a3-4856e6059032%27")) {
                    return @{ Content = '{"value":[{"id":"99999999-8888-7777-6666-555555555555","deviceId":"8d6e3dd1-4cc4-6d14-e0a3-4856e6059032","displayName":"linlog02","operatingSystem":"Linux","managementType":"MicrosoftSense","accountEnabled":true}]}' }
                }
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[]}' }
                }
                throw "Machine Configuration intuneDeviceId correlation should not fall through to hostname lookup: $Path"
            }
            Invoke-MachineSync @{
                ResourceId = $id
                RunId = [guid]::NewGuid().ToString()
                Source = 'Test'
                ResourceData = @{
                    properties = @{ status = 'Connected'; osType = 'Linux'; osProfile = @{ computerName = 'SERVER01' } }
                    gcEntraDeviceId = '8d6e3dd1-4cc4-6d14-e0a3-4856e6059032'
                }
            }
            Assert-Equal $script:Saved.Status 'WouldAdd'
            Assert-Equal $script:Saved.GuestConfigEntraDeviceId '8d6e3dd1-4cc4-6d14-e0a3-4856e6059032'
            Assert-Equal $script:Saved.EntraDeviceId '8d6e3dd1-4cc4-6d14-e0a3-4856e6059032'
            Assert-Equal $script:Saved.EntraObjectId '99999999-8888-7777-6666-555555555555'
            Assert-Equal $script:Saved.EntraCorrelationPath 'GuestConfigurationIntuneDeviceId'
        }
        Test-Case 'Inventory provisions each account-OS pair once before any device correlation' {
            $cfg = Get-SyncConfig
            $cfg.AdminUnitId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $cfg.AutoCreateGroups = $true
            $cfg.Mode = 'Enforce'
            $work = @()
            foreach ($cloud in @('Aws', 'Gcp', 'Azure')) {
                foreach ($os in @('Windows', 'Linux')) {
                    $cfg["${cloud}${os}GroupPrefix"] = "dfs-$($cloud.ToLowerInvariant())-{id}-$($os.ToLowerInvariant())-{mode}"
                    foreach ($number in 1..3) {
                        $work += @{
                            ResourceId = $id
                            Row = @{
                                properties = @{ status = 'Connected'; osType = $os; cloudMetadata = @{ provider = $cloud } }
                                tags = switch ($cloud) { 'Aws' { @{ AccountId = '123456789012' } }; 'Gcp' { @{ ProjectId = 'Project-A' } }; default { @{} } }
                                subscriptionName = 'Production'
                            }
                        }
                    }
                }
            }
            $script:AuReads = 0
            $script:CreatedNames = @()
            function script:Invoke-Graph {
                $script:AuReads++
                @{ Content = '{"value":[{"id":"11111111-2222-3333-4444-555555555555","displayName":"dfs-aws-123456789012-windows-active","securityEnabled":true,"groupTypes":[],"onPremisesSyncEnabled":false,"isAssignableToRole":false}]}' }
            }
            function script:New-AdminUnitSecurityGroup {
                param($AdminUnitId, $DisplayName)
                $script:CreatedNames += $DisplayName
                @{ Id = [guid]::NewGuid().ToString(); DisplayName = $DisplayName; Created = $true }
            }
            function script:Save-SharedAdminUnitGroups { param($AdminUnitId, $Groups) $script:PublishedGroups = $Groups }
            $summary = Initialize-InventoryGroups $cfg $work
            Assert-Equal $summary.Expected 12
            Assert-Equal $summary.Existing 1
            Assert-Equal $summary.Created 11
            Assert-Equal $script:AuReads 1
            Assert-Equal @($script:CreatedNames | Sort-Object -Unique).Count 11
            Assert-Equal $script:PublishedGroups.Count 12
        }
        Test-Case 'Inventory Audit and disabled auto-create never create groups or creation claims' {
            $cfg = Get-SyncConfig
            $cfg.AdminUnitId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $cfg.AutoCreateGroups = $true
            $work = @(@{
                ResourceId = $id
                Row = @{ properties = @{ osType = 'Windows'; cloudMetadata = @{ provider = 'AWS' } }; tags = @{ AccountId = '123456789012' }; subscriptionName = 'Production' }
            })
            function script:Invoke-Graph { @{ Content = '{"value":[]}' } }
            function script:New-AdminUnitSecurityGroup { throw 'No groups may be created.' }
            function script:Invoke-Table { throw 'No creation claims may be written.' }
            function script:Save-SharedAdminUnitGroups { param($AdminUnitId, $Groups) Assert-Equal $Groups.Count 0 }
            $audit = Initialize-InventoryGroups $cfg $work
            Assert-Equal $audit.WouldCreate 2
            Assert-Equal $audit.Created 0
            $cfg.Mode = 'Enforce'
            $cfg.AutoCreateGroups = $false
            $disabled = Initialize-InventoryGroups $cfg $work
            Assert-Equal $disabled.Missing 2
            Assert-Equal $disabled.Created 0
            $work[0].Row.tags = @{}
            Assert-Equal (Initialize-InventoryGroups $cfg $work).Expected 0
            $work[0].Row.properties.osType = ''
            Assert-Equal (Initialize-InventoryGroups $cfg $work).Expected 0
            $work[0].Row.properties.osType = 'Windows'
            $work[0].Row.properties.cloudMetadata.provider = ''
            $telemetry = @{ $id.ToLowerInvariant() = @{ Candidates = @(@{ CloudPlatforms = 'AWS' }) } }
            Assert-Equal (Initialize-InventoryGroups $cfg $work $telemetry).Expected 0
            $work[0].Row.tags = @{ AccountId = '123456789012' }
            $cfg.AwsWindowsGroupPrefix = ''
            Assert-Equal (Initialize-InventoryGroups $cfg $work).Expected 0
            $work[0].Row = $null
            Assert-Equal (Initialize-InventoryGroups $cfg $work).Expected 0
        }
        Test-Case 'Shared AU catalogs publish atomically and reuse paged group IDs across workers' {
            $au = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $groups = @(
                @{ id = '11111111-2222-3333-4444-555555555555'; displayName = 'dfs-aws-123456789012-windows-active'; securityEnabled = $true; groupTypes = @(); onPremisesSyncEnabled = $false; isAssignableToRole = $false }
                @{ id = '66666666-7777-8888-9999-000000000000'; displayName = 'dfs-aws-123456789012-linux-passive'; securityEnabled = $true; groupTypes = @(); onPremisesSyncEnabled = $false; isAssignableToRole = $false }
            )
            $script:CatalogWrites = @()
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Body, $Headers)
                if ($Method -eq 'PUT') {
                    Assert-True (-not $Headers -or -not $Headers.ContainsKey('If-Match'))
                    $script:CatalogWrites += $Body
                    return @{ Status = 204 }
                }
                @{ Status = 200; Content = ($script:CatalogWrites[-1] | ConvertTo-Json -Compress) }
            }
            Save-SharedAdminUnitGroups $au $groups
            Assert-Equal $script:CatalogWrites.Count 3
            Assert-Equal $script:CatalogWrites[-1].PartitionKey 'group-catalogs'
            Assert-Equal $script:CatalogWrites[-1].GroupCount 2
            $script:CatalogPages = 0
            function script:Get-TablePage {
                param($Filter, $Cursor)
                Assert-True ($Filter.Contains("Generation eq '$($script:CatalogWrites[-1].Generation)'"))
                $script:CatalogPages++
                $index = if ($Cursor) { 1 } else { 0 }
                @{
                    Items = @($script:CatalogWrites[$index].Data | ConvertFrom-Json -AsHashtable)
                    Cursor = if ($Cursor) { '' } else { 'next-page' }
                }
            }
            Set-Item Function:script:Get-SharedAdminUnitGroups $originals['Get-SharedAdminUnitGroups']
            function script:Invoke-Graph { throw 'A fresh shared catalog must avoid AU Graph listing.' }
            $script:AdminUnitGroupsCache.Clear()
            $script:AdminUnitGroupsExpires.Clear()
            Assert-Equal @(Get-AdminUnitGroups $au).Count 2
            Assert-Equal $script:CatalogPages 2
            Assert-Equal (Resolve-GroupByDisplayName $groups[0].displayName $au).Id $groups[0].id
            $script:AdminUnitGroupsCache.Clear()
            $script:AdminUnitGroupsExpires.Clear()
            $script:GroupByNameCache.Clear()
            Assert-Equal (Resolve-GroupByDisplayName $groups[1].displayName $au).Id $groups[1].id
            Assert-Equal $script:CatalogPages 4
        }
        Test-Case 'Expired or partially overwritten shared catalogs fall back to fresh Graph lookup' {
            $au = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $script:ManifestExpiry = [datetimeoffset]::UtcNow.AddMinutes(10).ToString('o')
            function script:Invoke-Table {
                @{
                    Status = 200
                    Content = (@{ ExpiresAt = $script:ManifestExpiry; Generation = '11111111-2222-3333-4444-555555555555'; GroupCount = 1 } | ConvertTo-Json -Compress)
                }
            }
            $script:CatalogPages = 0
            function script:Get-TablePage { $script:CatalogPages++; @{ Items = @(); Cursor = '' } }
            $script:AuReads = 0
            function script:Invoke-Graph { $script:AuReads++; @{ Content = '{"value":[]}' } }
            Set-Item Function:script:Get-SharedAdminUnitGroups $originals['Get-SharedAdminUnitGroups']
            Assert-Equal @(Get-AdminUnitGroups $au).Count 0
            Assert-Equal $script:AuReads 1
            Assert-Equal $script:CatalogPages 1
            $script:AdminUnitGroupsCache.Clear()
            $script:ManifestExpiry = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')
            Assert-Equal @(Get-AdminUnitGroups $au).Count 0
            Assert-Equal $script:AuReads 2
            Assert-Equal $script:CatalogPages 1
        }
        Test-Case 'Failed shared catalog writes never publish a complete manifest' {
            $script:ManifestWrites = 0
            function script:Invoke-Table {
                param($Path, $Method, $Body)
                if ($Body.PartitionKey -eq 'group-catalogs') { $script:ManifestWrites++; return @{ Status = 204 } }
                throw 'Storage write failed.'
            }
            Assert-Throws { Save-SharedAdminUnitGroups 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' @(@{ id = '11111111-2222-3333-4444-555555555555' }) }
            Assert-Equal $script:ManifestWrites 0
        }
        Test-Case 'Inventory blocks duplicate required group names instead of publishing an arbitrary ID' {
            $cfg = Get-SyncConfig
            $cfg.AdminUnitId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            function script:Invoke-Graph {
                @{ Content = '{"value":[{"id":"11111111-2222-3333-4444-555555555555","displayName":"MDfS-AWS-Windows-Passive-123456789012"},{"id":"66666666-7777-8888-9999-000000000000","displayName":"MDfS-AWS-Windows-Passive-123456789012"}]}' }
            }
            function script:Save-SharedAdminUnitGroups { throw 'Duplicate names must not be published.' }
            Assert-Throws {
                Initialize-InventoryGroups $cfg @(@{
                    ResourceId = $id
                    Row = @{ properties = @{ osType = 'Windows' }; tags = @{ AccountId = '123456789012' }; subscriptionName = 'Production' }
                })
            }
        }
        Test-Case 'Shared group metadata is revalidated before a membership update' {
            $cfg = Get-SyncConfig
            $cfg.AdminUnitId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $script:SharedAdminUnitGroups[$cfg.AdminUnitId] = $true
            function script:Get-DeviceCloudGroups { @() }
            function script:Resolve-GroupByDisplayName { @{ Id = '11111111-2222-3333-4444-555555555555'; DisplayName = 'Expected name' } }
            function script:Test-Group { @{ displayName = 'Renamed group' } }
            function script:Test-DirectMembership { throw 'Renamed groups must not reach membership processing.' }
            $state = @{ EntraObjectId = '22222222-3333-4444-5555-666666666666'; GroupName = 'Expected name'; Mode = 'Enforce' }
            Assert-Throws { Set-VerifiedMembership -State $state -Config $cfg }
        }
        Test-Case 'Shared IDs cannot authorize writes to groups removed from the configured AU' {
            $cfg = Get-SyncConfig
            $cfg.AdminUnitId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $script:SharedAdminUnitGroups[$cfg.AdminUnitId] = $true
            function script:Get-DeviceCloudGroups { @() }
            function script:Resolve-GroupByDisplayName { @{ Id = '11111111-2222-3333-4444-555555555555'; DisplayName = 'Expected name' } }
            function script:Test-Group { @{ displayName = 'Expected name' } }
            function script:Test-DirectMembership { $false }
            $script:AuMembershipReads = 0
            function script:Invoke-Graph {
                param($Path, $Method = 'GET', $Headers)
                Assert-Equal $Method 'GET'
                Assert-True ($Path.StartsWith('/directory/administrativeUnits/'))
                Assert-Equal $Headers.ConsistencyLevel 'eventual'
                $script:AuMembershipReads++
                @{ Status = 404 }
            }
            function script:Write-MutationIntent { throw 'Groups outside the AU must never reach mutation.' }
            $state = @{
                EntraObjectId = '22222222-3333-4444-5555-666666666666'; GroupName = 'Expected name'; Mode = 'Enforce'
                CloudGroupOS = 'Windows'; CloudIdentifier = 'account'; CloudGroupType = 'AWS'
            }
            Assert-Throws { Set-VerifiedMembership -State $state -Config $cfg }
            Assert-Equal $script:AuMembershipReads 1
        }
        Test-Case 'Shared IDs still in the AU can add and verify membership using a filtered lookup' {
            $cfg = Get-SyncConfig
            $cfg.AdminUnitId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $script:SharedAdminUnitGroups[$cfg.AdminUnitId] = $true
            function script:Get-DeviceCloudGroups { @() }
            function script:Resolve-GroupByDisplayName { @{ Id = '11111111-2222-3333-4444-555555555555'; DisplayName = 'Expected name' } }
            function script:Test-Group { @{ displayName = 'Expected name' } }
            $script:MembershipReads = 0
            $script:SharedMembershipPosts = 0
            function script:Test-DirectMembership { $script:MembershipReads++; $script:MembershipReads -gt 1 }
            function script:Invoke-Graph {
                param($Path, $Method = 'GET', $Headers)
                if ($Method -eq 'GET') {
                    Assert-Equal $Headers.ConsistencyLevel 'eventual'
                    Assert-True ([uri]::UnescapeDataString($Path).Contains("id eq '11111111-2222-3333-4444-555555555555'"))
                    return @{ Status = 200; Content = '{"value":[{"id":"11111111-2222-3333-4444-555555555555"}]}' }
                }
                $script:SharedMembershipPosts++
                @{ Status = 204 }
            }
            function script:Write-MutationIntent {}
            $state = @{
                EntraObjectId = '22222222-3333-4444-5555-666666666666'; GroupName = 'Expected name'; Mode = 'Enforce'
                CloudGroupOS = 'Windows'; CloudIdentifier = 'account'; CloudGroupType = 'AWS'; Key = 'key'
            }
            Set-VerifiedMembership -State $state -Config $cfg
            Assert-Equal $state.Status 'Verified'
            Assert-Equal $script:SharedMembershipPosts 1
        }
        Test-Case 'Event workers provision a newly discovered account missing from the shared catalog' {
            $cfg = Get-SyncConfig
            $cfg.AdminUnitId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $cfg.AutoCreateGroups = $true
            $cfg.Mode = 'Enforce'
            $cfg.AwsWindowsGroupPrefix = 'dfs-aws-{id}-windows-{mode}'
            $cfg.AwsLinuxGroupPrefix = 'dfs-aws-{id}-linux-{mode}'
            $target = Resolve-CloudGroupTarget $cfg @{ OS = 'Windows'; AzureTags = @{ AccountId = '123456789012' } }
            $script:EventGroups = @()
            $script:EventClaims = 0
            $script:EventMembershipReads = 0
            function script:Get-SharedAdminUnitGroups { @{ Groups = @(); ExpiresAt = [datetimeoffset]::UtcNow.AddMinutes(10) } }
            function script:Invoke-Table {
                param($Path, $Method, $Body)
                if ($Method -eq 'POST' -and $Body.PartitionKey -eq 'group-creations') { $script:EventClaims++ }
                @{ Status = if ($Method -eq 'POST') { 201 } else { 204 } }
            }
            function script:Invoke-Graph {
                param($Path, $Method = 'GET', $Body)
                if ($Path.StartsWith('/groups/')) { return @{ Status = 204 } }
                Assert-True ($Path.StartsWith('/directory/administrativeUnits/'))
                if ($Method -eq 'POST') {
                    $group = @{
                        id = [guid]::NewGuid().ToString(); displayName = $Body.displayName; securityEnabled = $true
                        groupTypes = @(); onPremisesSyncEnabled = $false; isAssignableToRole = $false
                    }
                    $script:EventGroups += $group
                    return @{ Status = 201; Content = ($group | ConvertTo-Json -Compress) }
                }
                @{ Status = 200; Content = (@{ value = @($script:EventGroups) } | ConvertTo-Json -Depth 10 -Compress) }
            }
            function script:Test-DirectMembership { $script:EventMembershipReads++; $script:EventMembershipReads -gt 1 }
            function script:Write-MutationIntent {}
            $state = @{
                EntraObjectId = '11111111-2222-3333-4444-555555555555'; GroupName = $target.GroupName; Mode = 'Enforce'
                Key = 'key'; RunId = [guid]::NewGuid().ToString(); ArcResourceId = $id; CloudGroupType = 'AWS'
                CloudGroupOS = 'Windows'; CloudIdentifier = '123456789012'; GroupAvMode = 'Passive'; MdeAntivirusMode = 'Passive'
            }
            Set-VerifiedMembership -State $state -CloudTarget $target -Config $cfg
            Assert-Equal $script:EventClaims 2
            Assert-Equal $script:EventGroups.Count 2
            Assert-Equal $state.Status 'Verified'
            Assert-Equal $state.GroupName 'dfs-aws-123456789012-windows-passive'
            Assert-True ('dfs-aws-123456789012-windows-active' -in $script:EventGroups.displayName)
        }
        Test-Case 'Default templates produce distinct lowercase cloud-account-OS-mode names for Windows and Linux' {
            foreach ($cloud in @('AWS', 'GCP', 'AZURE')) {
                foreach ($os in @('WINDOWS', 'LINUX')) {
                    [Environment]::SetEnvironmentVariable("SYNC_${cloud}_${os}_GROUP_PREFIX", "dfs-$($cloud.ToLowerInvariant())-{id}-$($os.ToLowerInvariant())-{mode}")
                }
            }
            $cfg = Get-SyncConfig
            foreach ($cloud in @('AWS', 'GCP', 'Azure')) {
                foreach ($os in @('Windows', 'Linux')) {
                    foreach ($mode in @('Active', 'Passive')) {
                        $cfg.DefaultGroupMode = $mode
                        $identifier = switch ($cloud) { 'AWS' { '123456789012' }; 'GCP' { 'My-Project-active' }; default { 'Trydex-Main' } }
                        $tags = switch ($cloud) { 'AWS' { @{ AccountId = $identifier } }; 'GCP' { @{ ProjectId = $identifier } }; default { @{} } }
                        $target = Resolve-CloudGroupTarget -Config $cfg -State @{
                            OS = $os; CloudProvider = $cloud; AzureTags = $tags; SubscriptionName = $identifier
                        }
                        $expected = "dfs-$cloud-$identifier-$os-$mode".ToLowerInvariant()
                        Assert-Equal $target.GroupName $expected
                        $otherMode = if ($mode -eq 'Active') { 'Passive' } else { 'Active' }
                        Assert-Equal $target.CounterpartGroupName "dfs-$cloud-$identifier-$os-$otherMode".ToLowerInvariant()
                        $parsed = ConvertFrom-CloudGroupDisplayName -Config $cfg -DisplayName $expected
                        Assert-True $parsed.Matched
                        Assert-Equal $parsed.CloudType $cloud
                        Assert-Equal $parsed.CloudIdentifier $identifier.ToLowerInvariant()
                        Assert-Equal $parsed.GroupMode $mode
                        Assert-Equal $parsed.OSCategory $os
                        $state = @{
                            MemberGroups = @($parsed); CloudGroupType = $cloud; CloudGroupOS = $os
                            CloudIdentifier = $identifier; MdeAntivirusMode = $mode
                        }
                        Update-GroupComplianceFlags $state
                        Assert-Equal $state.GroupComplianceStatus 'Compliant'
                        $state.CloudGroupOS = if ($os -eq 'Windows') { 'Linux' } else { 'Windows' }
                        Update-GroupComplianceFlags $state
                        Assert-True ('WrongGroup' -in $state.GroupFlagCodes)
                    }
                }
            }
            Assert-Equal (ConvertFrom-CloudGroupDisplayName $cfg 'dfs-aws-123456789012-windows-unknown').Matched $false
            Assert-Equal (ConvertFrom-CloudGroupDisplayName $cfg 'dfs-aws--windows-passive').Matched $false
            Assert-Equal (ConvertFrom-CloudGroupDisplayName $cfg 'dfs-aws-123456789012-passive').Matched $false
            $summary = Get-FunctionParametersSummary
            Assert-True ($summary.SYNC_AZURE_WINDOWS_GROUP_PREFIX.Contains('dfs-azure-<subscriptionname>-windows-passive'))
            Assert-True ($summary.SYNC_AZURE_LINUX_GROUP_PREFIX.Contains('dfs-azure-<subscriptionname>-linux-passive'))
        }
        Test-Case 'Template group discovery searches cloud prefixes and distinguishes Windows and Linux groups' {
            $cfg = Get-SyncConfig
            $cfg.Subscriptions = @()
            $cfg.ManagementGroups = @()
            foreach ($cloud in @('Aws', 'Gcp', 'Azure')) {
                $cfg["${cloud}WindowsGroupPrefix"] = "dfs-$($cloud.ToLowerInvariant())-{id}-windows-{mode}"
                $cfg["${cloud}LinuxGroupPrefix"] = "dfs-$($cloud.ToLowerInvariant())-{id}-linux-{mode}"
            }
            $script:CoverageQueries = @()
            function script:Invoke-Graph {
                param($Path)
                $script:CoverageQueries += [uri]::UnescapeDataString($Path)
                @{ Content = '{"value":[{"id":"11111111-2222-3333-4444-555555555555","displayName":"dfs-aws-123456789012-windows-active"},{"id":"66666666-7777-8888-9999-000000000000","displayName":"dfs-aws-123456789012-linux-passive"}]}' }
            }
            $catalog = Get-CoverageCatalog $cfg
            Assert-Equal $script:CoverageQueries.Count 3
            foreach ($cloud in @('aws', 'gcp', 'azure')) {
                Assert-Equal @($script:CoverageQueries | Where-Object { $_.Contains("startsWith(displayName,'dfs-$cloud-')") }).Count 1
            }
            Assert-Equal $catalog.ManagedGroups.Count 2
            Assert-Equal $catalog.ManagedGroups[0].OSCategory 'Windows'
            Assert-Equal $catalog.ManagedGroups[0].GroupMode 'Active'
            Assert-Equal $catalog.ManagedGroups[1].OSCategory 'Linux'
            Assert-Equal $catalog.ManagedGroups[1].GroupMode 'Passive'
        }
        Test-Case 'Template memberships retain existing Active assignment under a Passive default' {
            $cfg = Get-SyncConfig
            $cfg.AwsWindowsGroupPrefix = 'dfs-aws-{id}-windows-{mode}'
            $cfg.AwsLinuxGroupPrefix = 'dfs-aws-{id}-linux-{mode}'
            function script:Invoke-Graph {
                @{ Content = '{"value":[{"id":"11111111-2222-3333-4444-555555555555","displayName":"dfs-aws-123456789012-linux-active"}]}' }
            }
            $memberships = @(Get-DeviceCloudGroups $cfg '22222222-3333-4444-5555-666666666666')
            Assert-Equal $memberships.Count 1
            Assert-Equal $memberships[0].GroupMode 'Active'
            Assert-Equal $memberships[0].OSCategory 'Linux'
            Assert-Equal $memberships[0].CloudIdentifier '123456789012'
            $state = @{
                EntraObjectId = '22222222-3333-4444-5555-666666666666'; GroupName = 'dfs-aws-123456789012-linux-passive'
                CloudGroupType = 'AWS'; CloudGroupOS = 'Linux'; CloudIdentifier = '123456789012'; MdeAntivirusMode = 'Active'
            }
            Set-VerifiedMembership -State $state -Config $cfg
            Assert-Equal $state.Status 'Verified'
            Assert-Equal $state.GroupName 'dfs-aws-123456789012-linux-active'
            Assert-Equal $state.GroupAvMode 'Active'
            Assert-Equal $state.GroupComplianceStatus 'Compliant'
        }
        Test-Case 'New and existing direct memberships report the correct separate OS category immediately' {
            $cfg = Get-SyncConfig
            $cfg.AwsWindowsGroupPrefix = 'dfs-aws-{id}-windows-{mode}'
            $cfg.AwsLinuxGroupPrefix = 'dfs-aws-{id}-linux-{mode}'
            function script:Test-Group { @{ displayName = "dfs-aws-123456789012-$($script:MembershipOS.ToLowerInvariant())-passive" } }
            function script:Test-DirectMembership { $script:MembershipReads++; $script:MembershipReads -ge 2 }
            function script:Write-MutationIntent {}
            function script:Invoke-Graph { @{ Status = 204 } }
            foreach ($os in @('Windows', 'Linux')) {
                $script:MembershipOS = $os
                foreach ($alreadyPresent in @($true, $false)) {
                    $script:MembershipReads = if ($alreadyPresent) { 1 } else { 0 }
                    $state = @{
                        Key = 'key'; Mode = 'Enforce'; GroupId = '11111111-2222-3333-4444-555555555555'
                        EntraObjectId = '22222222-3333-4444-5555-666666666666'; CloudGroupType = 'AWS'
                        CloudGroupOS = $os; CloudIdentifier = '123456789012'; MdeAntivirusMode = 'Passive'
                    }
                    Set-VerifiedMembership -State $state -Config $cfg
                    Assert-Equal $state.Status 'Verified'
                    Assert-Equal $state.MemberGroups[0].OSCategory $os
                    Assert-Equal $state.GroupComplianceStatus 'Compliant'
                }
            }
            Test-Case 'Explicit custom shared templates remain supported without changing the new defaults' {
                $cfg = Get-SyncConfig
                $cfg.AwsWindowsGroupPrefix = 'dfs-aws-{id}-{mode}'
                $cfg.AwsLinuxGroupPrefix = 'dfs-aws-{id}-{mode}'
                $parsed = ConvertFrom-CloudGroupDisplayName $cfg 'dfs-aws-123456789012-active'
                Assert-True $parsed.Matched
                Assert-Equal $parsed.OSCategory 'All'
                Assert-Equal $parsed.GroupMode 'Active'
            }
        }
        Test-Case 'Per-account Cloud x OS Entra groups route Windows and Linux servers per AWS Account, GCP Project, and Azure Subscription' {
            $cfg = Get-SyncConfig
            Assert-Equal $cfg.DefaultGroupMode 'Passive'
            $params = Get-FunctionParametersSummary
            Assert-Equal $params.SYNC_DEFAULT_GROUP_MODE 'Passive'
            Assert-True ($params.SYNC_AWS_WINDOWS_GROUP_PREFIX.Contains('MDfS-AWS-Windows-Passive-<AccountId>'))
            Assert-True ($params.SYNC_AWS_LINUX_GROUP_PREFIX.Contains('MDfS-AWS-Linux-Passive-<AccountId>'))
            Assert-True ($params.SYNC_GCP_WINDOWS_GROUP_PREFIX.Contains('MDfS-GCP-Windows-Passive-<ProjectId>'))
            Assert-True ($params.SYNC_GCP_LINUX_GROUP_PREFIX.Contains('MDfS-GCP-Linux-Passive-<ProjectId>'))
            Assert-True ($params.SYNC_AZURE_WINDOWS_GROUP_PREFIX.Contains('MDfS-Azure-Windows-Passive-<SubscriptionName>'))
            Assert-True ($params.SYNC_AZURE_LINUX_GROUP_PREFIX.Contains('MDfS-Azure-Linux-Passive-<SubscriptionName>'))
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest { @{ Status = 200; Content = '{"properties":{"status":"Connected","osType":"Linux"}}' } }
            function script:Get-MdeCandidates { @() }
            function script:Get-SubscriptionName { 'Production subscription' }
            function script:Get-ArcExtensions { @() }
            function script:Save-MachineState { param($State) $script:Saved = $State }
            function script:Write-FunctionLog {}
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.CloudGroupType 'Azure'
            Assert-Equal $script:Saved.CloudGroupOS 'Linux'
            Assert-Equal $script:Saved.GroupName 'MDfS-Azure-Linux-Passive-Production subscription'
        }
        Test-Case 'Cloud x OS group routing uses AccountId for AWS, ProjectId for GCP, excludes AWS/GCP from Azure Subscription groups, and enforces Active/Passive rules and flags' {
            $cfg = Get-SyncConfig
            # 1. AWS Windows & Linux machines (default Passive mode)
            $awsWinTarget = Resolve-CloudGroupTarget -Config $cfg -State @{
                OS = 'Windows'; CloudProvider = 'AWS'; MdeCloudPlatforms = 'Amazon Web Services'; SubscriptionName = 'Production subscription'
                AzureTags = @{ AccountId = '123456789012'; Environment = 'Prod' }
            }
            Assert-Equal $awsWinTarget.CloudType 'AWS'
            Assert-Equal $awsWinTarget.OSCategory 'Windows'
            Assert-Equal $awsWinTarget.CloudIdentifier '123456789012'
            Assert-Equal $awsWinTarget.GroupName 'MDfS-AWS-Windows-Passive-123456789012'
            Assert-Equal $awsWinTarget.CounterpartGroupName 'MDfS-AWS-Windows-Active-123456789012'
            $awsLinTarget = Resolve-CloudGroupTarget -Config $cfg -State @{
                OS = 'Ubuntu 22.04'; CloudProvider = 'AWS'; MdeCloudPlatforms = ''; SubscriptionName = 'Production subscription'
                AzureTags = @{ AccountId = '123456789012' }
            }
            Assert-Equal $awsLinTarget.CloudType 'AWS'
            Assert-Equal $awsLinTarget.OSCategory 'Linux'
            Assert-Equal $awsLinTarget.GroupName 'MDfS-AWS-Linux-Passive-123456789012'
            # 2. Global flag set to Active routes to Active group by default
            $env:SYNC_DEFAULT_GROUP_MODE = 'Active'
            $activeCfg = Get-SyncConfig
            Assert-Equal $activeCfg.DefaultGroupMode 'Active'
            $awsActiveTarget = Resolve-CloudGroupTarget -Config $activeCfg -State @{
                OS = 'Windows'; CloudProvider = 'AWS'; MdeCloudPlatforms = ''; SubscriptionName = 'Production subscription'
                AzureTags = @{ AccountId = '123456789012' }
            }
            Assert-Equal $awsActiveTarget.GroupName 'MDfS-AWS-Windows-Active-123456789012'
            Assert-Equal $awsActiveTarget.CounterpartGroupName 'MDfS-AWS-Windows-Passive-123456789012'
            $env:SYNC_DEFAULT_GROUP_MODE = 'Passive'
            # 3. AWS/GCP missing tag never falls back to Azure Subscription group
            $awsNoTagTarget = Resolve-CloudGroupTarget -Config $cfg -State @{
                OS = 'Windows'; CloudProvider = 'AWS'; MdeCloudPlatforms = ''; SubscriptionName = 'Production subscription'
                AzureTags = @{ Environment = 'Prod' }
            }
            Assert-Equal $awsNoTagTarget.CloudType 'AWS'
            Assert-Equal $awsNoTagTarget.GroupName ''
            $gcpWinTarget = Resolve-CloudGroupTarget -Config $cfg -State @{
                OS = 'Windows'; CloudProvider = 'GCP'; MdeCloudPlatforms = 'Google Cloud Platform'; SubscriptionName = 'Production subscription'
                AzureTags = @{ ProjectId = 'my-gcp-project-01' }
            }
            Assert-Equal $gcpWinTarget.CloudType 'GCP'
            Assert-Equal $gcpWinTarget.OSCategory 'Windows'
            Assert-Equal $gcpWinTarget.GroupName 'MDfS-GCP-Windows-Passive-my-gcp-project-01'
            $azureWinTarget = Resolve-CloudGroupTarget -Config $cfg -State @{
                OS = 'Windows'; CloudProvider = 'Azure Arc'; MdeCloudPlatforms = 'Azure Arc'; SubscriptionName = 'Production subscription'
                AzureTags = @{ Environment = 'Prod' }
            }
            Assert-Equal $azureWinTarget.CloudType 'Azure'
            Assert-Equal $azureWinTarget.OSCategory 'Windows'
            Assert-Equal $azureWinTarget.GroupName 'MDfS-Azure-Windows-Passive-Production subscription'
            # 4. Rule 2: Global flag = Passive, device is already in Active group -> NOT added to Passive group; Rule 4: Active group + MDE Passive -> flagged Should be Active
            $env:SYNC_MODE = 'Enforce'
            function script:Invoke-Graph {
                param($Path, $Method = 'GET')
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[{"id":"99999999-9999-9999-9999-999999999999","displayName":"MDfS-AWS-Windows-Active-123456789012"}]}' }
                }
                throw "Should not call $Method $Path when already in Active group"
            }
            $stateInActive = @{
                Key = 'k'; RunId = [guid]::NewGuid().ToString(); ArcResourceId = $id
                GroupId = ''; GroupName = $awsWinTarget.GroupName
                CloudGroupType = 'AWS'; CloudGroupOS = 'Windows'; CloudIdentifier = '123456789012'
                MdeAntivirusMode = 'Passive'
                EntraObjectId = '55555555-5555-5555-5555-555555555555'; Mode = 'Enforce'
            }
            Set-VerifiedMembership $stateInActive $awsWinTarget $cfg
            Assert-Equal $stateInActive.GroupName 'MDfS-AWS-Windows-Active-123456789012'
            Assert-Equal $stateInActive.GroupAvMode 'Active'
            Assert-Equal $stateInActive.Membership 'Present'
            Assert-Equal $stateInActive.Status 'Verified'
            Assert-True ('AvModeMismatchShouldBeActive' -in $stateInActive.GroupFlagCodes)
            Assert-True ($stateInActive.GroupFlags[0].Contains('Should be Active'))
            # 5. Rule 3: Global flag = Active, device is already in Passive group -> NOT added to Active group; Rule 5: Passive group + MDE Active -> flagged Should be Active
            function script:Invoke-Graph {
                param($Path, $Method = 'GET')
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[{"id":"88888888-8888-8888-8888-888888888888","displayName":"MDfS-AWS-Windows-Passive-123456789012"}]}' }
                }
                throw "Should not call $Method $Path when already in Passive group"
            }
            $stateInPassive = @{
                Key = 'k'; RunId = [guid]::NewGuid().ToString(); ArcResourceId = $id
                GroupId = ''; GroupName = $awsActiveTarget.GroupName
                CloudGroupType = 'AWS'; CloudGroupOS = 'Windows'; CloudIdentifier = '123456789012'
                MdeAntivirusMode = 'Active'
                EntraObjectId = '55555555-5555-5555-5555-555555555555'; Mode = 'Enforce'
            }
            Set-VerifiedMembership $stateInPassive $awsActiveTarget $activeCfg
            Assert-Equal $stateInPassive.GroupName 'MDfS-AWS-Windows-Passive-123456789012'
            Assert-Equal $stateInPassive.GroupAvMode 'Passive'
            Assert-True ('AvModeMismatchShouldBeActive' -in $stateInPassive.GroupFlagCodes)
            Assert-True ($stateInPassive.GroupFlags[0].Contains('Should be Active'))
            # 6. Rules 6 & 7: Device in multiple groups and wrong AWS Account ID / Subscription / GCP Project is flagged and shows all groups
            function script:Invoke-Graph {
                param($Path, $Method = 'GET')
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[{"id":"11111111-2222-3333-4444-555555555555","displayName":"MDfS-AWS-Windows-Passive-123456789012"},{"id":"66666666-7777-8888-9999-000000000000","displayName":"MDfS-AWS-Windows-Active-999999999999"}]}' }
                }
                throw "Unexpected Graph call $Method $Path"
            }
            $stateMultiWrong = @{
                Key = 'k'; RunId = [guid]::NewGuid().ToString(); ArcResourceId = $id
                GroupId = ''; GroupName = $awsWinTarget.GroupName
                CloudGroupType = 'AWS'; CloudGroupOS = 'Windows'; CloudIdentifier = '123456789012'
                MdeAntivirusMode = 'Passive'
                EntraObjectId = '55555555-5555-5555-5555-555555555555'; Mode = 'Enforce'
            }
            Set-VerifiedMembership $stateMultiWrong $awsWinTarget $cfg
            Assert-Equal $stateMultiWrong.MemberGroups.Count 2
            Assert-Equal $stateMultiWrong.GroupName 'MDfS-AWS-Windows-Passive-123456789012; MDfS-AWS-Windows-Active-999999999999'
            Assert-True ('MultipleGroups' -in $stateMultiWrong.GroupFlagCodes)
            Assert-True ('WrongGroup' -in $stateMultiWrong.GroupFlagCodes)
            Assert-True ('AvModeMismatchShouldBeActive' -in $stateMultiWrong.GroupFlagCodes)
            # 7. Device not in any group is added to the default Passive group in Enforce mode
            $script:AddedGroups = @()
            function script:Invoke-Graph {
                param($Path, $Method = 'GET', $Body)
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[]}' }
                }
                if ($Path.StartsWith('/groups?$filter=')) {
                    Assert-True ($Path.Contains('MDfS-AWS-Windows-Passive-123456789012'))
                    return @{ Content = '{"value":[{"id":"99999999-9999-9999-9999-999999999999","displayName":"MDfS-AWS-Windows-Passive-123456789012","securityEnabled":true,"groupTypes":[],"onPremisesSyncEnabled":false,"isAssignableToRole":false}]}' }
                }
                if ($Method -eq 'POST' -and $Path.EndsWith('/members/$ref')) {
                    $script:AddedGroups += $Path
                    return @{ Status = 204 }
                }
                throw "Unexpected Graph call: $Method $Path"
            }
            $script:DirectChecks = @{}
            function script:Test-DirectMembership {
                param($GroupId, $ObjectId)
                if (-not $script:DirectChecks.ContainsKey($GroupId)) { $script:DirectChecks[$GroupId] = 0 }
                $script:DirectChecks[$GroupId]++
                return $script:DirectChecks[$GroupId] -gt 1
            }
            function script:Write-MutationIntent {}
            $syncState = @{
                Key = 'k'; RunId = [guid]::NewGuid().ToString(); ArcResourceId = $id
                GroupId = ''; GroupName = $awsWinTarget.GroupName
                CloudGroupType = 'AWS'; CloudGroupOS = 'Windows'; CloudIdentifier = '123456789012'
                MdeAntivirusMode = 'Passive'
                EntraObjectId = '55555555-5555-5555-5555-555555555555'; Mode = 'Enforce'
            }
            Set-VerifiedMembership $syncState $awsWinTarget $cfg
            Assert-Equal $syncState.GroupId '99999999-9999-9999-9999-999999999999'
            Assert-Equal $syncState.GroupName 'MDfS-AWS-Windows-Passive-123456789012'
            Assert-Equal $syncState.Membership 'Present'
            Assert-Equal $syncState.Status 'Verified'
            Assert-Equal $syncState.GroupFlags.Count 0
            Assert-Equal $syncState.GroupComplianceStatus 'Compliant'
            Assert-Equal $script:AddedGroups.Count 1
            # 8. Administrative Unit automatic group creation (Audit zero-write vs Enforce POST /directory/administrativeUnits/{auId}/members)
            $script:GroupByNameCache = @{}
            $script:AdminUnitGroupsCache = @{}
            $env:SYNC_ADMIN_UNIT_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $env:SYNC_AUTO_CREATE_GROUPS = 'true'
            $auCfg = Get-SyncConfig
            Assert-Equal $auCfg.AdminUnitId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            Assert-Equal $auCfg.AutoCreateGroups $true
            $env:SYNC_MODE = 'Audit'
            function script:Invoke-Graph {
                param($Path, $Method = 'GET', $Body)
                if ($Path.StartsWith('/directory/administrativeUnits/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/members/microsoft.graph.group')) {
                    return @{ Content = '{"value":[]}' }
                }
                throw "Audit mode with AU must only check AU groups, not call $Method $Path"
            }
            $auditAuState = @{
                Key = 'k'; RunId = [guid]::NewGuid().ToString(); ArcResourceId = $id
                GroupId = ''; GroupName = $awsWinTarget.GroupName
                CloudGroupType = 'AWS'; CloudGroupOS = 'Windows'; CloudIdentifier = '123456789012'
                MdeAntivirusMode = 'Passive'
                EntraObjectId = '55555555-5555-5555-5555-555555555555'; Mode = 'Audit'
            }
            Set-VerifiedMembership $auditAuState $awsWinTarget $auCfg
            Assert-Equal $auditAuState.Status 'WouldAdd'
            Assert-Equal $auditAuState.Membership 'Absent'
            Assert-Equal $auditAuState.Action 'WouldCreateGroupAndAdd'
            # Enforce mode creates both Passive and Active groups in the Administrative Unit and adds device
            $env:SYNC_MODE = 'Enforce'
            $script:AuCreatedGroups = @()
            function script:Invoke-Table { @{ Status = 204 } }
            function script:Invoke-Graph {
                param($Path, $Method = 'GET', $Body)
                if ($Path.StartsWith('/directory/administrativeUnits/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/members/microsoft.graph.group')) {
                    return @{ Content = '{"value":[]}' }
                }
                if ($Method -eq 'POST' -and $Path -eq '/directory/administrativeUnits/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/members') {
                    Assert-Equal $Body['@odata.type'] '#microsoft.graph.group'
                    $script:AuCreatedGroups += $Body.displayName
                    $newId = if ($Body.displayName.Contains('-Passive-')) { '12121212-1212-1212-1212-121212121212' } else { '34343434-3434-3434-3434-343434343434' }
                    return @{ Status = 201; Content = (@{ id = $newId; displayName = $Body.displayName } | ConvertTo-Json -Compress) }
                }
                if ($Method -eq 'POST' -and $Path.EndsWith('/members/$ref')) {
                    return @{ Status = 204 }
                }
                throw "Unexpected Graph call in AU auto-create test: $Method $Path"
            }
            $script:DirectChecks = @{}
            $enforceAuState = @{
                Key = 'k'; RunId = [guid]::NewGuid().ToString(); ArcResourceId = $id
                GroupId = ''; GroupName = $awsWinTarget.GroupName
                CloudGroupType = 'AWS'; CloudGroupOS = 'Windows'; CloudIdentifier = '123456789012'
                MdeAntivirusMode = 'Passive'
                EntraObjectId = '55555555-5555-5555-5555-555555555555'; Mode = 'Enforce'
            }
            $script:GroupByNameCache = @{}
            $script:AdminUnitGroupsCache = @{}
            Set-VerifiedMembership $enforceAuState $awsWinTarget $auCfg
            Assert-Equal $script:AuCreatedGroups.Count 2
            Assert-True ('MDfS-AWS-Windows-Passive-123456789012' -in $script:AuCreatedGroups)
            Assert-True ('MDfS-AWS-Windows-Active-123456789012' -in $script:AuCreatedGroups)
            Assert-Equal $enforceAuState.GroupId '12121212-1212-1212-1212-121212121212'
            Assert-Equal $enforceAuState.Membership 'Present'
            Assert-Equal $enforceAuState.Status 'Verified'
            $script:AdminUnitGroupsCache = @{}
            $env:SYNC_ADMIN_UNIT_ID = ''
            $env:SYNC_AUTO_CREATE_GROUPS = ''
            $env:SYNC_MODE = 'Audit'
        }
        Test-Case 'Group creation rechecks stale AU caches and rejects existing duplicates' {
            $au = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $name = 'MDfS-Azure-Windows-Passive-Production'
            $script:FreshGroups = @(@{
                id = '12121212-1212-1212-1212-121212121212'; displayName = $name
                securityEnabled = $true; groupTypes = @(); onPremisesSyncEnabled = $false; isAssignableToRole = $false
            })
            $script:AdminUnitGroupsCache[$au] = @()
            function script:Get-SharedAdminUnitGroups { throw 'Creation must bypass stale shared catalog data.' }
            function script:Invoke-Graph {
                param($Path, $Method = 'GET')
                Assert-Equal $Method 'GET'
                @{ Content = (@{ value = $script:FreshGroups } | ConvertTo-Json -Depth 10 -Compress) }
            }
            function script:Invoke-Table { throw 'Existing or ambiguous groups must not reserve creation.' }
            $resolved = New-AdminUnitSecurityGroup -AdminUnitId $au -DisplayName $name
            Assert-Equal $resolved.Id '12121212-1212-1212-1212-121212121212'
            $second = $script:FreshGroups[0].Clone()
            $second.id = '34343434-3434-3434-3434-343434343434'
            $script:FreshGroups += $second
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $au -DisplayName $name }
        }
        Test-Case 'Group creation reservation blocks interleaved workers and survives stale directory reads' {
            $script:CreationAu = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $script:CreationName = 'MDfS-Azure-Windows-Passive-Production'
            $script:CreationClaims = @{}
            $script:GroupPosts = 0
            $script:Interleave = $true
            $script:ReservationResponseConflict = $true
            $script:ThrowAfterCreate = $false
            $script:FailClaimSave = $false
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Body, $Headers, $AllowStatus)
                if ($Method -eq 'POST') {
                    if ($script:CreationClaims.ContainsKey($Body.RowKey)) { return @{ Status = 409 } }
                    $script:CreationClaims[$Body.RowKey] = $Body.Clone()
                    if ($script:ReservationResponseConflict) {
                        $script:ReservationResponseConflict = $false
                        return @{ Status = 409 }
                    }
                    return @{ Status = 201 }
                }
                $key = [regex]::Match($Path, "RowKey='([^']+)'").Groups[1].Value
                if ($Method -eq 'PUT') {
                    if ($script:FailClaimSave) { throw 'Table write failed after Graph create.' }
                    Assert-Equal $Headers['If-Match'] '*'
                    $script:CreationClaims[$key] = $Body.Clone()
                    return @{ Status = 204 }
                }
                @{ Status = 200; Content = ($script:CreationClaims[$key] | ConvertTo-Json -Compress) }
            }
            function script:Invoke-Graph {
                param($Path, $Method = 'GET', $Body, $AllowStatus, [switch]$DisableRetry)
                if ($Method -eq 'GET') { return @{ Status = 200; Content = '{"value":[]}' } }
                Assert-True $DisableRetry
                if ($script:Interleave) {
                    $script:Interleave = $false
                    # Interleave another worker after the claim but before the directory write.
                    $script:GroupByNameCache = @{}
                    $script:AdminUnitGroupsCache = @{}
                    Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:CreationAu -DisplayName $script:CreationName.ToUpperInvariant() }
                }
                $script:GroupPosts++
                if ($script:ThrowAfterCreate) { throw 'Connection lost after the group may have been created.' }
                @{ Status = 201; Content = (@{
                    id = '12121212-1212-1212-1212-121212121212'; displayName = $Body.displayName
                } | ConvertTo-Json -Compress) }
            }
            function script:Test-Group {
                param($GroupId)
                @{ id = $GroupId; displayName = $script:CreationName }
            }
            $first = New-AdminUnitSecurityGroup -AdminUnitId $script:CreationAu -DisplayName $script:CreationName
            Assert-Equal $script:GroupPosts 1
            $script:GroupByNameCache = @{}
            $script:AdminUnitGroupsCache = @{}
            $second = New-AdminUnitSecurityGroup -AdminUnitId $script:CreationAu -DisplayName $script:CreationName
            Assert-Equal $second.Id $first.Id
            Assert-Equal $script:GroupPosts 1
            function script:Test-Group { throw 'Recorded group is deleted or no longer a valid security group.' }
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:CreationAu -DisplayName $script:CreationName }
            Assert-Equal $script:GroupPosts 1

            # A lost Graph response must leave a durable pending claim, not authorize another POST.
            $script:CreationName = 'MDfS-Azure-Linux-Passive-Production'
            $script:ThrowAfterCreate = $true
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:CreationAu -DisplayName $script:CreationName }
            Assert-Equal $script:GroupPosts 2
            $script:GroupByNameCache = @{}
            $script:AdminUnitGroupsCache = @{}
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:CreationAu -DisplayName $script:CreationName }
            Assert-Equal $script:GroupPosts 2

            # The same safeguard applies if Graph succeeds but the completed claim cannot be saved.
            $script:CreationName = 'MDfS-Azure-Linux-Active-Production'
            $script:ThrowAfterCreate = $false
            $script:FailClaimSave = $true
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:CreationAu -DisplayName $script:CreationName }
            Assert-Equal $script:GroupPosts 3
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:CreationAu -DisplayName $script:CreationName }
            Assert-Equal $script:GroupPosts 3
        }
        Test-Case 'Group lookup permits a missing group only when explicitly requested' {
            $script:LookupStatus = 404
            function script:Invoke-Graph {
                param($Path, $AllowStatus)
                if ($script:LookupStatus -notin $AllowStatus) { throw "HTTP $script:LookupStatus" }
                @{ Status = $script:LookupStatus }
            }
            Assert-True ($null -eq (Test-Group -GroupId '12121212-1212-1212-1212-121212121212' -AllowMissing))
            Assert-Throws { Test-Group -GroupId '12121212-1212-1212-1212-121212121212' }
            $script:LookupStatus = 403
            Assert-Throws { Test-Group -GroupId '12121212-1212-1212-1212-121212121212' -AllowMissing }
        }
        Test-Case 'Deleted completed groups recover exclusively while uncertain claims remain protected' {
            $script:RecoveryAu = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $script:RecoveryName = 'dfs-azure-production-windows-passive'
            $script:DeletedGroup = '12121212-1212-1212-1212-121212121212'
            $script:ReplacementGroup = '34343434-3434-3434-3434-343434343434'
            $script:RecoveryClaim = @{ OperationId = 'original'; GroupId = $script:DeletedGroup; CreatedAt = [datetimeoffset]::UtcNow.AddMinutes(-31).ToString('o') }
            $script:RecoveryEtag = 'W/"1"'
            $script:RecoveryConflict = $false
            $script:RecoveryPermissionError = $false
            $script:RecoveryPosts = 0
            $script:RecoveryReads = 0
            $script:RecoveredExisting = $false
            function script:Resolve-GroupByDisplayName {
                param($DisplayName, $AdminUnitId, [switch]$ForceRefresh)
                Assert-True $ForceRefresh
                $script:RecoveryReads++
                if ($script:RecoveredExisting -and -not $script:RecoveryClaim.GroupId) {
                    return @{ Id = $script:ReplacementGroup; DisplayName = $DisplayName }
                }
                return $null
            }
            function script:Test-Group {
                param($GroupId, [switch]$AllowMissing)
                Assert-True $AllowMissing
                if ($script:RecoveryPermissionError) { throw 'HTTP 403' }
                if ($GroupId -eq $script:DeletedGroup) { return $null }
                @{ id = $GroupId; displayName = $script:RecoveryName }
            }
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Body, $Headers, $AllowStatus)
                if ($Method -eq 'POST') { return @{ Status = 409 } }
                if ($Method -eq 'GET') {
                    return @{ Status = 200; Headers = @{ ETag = $script:RecoveryEtag }; Content = ($script:RecoveryClaim | ConvertTo-Json -Compress) }
                }
                if (-not $Body.GroupId) {
                    Assert-Equal $Headers['If-Match'] 'W/"1"'
                    Assert-True (412 -in $AllowStatus)
                    if ($script:RecoveryConflict) { return @{ Status = 412 } }
                    Assert-Equal $Body.PreviousGroupId $script:DeletedGroup
                    Assert-True ($Body.OperationId -ne 'original')
                }
                $script:RecoveryClaim = $Body.Clone()
                @{ Status = 204 }
            }
            function script:Invoke-Graph {
                param($Path, $Method, $Body, [switch]$DisableRetry)
                Assert-Equal $Method 'POST'
                Assert-True $DisableRetry
                # Another worker must see a pending claim after recovery wins, before Graph finishes.
                Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName }
                $script:RecoveryPosts++
                @{ Status = 201; Content = (@{ id = $script:ReplacementGroup; displayName = $Body.displayName } | ConvertTo-Json -Compress) }
            }
            $result = New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName
            Assert-Equal $result.Id $script:ReplacementGroup
            Assert-Equal $script:RecoveryPosts 1
            Assert-Equal $script:RecoveryClaim.PreviousGroupId $script:DeletedGroup
            Assert-True ($script:RecoveryReads -ge 2)
            $null = New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName
            Assert-Equal $script:RecoveryPosts 1

            $script:RecoveryClaim = @{ OperationId = 'original'; GroupId = $script:DeletedGroup; CreatedAt = [datetimeoffset]::UtcNow.AddHours(-1).ToString('o') }
            $script:RecoveryConflict = $true
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName }
            Assert-Equal $script:RecoveryClaim.GroupId $script:DeletedGroup
            $script:RecoveryConflict = $false
            $script:RecoveryEtag = ''
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName }
            $script:RecoveryEtag = 'W/"1"'
            $script:RecoveryPermissionError = $true
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName }
            Assert-Equal $script:RecoveryPosts 1
            Assert-Equal $script:RecoveryClaim.GroupId $script:DeletedGroup

            $script:RecoveryPermissionError = $false
            $script:RecoveryClaim.CreatedAt = [datetimeoffset]::UtcNow.AddMinutes(-29).ToString('o')
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName }
            $script:RecoveryClaim.CreatedAt = 'invalid'
            Assert-Throws { New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName }
            Assert-Equal $script:RecoveryPosts 1
            $script:RecoveryClaim.CreatedAt = [datetimeoffset]::UtcNow.AddHours(-1).ToString('o')
            $script:RecoveredExisting = $true
            $result = New-AdminUnitSecurityGroup -AdminUnitId $script:RecoveryAu -DisplayName $script:RecoveryName
            Assert-Equal $result.Id $script:ReplacementGroup
            Assert-Equal $script:RecoveryClaim.GroupId $script:ReplacementGroup
            Assert-Equal $script:RecoveryPosts 1
        }
        Test-Case 'Group name caches are isolated by Administrative Unit' {
            $script:LookupCalls = 0
            function script:Invoke-Graph {
                param($Path)
                $script:LookupCalls++
                $groupId = if ($Path.Contains('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')) {
                    '12121212-1212-1212-1212-121212121212'
                } else { '34343434-3434-3434-3434-343434343434' }
                @{ Content = (@{ value = @(@{
                    id = $groupId; displayName = 'Same name'; securityEnabled = $true
                    groupTypes = @(); onPremisesSyncEnabled = $false; isAssignableToRole = $false
                }) } | ConvertTo-Json -Depth 10 -Compress) }
            }
            $a = Resolve-GroupByDisplayName -AdminUnitId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -DisplayName 'Same name'
            $b = Resolve-GroupByDisplayName -AdminUnitId 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee' -DisplayName 'Same name'
            Assert-True ($a.Id -ne $b.Id)
            Assert-Equal $script:LookupCalls 2
        }
        Test-Case 'Unique offboarded and stale devices remain visible but cannot authorize membership' {
            $script:ReportingCandidate = $candidate.Clone()
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest { @{ Status = 200; Content = '{"properties":{"status":"Connected","osType":"Windows"}}' } }
            function script:Get-SubscriptionName { 'Production subscription' }
            function script:Get-ArcExtensions { @() }
            function script:Get-MdeCandidates { @($script:ReportingCandidate) }
            function script:Get-MdeNetworkAddresses { @() }
            function script:Get-MdeAntivirus { @{ Mode = ''; Timestamp = ''; Status = 'NoData' } }
            function script:Invoke-Graph { throw 'Ineligible telemetry must not authorize directory operations.' }
            function script:Save-MachineState { param($State) $script:Saved = $State }
            function script:Write-FunctionLog {}
            $script:ReportingCandidate.OnboardingStatus = 'CanBeOnboarded'
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.Status 'PendingMde'
            Assert-Equal $script:Saved.MdeOnboardingStatus 'CanBeOnboarded'
            Assert-Equal $script:Saved.MdeDeviceId 'mde1'
            $script:ReportingCandidate.OnboardingStatus = 'Onboarded'
            $script:ReportingCandidate.Timestamp = $now.AddHours(-25).ToString('o')
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.Status 'StaleEvidence'
            Assert-Equal $script:Saved.MdeDeviceId 'mde1'
        }
        Test-Case 'Arc extensions pagination retains all names and states' {
            $script:ExtensionCalls = 0
            function script:Invoke-CloudRequest {
                param($Uri)
                $script:ExtensionCalls++
                if ($script:ExtensionCalls -eq 1) {
                    return @{ Content = (@{
                        value = @(@{ name = 'MonitorAgent'; properties = @{ typeHandlerVersion = '1.0'; provisioningState = 'Succeeded' } })
                        nextLink = $Uri + '&page=2'
                    } | ConvertTo-Json -Depth 10 -Compress) }
                }
                Test-Case 'MDE tags preserve source, spaces and case while removing exact duplicates' {
                    $tags = $candidate.Clone()
                    $tags.DeviceManualTags = '["Production","production","Tier 1","Production"]'
                    $tags.DeviceDynamicTags = @('Tier 1', 'Internet facing')
                    $tags.RegistryDeviceTag = ' Managed,Shared '
                    $state = @{}
                    Set-MdeTags $state $tags
                    Assert-Equal $state.MdeDeviceTags.Count 6
                    Assert-True ('Production' -cin $state.MdeDeviceTags)
                    Assert-True ('production' -cin $state.MdeDeviceTags)
                    Assert-True ('Internet facing' -in $state.MdeDynamicTags)
                    Assert-True ('Managed' -in $state.MdeRegistryTags)
                }
                Test-Case 'Empty MDE tags differ from uncollected tags and malformed tags are explicit' {
                    $state = @{ MdeDeviceTags = $null }
                    Set-MdeTags $state @{}
                    Assert-True ($null -ne $state.MdeDeviceTags)
                    Assert-Equal $state.MdeDeviceTags.Count 0
                    Assert-Equal @(ConvertTo-TagList '["Only tag"]').Count 1
                    Assert-Equal @(ConvertTo-TagList '[]').Count 0
                    Assert-Throws { ConvertTo-TagList '[invalid-json' }
                    Assert-Throws { ConvertTo-TagList '[{"invalid":"tag object"}]' }
                }
                Test-Case 'Azure tags retain original keys and values in deterministic order' {
                    $state = @{}
                    Set-AzureTags $state @{ tags = @{ z = 'last'; a = '<script>not markup</script>'; Environment = 'Production' } }
                    Assert-Equal $state.AzureTags.a '<script>not markup</script>'
                    Assert-Equal ($state.AzureTags.Keys -join ',') 'a,Environment,z'
                    Assert-Throws { Set-AzureTags @{} @{ tags = @('invalid') } }
                    Assert-Throws { Set-AzureTags @{} @{ tags = @{ Invalid = @{ unexpected = 'object' } } } }
                }
                @{ Content = '{"value":[{"name":"DefenderAgent","properties":{"typeHandlerVersion":"2.0","provisioningState":"Failed"}}]}' }
            }
            $extensions = @(Get-ArcExtensions $id)
            Assert-Equal $extensions.Count 2
            Assert-True ($extensions[0].Contains('state: Failed'))
            Assert-True ($extensions[1].Contains('state: Succeeded'))
        }
        Test-Case 'MDE network collection parses IPv4/IPv6 arrays and removes duplicates' {
            function script:Invoke-Graph {
                param($Body)
                Assert-True ($Body.Query.Contains('by DeviceId, NetworkAdapterName, MacAddress'))
                @{ Content = '{"results":[{"IPAddresses":"[{\"IPAddress\":\"10.0.0.4\"},{\"IPAddress\":\"2001:db8::4\"}]"},{"IPAddresses":"[{\"IPAddress\":\"10.0.0.4\"}]"}]}' }
            }
            $addresses = @(Get-MdeNetworkAddresses 'device-id')
            Assert-Equal $addresses.Count 2
            Assert-True ('2001:db8::4' -in $addresses)
        }
        Test-Case 'Antivirus inventory uses advanced hunting context and mode mapping' {
            $script:AvCode = '0'
            function script:Invoke-Graph {
                param($Path, $Method, $Body)
                Assert-Equal $Path '/security/runHuntingQuery'
                Assert-True ($Body.Query.Contains('DeviceTvmSecureConfigurationAssessment'))
                Assert-True ($Body.Query.Contains("ConfigurationId == 'scid-2010'"))
                Assert-True ($Body.Query.Contains('parse_json(Context)[0][0]'))
                Assert-True ($Body.Query.IndexOf('summarize arg_max') -lt $Body.Query.IndexOf('AvMode ='))
                @{ Content = (@{ results = @(@{ DeviceId = 'mde1'; AvMode = $script:AvCode; Timestamp = '2026-10-19T12:00:00Z' }) } | ConvertTo-Json -Depth 10 -Compress) }
            }
            foreach ($pair in @(@('0', 'Active'), @('1', 'Passive'), @('2', 'Disabled'), @('3', 'Other'), @('4', 'EDRBlocked'), @('5', 'PassiveAudit'))) {
                $script:AvCode = $pair[0]
                Assert-Equal (Get-MdeAntivirus 'mde1').Mode $pair[1]
            }
            $script:AvCode = '99'
            Assert-Throws { Get-MdeAntivirus 'mde1' }
        }
        Test-Case 'Missing antivirus inventory is not reported as active' {
            function script:Invoke-Graph { @{ Content = '{"results":[]}' } }
            $av = Get-MdeAntivirus 'mde1'
            Assert-Equal $av.Mode ''
            Assert-Equal $av.Status 'NoData'
        }
        Test-Case 'Empty latest antivirus context is not inferred from older data' {
            function script:Invoke-Graph { @{ Content = '{"results":[{"DeviceId":"mde1","AvMode":"","Timestamp":"2026-10-19T12:00:00Z"}]}' } }
            Assert-Equal (Get-MdeAntivirus 'mde1').Status 'NoData'
            Assert-Equal (Get-MdeAntivirus 'mde1').Mode ''
        }
        Test-Case 'Reporting enrichment failures are explicitly retained without inventing values' {
            $state = @{ Key = 'key'; InventoryErrors = @(); InventoryStatus = 'Collected'; MdeAntivirusMode = '' }
            Invoke-InventoryStep $state 'MDE antivirus mode' { throw 'HTTP 403 from graph.microsoft.com for POST request.' }
            Assert-Equal $state.InventoryStatus 'Partial'
            Assert-Equal $state.InventoryErrors.Count 1
            Assert-True ($state.InventoryErrors[0].Contains('HTTP 403'))
            Assert-Equal $state.MdeAntivirusMode ''
        }
        Test-Case 'Failure is persisted and rethrown for Service Bus retry' {
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest { throw 'HTTP 403 from management.azure.com for GET request.' }
            function script:Save-MachineState { param($State) $script:Saved = $State }
            function script:Write-FunctionLog { param($Entry) $script:FailedLog = $Entry }
            Assert-Throws { Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'EventGrid' } 2>$null }
            Assert-Equal $script:Saved.Status 'Failed'
            Assert-Equal $script:Saved.Membership 'Unknown'
            Assert-Equal $script:FailedLog.Status 'Failed'
            Assert-Equal $script:FailedLog.Health 'Degraded'
        }
        Test-Case 'Write-FunctionLog persists log row and updates system health summary' {
            $script:TableOps = @()
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Body)
                $script:TableOps += @{ Path = $Path; Method = $Method; Body = $Body }
                if ($Method -eq 'GET') { return @{ Status = 404 } }
                @{ Status = 204 }
            }
            Write-FunctionLog @{
                FunctionName = 'Inventory'
                TriggerReason = 'Scheduled timer (NCRONTAB schedule)'
                Status = 'Succeeded'
                Health = 'Healthy'
                Message = 'Inventory pass completed: queued 2 machine(s).'
                RunId = 'run-1'
                LastSuccessfulInventory = '2026-10-19T12:00:00Z'
                MachinesQueued = 2
            }
            Assert-Equal $script:TableOps.Count 3
            Assert-Equal $script:TableOps[0].Method 'POST'
            Assert-True ($script:TableOps[0].Body.RowKey.StartsWith('log_'))
            Assert-Equal $script:TableOps[2].Method 'PUT'
            $summary = ConvertFrom-Json -InputObject $script:TableOps[2].Body.Data -AsHashtable
            Assert-Equal $summary.FunctionAppStatus 'Running'
            Assert-Equal $summary.Health 'Healthy'
            Assert-Equal $summary.LastRunReason 'Scheduled timer (NCRONTAB schedule)'
            Assert-Equal $summary.MachinesQueued 2
            Assert-Equal $summary.SyncMode $env:SYNC_MODE
            Assert-Equal $summary.DefaultGroupMode $env:SYNC_DEFAULT_GROUP_MODE
        }
        Test-Case 'Function logging replaces stale mode fields with current worker settings' {
            $env:SYNC_MODE = 'Enforce'
            $env:SYNC_DEFAULT_GROUP_MODE = 'Active'
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Body)
                if ($Method -eq 'GET') {
                    return @{ Status = 200; Content = '{"Data":"{\"SyncMode\":\"Audit\",\"DefaultGroupMode\":\"Passive\"}"}' }
                }
                if ($Method -eq 'PUT') { $script:UpdatedSummary = $Body.Data | ConvertFrom-Json -AsHashtable }
                @{ Status = 204 }
            }
            Write-FunctionLog @{ FunctionName = 'Machine'; Status = 'Succeeded' }
            Assert-Equal $script:UpdatedSummary.SyncMode 'Enforce'
            Assert-Equal $script:UpdatedSummary.DefaultGroupMode 'Active'
            Assert-Equal $script:UpdatedSummary.Parameters.SYNC_MODE 'Enforce'
        }
        Test-Case 'Worker startup snapshot overrides stale telemetry and report environment on all APIs' {
            $env:SYNC_MODE = 'Enforce'
            $env:SYNC_DEFAULT_GROUP_MODE = 'Active'
            $script:ConfigurationEntity = $null
            function script:Get-TokenClaims { @{ oid = 'report-identity' } }
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Body)
                if ($Path -like "*RowKey='worker-configuration'*") {
                    if ($Method -eq 'PUT') { $script:ConfigurationEntity = $Body; return @{ Status = 204 } }
                    return @{ Status = 200; Content = ($script:ConfigurationEntity | ConvertTo-Json -Compress) }
                }
                if ($Path -like "*RowKey='permissions'*") {
                    return @{ Status = 200; Content = '{"Data":"{\"SyncMode\":\"Audit\",\"DefaultGroupMode\":\"Passive\",\"Checks\":[]}"}' }
                }
                @{ Status = 200; Content = '{"Data":"{\"SyncMode\":\"Audit\",\"Parameters\":{\"SYNC_MODE\":\"Audit\",\"SYNC_DEFAULT_GROUP_MODE\":\"Passive\"}}"}' }
            }
            Write-WorkerConfiguration
            $published = $script:ConfigurationEntity.Data | ConvertFrom-Json -AsHashtable
            Assert-Equal $published.SyncMode 'Enforce'
            Assert-Equal $published.DefaultGroupMode 'Active'
            Assert-True ([bool]$published.ObservedAt)
            $env:SYNC_MODE = 'Audit'
            $env:SYNC_DEFAULT_GROUP_MODE = 'Passive'
            $request = @{ Headers = @{} }
            $health = Get-ReportHealthResponse $request
            $permissions = Get-ReportPermissionsResponse $request
            Assert-Equal $health.SyncMode 'Enforce'
            Assert-Equal $health.DefaultGroupMode 'Active'
            Assert-Equal $health.Parameters.SYNC_DEFAULT_GROUP_MODE 'Active'
            Assert-Equal $permissions.SyncMode 'Enforce'
            Assert-Equal $permissions.DefaultGroupMode 'Active'
        }
        Test-Case 'Health uses legacy worker parameters and never invents report-side defaults' {
            function script:Invoke-Table {
                param($Path)
                if ($Path -like "*RowKey='inventory'*") {
                    return @{ Status = 200; Content = '{"Data":"{\"SyncMode\":\"Audit\",\"Parameters\":{\"SYNC_MODE\":\"Enforce\",\"SYNC_DEFAULT_GROUP_MODE\":\"Active\"}}"}' }
                }
                @{ Status = 404 }
            }
            $health = Get-ReportHealthResponse @{ Headers = @{} }
            Assert-Equal $health.SyncMode 'Enforce'
            Assert-Equal $health.DefaultGroupMode 'Active'
            function script:Invoke-Table { @{ Status = 404 } }
            $health = Get-ReportHealthResponse @{ Headers = @{} }
            Assert-Equal $health.SyncMode 'Unknown'
            Assert-Equal $health.DefaultGroupMode 'Unknown'
            Assert-Equal $health.Parameters.Count 0
        }
        Test-Case 'State and history transaction checks inner HTTP failures' {
            function script:Get-TableBase { 'https://example.table.core.windows.net' }
            function script:Invoke-CloudRequest {
                param($Body)
                Assert-True ($Body.Contains('If-Match: etag'))
                Assert-True ($Body.Contains('StateChanged'))
                @{ Content = "HTTP/1.1 412 Precondition Failed`r`n" }
            }
            Assert-Throws { Save-MachineState @{ Key = 'key'; LastChecked = 'now'; Status = 'Verified' } @{ ETag = 'etag'; Data = @{ Status = 'WouldAdd' } } }
        }
        Test-Case 'State and history commit accepts two successful operations' {
            function script:Get-TableBase { 'https://example.table.core.windows.net' }
            function script:Invoke-CloudRequest {
                param($Body)
                Assert-True ($Body.Contains('POST https://example.table.core.windows.net/machines HTTP/1.1'))
                @{ Content = "HTTP/1.1 201 Created`r`nHTTP/1.1 201 Created`r`n" }
            }
            Save-MachineState @{ Key = 'key'; LastChecked = 'now'; Status = 'PendingMde' } $null
        }
        Test-Case 'State and history commit decodes binary multipart responses and surfaces inner errors' {
            function script:Get-TableBase { 'https://example.table.core.windows.net' }
            function script:Invoke-CloudRequest { @{ Content = $script:BatchResponse } }
            $script:BatchResponse = [Text.Encoding]::UTF8.GetBytes("--changeset`r`nContent-Type: application/http`r`n`r`nHTTP/1.1 201 Created`r`n`r`n{`"Data`":`"Log mentions HTTP/1.1 403`"}`r`n--changeset`r`nContent-Type: application/http`r`n`r`nHTTP/1.1 204 No Content`r`n`r`n--changeset--`r`n")
            Save-MachineState @{ Key = 'key'; LastChecked = 'now'; Status = 'Verified' } $null
            $script:BatchResponse = [Text.Encoding]::UTF8.GetBytes("HTTP/1.1 400 Bad Request`r`n`r`n{`"odata.error`":{`"code`":`"PropertyValueTooLarge`"}}")
            $failure = $null
            try { Save-MachineState @{ Key = 'key'; LastChecked = 'now'; Status = 'Verified' } $null }
            catch { $failure = $_ }
            Assert-True ($null -ne $failure)
            Assert-True ($failure.Exception.Message.Contains('400; PropertyValueTooLarge'))
            $script:BatchResponse = [Text.Encoding]::UTF8.GetBytes('not a multipart response')
            Assert-Throws { Save-MachineState @{ Key = 'key'; LastChecked = 'now'; Status = 'Verified' } $null }
            $script:BatchResponse = "HTTP/1.1 100 Continue`r`nHTTP/1.1 201 Created`r`n"
            Assert-Throws { Save-MachineState @{ Key = 'key'; LastChecked = 'now'; Status = 'Verified' } $null }
        }
        Test-Case 'Re-addition outcomes are recorded even when final membership is unchanged' {
            $script:Committed = $false
            function script:Get-TableBase { 'https://example.table.core.windows.net' }
            function script:Invoke-Table { throw 'Must commit an outcome snapshot, not just update current state.' }
            function script:Invoke-CloudRequest { $script:Committed = $true; @{ Content = "HTTP/1.1 204 No Content`r`nHTTP/1.1 201 Created`r`n" } }
            $state = @{ Key = 'key'; LastChecked = 'now'; Status = 'Verified'; Membership = 'Present'; Action = 'AddedAndVerified' }
            Save-MachineState $state @{ ETag = 'etag'; Data = @{ Status = 'Verified'; Membership = 'Present' } }
            Assert-True $script:Committed
        }
        Test-Case 'Tag, MDE group and Entra group name changes create historical snapshots' {
            function script:Get-TableBase { 'https://example.table.core.windows.net' }
            function script:Invoke-Table { throw 'Metadata changes must create a historical snapshot.' }
            function script:Invoke-CloudRequest {
                param($Body)
                Assert-True ($Body.Contains('StateChanged'))
                @{ Content = "HTTP/1.1 204 No Content`r`nHTTP/1.1 201 Created`r`n" }
            }
            foreach ($field in @('MdeDeviceTags', 'MdeManualTags', 'MdeDynamicTags', 'MdeRegistryTags', 'MdeDeviceGroup', 'AzureTags', 'GroupName', 'ArcLastReportedAt', 'ArcAddedAt', 'DefenderExtensionStatus')) {
                $state = @{ Key = 'key'; LastChecked = 'now'; Status = 'Verified' }
                $state[$field] = if ($field -eq 'AzureTags') { @{ Environment = 'Production' } }
                    elseif ($field -in @('GroupName', 'ArcLastReportedAt', 'ArcAddedAt', 'DefenderExtensionStatus')) { '2026-10-19T12:00:00Z' }
                    else { @('new') }
                $previous = @{ Status = 'Verified' }
                if ($field -in @('GroupName', 'ArcLastReportedAt', 'ArcAddedAt', 'DefenderExtensionStatus')) { $previous[$field] = 'previous-value' }
                Save-MachineState $state @{ ETag = 'etag'; Data = $previous }
            }
        }
        Test-Case 'Graph calls and token inspection use the same canonical resource URI' {
            function script:Invoke-CloudRequest {
                param($Uri, $Resource)
                Assert-Equal $Resource 'https://graph.microsoft.com'
                Assert-Equal $Uri 'https://graph.microsoft.com/v1.0/devices'
                @{ Status = 200 }
            }
            Assert-Equal (Invoke-Graph -Path '/devices').Status 200
            Assert-Equal (Invoke-Graph -Path 'https://graph.microsoft.com/v1.0/devices').Status 200
            $script:TokenResource = ''
            function script:Get-AccessToken {
                param($Resource)
                $script:TokenResource = $Resource
                $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"roles":["AdministrativeUnit.Read.All"]}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                "header.$payload.signature"
            }
            Assert-Equal ((Get-TokenClaims).roles[0]) 'AdministrativeUnit.Read.All'
            Assert-Equal $script:TokenResource 'https://graph.microsoft.com'
        }
        Test-Case 'Cloud request respects Retry-After before retrying a 429' {
            $script:HttpCalls = 0; $script:Slept = 0
            function script:Get-AccessToken { 'synthetic-token' }
            function script:Invoke-WebRequest {
                $script:HttpCalls++
                if ($script:HttpCalls -eq 1) { return @{ StatusCode = 429; Headers = @{ 'Retry-After' = @('7') }; Content = '' } }
                @{ StatusCode = 200; Headers = @{}; Content = '{}' }
            }
            function script:Start-Sleep { param($Seconds) $script:Slept = $Seconds }
            $response = Invoke-CloudRequest -Uri 'https://graph.microsoft.com/v1.0/devices' -Resource 'https://graph.microsoft.com/'
            Assert-Equal $response.Status 200
            Assert-Equal $script:HttpCalls 2
            Assert-Equal $script:Slept 7
        }
        Test-Case 'Non-idempotent Graph creates are never automatically retried' {
            function script:Get-AccessToken { 'synthetic-token' }
            function script:Start-Sleep { throw 'Non-idempotent creates must not sleep and retry.' }
            function script:Invoke-WebRequest {
                $script:HttpCalls++
                @{ StatusCode = $script:HttpStatus; Headers = @{}; Content = '{"error":{"code":"Transient","message":"Unknown create outcome"}}' }
            }
            foreach ($status in @(408, 429, 500, 502, 503, 504)) {
                $script:HttpCalls = 0
                $script:HttpStatus = $status
                Assert-Throws { Invoke-Graph -Path '/directory/administrativeUnits/au/members' -Method POST -Body @{} -DisableRetry }
                Assert-Equal $script:HttpCalls 1
            }
        }
        Test-Case 'Table pagination preserves continuation keys' {
            function script:Invoke-Table {
                param($Path)
                $script:TablePath = $Path
                @{ Content = '{"value":[]}'; Headers = @{ 'x-ms-continuation-NextPartitionKey' = @('next partition'); 'x-ms-continuation-NextRowKey' = @('next row') } }
            }
            $page = Get-TablePage -Filter "RowKey eq 'state'"
            $null = Get-TablePage -Filter "RowKey eq 'state'" -Cursor $page.Cursor
            Assert-True ($script:TablePath.Contains('NextPartitionKey=next%20partition'))
            Assert-True ($script:TablePath.Contains('NextRowKey=next%20row'))
        }
        Test-Case 'Malformed and unexpected continuation fields are rejected' {
            Assert-Throws { Get-TableContinuation 'not-base64' }
            Assert-Throws { Get-TableContinuation 'a' }
            Assert-Throws { Get-TableContinuation ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"unexpected":"key"}'))) }
            Assert-Throws { Get-TableContinuation ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('[]'))) }
        }
        Test-Case 'Report reader requires tenant and app role' {
            Assert-Equal (Test-ReportReader @{ Headers = @{} }) $false
            $claims = @(
                @{ typ = 'roles'; val = 'Report.Reader' }
                @{ typ = 'tid'; val = $env:SYNC_TENANT_ID }
            )
            $principal = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 10 -Compress
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($principal))
            Assert-Equal (Test-ReportReader @{ Headers = @{ 'X-MS-CLIENT-PRINCIPAL' = $encoded } }) $true
            $claims[1].val = 'wrong-tenant'
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 10 -Compress)))
            Assert-Equal (Test-ReportReader @{ Headers = @{ 'X-MS-CLIENT-PRINCIPAL' = $encoded } }) $false
        }
        Test-Case 'Sync uses the existing reader role, configured tenant, and same-origin action header' {
            $env:WEBSITE_HOSTNAME = 'report.example.test'
            $claims = @(@{ typ = 'roles'; val = 'Report.Reader' }, @{ typ = 'tid'; val = $env:SYNC_TENANT_ID })
            function New-TestRequest {
                @{ Method = 'POST'; Headers = @{
                    'X-MS-CLIENT-PRINCIPAL' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 10 -Compress)))
                    'X-Sync-Action' = 'start'; Origin = 'https://report.example.test'
                } }
            }
            Assert-True (Test-ReportReader (New-TestRequest))
            Assert-True (Test-ReportSyncRequest (New-TestRequest))
            $claims[1].val = 'wrong-tenant'
            Assert-Equal (Test-ReportReader (New-TestRequest)) $false
            $claims[1].val = $env:SYNC_TENANT_ID
            $claims[0].val = 'Unrelated.Role'
            Assert-Equal (Test-ReportReader (New-TestRequest)) $false
            foreach ($origin in @('', 'http://report.example.test', 'https://report.example.test.evil', 'https://evil.example.test')) {
                $request = New-TestRequest
                $request.Headers.Origin = $origin
                Assert-Equal (Test-ReportSyncRequest $request) $false
            }
            $request = New-TestRequest
            $request.Headers.Remove('X-Sync-Action')
            Assert-Equal (Test-ReportSyncRequest $request) $false
            $request = New-TestRequest
            $request.Method = 'GET'
            Assert-Equal (Test-ReportSyncRequest $request) $false
        }
        Test-Case 'Atomic inventory claims serialize runs, persist completion, and coalesce queued requests' {
            $env:AzureFunctionsJobHost__functionTimeout = '00:10:00'
            $script:JobRow = $null
            $script:JobVersion = 0
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Body, $Headers, $AllowStatus)
                if ($Method -eq 'GET') {
                    if (-not $script:JobRow) { return @{ Status = 404 } }
                    return @{ Status = 200; Headers = @{ ETag = "v$script:JobVersion" }; Content = (ConvertTo-Json -InputObject $script:JobRow -Compress) }
                }
                if ($Method -eq 'POST' -and $script:JobRow) { return @{ Status = 409 } }
                if ($Method -eq 'PUT') { Assert-Equal $Headers['If-Match'] "v$script:JobVersion" }
                $script:JobRow = $Body.Clone()
                $script:JobVersion++
                return @{ Status = 204 }
            }
            Assert-Equal (Get-InventoryJobStatus).Status 'Unknown'
            $job = & $originals['Start-InventoryJob'] -TriggerReason 'Scheduled timer'
            Assert-True $job.RunId
            Assert-True (Get-InventoryJobStatus).IsRunning
            Assert-Equal (& $originals['Start-InventoryJob'] -TriggerReason 'Manual') $null
            Assert-Throws { & $originals['Complete-InventoryJob'] -RunId 'not-owner' -Status Succeeded -Message 'Must not overwrite.' }
            & $originals['Complete-InventoryJob'] -RunId $job.RunId -Status Succeeded -Message 'Completed.'
            Assert-Equal (Get-InventoryJobStatus).Status 'Succeeded'
            Assert-Equal (Get-InventoryJobStatus).IsRunning $false
            Assert-Equal (& $originals['Start-InventoryJob'] -TriggerReason 'Manual' -RequestedAt ([datetimeoffset]$job.StartedAt).AddSeconds(-1).ToString('o')) $null
            $job = & $originals['Start-InventoryJob'] -TriggerReason 'Manual'
            & $originals['Complete-InventoryJob'] -RunId $job.RunId -Status Failed -Message 'Inventory failure.'
            Assert-Equal (Get-InventoryJobStatus).Status 'Failed'
            Assert-Equal (Get-InventoryJobStatus).Message 'Inventory failure.'
        }
        Test-Case 'Competing insert and ETag claims do not execute another inventory' {
            $env:AzureFunctionsJobHost__functionTimeout = '00:10:00'
            $script:ClaimExists = $false
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Headers)
                if ($Method -eq 'POST') { return @{ Status = 409 } }
                if ($Method -eq 'PUT') {
                    Assert-Equal $Headers['If-Match'] 'old-etag'
                    return @{ Status = 412 }
                }
                if (-not $script:ClaimExists) { return @{ Status = 404 } }
                return @{ Status = 200; Headers = @{ ETag = 'old-etag' }; Content = '{"Status":"Succeeded","StartedAt":"2020-01-01T00:00:00Z"}' }
            }
            Assert-Equal (& $originals['Start-InventoryJob'] -TriggerReason 'Timer') $null
            $script:ClaimExists = $true
            Assert-Equal (& $originals['Start-InventoryJob'] -TriggerReason 'Manual') $null
        }
        Test-Case 'Interrupted jobs recover only with an enforced bounded function timeout' {
            $env:AzureFunctionsJobHost__functionTimeout = '00:10:00'
            $script:Recovered = $false
            function script:Invoke-Table {
                param($Path, $Method = 'GET', $Headers, $Body)
                if ($Method -eq 'PUT') {
                    Assert-Equal $Headers['If-Match'] 'stale-etag'
                    Assert-Equal $Body.Status 'Running'
                    $script:Recovered = $true
                    return @{ Status = 204 }
                }
                return @{ Status = 200; Headers = @{ ETag = 'stale-etag' }; Content = '{"RunId":"old","Status":"Running","StartedAt":"2020-01-01T00:00:00Z","ExpiresAt":"2020-01-01T00:15:00Z"}' }
            }
            Assert-Equal (Get-InventoryJobStatus).Status 'Interrupted'
            Assert-Equal (Get-InventoryJobStatus).IsRunning $false
            Assert-True (& $originals['Start-InventoryJob'] -TriggerReason 'Recovery').RunId
            Assert-True $script:Recovered
            foreach ($timeout in @('-00:00:01', '00:00:00', '00:10:01')) {
                $env:AzureFunctionsJobHost__functionTimeout = $timeout
                Assert-Throws { & $originals['Start-InventoryJob'] -TriggerReason 'Unsafe timeout' }
            }
        }
        Test-Case 'Inventory wrapper records success and failure and skips an occupied job' {
            function script:Invoke-InventoryRun { param($RunId); $script:CoreRunId = $RunId }
            Invoke-InventorySync -TriggerReason 'Manual'
            Assert-Equal $script:LastJobCompletion.Status 'Succeeded'
            Assert-Equal $script:LastJobCompletion.RunId $script:CoreRunId
            function script:Invoke-InventoryRun { throw 'Deliberate inventory failure' }
            Assert-Throws { Invoke-InventorySync }
            Assert-Equal $script:LastJobCompletion.Status 'Failed'
            Assert-Equal $script:LastJobCompletion.Message 'Deliberate inventory failure'
            function script:Start-InventoryJob { return $null }
            Invoke-InventorySync
        }
        Test-Case 'Manual requests send only to the dedicated queue with no automatic POST retries' {
            $env:ServiceBusConnection__fullyQualifiedNamespace = 'sync-test.servicebus.windows.net'
            function script:Invoke-CloudRequest {
                param($Uri, $Resource, $Method, $Body, [switch]$DisableRetry)
                Assert-Equal $Uri 'https://sync-test.servicebus.windows.net/inventory-sync/messages'
                Assert-Equal $Resource 'https://servicebus.azure.net'
                Assert-Equal $Method 'POST'
                Assert-True $DisableRetry
                Assert-True ([guid]::Parse($Body.RequestId))
                Assert-True ([datetimeoffset]::Parse($Body.RequestedAt))
                @{ Status = 201 }
            }
            Assert-True (New-ReportSyncRequest).RequestId
            function script:Invoke-CloudRequest { throw 'Queue unavailable' }
            Assert-Throws { New-ReportSyncRequest }
        }
        Test-Case 'Live routes bypass caches and restrict manual sync by role, origin, method, and running state' {
            $env:WEBSITE_HOSTNAME = 'report.example.test'
            $global:TestInventoryJob = @{ Status = 'Unknown'; IsRunning = $false }
            $global:TestQueuedRequests = 0
            function script:Get-InventoryJobStatus { return $global:TestInventoryJob.Clone() }
            function script:New-ReportSyncRequest {
                $global:TestQueuedRequests++
                @{ RequestId = 'test-request'; RequestedAt = [datetimeoffset]::UtcNow.ToString('o') }
            }
            $global:ReportStaticCache = @{}
            $global:ReportApiCache = @{ 'sync-status' = @{ Expires = [datetimeoffset]::UtcNow.AddHours(1); Body = '{"Status":"cached"}' } }
            $global:OutResponses = @()
            function global:Push-OutputBinding { param($Name, $Value); $global:OutResponses += $Value }
            function Invoke-TestDashboard([string]$Path, [string]$Method = 'GET', [string]$Origin = 'https://report.example.test', [string]$Action = 'start', [string]$Role = 'Report.Reader', [string]$Tenant = $env:SYNC_TENANT_ID, [switch]$Anonymous) {
                $claims = @(@{ typ = 'roles'; val = $Role }, @{ typ = 'tid'; val = $Tenant })
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 10 -Compress)))
                $requestHeaders = @{ 'X-Sync-Action' = $Action; Origin = $Origin }
                if (-not $Anonymous) { $requestHeaders['X-MS-CLIENT-PRINCIPAL'] = $encoded }
                & "$PSScriptRoot\..\report\Dashboard\run.ps1" -Request @{
                    Method = $Method
                    Headers = $requestHeaders
                    Params = @{ path = $Path }; Query = @{}
                } -TriggerMetadata @{}
                return $global:OutResponses[-1]
            }
            try {
                $response = Invoke-TestDashboard 'sync-status'
                Assert-Equal $response.StatusCode 200
                Assert-Equal $response.Headers['Cache-Control'] 'no-store'
                Assert-Equal $response.Headers['Referrer-Policy'] 'same-origin'
                Assert-Equal (ConvertFrom-Json $response.Body).Status 'Unknown'
                Assert-Equal (ConvertFrom-Json $response.Body).CanStartSync $false
                Assert-True ((ConvertFrom-Json $response.Body).StartSyncUnavailableReason.Contains('updated infrastructure'))
                Assert-Equal (Invoke-TestDashboard 'sync' 'POST').StatusCode 503
                Assert-Equal $global:TestQueuedRequests 0
                $env:ServiceBusConnection__fullyQualifiedNamespace = 'sync-test.servicebus.windows.net'
                $response = Invoke-TestDashboard 'sync-status'
                Assert-Equal (ConvertFrom-Json $response.Body).CanStartSync $true
                Assert-Equal (Invoke-TestDashboard 'sync' 'POST' -Role '').StatusCode 403
                Assert-Equal (Invoke-TestDashboard 'sync' 'POST' -Tenant 'wrong-tenant').StatusCode 403
                Assert-Equal (Invoke-TestDashboard 'sync' 'POST' -Anonymous).StatusCode 403
                Assert-Equal (Invoke-TestDashboard 'sync-status' -Anonymous).StatusCode 403
                Assert-Equal (Invoke-TestDashboard 'sync' 'POST' -Origin 'https://evil.example.test').StatusCode 403
                Assert-Equal (Invoke-TestDashboard 'sync' 'POST' -Action '').StatusCode 403
                Assert-Equal $global:TestQueuedRequests 0
                $response = Invoke-TestDashboard 'sync' 'POST'
                Assert-Equal $response.StatusCode 202
                Assert-Equal $response.Headers['Cache-Control'] 'no-store'
                Assert-Equal $global:TestQueuedRequests 1
                $global:TestInventoryJob = @{ Status = 'Running'; IsRunning = $true }
                Assert-Equal (Invoke-TestDashboard 'sync' 'POST').StatusCode 409
                Assert-Equal (Invoke-TestDashboard 'data' 'POST').StatusCode 405
                Assert-Equal (Invoke-TestDashboard 'sync' 'GET').StatusCode 405
                Assert-Equal $global:TestQueuedRequests 1
                $response = Invoke-TestDashboard 'sync-status'
                Assert-True (ConvertFrom-Json $response.Body).IsRunning
                Assert-True (ConvertFrom-Json $response.Body).CanStartSync
            } finally {
                Remove-Item Function:\global:Push-OutputBinding -ErrorAction SilentlyContinue
                Remove-Variable -Name OutResponses -Scope Global -ErrorAction SilentlyContinue
                Remove-Variable -Name TestInventoryJob, TestQueuedRequests -Scope Global -ErrorAction SilentlyContinue
                $global:ReportApiCache = @{}
            }
        }
        Test-Case 'Manual trigger validates messages and invokes the common inventory workflow' {
            $global:TestManualCalls = @()
            function Invoke-InventorySync {
                param($TriggerReason, $RequestedAt)
                $global:TestManualCalls += @{ TriggerReason = $TriggerReason; RequestedAt = $RequestedAt }
            }
            $trigger = "$PSScriptRoot\..\worker\ManualInventory\run.ps1"
            try {
                $request = @{ RequestId = [guid]::NewGuid().ToString(); RequestedAt = [datetimeoffset]::UtcNow.ToString('o') }
                & $trigger -SyncRequest (ConvertTo-Json -InputObject $request -Compress)
                Assert-Equal $global:TestManualCalls.Count 1
                Assert-Equal $global:TestManualCalls[0].TriggerReason 'Manual sync (Device inventory)'
                $request.RequestedAt = [datetimeoffset]::UtcNow.AddMinutes(-16).ToString('o')
                & $trigger -SyncRequest $request
                Assert-Equal $global:TestManualCalls.Count 1
                $request.RequestedAt = [datetimeoffset]::UtcNow.AddMinutes(2).ToString('o')
                Assert-Throws { & $trigger -SyncRequest $request }
                $request.RequestId = 'invalid'
                Assert-Throws { & $trigger -SyncRequest $request }
            } finally {
                Remove-Variable -Name TestManualCalls -Scope Global -ErrorAction SilentlyContinue
            }
        }
        Test-Case 'Permissions validation report evaluates Azure RBAC, Graph, and Entra readiness' {
            function script:Get-TokenClaims {
                param($Resource)
                Assert-True ($Resource -in @('https://graph.microsoft.com', 'https://management.azure.com/'))
                @{
                    oid = '77777777-8888-9999-aaaa-bbbbbbbbbbbb'
                    roles = @('ThreatHunting.Read.All', 'Device.Read.All')
                }
            }
            function script:Invoke-CloudRequest {
                param($Uri)
                @{ Status = 200; Content = '{"displayName":"Demo production"}' }
            }
            function script:Invoke-Graph {
                param($Path)
                if ($Path -like '/directory/administrativeUnits/*/scopedRoleMembers') {
                    return @{ Status = 200; Content = '{"value":[{"roleMemberInfo":{"id":"77777777-8888-9999-aaaa-bbbbbbbbbbbb"}}]}' }
                }
                if ($Path -like '/directory/administrativeUnits/*') {
                    return @{ Status = 200; Content = '{"id":"44444444-aaaa-bbbb-cccc-555555555555","displayName":"Defender AU","value":[]}' }
                }
                if ($Path -like '/servicePrincipals/*/ownedObjects*') {
                    return @{ Status = 200; Content = '{"value":[{"id":"g1","displayName":"MDfS-AWS-Windows-Passive-123456789012"}]}' }
                }
                @{ Status = 200; Content = '{"results":[],"value":[]}' }
            }
            $env:SYNC_ADMIN_UNIT_ID = '44444444-aaaa-bbbb-cccc-555555555555'
            $cfg = Get-SyncConfig
            $report = Get-PermissionsValidationReport -Config $cfg -DiscoveredMachinesCount 5 -ArgMachineRows 4 -ArgVmssRows 1
            Assert-Equal $report.WorkerPrincipalId '77777777-8888-9999-aaaa-bbbbbbbbbbbb'
            Assert-Equal $report.Checks.Count 6
            Assert-Equal (@($report.Checks | Where-Object { $_.Id -eq 'graph-group-read' }).Count) 0
            Assert-Equal (@($report.Checks | Where-Object { $_.Status -eq 'Granted' }).Count) 6
            $env:SYNC_ADMIN_UNIT_ID = ''
        }
        Test-Case 'Dashboard run.ps1 serves health and permissions without strict-mode variable errors' {
            $claims = @(
                @{ typ = 'roles'; val = 'Report.Reader' }
                @{ typ = 'tid'; val = $env:SYNC_TENANT_ID }
                @{ typ = 'upn'; val = 'admin@trydex.cloud' }
            )
            $principal = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 10 -Compress
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($principal))
            function script:Get-TokenClaims { @{ oid = 'cccccccc-dddd-eeee-ffff-000000000000' } }
            function script:Invoke-Table {
                param($Path)
                if ($Path -like "*RowKey='permissions'*" -or $Path -like "*RowKey='worker-configuration'*") { return @{ Status = 404 } }
                if ($Path -like "*RowKey='inventory'*") {
                    return @{
                        Status = 200
                        Content = (@{
                            Data = (@{
                                FunctionAppName = 'mdemdcsync-worker-l25i6m'
                                FunctionAppResourceId = '/subscriptions/9ebcb583-7adb-44ea-b688-06f1de624cc1/resourceGroups/aws-lab/providers/Microsoft.Web/sites/mdemdcsync-worker-l25i6m'
                                MachinesQueued = 2
                                LastRunStatus = 'Succeeded'
                                LastRunTime = '2026-10-29T16:00:00Z'
                            } | ConvertTo-Json -Compress)
                        } | ConvertTo-Json -Compress)
                    }
                }
                @{ Status = 200; Content = '{"value":[]}' }
            }
            $global:OutResponses = @()
            function global:Push-OutputBinding {
                param($Name, $Value)
                $global:OutResponses += $Value
            }
            $global:ReportStaticCache = @{}
            $global:ReportApiCache = @{}
            & "$PSScriptRoot\..\report\Dashboard\run.ps1" -Request @{
                Method = 'GET'
                Headers = @{ 'X-MS-CLIENT-PRINCIPAL' = $encoded }
                Params = @{ path = 'health' }
                Query = @{ cursor = ''; refresh = '1'; key = '' }
            } -TriggerMetadata @{}
            & "$PSScriptRoot\..\report\Dashboard\run.ps1" -Request @{
                Method = 'GET'
                Headers = @{ 'X-MS-CLIENT-PRINCIPAL' = $encoded }
                Params = @{ path = 'permissions' }
                Query = @{ cursor = ''; refresh = '1'; key = '' }
            } -TriggerMetadata @{}
            Remove-Item Function:\global:Push-OutputBinding -ErrorAction SilentlyContinue
            Assert-Equal $global:OutResponses.Count 2
            Assert-Equal $global:OutResponses[0].StatusCode 200
            Assert-Equal $global:OutResponses[1].StatusCode 200
            $healthBody = ConvertFrom-Json -InputObject $global:OutResponses[0].Body -AsHashtable
            $permBody = ConvertFrom-Json -InputObject $global:OutResponses[1].Body -AsHashtable
            Remove-Variable -Name OutResponses -Scope Global -ErrorAction SilentlyContinue
            Assert-Equal $healthBody.PortalTenant $env:SYNC_TENANT_ID
            Assert-Equal $permBody.PortalTenant $env:SYNC_TENANT_ID
            Assert-Equal $permBody.Checks.Count 9
        }
        Test-Case 'Bulk MDE hunting telemetry preloads DeviceInfo, NetworkInfo, and Antivirus without per-machine hunting calls' {
            function script:Invoke-Graph {
                param($Path, $Method, $Body)
                if ($Path -eq '/security/runHuntingQuery') {
                    Assert-True ($Body.Query.Contains('let MatchedDevices = DeviceInfo'))
                    Assert-True ($Body.Query.Contains('let NetInfo = DeviceNetworkInfo'))
                    Assert-True ($Body.Query.Contains('let AvInfo = DeviceTvmSecureConfigurationAssessment'))
                    return @{
                        Content = (@{
                            results = @(
                                @{
                                    Timestamp = $now.ToString('o')
                                    DeviceId = 'mde-bulk-1'
                                    DeviceName = 'server01.example.com'
                                    AadDeviceId = '44444444-4444-4444-4444-444444444444'
                                    OnboardingStatus = 'Onboarded'
                                    MergedToDeviceId = ''
                                    SensorHealthState = 'Active'
                                    CloudPlatforms = 'AWS'
                                    AzureVmId = 'arc-vm-id'
                                    AzureResourceId = $id
                                    PublicIP = '203.0.113.10'
                                    DeviceManualTags = '["BulkTag"]'
                                    DeviceDynamicTags = '[]'
                                    RegistryDeviceTag = ''
                                    MachineGroup = 'BulkGroup'
                                    NetIPs = @('[{"IPAddress":"10.20.30.40"}]')
                                    AvMode = '1'
                                    AvTimestamp = '2026-10-19T12:00:00Z'
                                }
                            )
                        } | ConvertTo-Json -Depth 10 -Compress)
                    }
                }
                if ($Path.StartsWith('/devices?')) {
                    return @{ Content = '{"value":[{"id":"55555555-5555-5555-5555-555555555555","deviceId":"44444444-4444-4444-4444-444444444444","accountEnabled":true}]}' }
                }
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[]}' }
                }
                throw "Unexpected Graph call: $Path"
            }
            $bulkMap = Get-BulkMdeTelemetry -DiscoveredMachines @(
                @{
                    ResourceId = $id
                    Row = @{ properties = @{ vmId = 'arc-vm-id'; status = 'Connected'; osType = 'Windows' } }
                }
            )
            Assert-True ($bulkMap.ContainsKey($id.ToLowerInvariant()))
            $entry = $bulkMap[$id.ToLowerInvariant()]
            Assert-Equal $entry.Candidates.Count 1
            Assert-Equal $entry.NetworkAddresses[0] '10.20.30.40'
            Assert-Equal $entry.Antivirus.Mode 'Passive'

            # Verify Invoke-MachineSync consumes MdeData without calling /security/runHuntingQuery
            function script:Invoke-Graph {
                param($Path)
                if ($Path -eq '/security/runHuntingQuery') {
                    throw 'Invoke-MachineSync must use preloaded MdeData without calling /security/runHuntingQuery'
                }
                if ($Path.StartsWith('/devices?')) {
                    return @{ Content = '{"value":[{"id":"55555555-5555-5555-5555-555555555555","deviceId":"44444444-4444-4444-4444-444444444444","accountEnabled":true}]}' }
                }
                if ($Path.Contains('/memberOf')) {
                    return @{ Content = '{"value":[]}' }
                }
                throw "Unexpected Graph call: $Path"
            }
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest { @{ Status = 200; Content = '{"properties":{"status":"Connected","osType":"Windows"}}' } }
            function script:Resolve-GroupByDisplayName { @{ Id = '22222222-2222-2222-2222-222222222222'; DisplayName = 'MDfS-AWS-Windows-Passive-123456789012' } }
            function script:Test-DirectMembership { $false }
            function script:Save-MachineState { param($State) $script:SavedBulkState = $State }
            function script:Write-FunctionLog {}
            Invoke-MachineSync @{
                ResourceId = $id
                RunId = [guid]::NewGuid().ToString()
                Source = 'Schedule'
                ResourceData = @{
                    name = 'server01'
                    subscriptionName = 'Production subscription'
                    tags = @{ AccountId = '123456789012' }
                    argExtensions = @('MDE.Windows (version: 2.0; state: Succeeded)')
                    gcEntraDeviceId = ''
                    properties = @{ status = 'Connected'; osType = 'Windows'; vmId = 'arc-vm-id'; osProfile = @{ computerName = 'SERVER01' } }
                }
                MdeData = $entry
            }
            Assert-Equal $script:SavedBulkState.Status 'WouldAdd'
            Assert-Equal $script:SavedBulkState.MdeDeviceId 'mde-bulk-1'
            Assert-Equal $script:SavedBulkState.MdeAntivirusMode 'Passive'
            Assert-True ('10.20.30.40' -in $script:SavedBulkState.IPAddresses)
        }
        Write-Host "`n$script:Passed passed; $script:Failed failed."
        if ($script:Failed) { throw 'Solution tests failed.' }
    }
}
finally {
    Remove-Module $module.Name
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
