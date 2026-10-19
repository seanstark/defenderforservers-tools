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

$names = @('SYNC_SUBSCRIPTION_IDS', 'SYNC_MANAGEMENT_GROUP_IDS', 'SYNC_RESOURCE_GROUP_NAMES', 'SYNC_GROUP_ID', 'SYNC_WINDOWS_GROUP_ID', 'SYNC_LINUX_GROUP_ID', 'SYNC_MODE', 'SYNC_TENANT_ID', 'SYNC_FRESHNESS_HOURS')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$env:SYNC_SUBSCRIPTION_IDS = '11111111-1111-1111-1111-111111111111'
$env:SYNC_MANAGEMENT_GROUP_IDS = ''
$env:SYNC_RESOURCE_GROUP_NAMES = ''
$env:SYNC_GROUP_ID = '22222222-2222-2222-2222-222222222222'
$env:SYNC_WINDOWS_GROUP_ID = ''
$env:SYNC_LINUX_GROUP_ID = ''
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
            'Get-MdeCandidates', 'Test-Group', 'Test-DirectMembership', 'Write-MutationIntent', 'Get-TableBase', 'Get-TablePage',
            'Send-MachineWork', 'Get-AccessToken', 'Invoke-WebRequest', 'Start-Sleep',
            'Get-SubscriptionName', 'Get-ArcExtensions', 'Get-MdeNetworkAddresses', 'Get-MdeAntivirus', 'Get-ManagementGroupSubscriptions', 'Write-FunctionLog')) {
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
                $env:SYNC_GROUP_ID = '22222222-2222-2222-2222-222222222222'
                $env:SYNC_WINDOWS_GROUP_ID = ''
                $env:SYNC_LINUX_GROUP_ID = ''
                $script:ManagementGroupSubscriptions = @{}
                $script:ManagementGroupCacheExpires = [datetimeoffset]::MinValue
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
            function script:Invoke-CloudRequest {
                param($Uri, $Resource, $Method, $Body)
                $script:GraphBodies += $Body
                @{ Content = (@{ data = @(@{ id = $mgId }); resultTruncated = 'false' } | ConvertTo-Json -Compress) }
            }
            function script:Get-TablePage { @{ Items = @(); Cursor = '' } }
            function script:Write-FunctionLog {
                param($Entry)
                $script:LastFunctionLog = $Entry
            }
            function script:Send-MachineWork { param($ResourceId) $script:Queued += $ResourceId }
            Invoke-InventorySync -TriggerReason 'Scheduled timer (NCRONTAB schedule)'
            Assert-Equal $script:GraphBodies.Count 1
            Assert-Equal ($script:GraphBodies[0].managementGroups -join ',') 'mg-servers'
            Assert-True ($script:GraphBodies[0].query.Contains('tolower(resourceGroup) in ("rg-prod", "servers")'))
            Assert-Equal $script:Queued.Count 1
            Assert-Equal $script:LastFunctionLog.FunctionName 'Inventory'
            Assert-Equal $script:LastFunctionLog.TriggerReason 'Scheduled timer (NCRONTAB schedule)'
            Assert-Equal $script:LastFunctionLog.Status 'Succeeded'
            Assert-Equal $script:LastFunctionLog.Health 'Healthy'
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
            Assert-Equal $script:LoggedRun.TriggerReason 'Event Grid (Arc machine connected/updated)'
            Assert-Equal $script:LoggedRun.Status 'ArcMissing'
        }
        Test-Case 'Full machine workflow resolves deviceId to object ID in Audit' {
            $script:Candidates = @($candidate)
            $script:ResolvedObject = ''
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest {
                @{ Status = 200; Content = '{"tags":{"Environment":"Production","Cost center":"123"},"systemData":{"createdAt":"2026-10-01T08:00:00Z","lastModifiedAt":"2026-10-19T11:30:00Z"},"properties":{"status":"Connected","lastStatusChange":"2026-10-19T11:55:00Z","osType":"Windows","dnsFqdn":"server01.example.com","osProfile":{"computerName":"SERVER01"},"cloudMetadata":{"provider":"AWS"},"vmId":"arc-vm-id","networkProfile":{"networkInterfaces":[{"ipAddresses":[{"address":"10.0.0.4"}]}]}}}' }
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
                throw "Unexpected Graph request $Path"
            }
            function script:Test-Group { @{ displayName = 'Arc servers' } }
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
            Assert-Equal $script:Saved.GroupName 'Arc servers'
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
        Test-Case 'Full MDE-only workflow makes no directory lookup or membership write' {
            $script:Linux = $candidate.Clone(); $script:Linux.AadDeviceId = ''
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest { @{ Status = 200; Content = '{"properties":{"status":"Connected","osType":"Linux"}}' } }
            function script:Get-MdeCandidates { @($script:Linux) }
            function script:Get-SubscriptionName { 'Production subscription' }
            function script:Get-ArcExtensions { @() }
            function script:Get-MdeNetworkAddresses { @() }
            function script:Get-MdeAntivirus { @{ Mode = ''; Timestamp = ''; Status = 'NoData' } }
            function script:Invoke-Graph { throw 'No directory call is allowed without an Entra identifier.' }
            function script:Save-MachineState { param($State) $script:Saved = $State }
            function script:Write-FunctionLog {}
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.Status 'NoEntraDevice'
            Assert-Equal $script:Saved.Membership 'Unknown'
        }
        Test-Case 'OS-specific Entra groups route Windows and Linux servers to separate groups' {
            $env:SYNC_GROUP_ID = ''
            $env:SYNC_WINDOWS_GROUP_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $env:SYNC_LINUX_GROUP_ID = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            $cfg = Get-SyncConfig
            Assert-Equal (Resolve-TargetGroupId -Config $cfg -OSType 'Windows') 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            Assert-Equal (Resolve-TargetGroupId -Config $cfg -OSType 'Linux') 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            $params = Get-FunctionParametersSummary
            Assert-Equal $params.SYNC_WINDOWS_GROUP_ID 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            Assert-Equal $params.SYNC_LINUX_GROUP_ID 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            function script:Get-MachineState { $null }
            function script:Invoke-CloudRequest { @{ Status = 200; Content = '{"properties":{"status":"Connected","osType":"Linux"}}' } }
            function script:Get-MdeCandidates { @() }
            function script:Get-SubscriptionName { 'Production subscription' }
            function script:Get-ArcExtensions { @() }
            function script:Save-MachineState { param($State) $script:Saved = $State }
            function script:Write-FunctionLog {}
            Invoke-MachineSync @{ ResourceId = $id; RunId = [guid]::NewGuid().ToString(); Source = 'Test' }
            Assert-Equal $script:Saved.GroupId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
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
        Write-Host "`n$script:Passed passed; $script:Failed failed."
        if ($script:Failed) { throw 'Solution tests failed.' }
    }
}
finally {
    Remove-Module $module.Name
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
