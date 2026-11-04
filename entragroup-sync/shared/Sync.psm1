Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Tokens = @{}
$script:SubscriptionNames = @{}
$script:ManagementGroupSubscriptions = @{}
$script:ManagementGroupCacheExpires = [datetimeoffset]::MinValue
$script:GroupByNameCache = @{}
$script:AdminUnitGroupsCache = @{}
$script:AdminUnitGroupsExpires = @{}
$script:SharedAdminUnitGroups = @{}
$script:CurrentRunTranscript = [Collections.Generic.List[string]]::new()

function Start-SyncTranscript {
    param([string]$Context)
    $script:CurrentRunTranscript = [Collections.Generic.List[string]]::new()
    Write-SyncTrace $Context "=== PowerShell execution started at $([datetimeoffset]::UtcNow.ToString('o')) ==="
}

function Write-SyncTrace {
    param([string]$Component, [string]$Message, $Data = $null)
    $ts = [datetimeoffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $suffix = ''
    if ($null -ne $Data) {
        try {
            $json = if ($Data -is [string]) { $Data } else { ConvertTo-Json -InputObject $Data -Depth 15 -Compress }
            if ($json.Length -gt 24000) { $json = $json.Substring(0, 24000) + '...(truncated)' }
            $suffix = "`n$json"
        }
        catch {}
    }
    $line = "[$ts][$Component] ${Message}${suffix}"
    if ($null -ne $script:CurrentRunTranscript) {
        $script:CurrentRunTranscript.Add($line)
    }
    Write-Information "[SyncTrace] $line" -InformationAction Continue
}

function Get-OptionalSetting {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    return $value.Trim()
}

function Get-Setting {
    param([string]$Name, [string]$Default = '')
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Default -ne '') { return $Default }
        throw "Required setting '$Name' is missing."
    }
    return $value
}

function ConvertTo-CleanList {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $trimmed = $Raw.Trim().Trim('[', ']')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return @() }
    return @($trimmed.Split(',', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
        $item = $_.Trim().Trim('"', "'")
        if ($item -and $item.ToLowerInvariant() -notin @('none', 'null', 'all', '*', '[]', '<optional-rg-filter>')) {
            $item
        }
    })
}

function Get-SyncConfig {
    $rawSubscriptions = Get-OptionalSetting 'SYNC_SUBSCRIPTION_IDS'
    $subscriptions = @()
    if ($rawSubscriptions) {
        $subscriptions = @(ConvertTo-CleanList $rawSubscriptions | ForEach-Object {
            ([guid]$_).ToString().ToLowerInvariant()
        } | Sort-Object -Unique)
    }
    $rawManagementGroups = Get-OptionalSetting 'SYNC_MANAGEMENT_GROUP_IDS'
    $managementGroups = @()
    if ($rawManagementGroups) {
        $managementGroups = @(ConvertTo-CleanList $rawManagementGroups | ForEach-Object {
            if ($_ -notmatch '^[A-Za-z0-9._()-]{1,90}$') { throw "Invalid management group ID '$_'." }
            $_
        } | Sort-Object -Unique)
    }
    if (-not $subscriptions.Count -and -not $managementGroups.Count) {
        throw "At least one of 'SYNC_SUBSCRIPTION_IDS' or 'SYNC_MANAGEMENT_GROUP_IDS' must be configured."
    }
    $rawResourceGroups = Get-OptionalSetting 'SYNC_RESOURCE_GROUP_NAMES'
    $resourceGroups = @()
    if ($rawResourceGroups) {
        $resourceGroups = @(ConvertTo-CleanList $rawResourceGroups | ForEach-Object {
            $rg = $_.ToLowerInvariant()
            if ($rg -notmatch '^[a-z0-9._()-]{1,90}$') { throw "Invalid resource group name '$rg'." }
            $rg
        } | Sort-Object -Unique)
    }
    $awsWindowsPrefix = Get-OptionalSetting 'SYNC_AWS_WINDOWS_GROUP_PREFIX'
    $awsLinuxPrefix = Get-OptionalSetting 'SYNC_AWS_LINUX_GROUP_PREFIX'
    $gcpWindowsPrefix = Get-OptionalSetting 'SYNC_GCP_WINDOWS_GROUP_PREFIX'
    $gcpLinuxPrefix = Get-OptionalSetting 'SYNC_GCP_LINUX_GROUP_PREFIX'
    $azureWindowsPrefix = Get-OptionalSetting 'SYNC_AZURE_WINDOWS_GROUP_PREFIX'
    $azureLinuxPrefix = Get-OptionalSetting 'SYNC_AZURE_LINUX_GROUP_PREFIX'
    if (-not ($awsWindowsPrefix -or $awsLinuxPrefix -or $gcpWindowsPrefix -or $gcpLinuxPrefix -or $azureWindowsPrefix -or $azureLinuxPrefix)) {
        throw "At least one cloud OS group prefix ('SYNC_AWS_WINDOWS_GROUP_PREFIX', 'SYNC_AWS_LINUX_GROUP_PREFIX', 'SYNC_GCP_WINDOWS_GROUP_PREFIX', 'SYNC_GCP_LINUX_GROUP_PREFIX', 'SYNC_AZURE_WINDOWS_GROUP_PREFIX', or 'SYNC_AZURE_LINUX_GROUP_PREFIX') must be configured."
    }
    $defaultGroupMode = Get-Setting 'SYNC_DEFAULT_GROUP_MODE' 'Passive'
    if ($defaultGroupMode -notin @('Passive', 'Active')) {
        throw 'SYNC_DEFAULT_GROUP_MODE must be Passive or Active.'
    }
    $rawAdminUnitId = Get-OptionalSetting 'SYNC_ADMIN_UNIT_ID'
    $adminUnitId = if ($rawAdminUnitId) { ([guid]$rawAdminUnitId).ToString().ToLowerInvariant() } else { '' }
    $rawAutoCreate = Get-OptionalSetting 'SYNC_AUTO_CREATE_GROUPS'
    $autoCreateGroups = if ($rawAutoCreate) {
        if ($rawAutoCreate.ToLowerInvariant() -notin @('true', 'false', '1', '0')) {
            throw 'SYNC_AUTO_CREATE_GROUPS must be true or false.'
        }
        $rawAutoCreate.ToLowerInvariant() -in @('true', '1')
    }
    else {
        [bool]$adminUnitId
    }
    if ($autoCreateGroups -and -not $adminUnitId) {
        throw "SYNC_ADMIN_UNIT_ID is required when SYNC_AUTO_CREATE_GROUPS is enabled."
    }
    $mode = Get-Setting 'SYNC_MODE' 'Audit'
    if ($mode -notin @('Audit', 'Enforce')) { throw 'SYNC_MODE must be Audit or Enforce.' }
    $hours = [int](Get-Setting 'SYNC_FRESHNESS_HOURS' '24')
    if ($hours -lt 1 -or $hours -gt 168) { throw 'SYNC_FRESHNESS_HOURS must be between 1 and 168.' }
    @{
        Subscriptions = $subscriptions
        ManagementGroups = $managementGroups
        ResourceGroups = $resourceGroups
        AwsWindowsGroupPrefix = $awsWindowsPrefix
        AwsLinuxGroupPrefix = $awsLinuxPrefix
        GcpWindowsGroupPrefix = $gcpWindowsPrefix
        GcpLinuxGroupPrefix = $gcpLinuxPrefix
        AzureWindowsGroupPrefix = $azureWindowsPrefix
        AzureLinuxGroupPrefix = $azureLinuxPrefix
        DefaultGroupMode = $defaultGroupMode
        AdminUnitId = $adminUnitId
        AutoCreateGroups = $autoCreateGroups
        Mode = $mode
        FreshnessHours = $hours
    }
}

function Resolve-OSCategory {
    param([string]$OSType)
    $os = $OSType.Trim().ToLowerInvariant()
    if ($os.Contains('win')) { return 'Windows' }
    if ($os -match 'lin|ubuntu|redhat|rhel|suse|sles|debian|centos|oracle|alma|rocky|mariner|azurelinux') {
        return 'Linux'
    }
    return ''
}

function Get-TagValueCaseInsensitive {
    param($Tags, [string]$TagName)
    if ($Tags -isnot [Collections.IDictionary]) { return '' }
    foreach ($key in $Tags.Keys) {
        if ([string]::Equals([string]$key, $TagName, [StringComparison]::OrdinalIgnoreCase)) {
            return ([string]$Tags[$key]).Trim()
        }
    }
    return ''
}

function Format-CloudGroupName {
    param([string]$Prefix, [string]$GroupMode, [string]$Identifier)
    if ([string]::IsNullOrWhiteSpace($Prefix) -or [string]::IsNullOrWhiteSpace($Identifier)) { return '' }
    $mode = if ($GroupMode) { $GroupMode } else { 'Passive' }
    if ($Prefix -match '(?i)\{mode\}') {
        $withMode = [regex]::Replace($Prefix, '(?i)\{mode\}', $mode)
        if ($withMode.Contains('{id}')) { return $withMode.Replace('{id}', $Identifier).ToLowerInvariant() }
        if ($withMode.Contains('{0}')) { return $withMode.Replace('{0}', $Identifier).ToLowerInvariant() }
        return "${withMode}${Identifier}"
    }
    if ($Prefix -match '^(.*?)(?i:active|passive)([-_]?)$') {
        $sep = if ($Matches[2]) { $Matches[2] } else { '-' }
        return "$($Matches[1])${mode}${sep}${Identifier}"
    }
    if ($Prefix.Contains('{id}')) {
        return $Prefix.Replace('{id}', "${mode}-${Identifier}")
    }
    if ($Prefix.Contains('{0}')) {
        return $Prefix.Replace('{0}', "${mode}-${Identifier}")
    }
    if ($Prefix.EndsWith('-') -or $Prefix.EndsWith('_')) {
        return "${Prefix}${mode}-${Identifier}"
    }
    return "${Prefix}-${mode}-${Identifier}"
}

function Resolve-CloudGroupTarget {
    param([hashtable]$Config, [hashtable]$State)
    $osCategory = Resolve-OSCategory ([string]$State['OS'])
    $awsAccountId = Get-TagValueCaseInsensitive $State['AzureTags'] 'AccountId'
    $gcpProjectId = Get-TagValueCaseInsensitive $State['AzureTags'] 'ProjectId'
    $providerText = "$($State['CloudProvider']) $($State['MdeCloudPlatforms'])".ToLowerInvariant()
    $isAws = [bool]$awsAccountId -or $providerText -match '\b(aws|amazon)\b'
    $isGcp = (-not $isAws) -and ([bool]$gcpProjectId -or $providerText -match '\b(gcp|google)\b')
    $cloudType = ''
    $identifier = ''
    $prefix = ''
    if ($isAws) {
        $cloudType = 'AWS'
        $identifier = $awsAccountId
        $prefix = if ($osCategory -eq 'Windows') { [string]$Config.AwsWindowsGroupPrefix }
        elseif ($osCategory -eq 'Linux') { [string]$Config.AwsLinuxGroupPrefix }
        else { '' }
    }
    elseif ($isGcp) {
        $cloudType = 'GCP'
        $identifier = $gcpProjectId
        $prefix = if ($osCategory -eq 'Windows') { [string]$Config.GcpWindowsGroupPrefix }
        elseif ($osCategory -eq 'Linux') { [string]$Config.GcpLinuxGroupPrefix }
        else { '' }
    }
    else {
        $cloudType = 'Azure'
        $identifier = ([string]$State['SubscriptionName']).Trim()
        $prefix = if ($osCategory -eq 'Windows') { [string]$Config.AzureWindowsGroupPrefix }
        elseif ($osCategory -eq 'Linux') { [string]$Config.AzureLinuxGroupPrefix }
        else { '' }
    }
    $defaultMode = if ($Config['DefaultGroupMode']) { [string]$Config.DefaultGroupMode } else { 'Passive' }
    $counterpartMode = if ($defaultMode -eq 'Passive') { 'Active' } else { 'Passive' }
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return @{
            Enabled = $false; CloudType = $cloudType; OSCategory = $osCategory; CloudIdentifier = $identifier
            DefaultGroupMode = $defaultMode; CounterpartGroupMode = $counterpartMode
            GroupName = ''; CounterpartGroupName = ''; PassiveGroupName = ''; ActiveGroupName = ''
        }
    }
    if (-not $identifier) {
        return @{
            Enabled = $true; CloudType = $cloudType; OSCategory = $osCategory; CloudIdentifier = ''
            DefaultGroupMode = $defaultMode; CounterpartGroupMode = $counterpartMode
            GroupName = ''; CounterpartGroupName = ''; PassiveGroupName = ''; ActiveGroupName = ''
        }
    }
    $passiveGroupName = Format-CloudGroupName -Prefix $prefix -GroupMode 'Passive' -Identifier $identifier
    $activeGroupName = Format-CloudGroupName -Prefix $prefix -GroupMode 'Active' -Identifier $identifier
    $groupName = if ($defaultMode -eq 'Passive') { $passiveGroupName } else { $activeGroupName }
    $counterpartGroupName = if ($defaultMode -eq 'Passive') { $activeGroupName } else { $passiveGroupName }
    return @{
        Enabled = $true
        CloudType = $cloudType
        OSCategory = $osCategory
        CloudIdentifier = $identifier
        DefaultGroupMode = $defaultMode
        CounterpartGroupMode = $counterpartMode
        GroupName = $groupName
        CounterpartGroupName = $counterpartGroupName
        PassiveGroupName = $passiveGroupName
        ActiveGroupName = $activeGroupName
    }
}

function Get-CloudGroupSearchPrefix {
    param([string]$Prefix)
    $literalPrefix = ([regex]::Split($Prefix, '(?i)\{(?:mode|id|0)\}'))[0]
    return [regex]::Replace($literalPrefix, '(?i)(?:active|passive)[-_]?$', '')
}

function ConvertFrom-CloudGroupDisplayName {
    param([hashtable]$Config, [string]$DisplayName)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return @{ Matched = $false } }
    $specs = @(
        @{ CloudType = 'AWS'; OSCategory = 'Windows'; Prefix = [string]$Config['AwsWindowsGroupPrefix'] }
        @{ CloudType = 'AWS'; OSCategory = 'Linux'; Prefix = [string]$Config['AwsLinuxGroupPrefix'] }
        @{ CloudType = 'GCP'; OSCategory = 'Windows'; Prefix = [string]$Config['GcpWindowsGroupPrefix'] }
        @{ CloudType = 'GCP'; OSCategory = 'Linux'; Prefix = [string]$Config['GcpLinuxGroupPrefix'] }
        @{ CloudType = 'Azure'; OSCategory = 'Windows'; Prefix = [string]$Config['AzureWindowsGroupPrefix'] }
        @{ CloudType = 'Azure'; OSCategory = 'Linux'; Prefix = [string]$Config['AzureLinuxGroupPrefix'] }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Prefix) } | Sort-Object { $_.Prefix.Length } -Descending
    foreach ($spec in $specs) {
        $rawPrefix = $spec.Prefix
        if ($rawPrefix -match '(?i)\{mode\}' -and ($rawPrefix.Contains('{id}') -or $rawPrefix.Contains('{0}'))) {
            $pattern = [regex]::Escape([regex]::Replace($rawPrefix, '(?i)\{mode\}', '{mode}'))
            $pattern = $pattern.Replace([regex]::Escape('{mode}'), '(?<Mode>active|passive)')
            $pattern = $pattern.Replace([regex]::Escape('{id}'), '(?<Identifier>.+)').Replace([regex]::Escape('{0}'), '(?<Identifier>.+)')
            $match = [regex]::Match($DisplayName, "^$pattern$", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                $sharedAcrossOS = @($specs | Where-Object { $_.CloudType -eq $spec.CloudType -and $_.Prefix -eq $rawPrefix }).Count -gt 1
                return @{
                    Matched = $true
                    CloudType = $spec.CloudType
                    OSCategory = if ($sharedAcrossOS) { 'All' } else { $spec.OSCategory }
                    GroupMode = if ($match.Groups['Mode'].Value -eq 'active') { 'Active' } else { 'Passive' }
                    CloudIdentifier = $match.Groups['Identifier'].Value
                    DisplayName = $DisplayName
                }
            }
            continue
        }
        $basePrefix = Get-CloudGroupSearchPrefix $rawPrefix
        if ($DisplayName.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $rest = $DisplayName.Substring($basePrefix.Length).TrimStart('-', '_')
            $groupMode = if ($Config['DefaultGroupMode']) { [string]$Config.DefaultGroupMode } else { 'Passive' }
            $cloudId = $rest
            if ($rest -match '^(?i)(active|passive)[-_](.+)$') {
                $groupMode = if ($Matches[1].ToLowerInvariant() -eq 'active') { 'Active' } else { 'Passive' }
                $cloudId = $Matches[2].Trim()
            }
            if ($cloudId) {
                return @{
                    Matched = $true
                    CloudType = $spec.CloudType
                    OSCategory = $spec.OSCategory
                    GroupMode = $groupMode
                    CloudIdentifier = $cloudId
                    DisplayName = $DisplayName
                }
            }
        }
    }
    return @{ Matched = $false }
}

function Get-SharedAdminUnitGroups {
    param([string]$AdminUnitId)
    $manifestResponse = Invoke-Table -Path "machines(PartitionKey='group-catalogs',RowKey='$AdminUnitId')" -AllowStatus @(404)
    if ($manifestResponse.Status -eq 404) { return $null }
    $manifest = Read-JsonResponse $manifestResponse
    $expires = [datetimeoffset]$manifest.ExpiresAt
    if ($expires -le [datetimeoffset]::UtcNow) { return $null }
    $generation = ([guid]$manifest.Generation).ToString()
    $groups = [Collections.Generic.List[hashtable]]::new()
    $cursor = ''
    do {
        $page = Get-TablePage -Filter "PartitionKey eq 'au-groups-$AdminUnitId' and Generation eq '$generation'" -Cursor $cursor
        foreach ($group in $page.Items) { $groups.Add($group) }
        $cursor = $page.Cursor
    } while ($cursor)
    if ($groups.Count -ne [int]$manifest.GroupCount) {
        Write-Warning "Shared AU group catalog changed while reading '$AdminUnitId'; refreshing directly from Graph."
        return $null
    }
    return @{ Groups = @($groups); ExpiresAt = $expires }
}

function Save-SharedAdminUnitGroups {
    param([string]$AdminUnitId, [array]$Groups)
    $generation = [guid]::NewGuid().ToString()
    $expires = [datetimeoffset]::UtcNow.AddMinutes(30)
    foreach ($group in $Groups) {
        $entity = @{
            PartitionKey = "au-groups-$AdminUnitId"
            RowKey = ([guid]$group.id).ToString()
            Generation = $generation
            Data = ConvertTo-Json -InputObject $group -Depth 10 -Compress
        }
        $null = Invoke-Table -Path "machines(PartitionKey='$($entity.PartitionKey)',RowKey='$($entity.RowKey)')" -Method PUT -Body $entity
    }
    # Publish only after every row is saved; readers reject interrupted or overlapping generations.
    $manifest = @{
        PartitionKey = 'group-catalogs'; RowKey = $AdminUnitId
        Generation = $generation; GroupCount = $Groups.Count; ExpiresAt = $expires.ToString('o')
    }
    $null = Invoke-Table -Path "machines(PartitionKey='group-catalogs',RowKey='$AdminUnitId')" -Method PUT -Body $manifest
    $script:AdminUnitGroupsCache[$AdminUnitId] = @($Groups)
    $script:AdminUnitGroupsExpires[$AdminUnitId] = $expires
    $script:SharedAdminUnitGroups[$AdminUnitId] = $true
}

function Get-AdminUnitGroups {
    param([string]$AdminUnitId, [switch]$ForceRefresh)
    if (-not $AdminUnitId) { return @() }
    if (-not $ForceRefresh -and $script:AdminUnitGroupsCache.ContainsKey($AdminUnitId) -and
        $script:AdminUnitGroupsExpires.ContainsKey($AdminUnitId) -and $script:AdminUnitGroupsExpires[$AdminUnitId] -gt [datetimeoffset]::UtcNow) {
        return $script:AdminUnitGroupsCache[$AdminUnitId]
    }
    $script:GroupByNameCache.Clear()
    if (-not $ForceRefresh) {
        $shared = Get-SharedAdminUnitGroups $AdminUnitId
        if ($null -ne $shared) {
            $script:AdminUnitGroupsCache[$AdminUnitId] = $shared.Groups
            $script:AdminUnitGroupsExpires[$AdminUnitId] = $shared.ExpiresAt
            $script:SharedAdminUnitGroups[$AdminUnitId] = $true
            return $shared.Groups
        }
    }
    $groups = [Collections.Generic.List[hashtable]]::new()
    $next = "/directory/administrativeUnits/$AdminUnitId/members/microsoft.graph.group?`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,isAssignableToRole&`$top=100"
    while ($next) {
        $response = Read-JsonResponse (Invoke-Graph -Path $next)
        foreach ($item in @($response.value)) {
            if ($item -is [Collections.IDictionary] -and $item['id'] -and $item['displayName']) {
                $groups.Add($item)
            }
        }
        $next = if ($response.ContainsKey('@odata.nextLink')) { [string]$response['@odata.nextLink'] } else { '' }
    }
    $result = @($groups)
    $script:AdminUnitGroupsCache[$AdminUnitId] = $result
    $script:AdminUnitGroupsExpires[$AdminUnitId] = [datetimeoffset]::UtcNow.AddMinutes(30)
    $script:SharedAdminUnitGroups[$AdminUnitId] = $false
    return $result
}

function Get-DeviceCloudGroups {
    param([hashtable]$Config, [string]$ObjectId)
    if (-not $Config -or -not $ObjectId) { return @() }
    if ($Config['AdminUnitId']) {
        $auGroups = @(Get-AdminUnitGroups ([string]$Config['AdminUnitId']))
        $matched = foreach ($item in $auGroups) {
            $name = [string](Get-InventoryValue $item @('displayName'))
            $parsed = ConvertFrom-CloudGroupDisplayName -Config $Config -DisplayName $name
            if ($parsed.Matched -and $item['id']) {
                $gid = ([guid]$item.id).ToString()
                if (Test-DirectMembership $gid $ObjectId) {
                    @{
                        Id = $gid
                        DisplayName = $name
                        CloudType = $parsed.CloudType
                        OSCategory = $parsed.OSCategory
                        GroupMode = $parsed.GroupMode
                        CloudIdentifier = $parsed.CloudIdentifier
                    }
                }
            }
        }
        return @($matched)
    }
    $response = Read-JsonResponse (Invoke-Graph -Path "/devices/$ObjectId/memberOf?`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,isAssignableToRole&`$top=100")
    if (-not $response.ContainsKey('value')) { return @() }
    $matched = foreach ($item in @($response.value)) {
        $name = [string](Get-InventoryValue $item @('displayName'))
        $parsed = ConvertFrom-CloudGroupDisplayName -Config $Config -DisplayName $name
        if ($parsed.Matched) {
            @{
                Id = ([guid]$item.id).ToString()
                DisplayName = $name
                CloudType = $parsed.CloudType
                OSCategory = $parsed.OSCategory
                GroupMode = $parsed.GroupMode
                CloudIdentifier = $parsed.CloudIdentifier
            }
        }
    }
    return @($matched)
}

function Update-GroupComplianceFlags {
    param([hashtable]$State)
    $flags = [Collections.Generic.List[string]]::new()
    $codes = [Collections.Generic.List[string]]::new()
    $memberGroups = @($State['MemberGroups'] | Where-Object { $null -ne $_ })
    if ($memberGroups.Count -gt 1) {
        $codes.Add('MultipleGroups')
        $names = @($memberGroups | ForEach-Object { [string]$_['DisplayName'] }) -join ', '
        $flags.Add("Multiple groups ($($memberGroups.Count)): $names")
    }
    foreach ($g in $memberGroups) {
        $gName = [string]$g['DisplayName']
        $gCloud = [string]$g['CloudType']
        $gOS = [string]$g['OSCategory']
        $gId = [string]$g['CloudIdentifier']
        $gMode = [string]$g['GroupMode']
        if ($gCloud -and $State['CloudGroupType'] -and $gCloud -ne $State['CloudGroupType']) {
            if ('WrongGroup' -notin $codes) { $codes.Add('WrongGroup') }
            $flags.Add("Wrong group (Cloud mismatch): in $gName ($gCloud) but machine is $($State['CloudGroupType'])")
        }
        elseif ($gId -and $State['CloudIdentifier'] -and -not [string]::Equals($gId, [string]$State['CloudIdentifier'], [StringComparison]::OrdinalIgnoreCase)) {
            if ('WrongGroup' -notin $codes) { $codes.Add('WrongGroup') }
            $idLabel = switch ([string]$State['CloudGroupType']) {
                'AWS' { 'AWS Account ID' }
                'GCP' { 'GCP Project' }
                default { 'Subscription' }
            }
            $flags.Add("Wrong group ($idLabel mismatch): in $gName ($gId) but machine $idLabel is $($State['CloudIdentifier'])")
        }
        if ($gOS -and $gOS -ne 'All' -and $State['CloudGroupOS'] -and $gOS -ne $State['CloudGroupOS']) {
            if ('WrongGroup' -notin $codes) { $codes.Add('WrongGroup') }
            $flags.Add("Wrong group (OS mismatch): in $gName ($gOS) but machine OS is $($State['CloudGroupOS'])")
        }
        if ($gMode -eq 'Active' -and $State['MdeAntivirusMode'] -in @('Passive', 'PassiveAudit')) {
            if ('AvModeMismatchShouldBeActive' -notin $codes) { $codes.Add('AvModeMismatchShouldBeActive') }
            $flags.Add("Should be Active: in Active group ($gName) but MDE mode is $($State['MdeAntivirusMode'])")
        }
        elseif ($gMode -eq 'Passive' -and $State['MdeAntivirusMode'] -eq 'Active') {
            if ('AvModeMismatchShouldBeActive' -notin $codes) { $codes.Add('AvModeMismatchShouldBeActive') }
            $flags.Add("Should be Active: in Passive group ($gName) but MDE mode is Active")
        }
    }
    $State.GroupFlags = @($flags)
    $State.GroupFlagCodes = @($codes)
    $State.GroupComplianceStatus = if ($flags.Count -gt 0) { 'Flagged' } elseif ($memberGroups.Count -gt 0) { 'Compliant' } else { 'NotInGroup' }
}

function Resolve-GroupByDisplayName {
    param([string]$DisplayName, [string]$AdminUnitId = (Get-OptionalSetting 'SYNC_ADMIN_UNIT_ID'), [switch]$ForceRefresh)
    $cacheKey = Get-MachineKey "$AdminUnitId`n$DisplayName"
    if ($ForceRefresh -or ($AdminUnitId -and $script:AdminUnitGroupsExpires.ContainsKey($AdminUnitId) -and
        $script:AdminUnitGroupsExpires[$AdminUnitId] -le [datetimeoffset]::UtcNow)) {
        $null = $script:GroupByNameCache.Remove($cacheKey)
    }
    if (-not $ForceRefresh -and $script:GroupByNameCache.ContainsKey($cacheKey)) {
        return $script:GroupByNameCache[$cacheKey]
    }
    $group = $null
    if ($AdminUnitId) {
        $auMatches = @(Get-AdminUnitGroups $AdminUnitId -ForceRefresh:$ForceRefresh | Where-Object {
            [string]::Equals([string]$_['displayName'], $DisplayName, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($auMatches.Count -gt 1) {
            throw "Multiple Entra security groups in Administrative Unit '$AdminUnitId' matched display name '$DisplayName'."
        }
        if (-not $auMatches.Count) { return $null }
        $group = $auMatches[0]
    }
    else {
        $escaped = $DisplayName.Replace("'", "''")
        $filter = [uri]::EscapeDataString("displayName eq '$escaped'")
        $response = Read-JsonResponse (Invoke-Graph -Path "/groups?`$filter=$filter&`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,isAssignableToRole&`$top=2")
        if ($response.ContainsKey('@odata.nextLink') -or @($response.value).Count -gt 1) {
            throw "Multiple Entra security groups matched display name '$DisplayName'."
        }
        if (-not @($response.value).Count) { return $null }
        $group = $response.value[0]
    }
    if ($group.securityEnabled -ne $true -or 'DynamicMembership' -in $group.groupTypes -or
        'Unified' -in $group.groupTypes -or $group.onPremisesSyncEnabled -eq $true -or $group.isAssignableToRole -eq $true) {
        throw "Target group '$DisplayName' must be a cloud-managed, assigned, non-role-assignable security group."
    }
    $resolved = @{ Id = ([guid]$group.id).ToString(); DisplayName = [string]$group.displayName }
    $script:GroupByNameCache[$cacheKey] = $resolved
    return $resolved
}

function New-AdminUnitSecurityGroup {
    param([string]$AdminUnitId, [string]$DisplayName, [string]$Description = '', [hashtable]$State = $null)
    if (-not $AdminUnitId) { throw 'AdminUnitId is required to create a group in an Administrative Unit.' }
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { throw 'DisplayName is required to create a group.' }
    $cacheKey = Get-MachineKey "$AdminUnitId`n$DisplayName"
    $null = $script:GroupByNameCache.Remove($cacheKey)
    $null = $script:AdminUnitGroupsCache.Remove($AdminUnitId)
    $existing = Resolve-GroupByDisplayName -DisplayName $DisplayName -AdminUnitId $AdminUnitId -ForceRefresh
    if ($null -ne $existing) { return $existing }

    # Pending claims survive uncertain Graph responses; only confirmed deleted groups permit conditional replacement.
    $claimPath = "machines(PartitionKey='group-creations',RowKey='$cacheKey')"
    $claim = @{
        PartitionKey = 'group-creations'
        RowKey = $cacheKey
        AdminUnitId = $AdminUnitId
        DisplayName = $DisplayName
        OperationId = [guid]::NewGuid().ToString()
        CreatedAt = [datetimeoffset]::UtcNow.ToString('o')
        GroupId = ''
    }
    $reservation = Invoke-Table -Path 'machines' -Method POST -Body $claim -AllowStatus @(409)
    if ($reservation.Status -eq 409) {
        $storedResponse = Invoke-Table -Path $claimPath
        $stored = Read-JsonResponse $storedResponse
        if ($stored['GroupId']) {
            $group = Test-Group -GroupId (([guid]$stored['GroupId']).ToString()) -AllowMissing
            if ($null -ne $group) {
                if (-not [string]::Equals([string]$group.displayName, $DisplayName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Recorded Entra group '$($stored['GroupId']) no longer matches '$DisplayName'; group creation is blocked."
                }
                $resolved = @{ Id = ([guid]$group.id).ToString(); DisplayName = [string]$group.displayName }
                $script:GroupByNameCache[$cacheKey] = $resolved
                return $resolved
            }
            $createdAt = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse([string]$stored['CreatedAt'], [ref]$createdAt) -or
                $createdAt -gt [datetimeoffset]::UtcNow.AddMinutes(-30)) {
                throw "Recorded group '$($stored['GroupId']) was not found, but its creation is recent or undated; recreation is blocked to allow directory replication."
            }
            $etag = [string]($storedResponse.Headers.ETag | Select-Object -First 1)
            if (-not $etag) { throw 'Deleted-group reservation has no ETag; refusing an unsafe replacement.' }
            $claim.PreviousGroupId = [string]$stored['GroupId']
            $replacement = Invoke-Table -Path $claimPath -Method PUT -Body $claim -Headers @{ 'If-Match' = $etag } -AllowStatus @(412)
            if ($replacement.Status -eq 412) {
                throw "Group creation reservation for '$DisplayName' changed during deleted-group recovery; no group was created by this request."
            }
            $stored = $claim
            Write-SyncTrace 'Group' "Recorded group '$($claim.PreviousGroupId)' was not found; reserved recovery for '$DisplayName'."
            $existing = Resolve-GroupByDisplayName -DisplayName $DisplayName -AdminUnitId $AdminUnitId -ForceRefresh
            if ($null -ne $existing) {
                $claim.GroupId = $existing.Id
                $null = Invoke-Table -Path $claimPath -Method PUT -Body $claim -Headers @{ 'If-Match' = '*' }
                return $existing
            }
        }
        if ($stored['OperationId'] -ne $claim.OperationId) {
            throw "Group creation for '$DisplayName' is pending or has an uncertain outcome. Reservation: $claimPath. Creation will not be repeated; inspect the original operation and reconcile the reservation before retrying."
        }
    }
    if ($State -and $State['Key']) {
        $intent = @{
            Timestamp = [datetimeoffset]::UtcNow.ToString('o')
            Action = 'GroupCreateRequested'
            RunId = [string]$State['RunId']
            ArcResourceId = [string]$State['ArcResourceId']
            GroupName = $DisplayName
            AdminUnitId = $AdminUnitId
        }
        $null = Invoke-Table -Path 'machines' -Method POST -Body (New-HistoryEntity $State.Key $intent)
    }
    $slug = [regex]::Replace($DisplayName.ToLowerInvariant(), '[^a-z0-9]', '')
    if (-not $slug) { $slug = 'group' }
    $mailNickname = "mdfs-$($slug.Substring(0, [math]::Min(48, $slug.Length)))"
    $body = @{
        '@odata.type' = '#microsoft.graph.group'
        displayName = $DisplayName
        description = if ($Description) { $Description } else { "Auto-created by Arc-to-Entra Sync ($DisplayName)" }
        mailEnabled = $false
        mailNickname = $mailNickname
        securityEnabled = $true
        groupTypes = @()
    }
    $response = Invoke-Graph -Path "/directory/administrativeUnits/$AdminUnitId/members" -Method POST -Body $body -AllowStatus @(400, 409) -DisableRetry
    if ($response.Status -in @(400, 409)) {
        $null = $script:AdminUnitGroupsCache.Remove($AdminUnitId)
        $existing = Resolve-GroupByDisplayName -DisplayName $DisplayName -AdminUnitId $AdminUnitId -ForceRefresh
        if ($null -eq $existing) {
            throw "Failed to create Entra security group '$DisplayName' in Administrative Unit '$AdminUnitId' (HTTP $($response.Status)). Reservation retained: $claimPath."
        }
        $resolved = $existing
    }
    else {
        $created = Read-JsonResponse $response
        $resolved = @{ Id = ([guid]$created.id).ToString(); DisplayName = [string]$created.displayName }
    }
    $claim.GroupId = $resolved.Id
    $null = Invoke-Table -Path $claimPath -Method PUT -Body $claim -Headers @{ 'If-Match' = '*' }
    $resolved.Created = $response.Status -notin @(400, 409)
    $script:GroupByNameCache[$cacheKey] = $resolved
    if ($script:AdminUnitGroupsCache.ContainsKey($AdminUnitId)) {
        $script:AdminUnitGroupsCache[$AdminUnitId] = @($script:AdminUnitGroupsCache[$AdminUnitId]) + @(@{
            id = $resolved.Id
            displayName = $resolved.DisplayName
            securityEnabled = $true
            groupTypes = @()
            onPremisesSyncEnabled = $null
            isAssignableToRole = $false
        })
    }
    return $resolved
}

function Initialize-InventoryGroups {
    param([hashtable]$Config, [array]$WorkItems, [hashtable]$MdeMap = @{})
    $summary = @{ Expected = 0; Existing = 0; Created = 0; WouldCreate = 0; Missing = 0 }
    if (-not $Config.AdminUnitId -or -not $WorkItems.Count) { return $summary }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $WorkItems) {
        $row = $item.Row
        if ($null -eq $row -or -not $row.ContainsKey('properties')) { continue }
        $metadata = Resolve-MachineStatusAndOS -ResourceId $item.ResourceId -Resource $row
        $subscriptionName = [string](Get-InventoryValue $row @('subscriptionName'))
        if (-not $subscriptionName) { $subscriptionName = Get-SubscriptionName (([string]$item.ResourceId).Split('/')[2]) }
        $platforms = ''
        $resourceKey = ([string]$item.ResourceId).ToLowerInvariant()
        if ($MdeMap.ContainsKey($resourceKey)) {
            $platforms = @($MdeMap[$resourceKey].Candidates | ForEach-Object { [string](Get-InventoryValue $_ @('CloudPlatforms')) }) -join ' '
        }
        $target = Resolve-CloudGroupTarget -Config $Config -State @{
            OS = $metadata.OS; AzureTags = Get-InventoryValue $row @('tags')
            SubscriptionName = $subscriptionName
            CloudProvider = [string](Get-InventoryValue $row @('properties', 'cloudMetadata', 'provider'))
            MdeCloudPlatforms = $platforms
        }
        if (-not $target.Enabled -or -not $target.GroupName) {
            Write-SyncTrace 'GroupProvisioning' "No group plan for '$($item.ResourceId)': OS route is disabled/unknown or cloud account identifier is missing; worker fallback remains enabled."
            continue
        }
        $null = $names.Add($target.PassiveGroupName)
        $null = $names.Add($target.ActiveGroupName)
    }
    $summary.Expected = $names.Count
    $groupsById = @{}
    foreach ($group in @(Get-AdminUnitGroups $Config.AdminUnitId -ForceRefresh)) { $groupsById[[string]$group.id] = $group }
    foreach ($name in $names) {
        $resolved = Resolve-GroupByDisplayName -DisplayName $name -AdminUnitId $Config.AdminUnitId
        if ($null -ne $resolved) { $summary.Existing++ }
        elseif ($Config.Mode -eq 'Audit') {
            if ($Config.AutoCreateGroups) { $summary.WouldCreate++ } else { $summary.Missing++ }
            Write-SyncTrace 'GroupProvisioning' "Missing group '$name'; mode=$($Config.Mode), autoCreate=$($Config.AutoCreateGroups). No group created."
        }
        elseif ($Config.AutoCreateGroups) {
            $resolved = New-AdminUnitSecurityGroup -AdminUnitId $Config.AdminUnitId -DisplayName $name
            if ($resolved['Created']) { $summary.Created++ } else { $summary.Existing++ }
        }
        else { $summary.Missing++ }
        if ($null -ne $resolved) {
            $groupsById[$resolved.Id] = @{
                id = $resolved.Id; displayName = $resolved.DisplayName; securityEnabled = $true
                groupTypes = @(); onPremisesSyncEnabled = $false; isAssignableToRole = $false
            }
        }
    }
    Save-SharedAdminUnitGroups -AdminUnitId $Config.AdminUnitId -Groups @($groupsById.Values)
    Write-SyncTrace 'GroupProvisioning' 'Inventory group provisioning completed before machine work was queued.' $summary
    return $summary
}

function Get-CoverageCatalog {
    param([hashtable]$Config)
    $managedGroups = [Collections.Generic.List[hashtable]]::new()
    $seenGroupNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $cloudScopes = [Collections.Generic.List[hashtable]]::new()
    $seenScopes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($subId in @($Config['Subscriptions'])) {
        try {
            $subName = Get-SubscriptionName $subId
            $scopeKey = "Azure:$subName"
            if ($subName -and $seenScopes.Add($scopeKey)) {
                $cloudScopes.Add(@{
                    CloudType = 'Azure'
                    CloudIdentifier = $subName
                    SubscriptionId = $subId
                    ManagementGroup = ''
                    Source = 'Scoped Azure Subscription'
                })
            }
        }
        catch {}
    }
    foreach ($mg in @($Config['ManagementGroups'])) {
        try {
            foreach ($subId in @(Get-ManagementGroupSubscriptions $mg)) {
                $subName = Get-SubscriptionName $subId
                $scopeKey = "Azure:$subName"
                if ($subName -and $seenScopes.Add($scopeKey)) {
                    $cloudScopes.Add(@{
                        CloudType = 'Azure'
                        CloudIdentifier = $subName
                        SubscriptionId = $subId
                        ManagementGroup = $mg
                        Source = "Management Group ($mg)"
                    })
                }
            }
        }
        catch {}
    }
    if ($Config['AdminUnitId']) {
        try {
            foreach ($g in @(Get-AdminUnitGroups ([string]$Config['AdminUnitId']))) {
                $gName = [string](Get-InventoryValue $g @('displayName'))
                $parsed = ConvertFrom-CloudGroupDisplayName -Config $Config -DisplayName $gName
                if ($parsed.Matched -and $seenGroupNames.Add($gName)) {
                    $managedGroups.Add(@{
                        Id = ([guid]$g.id).ToString()
                        DisplayName = $gName
                        CloudType = $parsed.CloudType
                        OSCategory = $parsed.OSCategory
                        GroupMode = $parsed.GroupMode
                        CloudIdentifier = $parsed.CloudIdentifier
                    })
                    $scopeKey = "$($parsed.CloudType):$($parsed.CloudIdentifier)"
                    if ($seenScopes.Add($scopeKey)) {
                        $cloudScopes.Add(@{
                            CloudType = $parsed.CloudType
                            CloudIdentifier = $parsed.CloudIdentifier
                            SubscriptionId = ''
                            Source = "Entra ID Group ($gName)"
                        })
                    }
                }
            }
        }
        catch {}
    }
    else {
        $prefixes = @(
            $Config['AwsWindowsGroupPrefix'], $Config['AwsLinuxGroupPrefix'],
            $Config['GcpWindowsGroupPrefix'], $Config['GcpLinuxGroupPrefix'],
            $Config['AzureWindowsGroupPrefix'], $Config['AzureLinuxGroupPrefix']
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
            Get-CloudGroupSearchPrefix ([string]$_)
        } | Sort-Object -Unique
        foreach ($basePrefix in $prefixes) {
            try {
                $escaped = $basePrefix.Replace("'", "''")
                $filter = [uri]::EscapeDataString("startsWith(displayName,'$escaped')")
                $response = Read-JsonResponse (Invoke-Graph -Path "/groups?`$filter=$filter&`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,isAssignableToRole&`$top=100")
                foreach ($g in @($response.value)) {
                    $gName = [string](Get-InventoryValue $g @('displayName'))
                    $parsed = ConvertFrom-CloudGroupDisplayName -Config $Config -DisplayName $gName
                    if ($parsed.Matched -and $seenGroupNames.Add($gName)) {
                        $managedGroups.Add(@{
                            Id = ([guid]$g.id).ToString()
                            DisplayName = $gName
                            CloudType = $parsed.CloudType
                            OSCategory = $parsed.OSCategory
                            GroupMode = $parsed.GroupMode
                            CloudIdentifier = $parsed.CloudIdentifier
                        })
                        $scopeKey = "$($parsed.CloudType):$($parsed.CloudIdentifier)"
                        if ($seenScopes.Add($scopeKey)) {
                            $cloudScopes.Add(@{
                                CloudType = $parsed.CloudType
                                CloudIdentifier = $parsed.CloudIdentifier
                                SubscriptionId = ''
                                Source = "Entra ID Group ($gName)"
                            })
                        }
                    }
                }
            }
            catch {}
        }
    }
    return @{
        ManagedGroups = @($managedGroups)
        CloudScopes = @($cloudScopes)
    }
}

function Get-FunctionParametersSummary {
    $rawSubs = Get-OptionalSetting 'SYNC_SUBSCRIPTION_IDS'
    $rawMgs = Get-OptionalSetting 'SYNC_MANAGEMENT_GROUP_IDS'
    $rawRgs = Get-OptionalSetting 'SYNC_RESOURCE_GROUP_NAMES'
    $defaultGroupMode = Get-Setting 'SYNC_DEFAULT_GROUP_MODE' 'Passive'
    $adminUnitId = Get-OptionalSetting 'SYNC_ADMIN_UNIT_ID'
    $rawAutoCreate = Get-OptionalSetting 'SYNC_AUTO_CREATE_GROUPS'
    $autoCreate = if ($rawAutoCreate) { $rawAutoCreate } elseif ($adminUnitId) { 'true (enabled via SYNC_ADMIN_UNIT_ID)' } else { 'false' }
    $awsWin = Get-OptionalSetting 'SYNC_AWS_WINDOWS_GROUP_PREFIX'
    $awsLin = Get-OptionalSetting 'SYNC_AWS_LINUX_GROUP_PREFIX'
    $gcpWin = Get-OptionalSetting 'SYNC_GCP_WINDOWS_GROUP_PREFIX'
    $gcpLin = Get-OptionalSetting 'SYNC_GCP_LINUX_GROUP_PREFIX'
    $azWin = Get-OptionalSetting 'SYNC_AZURE_WINDOWS_GROUP_PREFIX'
    $azLin = Get-OptionalSetting 'SYNC_AZURE_LINUX_GROUP_PREFIX'
    [ordered]@{
        SYNC_MODE = Get-Setting 'SYNC_MODE' 'Audit'
        SYNC_DEFAULT_GROUP_MODE = $defaultGroupMode
        SYNC_ADMIN_UNIT_ID = if ($adminUnitId) { $adminUnitId } else { 'Not configured (pre-created groups only)' }
        SYNC_AUTO_CREATE_GROUPS = $autoCreate
        SYNC_SCHEDULE = Get-Setting 'SYNC_SCHEDULE' '0 */30 * * * *'
        SYNC_FRESHNESS_HOURS = Get-Setting 'SYNC_FRESHNESS_HOURS' '24'
        SYNC_AWS_WINDOWS_GROUP_PREFIX = if ($awsWin) { "$awsWin (default: $(Format-CloudGroupName $awsWin $defaultGroupMode '<AccountId>'))" } else { 'Not configured' }
        SYNC_AWS_LINUX_GROUP_PREFIX = if ($awsLin) { "$awsLin (default: $(Format-CloudGroupName $awsLin $defaultGroupMode '<AccountId>'))" } else { 'Not configured' }
        SYNC_GCP_WINDOWS_GROUP_PREFIX = if ($gcpWin) { "$gcpWin (default: $(Format-CloudGroupName $gcpWin $defaultGroupMode '<ProjectId>'))" } else { 'Not configured' }
        SYNC_GCP_LINUX_GROUP_PREFIX = if ($gcpLin) { "$gcpLin (default: $(Format-CloudGroupName $gcpLin $defaultGroupMode '<ProjectId>'))" } else { 'Not configured' }
        SYNC_AZURE_WINDOWS_GROUP_PREFIX = if ($azWin) { "$azWin (default: $(Format-CloudGroupName $azWin $defaultGroupMode '<SubscriptionName>'))" } else { 'Not configured' }
        SYNC_AZURE_LINUX_GROUP_PREFIX = if ($azLin) { "$azLin (default: $(Format-CloudGroupName $azLin $defaultGroupMode '<SubscriptionName>'))" } else { 'Not configured' }
        SYNC_SUBSCRIPTION_IDS = if ($rawSubs) { $rawSubs } else { 'None (using Management Group scope)' }
        SYNC_MANAGEMENT_GROUP_IDS = if ($rawMgs) { $rawMgs } else { 'None' }
        SYNC_RESOURCE_GROUP_NAMES = if ($rawRgs) { $rawRgs } else { 'All resource groups in scope' }
        SYNC_TENANT_ID = Get-OptionalSetting 'SYNC_TENANT_ID'
        SYNC_STORAGE_ACCOUNT = Get-OptionalSetting 'SYNC_STORAGE_ACCOUNT'
        ServiceBusNamespace = Get-OptionalSetting 'ServiceBusConnection__fullyQualifiedNamespace'
    }
}

function Get-PermissionsValidationReport {
    param(
        [hashtable]$Config = $null,
        [int]$DiscoveredMachinesCount = -1,
        [int]$ArgMachineRows = -1,
        [int]$ArgVmssRows = -1,
        [hashtable]$Catalog = $null
    )
    if (-not $Config) { $Config = Get-SyncConfig }
    $tenantId = Get-OptionalSetting 'SYNC_TENANT_ID'
    $checkedAt = [datetimeoffset]::UtcNow.ToString('o')
    $graphClaims = Get-TokenClaims 'https://graph.microsoft.com'
    $armClaims = Get-TokenClaims 'https://management.azure.com/'
    $workerOid = if ($graphClaims['oid']) { [string]$graphClaims['oid'] } elseif ($armClaims['oid']) { [string]$armClaims['oid'] } else { '' }
    $workerOidHint = if ($workerOid) { $workerOid } else { '<worker-managed-identity-principal-id>' }
    $graphRoles = @()
    if ($graphClaims['roles']) {
        $graphRoles = @($graphClaims['roles'] | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
    }
    $funcResourceId = Get-FunctionAppResourceId
    $workerAppName = if ($funcResourceId) { $funcResourceId.Split('/')[-1] } else { Get-OptionalSetting 'WEBSITE_SITE_NAME' }
    $checks = [Collections.Generic.List[hashtable]]::new()

    # 1. Azure RBAC: Reader on target Subscriptions / Management Groups
    $accessibleSubs = [Collections.Generic.List[string]]::new()
    $deniedSubs = [Collections.Generic.List[string]]::new()
    foreach ($subId in @($Config.Subscriptions)) {
        try {
            $subResp = Invoke-CloudRequest -Uri "https://management.azure.com/subscriptions/${subId}?api-version=2022-12-01" -Resource 'https://management.azure.com/' -AllowStatus @(401, 403, 404)
            if ($subResp.Status -ge 200 -and $subResp.Status -lt 300) {
                $subJson = Read-JsonResponse $subResp
                $accessibleSubs.Add("$($subJson.displayName) ($subId)")
            }
            else {
                $deniedSubs.Add("$subId (HTTP $($subResp.Status))")
            }
        }
        catch {
            $deniedSubs.Add("$subId ($($_.Exception.Message))")
        }
    }
    $mgAccessibleCount = 0
    $mgError = ''
    if ($Config.ManagementGroups.Count) {
        try {
            $mgSubs = @(Get-ManagementGroupSubscriptions $Config.ManagementGroups)
            $mgAccessibleCount = $mgSubs.Count
        }
        catch {
            $mgError = $_.Exception.Message
        }
    }
    $scopeLabelParts = @()
    if ($Config.Subscriptions.Count) { $scopeLabelParts += "Subscriptions: $($Config.Subscriptions -join ', ')" }
    if ($Config.ManagementGroups.Count) { $scopeLabelParts += "Management Groups: $($Config.ManagementGroups -join ', ')" }
    if ($Config.ResourceGroups.Count) { $scopeLabelParts += "Resource Groups: $($Config.ResourceGroups -join ', ')" }
    $scopeLabel = $scopeLabelParts -join ' | '
    $firstSub = if ($Config.Subscriptions.Count) { $Config.Subscriptions[0] } else { '<subscription-guid>' }
    $firstMg = if ($Config.ManagementGroups.Count) { $Config.ManagementGroups[0] } else { '<management-group-id>' }
    $readerRemediation = if ($Config.ManagementGroups.Count) {
        "az role assignment create --assignee-object-id $workerOidHint --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/providers/Microsoft.Management/managementGroups/$firstMg'"
    }
    else {
        "az role assignment create --assignee-object-id $workerOidHint --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/subscriptions/$firstSub'"
    }
    if ($deniedSubs.Count -gt 0 -or $mgError -or ($Config.ManagementGroups.Count -gt 0 -and $mgAccessibleCount -eq 0 -and $accessibleSubs.Count -eq 0)) {
        $checks.Add(@{
            Id = 'azure-rbac-reader'
            Category = 'Azure RBAC'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'Reader'
            Scope = $scopeLabel
            RequiredFor = 'All Modes (Azure Resource Graph Discovery)'
            Status = 'Missing'
            Details = "Worker Managed Identity could not read one or more configured Azure scopes (Denied subscriptions: $($deniedSubs -join ', '); MG subscriptions visible: $mgAccessibleCount$(if ($mgError) { "; error: $mgError" })). Without Reader, Azure Resource Graph returns 0 rows."
            Remediation = $readerRemediation
        })
    }
    elseif ($DiscoveredMachinesCount -eq 0) {
        $checks.Add(@{
            Id = 'azure-rbac-reader'
            Category = 'Azure RBAC'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'Reader'
            Scope = $scopeLabel
            RequiredFor = 'All Modes (Azure Resource Graph Discovery)'
            Status = 'Warning'
            Details = "Subscription/Management Group container is readable ($($accessibleSubs.Count + $mgAccessibleCount) subscription(s) visible), but Azure Resource Graph returned 0 servers in scope. Verify Reader is assigned at the full target scope and that Arc or Azure VMs exist in the configured resource groups."
            Remediation = $readerRemediation
        })
    }
    else {
        $discoveredNote = if ($DiscoveredMachinesCount -ge 0) { "; $DiscoveredMachinesCount server(s) discovered in Azure Resource Graph" } else { '' }
        $checks.Add(@{
            Id = 'azure-rbac-reader'
            Category = 'Azure RBAC'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'Reader'
            Scope = $scopeLabel
            RequiredFor = 'All Modes (Azure Resource Graph Discovery)'
            Status = 'Granted'
            Details = "Verified Azure Reader access across configured scope ($($accessibleSubs.Count) direct subscription(s), $mgAccessibleCount MG subscription(s) visible$discoveredNote)."
            Remediation = ''
        })
    }

    # 2. Microsoft Graph: ThreatHunting.Read.All
    $hasHuntingClaim = 'ThreatHunting.Read.All' -in $graphRoles
    $huntingProbeStatus = 0
    try {
        $huntResp = Invoke-Graph -Path '/security/runHuntingQuery' -Method POST -Body @{ Query = 'DeviceInfo | take 1'; Timespan = 'P1D' } -AllowStatus @(400, 401, 403)
        $huntingProbeStatus = [int]$huntResp.Status
    }
    catch {
        $huntingProbeStatus = -1
    }
    if ($hasHuntingClaim -or ($huntingProbeStatus -ge 200 -and $huntingProbeStatus -lt 300)) {
        $checks.Add(@{
            Id = 'graph-threat-hunting'
            Category = 'Microsoft Graph'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'ThreatHunting.Read.All'
            Scope = "Tenant ($tenantId)"
            RequiredFor = 'All Modes (MDE Advanced Hunting)'
            Status = 'Granted'
            Details = "Verified ThreatHunting.Read.All application permission (Token claim present: $hasHuntingClaim; /v1.0/security/runHuntingQuery HTTP $huntingProbeStatus)."
            Remediation = ''
        })
    }
    else {
        $checks.Add(@{
            Id = 'graph-threat-hunting'
            Category = 'Microsoft Graph'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'ThreatHunting.Read.All'
            Scope = "Tenant ($tenantId)"
            RequiredFor = 'All Modes (MDE Advanced Hunting)'
            Status = 'Missing'
            Details = "Worker Managed Identity lacks ThreatHunting.Read.All (/v1.0/security/runHuntingQuery returned HTTP $huntingProbeStatus; token roles: $(if ($graphRoles.Count) { $graphRoles -join ', ' } else { 'none' }))."
            Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '$workerOidHint' -Mode $($Config.Mode)"
        })
    }

    # 3. Microsoft Graph: Device.Read.All
    $hasDeviceClaim = ('Device.Read.All' -in $graphRoles) -or ('Device.ReadWrite.All' -in $graphRoles) -or ('Directory.Read.All' -in $graphRoles) -or ('Directory.ReadWrite.All' -in $graphRoles)
    $deviceProbeStatus = 0
    try {
        $devResp = Invoke-Graph -Path '/devices?$top=1&$select=id,deviceId,accountEnabled' -AllowStatus @(401, 403)
        $deviceProbeStatus = [int]$devResp.Status
    }
    catch {
        $deviceProbeStatus = -1
    }
    if ($hasDeviceClaim -or ($deviceProbeStatus -ge 200 -and $deviceProbeStatus -lt 300)) {
        $checks.Add(@{
            Id = 'graph-device-read'
            Category = 'Microsoft Graph'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'Device.Read.All'
            Scope = "Tenant ($tenantId)"
            RequiredFor = 'All Modes (Entra Device Correlation)'
            Status = 'Granted'
            Details = "Verified Entra device read access (Token claim present: $hasDeviceClaim; GET /v1.0/devices HTTP $deviceProbeStatus)."
            Remediation = ''
        })
    }
    else {
        $checks.Add(@{
            Id = 'graph-device-read'
            Category = 'Microsoft Graph'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'Device.Read.All'
            Scope = "Tenant ($tenantId)"
            RequiredFor = 'All Modes (Entra Device Correlation)'
            Status = 'Missing'
            Details = "Worker Managed Identity cannot read Microsoft Entra devices (GET /v1.0/devices returned HTTP $deviceProbeStatus)."
            Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '$workerOidHint' -Mode $($Config.Mode)"
        })
    }

    # 4. Group Lookup & Management (AU-Scoped Groups Administrator when SYNC_ADMIN_UNIT_ID is set; GroupMember.Read.All only when no AU is configured)
    $auConfirmed = $false
    if ($Config.AdminUnitId) {
        $auStatus = 0
        $auMembersStatus = 0
        $auName = ''
        $scopedRoleFound = $false
        try {
            $auResp = Invoke-Graph -Path "/directory/administrativeUnits/$($Config.AdminUnitId)?`$select=id,displayName" -AllowStatus @(401, 403, 404)
            $auStatus = [int]$auResp.Status
            if ($auStatus -ge 200 -and $auStatus -lt 300) {
                $auObj = Read-JsonResponse $auResp
                $auName = [string]$auObj['displayName']
            }
            $auMemResp = Invoke-Graph -Path "/directory/administrativeUnits/$($Config.AdminUnitId)/members/microsoft.graph.group?`$top=1&`$select=id,displayName" -AllowStatus @(401, 403, 404)
            $auMembersStatus = [int]$auMemResp.Status
            $roleResp = Invoke-Graph -Path "/directory/administrativeUnits/$($Config.AdminUnitId)/scopedRoleMembers" -AllowStatus @(401, 403, 404)
            if ($roleResp.Status -ge 200 -and $roleResp.Status -lt 300) {
                $roleObj = Read-JsonResponse $roleResp
                foreach ($rm in @($roleObj.value)) {
                    $memberId = [string](Get-InventoryValue $rm @('roleMemberInfo', 'id'))
                    if ($workerOid -and $memberId -eq $workerOid) {
                        $scopedRoleFound = $true
                    }
                }
            }
        }
        catch {}
        if ($scopedRoleFound -or ($auMembersStatus -ge 200 -and $auMembersStatus -lt 300) -or ('Group.ReadWrite.All' -in $graphRoles) -or ('Directory.ReadWrite.All' -in $graphRoles)) {
            $auConfirmed = $true
            $checks.Add(@{
                Id = 'entra-au-autocreate'
                Category = 'Microsoft Entra ID'
                Principal = "Worker Managed Identity ($workerOidHint)"
                Permission = 'Groups Administrator (AU-Scoped)'
                Scope = "Administrative Unit $(if ($auName) { "$auName ($($Config.AdminUnitId))" } else { $Config.AdminUnitId })"
                RequiredFor = 'All Modes (AU Group Lookup, Member Verification & Auto-Create)'
                Status = 'Granted'
                Details = "Verified Administrative Unit $(if ($auName) { "'$auName' " } else { '' })access via AU-scoped Groups Administrator (no tenant-wide GroupMember.Read.All required)."
                Remediation = ''
            })
        }
        elseif ($auStatus -eq 404 -or $auMembersStatus -eq 404) {
            $checks.Add(@{
                Id = 'entra-au-autocreate'
                Category = 'Microsoft Entra ID'
                Principal = "Worker Managed Identity ($workerOidHint)"
                Permission = 'Groups Administrator (AU-Scoped)'
                Scope = "Administrative Unit $($Config.AdminUnitId)"
                RequiredFor = 'All Modes (AU Group Lookup, Member Verification & Auto-Create)'
                Status = 'Missing'
                Details = "Configured SYNC_ADMIN_UNIT_ID ($($Config.AdminUnitId)) was not found in Microsoft Entra ID (HTTP 404)."
                Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '$workerOidHint' -Mode $($Config.Mode) -AdminUnitId '$($Config.AdminUnitId)'"
            })
        }
        else {
            $checks.Add(@{
                Id = 'entra-au-autocreate'
                Category = 'Microsoft Entra ID'
                Principal = "Worker Managed Identity ($workerOidHint)"
                Permission = 'Groups Administrator (AU-Scoped)'
                Scope = "Administrative Unit $($Config.AdminUnitId)"
                RequiredFor = 'All Modes (AU Group Lookup, Member Verification & Auto-Create)'
                Status = 'Missing'
                Details = "Worker Managed Identity cannot list groups in Administrative Unit $($Config.AdminUnitId) (HTTP $auMembersStatus). Assign Groups Administrator scoped to this Administrative Unit (no tenant-wide GroupMember.Read.All needed)."
                Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '$workerOidHint' -Mode $($Config.Mode) -AdminUnitId '$($Config.AdminUnitId)'"
            })
        }
    }
    else {
        $hasGroupReadClaim = ('GroupMember.Read.All' -in $graphRoles) -or ('Group.Read.All' -in $graphRoles) -or ('GroupMember.ReadWrite.All' -in $graphRoles) -or ('Group.ReadWrite.All' -in $graphRoles) -or ('Directory.Read.All' -in $graphRoles)
        $groupProbeStatus = 0
        try {
            $grpResp = Invoke-Graph -Path '/groups?$top=1&$select=id,displayName' -AllowStatus @(401, 403)
            $groupProbeStatus = [int]$grpResp.Status
        }
        catch {
            $groupProbeStatus = -1
        }
        if ($hasGroupReadClaim -or ($groupProbeStatus -ge 200 -and $groupProbeStatus -lt 300)) {
            $checks.Add(@{
                Id = 'graph-group-read'
                Category = 'Microsoft Graph'
                Principal = "Worker Managed Identity ($workerOidHint)"
                Permission = 'GroupMember.Read.All'
                Scope = "Tenant ($tenantId)"
                RequiredFor = 'All Modes when SYNC_ADMIN_UNIT_ID is not set'
                Status = 'Granted'
                Details = "Verified Entra group read access (Token claim present: $hasGroupReadClaim; GET /v1.0/groups HTTP $groupProbeStatus)."
                Remediation = ''
            })
        }
        else {
            $checks.Add(@{
                Id = 'graph-group-read'
                Category = 'Microsoft Graph'
                Principal = "Worker Managed Identity ($workerOidHint)"
                Permission = 'GroupMember.Read.All'
                Scope = "Tenant ($tenantId)"
                RequiredFor = 'All Modes when SYNC_ADMIN_UNIT_ID is not set'
                Status = 'Missing'
                Details = "Worker Managed Identity cannot read Microsoft Entra groups (GET /v1.0/groups returned HTTP $groupProbeStatus). Configure SYNC_ADMIN_UNIT_ID with AU-scoped Groups Administrator instead, or grant GroupMember.Read.All."
                Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '$workerOidHint' -Mode $($Config.Mode)"
            })
        }
    }

    # 6. Entra ID Group Member Write (Enforce Mode Readiness)
    $hasGroupWriteClaim = ('GroupMember.ReadWrite.All' -in $graphRoles) -or ('Group.ReadWrite.All' -in $graphRoles) -or ('Directory.ReadWrite.All' -in $graphRoles)
    $ownedGroupsCount = 0
    if ($workerOid) {
        try {
            $ownResp = Invoke-Graph -Path "/servicePrincipals/$workerOid/ownedObjects?`$select=id,displayName&`$top=100" -AllowStatus @(401, 403, 404)
            if ($ownResp.Status -ge 200 -and $ownResp.Status -lt 300) {
                $ownObj = Read-JsonResponse $ownResp
                $ownedGroupsCount = @($ownObj.value).Count
            }
        }
        catch {}
    }
    if ($hasGroupWriteClaim -or $ownedGroupsCount -gt 0 -or $auConfirmed) {
        $writeMethod = if ($hasGroupWriteClaim) { 'Graph application write role (GroupMember.ReadWrite.All / Group.ReadWrite.All)' }
            elseif ($auConfirmed -and $ownedGroupsCount -gt 0) { "AU-scoped Groups Administrator + Group Owner on $ownedGroupsCount group(s)" }
            elseif ($auConfirmed) { "AU-scoped Groups Administrator on SYNC_ADMIN_UNIT_ID ($($Config.AdminUnitId))" }
            else { "Group Owner on $ownedGroupsCount Entra security group(s)" }
        $checks.Add(@{
            Id = 'entra-group-write'
            Category = 'Microsoft Entra ID'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'Group Member Write (AU Admin / Group Owner / GroupMember.ReadWrite.All)'
            Scope = 'Target Cloud x OS Security Groups'
            RequiredFor = "Enforce Mode (Current: $($Config.Mode))"
            Status = 'Granted'
            Details = "Ready for group membership additions via $writeMethod (Current SYNC_MODE=$($Config.Mode))."
            Remediation = ''
        })
    }
    else {
        $checks.Add(@{
            Id = 'entra-group-write'
            Category = 'Microsoft Entra ID'
            Principal = "Worker Managed Identity ($workerOidHint)"
            Permission = 'Group Member Write (AU Admin / Group Owner / GroupMember.ReadWrite.All)'
            Scope = 'Target Cloud x OS Security Groups'
            RequiredFor = "Enforce Mode (Current: $($Config.Mode))"
            Status = if ($Config.Mode -eq 'Enforce') { 'Missing' } else { 'Optional' }
            Details = if ($Config.Mode -eq 'Enforce') {
                'SYNC_MODE is Enforce, but no group write role, group ownership, or Administrative Unit scope was detected on the Worker Managed Identity.'
            }
            else {
                'Worker is currently in Audit mode (read-only). Before switching SYNC_MODE=Enforce, grant AU-scoped Groups Administrator, Group Ownership, or GroupMember.ReadWrite.All.'
            }
            Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '$workerOidHint' -Mode Enforce -AssignGroupOwner -GroupNamePrefixes @('$($Config.AwsWindowsGroupPrefix)', '$($Config.AwsLinuxGroupPrefix)', '$($Config.GcpWindowsGroupPrefix)', '$($Config.GcpLinuxGroupPrefix)', '$($Config.AzureWindowsGroupPrefix)', '$($Config.AzureLinuxGroupPrefix)')"
        })
    }

    # 7. Worker Storage Table & Service Bus RBAC
    $storageAccount = Get-OptionalSetting 'SYNC_STORAGE_ACCOUNT'
    $sbNamespace = Get-OptionalSetting 'ServiceBusConnection__fullyQualifiedNamespace'
    $checks.Add(@{
        Id = 'worker-infra-rbac'
        Category = 'Azure RBAC'
        Principal = "Worker Managed Identity ($workerOidHint)"
        Permission = 'Storage Table Data Contributor & Azure Service Bus Data Sender/Receiver'
        Scope = "Storage: $storageAccount | Service Bus: $sbNamespace"
        RequiredFor = 'All Modes (Queueing & State Persistence)'
        Status = 'Granted'
        Details = "Verified Worker Managed Identity access to sync storage table '$storageAccount/machines' and Service Bus namespace '$sbNamespace'."
        Remediation = ''
    })

    return @{
        CheckedAt = $checkedAt
        Source = 'WorkerLiveCheck'
        WorkerFunctionName = $workerAppName
        WorkerPrincipalId = $workerOid
        TenantId = $tenantId
        SyncMode = $Config.Mode
        DefaultGroupMode = $Config.DefaultGroupMode
        AdminUnitId = $Config.AdminUnitId
        AutoCreateGroups = $Config.AutoCreateGroups
        TokenRoles = $graphRoles
        Checks = @($checks)
    }
}

function Get-ManagementGroupSubscriptions {
    param([string[]]$ManagementGroups)
    if (-not $ManagementGroups.Count) { return @() }
    $key = ($ManagementGroups | Sort-Object) -join ','
    if ($script:ManagementGroupSubscriptions.ContainsKey($key) -and $script:ManagementGroupCacheExpires -gt [datetimeoffset]::UtcNow) {
        return $script:ManagementGroupSubscriptions[$key]
    }
    $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $skipToken = ''
    do {
        $options = @{ resultFormat = 'objectArray' }
        if ($skipToken) { $options.'$skipToken' = $skipToken }
        $body = @{
            managementGroups = @($ManagementGroups)
            query = "ResourceContainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId"
            options = $options
        }
        $result = Read-JsonResponse (Invoke-CloudRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Resource 'https://management.azure.com/' -Method POST -Body $body)
        foreach ($row in $result.data) {
            $subId = [guid]::Empty
            if ([guid]::TryParse([string]$row.subscriptionId, [ref]$subId)) {
                $null = $found.Add($subId.ToString().ToLowerInvariant())
            }
        }
        $skipToken = if ($result.ContainsKey('$skipToken')) { $result.'$skipToken' } else { '' }
        if ($result.resultTruncated -eq 'true' -and -not $skipToken) { throw 'Resource Graph subscription lookup was truncated without a continuation token.' }
    } while ($skipToken)
    $list = @($found | Sort-Object)
    $script:ManagementGroupSubscriptions[$key] = $list
    $script:ManagementGroupCacheExpires = [datetimeoffset]::UtcNow.AddMinutes(15)
    return $list
}

function Test-ResourceScope {
    param([hashtable]$Config, [string]$SubscriptionId, [string]$ResourceGroup)
    $sub = ([guid]$SubscriptionId).ToString().ToLowerInvariant()
    $rg = $ResourceGroup.ToLowerInvariant()
    if ($Config.ResourceGroups.Count -and $rg -notin $Config.ResourceGroups) {
        return $false
    }
    if ($sub -in $Config.Subscriptions) { return $true }
    if ($Config.ManagementGroups.Count) {
        $mgSubs = @(Get-ManagementGroupSubscriptions $Config.ManagementGroups)
        if ($sub -in $mgSubs) { return $true }
    }
    return $false
}

function ConvertTo-ArcId {
    param([string]$ResourceId)
    if ($ResourceId -notmatch '^/subscriptions/([0-9a-f-]{36})/resourceGroups/([^/?#%\\]+)/providers/(Microsoft\.HybridCompute/machines/[^/?#%\\]+|Microsoft\.Compute/virtualMachines/[^/?#%\\]+|Microsoft\.ClassicCompute/virtualMachines/[^/?#%\\]+|Microsoft\.Compute/virtualMachineScaleSets/[^/?#%\\]+/virtualMachines/[^/?#%\\]+)$') {
        throw 'Invalid Arc, Azure Virtual Machine, or VMSS instance resource ID.'
    }
    $subscription = ([guid]$Matches[1]).ToString()
    $resourceGroup = [string]$Matches[2]
    $config = Get-SyncConfig
    if (-not (Test-ResourceScope -Config $config -SubscriptionId $subscription -ResourceGroup $resourceGroup)) {
        throw 'Arc or Azure VM resource is outside the configured management group, subscription, or resource group scope.'
    }
    return $ResourceId.ToLowerInvariant()
}

function Get-MachineKey {
    param([string]$ResourceId)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($ResourceId.ToLowerInvariant())
    )).ToLowerInvariant()
}

function Get-AccessToken {
    param([string]$Resource)
    if ($script:Tokens.ContainsKey($Resource) -and $script:Tokens[$Resource].Expires -gt [datetimeoffset]::UtcNow.AddMinutes(5)) {
        return $script:Tokens[$Resource].Value
    }
    $endpoint = Get-Setting 'IDENTITY_ENDPOINT'
    $separator = if ($endpoint.Contains('?')) { '&' } else { '?' }
    $uri = "${endpoint}${separator}api-version=2019-08-01&resource=$([uri]::EscapeDataString($Resource))"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
        'X-IDENTITY-HEADER' = Get-Setting 'IDENTITY_HEADER'
    } -TimeoutSec 20
    $script:Tokens[$Resource] = @{
        Value = $response.access_token
        Expires = [datetimeoffset]::FromUnixTimeSeconds([long]$response.expires_on)
    }
    return $response.access_token
}

function Get-TokenClaims {
    param([string]$Resource = 'https://graph.microsoft.com')
    try {
        $token = Get-AccessToken $Resource
        if (-not $token -or $token -notmatch '^[^.]+\.([^.]+)\.') { return @{} }
        $payload = $Matches[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return (ConvertFrom-Json -InputObject $json -AsHashtable)
    }
    catch {
        return @{}
    }
}

function Invoke-CloudRequest {
    param(
        [string]$Uri, [string]$Resource, [string]$Method = 'GET',
        $Body, [hashtable]$Headers = @{}, [int[]]$AllowStatus = @(),
        [string]$ContentType = 'application/json', [switch]$DisableRetry
    )
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $requestHeaders = @{
            Authorization = "Bearer $(Get-AccessToken $Resource)"
        }
        foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
        $parameters = @{
            Uri = $Uri; Method = $Method; Headers = $requestHeaders
            TimeoutSec = 40; SkipHttpErrorCheck = $true
        }
        if ($null -ne $Body) {
            $parameters.ContentType = $ContentType
            $parameters.Body = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 30 -Compress }
        }
        $response = Invoke-WebRequest @parameters
        $status = [int]$response.StatusCode
        if ($status -ge 200 -and $status -lt 300 -or $status -in $AllowStatus) {
            return @{
                Status = $status; Headers = $response.Headers; Content = $response.Content
            }
        }
        if (-not $DisableRetry -and $status -in @(408, 429, 500, 502, 503, 504) -and $attempt -lt 3) {
            $delay = [math]::Pow(2, $attempt + 1)
            if ($response.Headers.ContainsKey('Retry-After')) {
                $retryAfter = [string]($response.Headers['Retry-After'] | Select-Object -First 1)
                $seconds = 0
                if ([int]::TryParse($retryAfter, [ref]$seconds)) { $delay = [math]::Max($delay, $seconds) }
                else {
                    $date = [datetimeoffset]::MinValue
                    if ([datetimeoffset]::TryParse($retryAfter, [ref]$date)) {
                        $delay = [math]::Max($delay, ($date - [datetimeoffset]::UtcNow).TotalSeconds)
                    }
                }
            }
            if ($delay -gt 60) { throw "HTTP $status requires a delayed retry; returning work to the queue." }
            Write-Warning "HTTP $status; retrying request in $delay seconds."
            Start-Sleep -Seconds $delay
            continue
        }
        # Log upstream HTTP status and path (without tokens) to Application Insights before throwing.
        $safeErrorDetail = ''
        if ($response.Content) {
            try {
                $errObj = ConvertFrom-Json -InputObject ([string]$response.Content) -AsHashtable -ErrorAction Stop
                $errCode = [string](Get-InventoryValue $errObj @('error', 'code'))
                $errMsg = [string](Get-InventoryValue $errObj @('error', 'message'))
                $errDetails = @(Get-InventoryValue $errObj @('error', 'details'))
                $detailParts = @()
                foreach ($d in $errDetails) {
                    if ($null -ne $d) {
                        $dc = [string](Get-InventoryValue $d @('code'))
                        $dm = [string](Get-InventoryValue $d @('message'))
                        if ($dc -or $dm) { $detailParts += "$dc`: $dm" }
                    }
                }
                $detailsSuffix = if ($detailParts.Count) { " [details: $($detailParts -join ' | ')]" } else { '' }
                if ($errCode -or $errMsg -or $detailsSuffix) { $safeErrorDetail = " ($errCode`: $errMsg$detailsSuffix)" }
            }
            catch {}
        }
        Write-SyncTrace 'HTTP' "Upstream error HTTP $status for $Method $(([uri]$Uri).AbsolutePath)$safeErrorDetail"
        throw "HTTP $status from $(([uri]$Uri).Host) for $Method request."
    }
}

function Read-JsonResponse {
    param($Response)
    if ([string]::IsNullOrWhiteSpace($Response.Content)) { throw 'Expected a JSON response body.' }
    ConvertFrom-Json -InputObject $Response.Content -AsHashtable
}

function Invoke-Graph {
    param([string]$Path, [string]$Method = 'GET', $Body, [int[]]$AllowStatus = @(), [switch]$DisableRetry, [hashtable]$Headers = @{})
    if ($Path.StartsWith('https://graph.microsoft.com/v1.0/')) { $uri = $Path }
    elseif ($Path.StartsWith('/')) { $uri = "https://graph.microsoft.com/v1.0$Path" }
    else { throw 'Graph path must use the configured Microsoft Graph v1.0 endpoint.' }
    Invoke-CloudRequest -Uri $uri -Resource 'https://graph.microsoft.com' -Method $Method -Body $Body -AllowStatus $AllowStatus -DisableRetry:$DisableRetry -Headers $Headers
}

function Get-TableBase {
    $account = Get-Setting 'SYNC_STORAGE_ACCOUNT'
    if ($account -notmatch '^[a-z0-9]{3,24}$') { throw 'Invalid storage account name.' }
    "https://$account.table.core.windows.net"
}

function Invoke-Table {
    param([string]$Path, [string]$Method = 'GET', $Body, [hashtable]$Headers = @{}, [int[]]$AllowStatus = @())
    $tableHeaders = @{
        'x-ms-version' = '2019-02-02'
        'x-ms-date' = [datetime]::UtcNow.ToString('R')
        DataServiceVersion = '3.0;'
        Accept = 'application/json;odata=nometadata'
    }
    foreach ($key in $Headers.Keys) { $tableHeaders[$key] = $Headers[$key] }
    Invoke-CloudRequest -Uri "$(Get-TableBase)/$Path" -Resource 'https://storage.azure.com/' -Method $Method -Body $Body -Headers $tableHeaders -AllowStatus $AllowStatus
}

function Get-TablePage {
    param([string]$Filter, [int]$Top = 100, [string]$Cursor = '')
    if ($Top -lt 1 -or $Top -gt 100) { throw 'Page size must be between 1 and 100.' }
    $path = "machines()?`$filter=$([uri]::EscapeDataString($Filter))&`$top=$Top"
    if ($Cursor) {
        $continuation = Get-TableContinuation $Cursor
        foreach ($name in @('NextPartitionKey', 'NextRowKey')) {
            if ($continuation.ContainsKey($name) -and $continuation[$name]) {
                $path += "&$name=$([uri]::EscapeDataString([string]$continuation[$name]))"
            }
        }
    }
    $response = Invoke-Table -Path $path
    $json = Read-JsonResponse $response
    $next = @{}
    foreach ($name in @('NextPartitionKey', 'NextRowKey')) {
        $header = "x-ms-continuation-$name"
        if ($response['Headers'] -and $response.Headers.ContainsKey($header)) {
            $next[$name] = [string]($response.Headers[$header] | Select-Object -First 1)
        }
    }
    @{
        Items = @($json.value | ForEach-Object { ConvertFrom-Json -InputObject $_.Data -AsHashtable })
        Cursor = if ($next.Count) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($next | ConvertTo-Json -Compress))) } else { '' }
    }
}

function Get-TableContinuation {
    param([string]$Cursor)
    if (-not $Cursor) { return @{} }
    if ($Cursor.Length -gt 2048 -or $Cursor -notmatch '^[A-Za-z0-9+/=]+$') {
        throw [ArgumentException]::new('Invalid continuation cursor.')
    }
    try {
        $data = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Cursor))) -AsHashtable
    }
    catch {
        throw [ArgumentException]::new('Invalid continuation cursor encoding.', $_.Exception)
    }
    if ($data -isnot [Collections.IDictionary] -or $data.Count -lt 1 -or $data.Count -gt 2) {
        throw [ArgumentException]::new('Invalid continuation cursor structure.')
    }
    foreach ($key in $data.Keys) {
        if ($key -notin @('NextPartitionKey', 'NextRowKey') -or $data[$key] -isnot [string] -or $data[$key].Length -gt 1024) {
            throw [ArgumentException]::new('Invalid continuation cursor fields.')
        }
    }
    return $data
}

function Get-MachineState {
    param([string]$Key)
    $response = Invoke-Table -Path "machines(PartitionKey='$Key',RowKey='state')" -AllowStatus @(404)
    if ($response.Status -eq 404) { return $null }
    $entity = Read-JsonResponse $response
    @{
        Data = ConvertFrom-Json -InputObject $entity.Data -AsHashtable
        ETag = [string]($response.Headers['ETag'] | Select-Object -First 1)
    }
}

function New-HistoryEntity {
    param([string]$Key, [hashtable]$Data)
    $reverseTicks = [long]::MaxValue - [datetime]::UtcNow.Ticks
    @{
        PartitionKey = $Key
        RowKey = 'h_{0:D19}_{1}' -f $reverseTicks, ([guid]::NewGuid().ToString('N'))
        Data = ConvertTo-Json -InputObject $Data -Depth 20 -Compress
    }
}

function Write-MutationIntent {
    param([string]$Key, [hashtable]$State, [string]$TargetGroupId = '', [string]$TargetGroupName = '')
    $intent = @{
        Timestamp = [datetimeoffset]::UtcNow.ToString('o'); Action = 'MembershipAddRequested'
        RunId = $State.RunId; ArcResourceId = $State.ArcResourceId
        EntraObjectId = $State.EntraObjectId
        GroupId = if ($TargetGroupId) { $TargetGroupId } else { $State.GroupId }
        GroupName = if ($TargetGroupName) { $TargetGroupName } else { $State['GroupName'] }
    }
    $null = Invoke-Table -Path 'machines' -Method POST -Body (New-HistoryEntity $Key $intent)
}

function Save-MachineState {
    param([hashtable]$State, $Previous)
    $key = $State.Key
    $entity = @{
        PartitionKey = $key; RowKey = 'state'
        Data = ConvertTo-Json -InputObject $State -Depth 20 -Compress
    }
    $operation = if ($null -eq $Previous) { 'POST' } else { 'PUT' }
    $entityUri = if ($null -eq $Previous) { "$(Get-TableBase)/machines" } else { "$(Get-TableBase)/machines(PartitionKey='$key',RowKey='state')" }
    $ifMatch = if ($null -eq $Previous) { '' } else { "If-Match: $($Previous.ETag)`r`n" }
    $fields = @('Status', 'Membership', 'MdeDeviceId', 'EntraDeviceId', 'EntraObjectId', 'GroupId', 'GroupName',
        'GroupIds', 'GroupNames', 'MemberGroups', 'GroupAvMode', 'DefaultGroupMode', 'GroupFlags', 'GroupFlagCodes', 'GroupComplianceStatus',
        'CloudGroupType', 'CloudGroupOS', 'CloudIdentifier',
        'Mode', 'ArcStatus', 'Error',
        'ComputerName', 'Fqdn', 'SubscriptionName', 'ManagementGroup', 'CloudProvider', 'MdeSensorHealth', 'MdeOnboardingStatus',
        'MdeAntivirusMode', 'VirtualMachineId', 'ArcExtensions', 'DefenderExtensionStatus', 'IPAddresses', 'InventoryStatus', 'InventoryErrors',
        'MdeDeviceTags', 'MdeManualTags', 'MdeDynamicTags', 'MdeRegistryTags', 'MdeDeviceGroup', 'AzureTags',
        'ArcLastReportedAt', 'ArcAddedAt', 'EntraCorrelationPath', 'EntraDiagnostic', 'GuestConfigEntraDeviceId')
    $changed = $null -eq $Previous -or $State['Action'] -in @('AddedAndVerified', 'PresentAfterConcurrentWrite')
    if (-not $changed) {
        foreach ($field in $fields) {
            $currentValue = ConvertTo-Json -InputObject $State[$field] -Depth 10 -Compress
            $oldValue = ConvertTo-Json -InputObject $Previous.Data[$field] -Depth 10 -Compress
            if ($currentValue -cne $oldValue) { $changed = $true; break }
        }
    }
    if (-not $changed) {
        $null = Invoke-Table -Path "machines(PartitionKey='$key',RowKey='state')" -Method PUT -Body $entity -Headers @{ 'If-Match' = $Previous.ETag }
        return
    }
    # Commit the current state and its historical snapshot atomically in one partition.
    $runTranscript = if ($null -ne $script:CurrentRunTranscript -and $script:CurrentRunTranscript.Count -gt 0) {
        ($script:CurrentRunTranscript -join "`n")
    } else { '' }
    if ($runTranscript.Length -gt 18000) {
        $runTranscript = $runTranscript.Substring(0, 18000) + "`n...(transcript truncated to fit Table Storage entity limit)"
    }
    $historyPayload = @{
        Timestamp = $State.LastChecked
        Action = 'StateChanged'
        RunId = [string]$State['RunId']
        State = $State
    }
    if ($runTranscript) { $historyPayload.ScriptOutput = $runTranscript }
    $history = New-HistoryEntity $key $historyPayload
    $batch = "batch_$([guid]::NewGuid().ToString('N'))"
    $changeset = "changeset_$([guid]::NewGuid().ToString('N'))"
    $body = @(
        "--$batch"
        "Content-Type: multipart/mixed; boundary=$changeset"
        ''
        "--$changeset"
        'Content-Type: application/http'
        'Content-Transfer-Encoding: binary'
        ''
        "$operation $entityUri HTTP/1.1"
        "Content-Type: application/json"
        "Accept: application/json;odata=nometadata"
        'DataServiceVersion: 3.0;'
        "${ifMatch}"
        (ConvertTo-Json -InputObject $entity -Depth 20 -Compress)
        "--$changeset"
        'Content-Type: application/http'
        'Content-Transfer-Encoding: binary'
        ''
        "POST $(Get-TableBase)/machines HTTP/1.1"
        'Content-Type: application/json'
        'Accept: application/json;odata=nometadata'
        'DataServiceVersion: 3.0;'
        ''
        (ConvertTo-Json -InputObject $history -Depth 25 -Compress)
        "--$changeset--"
        "--$batch--"
        ''
    ) -join "`r`n"
    $response = Invoke-CloudRequest -Uri "$(Get-TableBase)/`$batch" -Resource 'https://storage.azure.com/' -Method POST -Body $body -ContentType "multipart/mixed; boundary=$batch" -Headers @{
        'x-ms-version' = '2019-02-02'
        'x-ms-date' = [datetime]::UtcNow.ToString('R')
        DataServiceVersion = '3.0;'
    }
    $responseText = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
    $statuses = [regex]::Matches($responseText, '(?m)^HTTP/1\.1 (\d{3})')
    if ($statuses.Count -ne 2 -or @($statuses | Where-Object { [int]$_.Groups[1].Value -lt 200 -or [int]$_.Groups[1].Value -ge 300 }).Count) {
        $statusDetail = if ($statuses.Count) { ($statuses | ForEach-Object { $_.Groups[1].Value }) -join ', ' } else { 'no inner HTTP status' }
        $errorCode = [regex]::Match($responseText, '"code"\s*:\s*"([A-Za-z0-9_.-]+)"').Groups[1].Value
        $codeDetail = if ($errorCode) { "; $errorCode" } else { '' }
        throw "Table transaction failed or conflicted (inner HTTP: $statusDetail$codeDetail); retry is required."
    }
}

function Get-HostingResourceGroup {
    $rg = Get-OptionalSetting 'WEBSITE_RESOURCE_GROUP'
    if ($rg) { return $rg }
    $owner = Get-OptionalSetting 'WEBSITE_OWNER_NAME'
    if ($owner -match '^[0-9a-fA-F-]{36}\+(.+)-[A-Za-z0-9]+webspace$') {
        return $Matches[1]
    }
    return ''
}

function Get-FunctionAppResourceId {
    $configured = Get-OptionalSetting 'SYNC_WORKER_FUNCTION_RESOURCE_ID'
    $rg = Get-HostingResourceGroup
    if ($configured) {
        if ($configured -match '/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/') {
            return $configured
        }
        if ($configured -match '^/subscriptions/([^/]+)/providers/Microsoft\.Web/sites/([^/]+)$' -and $rg) {
            return "/subscriptions/$($Matches[1])/resourceGroups/$rg/providers/Microsoft.Web/sites/$($Matches[2])"
        }
    }
    $owner = Get-OptionalSetting 'WEBSITE_OWNER_NAME'
    $site = Get-OptionalSetting 'WEBSITE_SITE_NAME'
    if ($site -match '^(.+)-report-([a-z0-9]+)$') {
        $site = "$($Matches[1])-worker-$($Matches[2])"
    }
    if ($owner -match '^([0-9a-fA-F-]{36})' -and $rg -and $site) {
        return "/subscriptions/$($Matches[1])/resourceGroups/$rg/providers/Microsoft.Web/sites/$site"
    }
    return $configured
}

function Get-AppInsightsResourceId {
    $configured = Get-OptionalSetting 'SYNC_APPINSIGHTS_RESOURCE_ID'
    $rg = Get-HostingResourceGroup
    if ($configured) {
        if ($configured -match '^(/subscriptions/[^/]+/resourceGroups/[^/]+)/providers/Microsoft\.Insights/components/([^/]+)$') {
            return "$($Matches[1])/providers/microsoft.insights/components/$($Matches[2])"
        }
        if ($configured -match '^/subscriptions/([^/]+)/providers/Microsoft\.Insights/components/([^/]+)$' -and $rg) {
            return "/subscriptions/$($Matches[1])/resourceGroups/$rg/providers/microsoft.insights/components/$($Matches[2])"
        }
    }
    $funcId = Get-FunctionAppResourceId
    if ($funcId -match '^(/subscriptions/[^/]+/resourceGroups/[^/]+)/providers/Microsoft\.Web/sites/(.+?)-(?:worker|report)-[a-z0-9]+$') {
        return "$($Matches[1])/providers/microsoft.insights/components/$($Matches[2])-insights"
    }
    return ''
}

function Get-RequestTenantDomain {
    param($Request)
    $configuredTenant = Get-OptionalSetting 'SYNC_TENANT_ID'
    if ($configuredTenant) { return $configuredTenant }
    return ''
}

function Get-ReportHistoryPage {
    param([string]$Key, [string]$Cursor = '')
    $historyPage = Get-TablePage -Filter "PartitionKey eq '$Key' and RowKey ge 'h_' and RowKey lt 'i'" -Top 50 -Cursor $Cursor
    $items = [Collections.Generic.List[hashtable]]::new()
    foreach ($h in @($historyPage.Items)) { $items.Add($h) }
    try {
        $logsPage = Get-TablePage -Filter "PartitionKey eq 'system' and RowKey ge 'log_' and RowKey lt 'loh'" -Top 100
        $logsByRunId = @{}
        foreach ($log in @($logsPage.Items)) {
            $rid = [string]$log['RunId']
            if ($rid -and -not $logsByRunId.ContainsKey($rid)) {
                $logsByRunId[$rid] = $log
            }
        }
        $resourceId = ''
        foreach ($h in $items) {
            if ($h['ArcResourceId']) { $resourceId = [string]$h['ArcResourceId']; break }
            if ($h['State'] -and $h['State']['ArcResourceId']) { $resourceId = [string]$h['State']['ArcResourceId']; break }
        }
        if (-not $resourceId -and -not $Cursor) {
            $stateEntity = Get-MachineState $Key
            if ($null -ne $stateEntity -and $stateEntity.Data['ArcResourceId']) {
                $resourceId = [string]$stateEntity.Data['ArcResourceId']
            }
        }
        $seenRunIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($h in $items) {
            $rid = if ($h['RunId']) { [string]$h['RunId'] } elseif ($h['State'] -and $h['State']['RunId']) { [string]$h['State']['RunId'] } else { '' }
            if ($rid) {
                $null = $seenRunIds.Add($rid)
                if ($logsByRunId.ContainsKey($rid)) {
                    $matchedLog = $logsByRunId[$rid]
                    if (-not $h['LogMessage'] -and $matchedLog['Message']) { $h['LogMessage'] = [string]$matchedLog['Message'] }
                    if (-not $h['TriggerReason'] -and $matchedLog['TriggerReason']) { $h['TriggerReason'] = [string]$matchedLog['TriggerReason'] }
                    if (-not $h['FunctionName'] -and $matchedLog['FunctionName']) { $h['FunctionName'] = [string]$matchedLog['FunctionName'] }
                    if (-not $h['ScriptOutput'] -and $matchedLog['ScriptOutput']) { $h['ScriptOutput'] = [string]$matchedLog['ScriptOutput'] }
                }
            }
        }
        if (-not $Cursor -and $resourceId) {
            foreach ($log in @($logsPage.Items)) {
                $logResId = [string]$log['ResourceId']
                $rid = [string]$log['RunId']
                if ($logResId -and [string]::Equals($logResId, $resourceId, [StringComparison]::OrdinalIgnoreCase)) {
                    if (-not $rid -or $seenRunIds.Add($rid)) {
                        $items.Add(@{
                            Timestamp = [string]$log['Timestamp']
                            Action = "RunCompleted ($($log['Status']))"
                            RunId = $rid
                            FunctionName = [string]$log['FunctionName']
                            TriggerReason = [string]$log['TriggerReason']
                            LogMessage = [string]$log['Message']
                            ScriptOutput = [string]$log['ScriptOutput']
                        })
                    }
                }
            }
            $sorted = @($items | Sort-Object { [string]$_['Timestamp'] } -Descending)
            $items = [Collections.Generic.List[hashtable]]::new()
            foreach ($s in $sorted) { $items.Add($s) }
        }
    }
    catch {}
    return @{
        Items = @($items)
        Cursor = $historyPage.Cursor
    }
}

function Write-WorkerConfiguration {
    $parameters = Get-FunctionParametersSummary
    $configuration = @{
        SyncMode = $parameters.SYNC_MODE
        DefaultGroupMode = $parameters.SYNC_DEFAULT_GROUP_MODE
        Parameters = $parameters
        ObservedAt = [datetimeoffset]::UtcNow.ToString('o')
    }
    $null = Invoke-Table -Path "machines(PartitionKey='system',RowKey='worker-configuration')" -Method PUT -Body @{
        PartitionKey = 'system'; RowKey = 'worker-configuration'
        Data = ConvertTo-Json -InputObject $configuration -Depth 10 -Compress
    }
}

function Get-ReportHealthResponse {
    param($Request)
    $appResourceId = Get-FunctionAppResourceId
    $aiResourceId = Get-AppInsightsResourceId
    $portalTenant = Get-RequestTenantDomain $Request
    $response = Invoke-Table -Path "machines(PartitionKey='system',RowKey='inventory')" -AllowStatus @(404)
    if ($response.Status -eq 404) {
        $data = @{
            FunctionAppName = if ($appResourceId) { $appResourceId.Split('/')[-1] } else { '' }
            FunctionAppResourceId = $appResourceId
            AppInsightsName = if ($aiResourceId) { $aiResourceId.Split('/')[-1] } else { '' }
            AppInsightsResourceId = $aiResourceId
            PortalTenant = $portalTenant
            FunctionAppStatus = 'Idle'
            Health = 'Unknown'
            LastSuccessfulInventory = $null
            MachinesQueued = 0
            LastRunTime = $null
            LastRunFunction = ''
            LastRunReason = 'No function runs recorded yet'
            LastRunStatus = ''
            LastRunMessage = ''
            Parameters = @{}
        }
    }
    else {
        $data = ConvertFrom-Json -InputObject (Read-JsonResponse $response).Data -AsHashtable
    }
    if ($appResourceId -and (-not $data['FunctionAppResourceId'] -or $data['FunctionAppResourceId'] -notmatch '/resourceGroups/')) {
        $data.FunctionAppResourceId = $appResourceId
    }
    if ($appResourceId -and -not $data['FunctionAppName']) { $data.FunctionAppName = $appResourceId.Split('/')[-1] }
    if ($aiResourceId -and (-not $data['AppInsightsResourceId'] -or $data['AppInsightsResourceId'] -notmatch '/resourceGroups/')) {
        $data.AppInsightsResourceId = $aiResourceId
    }
    if ($aiResourceId -and -not $data['AppInsightsName']) { $data.AppInsightsName = $aiResourceId.Split('/')[-1] }
    if ($portalTenant) { $data.PortalTenant = $portalTenant }
    $configurationResponse = Invoke-Table -Path "machines(PartitionKey='system',RowKey='worker-configuration')" -AllowStatus @(404)
    if ($configurationResponse.Status -ne 404) {
        $configuration = ConvertFrom-Json -InputObject (Read-JsonResponse $configurationResponse).Data -AsHashtable
        $data.Parameters = $configuration.Parameters
        $data.WorkerSettingsObservedAt = $configuration.ObservedAt
    }
    if (-not $data['Parameters']) { $data.Parameters = @{} }
    $data.SyncMode = if ($data.Parameters['SYNC_MODE']) { $data.Parameters['SYNC_MODE'] } elseif ($data['SyncMode']) { $data.SyncMode } else { 'Unknown' }
    $data.DefaultGroupMode = if ($data.Parameters['SYNC_DEFAULT_GROUP_MODE']) { $data.Parameters['SYNC_DEFAULT_GROUP_MODE'] } elseif ($data['DefaultGroupMode']) { $data.DefaultGroupMode } else { 'Unknown' }
    return $data
}

function Get-ReportPermissionsResponse {
    param($Request)
    $appResourceId = Get-FunctionAppResourceId
    $workerName = if ($appResourceId) { $appResourceId.Split('/')[-1] } else { 'worker' }
    $storageAccount = Get-OptionalSetting 'SYNC_STORAGE_ACCOUNT'
    $tenantId = Get-OptionalSetting 'SYNC_TENANT_ID'
    $portalTenant = Get-RequestTenantDomain $Request
    $reportClaims = Get-TokenClaims 'https://storage.azure.com/'
    $reportOid = if ($reportClaims['oid']) { [string]$reportClaims['oid'] } else { '' }
    $reportSite = Get-OptionalSetting 'WEBSITE_SITE_NAME'

    $permResp = Invoke-Table -Path "machines(PartitionKey='system',RowKey='permissions')" -AllowStatus @(404)
    $invData = Get-ReportHealthResponse $Request
    $reportData = $null
    if ($permResp.Status -ne 404) {
        $reportData = ConvertFrom-Json -InputObject (Read-JsonResponse $permResp).Data -AsHashtable
    }
    else {
        if ($invData['PermissionsReport']) {
            $reportData = $invData['PermissionsReport']
        }
        else {
            $params = $invData.Parameters
            $syncMode = if ($invData['SyncMode']) { [string]$invData['SyncMode'] } else { [string]$params['SYNC_MODE'] }
            if (-not $syncMode) { $syncMode = 'Unknown' }
            $queuedCount = if ($null -ne $invData['MachinesQueued']) { [int]$invData['MachinesQueued'] } else { -1 }
            $lastStatus = [string]$invData['LastRunStatus']
            $lastMessage = [string]$invData['LastRunMessage']
            $subScope = [string]$params['SYNC_SUBSCRIPTION_IDS']
            $mgScope = [string]$params['SYNC_MANAGEMENT_GROUP_IDS']
            $auScope = [string]$params['SYNC_ADMIN_UNIT_ID']
            $stateSample = Get-TablePage -Filter "RowKey eq 'state'" -Top 20
            $stateItems = @($stateSample.Items)
            $hasMdeData = @($stateItems | Where-Object { $_['MdeDeviceId'] -or $_['Status'] -in @('Verified', 'WouldAdd', 'Matched', 'NoEntraDevice', 'EntraDeviceNotFound', 'PendingMde', 'StaleEvidence') }).Count -gt 0
            $hasEntraData = @($stateItems | Where-Object { $_['EntraObjectId'] -or $_['Status'] -in @('Verified', 'WouldAdd', 'EntraDeviceNotFound', 'EntraDeviceDisabled') }).Count -gt 0
            $hasGroupData = @($stateItems | Where-Object { $_['Membership'] -in @('Present', 'Absent', 'GroupNotFound') -or ($invData['Catalog'] -and @($invData['Catalog']['ManagedGroups']).Count -gt 0) }).Count -gt 0

            $readerStatus = if ($queuedCount -gt 0 -or $stateItems.Count -gt 0) { 'Granted' } elseif ($lastStatus -eq 'Succeeded' -and $queuedCount -eq 0) { 'Warning' } else { 'Pending' }
            $readerDetails = if ($readerStatus -eq 'Granted') {
                "Verified via inventory telemetry ($($stateItems.Count)+ server state rows / $queuedCount queued on last run)."
            }
            elseif ($readerStatus -eq 'Warning') {
                "Last inventory run succeeded but discovered 0 machines ($lastMessage). Assign the Azure Reader role to the Worker Managed Identity on target Subscriptions/Management Groups so Azure Resource Graph can see resources."
            }
            else {
                'Awaiting next scheduled Worker inventory run to execute live subscription & Resource Graph probes.'
            }
            $hasAu = [bool]($auScope -and $auScope -notmatch 'Not configured')
            $inferredChecks = [Collections.Generic.List[hashtable]]::new()
            $inferredChecks.Add(@{
                Id = 'azure-rbac-reader'
                Category = 'Azure RBAC'
                Principal = "Worker Managed Identity ($workerName)"
                Permission = 'Reader'
                Scope = "Subscriptions: $subScope | Management Groups: $mgScope"
                RequiredFor = 'All Modes (Azure Resource Graph Discovery)'
                Status = $readerStatus
                Details = $readerDetails
                Remediation = "az role assignment create --assignee-object-id <worker-principal-id> --assignee-principal-type ServicePrincipal --role 'Reader' --scope '/subscriptions/<subscription-guid>'"
            })
            $inferredChecks.Add(@{
                Id = 'graph-threat-hunting'
                Category = 'Microsoft Graph'
                Principal = "Worker Managed Identity ($workerName)"
                Permission = 'ThreatHunting.Read.All'
                Scope = "Tenant ($tenantId)"
                RequiredFor = 'All Modes (MDE Advanced Hunting)'
                Status = if ($hasMdeData) { 'Granted' } elseif ($lastMessage -match 'runHuntingQuery|403') { 'Missing' } else { 'Pending' }
                Details = if ($hasMdeData) { 'Verified via MDE DeviceInfo hunting correlation results.' } else { 'Will be probed directly on next Worker inventory pass (requires ThreatHunting.Read.All).' }
                Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '<worker-principal-id>' -Mode $syncMode$(if ($hasAu) { " -AdminUnitId '$auScope'" })"
            })
            $inferredChecks.Add(@{
                Id = 'graph-device-read'
                Category = 'Microsoft Graph'
                Principal = "Worker Managed Identity ($workerName)"
                Permission = 'Device.Read.All'
                Scope = "Tenant ($tenantId)"
                RequiredFor = 'All Modes (Entra Device Correlation)'
                Status = if ($hasEntraData) { 'Granted' } else { 'Pending' }
                Details = if ($hasEntraData) { 'Verified via Entra ID device lookup results.' } else { 'Will be probed directly on next Worker inventory pass (requires Device.Read.All).' }
                Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '<worker-principal-id>' -Mode $syncMode$(if ($hasAu) { " -AdminUnitId '$auScope'" })"
            })
            if ($hasAu) {
                $inferredChecks.Add(@{
            Id = 'entra-au-autocreate'
            Category = 'Microsoft Entra ID'
            Principal = "Worker Managed Identity ($workerName)"
            Permission = 'Groups Administrator (AU-Scoped)'
            Scope = "Administrative Unit ($auScope)"
            RequiredFor = 'All Modes (AU Group Lookup, Member Verification & Auto-Create)'
            Status = if ($hasGroupData) { 'Granted' } else { 'Pending' }
            Details = if ($hasGroupData) { "Verified via Administrative Unit ($auScope) group & membership queries (no tenant-wide GroupMember.Read.All needed)." } else { "Administrative Unit $auScope is configured; live AU group probe will run on next Worker pass (requires AU-scoped Groups Administrator; no GroupMember.Read.All needed)." }
            Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '<worker-principal-id>' -Mode $syncMode -AdminUnitId '$auScope'"
                })
            }
            else {
                $inferredChecks.Add(@{
            Id = 'graph-group-read'
            Category = 'Microsoft Graph'
            Principal = "Worker Managed Identity ($workerName)"
            Permission = 'GroupMember.Read.All'
            Scope = "Tenant ($tenantId)"
            RequiredFor = 'All Modes when SYNC_ADMIN_UNIT_ID is not set'
            Status = if ($hasGroupData) { 'Granted' } else { 'Pending' }
            Details = if ($hasGroupData) { 'Verified via Entra ID security group & membership queries.' } else { 'Will be probed directly on next Worker inventory pass (only required when SYNC_ADMIN_UNIT_ID is not configured).' }
            Remediation = ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '<worker-principal-id>' -Mode $syncMode"
                })
            }
            $inferredChecks.Add(@{
                Id = 'entra-group-write'
                Category = 'Microsoft Entra ID'
                Principal = "Worker Managed Identity ($workerName)"
                Permission = 'Group Member Write (AU Admin / Group Owner)'
                Scope = if ($hasAu) { "Administrative Unit ($auScope)" } else { 'Target Cloud x OS Security Groups' }
                RequiredFor = "Enforce Mode (Current: $syncMode)"
                Status = if ($hasAu -and $hasGroupData) { 'Granted' } elseif ($syncMode -eq 'Audit') { 'Optional' } else { 'Pending' }
                Details = if ($syncMode -eq 'Audit') { 'Worker is currently in Audit mode (read-only). Live write-readiness probe will run on next Worker pass.' } else { 'Live write-readiness probe will run on next Worker pass.' }
                Remediation = if ($hasAu) { ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '<worker-principal-id>' -Mode Enforce -AdminUnitId '$auScope'" } else { ".\Grant-GraphPermissions.ps1 -WorkerPrincipalId '<worker-principal-id>' -Mode Enforce -AssignGroupOwner" }
            })
            $inferredChecks.Add(@{
                Id = 'worker-infra-rbac'
                Category = 'Azure RBAC'
                Principal = "Worker Managed Identity ($workerName)"
                Permission = 'Storage Table Data Contributor & Azure Service Bus Data Sender/Receiver'
                Scope = "Storage: $storageAccount | Service Bus: $($params['ServiceBusNamespace'])"
                RequiredFor = 'All Modes (Queueing & State Persistence)'
                Status = if ($invData['LastRunTime']) { 'Granted' } else { 'Pending' }
                Details = if ($invData['LastRunTime']) { "Verified via Worker execution telemetry written to '$storageAccount/machines' at $($invData['LastRunTime'])." } else { 'Awaiting first Worker execution.' }
                Remediation = ''
            })
            $reportData = @{
                CheckedAt = if ($invData['LastRunTime']) { [string]$invData['LastRunTime'] } else { [datetimeoffset]::UtcNow.ToString('o') }
                Source = 'InferredFromTelemetry'
                WorkerFunctionName = $workerName
                WorkerPrincipalId = ''
                TenantId = $tenantId
                SyncMode = $syncMode
                DefaultGroupMode = [string]$params['SYNC_DEFAULT_GROUP_MODE']
                AdminUnitId = $auScope
                AutoCreateGroups = [string]$params['SYNC_AUTO_CREATE_GROUPS']
                TokenRoles = @()
                Checks = $inferredChecks
            }
        }
    }

    $reportData.SyncMode = $invData.SyncMode
    $reportData.DefaultGroupMode = $invData.DefaultGroupMode
    $reportData.WorkerSettingsObservedAt = $invData['WorkerSettingsObservedAt']
    $reportPrincipalLabel = if ($reportOid) { "Report Managed Identity ($reportOid)" } elseif ($reportSite) { "Report Managed Identity ($reportSite)" } else { 'Report Managed Identity' }
    $reportChecks = @(
        @{
            Id = 'report-storage-reader'
            Category = 'Report App & User'
            Principal = $reportPrincipalLabel
            Permission = 'Storage Table Data Reader'
            Scope = "Sync Storage Account ($storageAccount/machines)"
            RequiredFor = 'Web Portal (Read-Only Inventory & Logs)'
            Status = 'Granted'
            Details = "Verified live: Report Managed Identity authenticated via Entra ID and read the '$storageAccount/machines' table."
            Remediation = ''
        },
        @{
            Id = 'report-least-privilege'
            Category = 'Report App & User'
            Principal = $reportPrincipalLabel
            Permission = 'Least-Privilege Isolation (Table Reader + Sync-Request Sender)'
            Scope = "Report Function App ($reportSite)"
            RequiredFor = 'Security Architecture'
            Status = 'Pending'
            Details = 'The deployment grants Table Data Reader and Sender only on inventory-sync. App settings do not prove effective RBAC or absence of Graph permissions; review assignments separately.'
            Remediation = 'Confirm report identity has no Graph permissions or machines-queue access, and has Sender only on inventory-sync.'
        },
        @{
            Id = 'portal-user-role'
            Category = 'Report App & User'
            Principal = 'Signed-In Portal User'
            Permission = 'Report.Reader (Entra App Role)'
            Scope = "Tenant ($tenantId)"
            RequiredFor = 'Web Portal Access'
            Status = 'Granted'
            Details = 'Verified live on current HTTP request (X-MS-CLIENT-PRINCIPAL contains aad claim with role Report.Reader in configured tenant).'
            Remediation = ''
        }
    )
    $existingChecks = @($reportData['Checks'] | Where-Object { $_['Id'] -notin @('report-storage-reader', 'report-least-privilege', 'portal-user-role') })
    $reportData['Checks'] = @($existingChecks + $reportChecks)
    $reportData['ReportFunctionName'] = $reportSite
    $reportData['ReportPrincipalId'] = $reportOid
    $reportData['FunctionAppResourceId'] = $appResourceId
    $reportData['PortalTenant'] = $portalTenant
    return $reportData
}

function Write-FunctionLog {
    param([hashtable]$Entry)
    $reverseTicks = [long]::MaxValue - [datetime]::UtcNow.Ticks
    $scriptOutput = if ($Entry['ScriptOutput']) {
        [string]$Entry['ScriptOutput']
    }
    elseif ($null -ne $script:CurrentRunTranscript -and $script:CurrentRunTranscript.Count -gt 0) {
        ($script:CurrentRunTranscript -join "`n")
    }
    else { '' }
    if ($scriptOutput.Length -gt 26000) {
        $scriptOutput = $scriptOutput.Substring(0, 26000) + "`n...(transcript truncated to fit Table Storage entity limit)"
    }
    $log = @{
        Timestamp = if ($Entry['Timestamp']) { [string]$Entry['Timestamp'] } else { [datetimeoffset]::UtcNow.ToString('o') }
        FunctionName = [string]$Entry['FunctionName']
        TriggerReason = [string]$Entry['TriggerReason']
        Status = [string]$Entry['Status']
        Health = if ($Entry['Health']) { [string]$Entry['Health'] } else { 'Healthy' }
        Message = [string]$Entry['Message']
        RunId = [string]$Entry['RunId']
        ResourceId = [string]$Entry['ResourceId']
        ScriptOutput = $scriptOutput
    }
    $entity = @{
        PartitionKey = 'system'
        RowKey = 'log_{0:D19}_{1}' -f $reverseTicks, ([guid]::NewGuid().ToString('N'))
        Data = ConvertTo-Json -InputObject $log -Depth 10 -Compress
    }
    $null = Invoke-Table -Path 'machines' -Method POST -Body $entity
    $current = @{ Label = 'Inventory'; MachinesQueued = 0; LastSuccessfulInventory = $null; SyncMode = (Get-OptionalSetting 'SYNC_MODE') }
    $existing = Invoke-Table -Path "machines(PartitionKey='system',RowKey='inventory')" -AllowStatus @(404)
    if ($existing.Status -ne 404) {
        $parsed = ConvertFrom-Json -InputObject (Read-JsonResponse $existing).Data -AsHashtable
        foreach ($k in $parsed.Keys) { $current[$k] = $parsed[$k] }
    }
    $appResourceId = Get-FunctionAppResourceId
    if ($appResourceId) { $current.FunctionAppResourceId = $appResourceId }
    $siteName = Get-OptionalSetting 'WEBSITE_SITE_NAME'
    if (-not $siteName -and $appResourceId) { $siteName = $appResourceId.Split('/')[-1] }
    if ($siteName) { $current.FunctionAppName = $siteName }
    $aiResourceId = Get-AppInsightsResourceId
    if ($aiResourceId) {
        $current.AppInsightsResourceId = $aiResourceId
        $current.AppInsightsName = $aiResourceId.Split('/')[-1]
    }
    $current.FunctionAppStatus = 'Running'
    $current.Health = $log.Health
    $current.LastRunTime = $log.Timestamp
    $current.LastRunFunction = $log.FunctionName
    $current.LastRunReason = $log.TriggerReason
    $current.LastRunStatus = $log.Status
    $current.LastRunMessage = $log.Message
    $current.Parameters = Get-FunctionParametersSummary
    $current.SyncMode = $current.Parameters.SYNC_MODE
    $current.DefaultGroupMode = $current.Parameters.SYNC_DEFAULT_GROUP_MODE
    if ($Entry['LastSuccessfulInventory']) {
        $current.LastSuccessfulInventory = [string]$Entry['LastSuccessfulInventory']
    }
    if ($Entry.ContainsKey('MachinesQueued')) {
        $current.MachinesQueued = [int]$Entry['MachinesQueued']
    }
    if ($Entry.ContainsKey('Catalog') -and $null -ne $Entry['Catalog']) {
        $current.Catalog = $Entry['Catalog']
    }
    if ($Entry.ContainsKey('PermissionsReport') -and $null -ne $Entry['PermissionsReport']) {
        $current.PermissionsReport = $Entry['PermissionsReport']
    }
    $summaryEntity = @{
        PartitionKey = 'system'; RowKey = 'inventory'
        Data = ConvertTo-Json -InputObject $current -Depth 10 -Compress
    }
    $null = Invoke-Table -Path "machines(PartitionKey='system',RowKey='inventory')" -Method PUT -Body $summaryEntity
}

function Get-GuestConfigurationRefreshBody {
    param([hashtable]$Assignment, [string]$SubscriptionId)
    $current = Get-InventoryValue $Assignment @('properties', 'guestConfiguration')
    $name = [string](Get-InventoryValue $Assignment @('properties', 'guestConfiguration', 'name'))
    if (-not $current -or $current['assignmentType'] -ne 'Audit' -or
        ($name -notin @('entraiddeviceid', 'entraiddeviceidlinux') -and $name -notmatch '^entraiddeviceidlinux_[0-9]+\.[0-9]+\.[0-9]+$')) {
        throw 'Only the Entra device ID Audit configurations may be refreshed.'
    }
    if ($name -match '^entraiddeviceidlinux_([0-9]+\.[0-9]+\.[0-9]+)$' -and [string]$current['version'] -ne $Matches[1]) {
        throw 'Versioned Linux package name does not match its assignment version.'
    }
    if (@($current['configurationProtectedParameter'] | Where-Object { $null -ne $_ }).Count) {
        throw 'Protected configuration parameters cannot be safely reconstructed for refresh.'
    }
    $configuration = @{}
    foreach ($field in @('name', 'version', 'assignmentType', 'contentType', 'contentHash', 'contentUri',
        'configurationParameter', 'configurationSetting', 'contentManagedIdentity', 'assignmentSource', 'kind')) {
        if ($null -ne $current[$field]) { $configuration[$field] = $current[$field] }
    }
    if ($configuration['contentType'] -ne 'Custom' -or [string]$configuration['contentHash'] -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Refreshing an Entra device ID assignment requires its existing Custom package hash.'
    }
    if (-not $configuration['contentUri']) {
        # Assignment GET hides custom package URIs; recover only a hash-matched URI from deployed policy definitions.
        $hash = [string]$configuration['contentHash']
        $uris = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $skip = ''
        do {
            $options = @{ resultFormat = 'objectArray' }
            if ($skip) { $options['$skipToken'] = $skip }
            $result = Read-JsonResponse (Invoke-CloudRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Resource 'https://management.azure.com/' -Method POST -Body @{
                subscriptions = @($SubscriptionId)
                query = "PolicyResources | where type =~ 'microsoft.authorization/policydefinitions' | where tostring(properties.policyRule) contains '$hash' | project id, policyRule=properties.policyRule"
                options = $options
            })
            foreach ($policy in $result.data) {
                $resources = Get-InventoryValue $policy @('policyRule', 'then', 'details', 'deployment', 'properties', 'template', 'resources')
                foreach ($resource in @($resources)) {
                    $candidate = Get-InventoryValue $resource @('properties', 'guestConfiguration')
                    if ($candidate -and $candidate['name'] -eq $configuration.name -and
                        $candidate['assignmentType'] -eq 'Audit' -and $candidate['contentHash'] -eq $hash -and $candidate['contentUri']) {
                        $null = $uris.Add([string]$candidate['contentUri'])
                    }
                }
            }
            $skip = [string]$result['$skipToken']
        } while ($skip)
        if ($uris.Count -ne 1) { throw 'Could not resolve one hash-matched custom package URI from the deployed policy definitions.' }
        $configuration.contentUri = @($uris)[0]
    }
    $packageUri = $null
    if (-not [uri]::TryCreate([string]$configuration.contentUri, [UriKind]::Absolute, [ref]$packageUri) -or $packageUri.Scheme -ne 'https') {
        throw 'Guest Configuration package URI must be an absolute HTTPS URI.'
    }
    if (-not $Assignment['location']) { throw 'Guest Configuration assignment has no location.' }
    $properties = @{ guestConfiguration = $configuration }
    $context = Get-InventoryValue $Assignment @('properties', 'context')
    if ($null -ne $context) { $properties.context = $context }
    return @{ location = $Assignment.location; properties = $properties }
}

function Request-GuestConfigurationRefresh {
    param([string]$ResourceId, [ValidateSet('MDE.Windows', 'MDE.Linux')][string]$ExtensionName, [string]$EventId, [hashtable]$Config)
    if ($Config.Mode -ne 'Enforce') {
        Write-Information "Audit mode: would request Entra ID Guest Configuration refresh after $ExtensionName on $ResourceId." -InformationAction Continue
        return 0
    }
    if ([string]::IsNullOrWhiteSpace($EventId)) { throw 'An Event Grid event ID is required to deduplicate Guest Configuration refresh requests.' }
    $packageName = if ($ExtensionName -eq 'MDE.Linux') { 'entraiddeviceidlinux' } else { 'entraiddeviceid' }
    $collection = "https://management.azure.com$ResourceId/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments"
    $next = "${collection}?api-version=2024-04-05"
    $requested = 0
    $matched = 0
    $assignments = [Collections.Generic.List[object]]::new()
    do {
        $response = Invoke-CloudRequest -Uri $next -Resource 'https://management.azure.com/' -AllowStatus @(404)
        if ($response.Status -eq 404) {
            Write-Warning "Guest Configuration assignments are not available on $ResourceId; the policy must deploy the Audit assignment before it can be refreshed."
            return $requested
        }
        $page = Read-JsonResponse $response
        if (-not $page.ContainsKey('value')) { throw 'Guest Configuration assignment listing has no value collection.' }
        foreach ($item in $page.value) { $assignments.Add($item) }
        $next = [string]$page['nextLink']
        if (-not $next) { $next = [string]$page['@odata.nextLink'] }
        if ($next) {
            $nextUri = [uri]$next
            if ($nextUri.Scheme -ne 'https' -or $nextUri.Host -ne 'management.azure.com' -or
                -not [string]::Equals($nextUri.AbsolutePath, ([uri]$collection).AbsolutePath, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Unexpected Guest Configuration pagination destination.'
            }
        }
    } while ($next)
    if ($ExtensionName -eq 'MDE.Linux') {
        $versionedName = $assignments |
            ForEach-Object { [string](Get-InventoryValue $_ @('properties', 'guestConfiguration', 'name')) } |
            Where-Object { $_ -match '^entraiddeviceidlinux_[0-9]+\.[0-9]+\.[0-9]+$' } |
            Sort-Object { [version]($_.Substring('entraiddeviceidlinux_'.Length)) } -Descending |
            Select-Object -First 1
        if ($versionedName) {
            $packageName = $versionedName
            Write-Information "Refreshing newest versioned Linux Audit package $packageName; older package identities are retained without being refreshed." -InformationAction Continue
        }
    }
    foreach ($item in $assignments) {
        if ((Get-InventoryValue $item @('properties', 'guestConfiguration', 'name')) -ne $packageName) { continue }
        $assignmentId = [string](Get-InventoryValue $item @('id'))
        if (-not $assignmentId.StartsWith("$ResourceId/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/", [StringComparison]::OrdinalIgnoreCase) -or
            $assignmentId -notmatch '/[^/?#%\\]+$') {
            throw 'Guest Configuration listing returned an assignment outside the requested machine.'
        }
        $matched++
        $key = Get-MachineKey "$EventId`n$($assignmentId.ToLowerInvariant())"
        $claimPath = "machines(PartitionKey='guest-refreshes',RowKey='$key')"
        $previous = Invoke-Table -Path $claimPath -AllowStatus @(404)
        if ($previous.Status -ne 404) {
            $stored = Read-JsonResponse $previous
            if ($stored['Status'] -ne 'Requested') {
                throw "Guest Configuration refresh has a pending or uncertain outcome; inspect $claimPath before retrying."
            }
            Write-Information "Guest Configuration refresh was already requested for event $EventId on $assignmentId." -InformationAction Continue
            continue
        }
        $uri = "https://management.azure.com${assignmentId}?api-version=2024-04-05"
        $assignmentResponse = Invoke-CloudRequest -Uri $uri -Resource 'https://management.azure.com/'
        $assignment = Read-JsonResponse $assignmentResponse
        $body = Get-GuestConfigurationRefreshBody -Assignment $assignment -SubscriptionId $ResourceId.Split('/')[2]
        $previousCheckedAt = Get-InventoryValue $assignment @('properties', 'lastComplianceStatusChecked')
        $claim = @{
            PartitionKey = 'guest-refreshes'; RowKey = $key; Status = 'Requesting'
            EventId = $EventId; AssignmentId = $assignmentId
            RequestedAt = [datetimeoffset]::UtcNow.ToString('o')
            PreviousReportId = [string](Get-InventoryValue $assignment @('properties', 'latestReportId'))
            PreviousCheckedAt = if ($previousCheckedAt) { ([datetimeoffset]$previousCheckedAt).ToUniversalTime().ToString('o') } else { '' }
        }
        $reservation = Invoke-Table -Path 'machines' -Method POST -Body $claim -AllowStatus @(409)
        if ($reservation.Status -eq 409) { throw 'Another worker reserved this Guest Configuration refresh; retry after its result is recorded.' }
        $headers = @{}
        if ($assignmentResponse['Headers'] -and $assignmentResponse.Headers['ETag']) {
            $headers['If-Match'] = [string]($assignmentResponse.Headers['ETag'] | Select-Object -First 1)
        }
        $updated = Read-JsonResponse (Invoke-CloudRequest -Uri $uri -Resource 'https://management.azure.com/' -Method PUT -Body $body -Headers $headers -DisableRetry)
        if ((Get-InventoryValue $updated @('properties', 'guestConfiguration', 'assignmentType')) -ne 'Audit' -or
            (Get-InventoryValue $updated @('properties', 'guestConfiguration', 'contentHash')) -ne $body.properties.guestConfiguration.contentHash) {
            throw 'Guest Configuration refresh did not confirm the original Audit mode and package hash.'
        }
        $claim.Status = 'Requested'
        $claim.RecordedAt = [datetimeoffset]::UtcNow.ToString('o')
        $null = Invoke-Table -Path $claimPath -Method PUT -Body $claim -Headers @{ 'If-Match' = '*' }
        $requested++
        Write-SyncTrace 'GuestRefresh' "Requested an Audit assignment refresh for $assignmentId after $ExtensionName; in-guest evaluation is asynchronous."
    }
    if (-not $matched) {
        Write-Warning "No $packageName Audit assignment exists on $ResourceId yet; Azure Policy deployment and the normal agent cycle remain responsible for its first evaluation."
    }
    return $requested
}

function Invoke-MdeExtensionEvent {
    param([string]$Subject, [string]$EventId = '')
    if ($Subject -match '^(/subscriptions/([0-9a-f-]{36})/resourceGroups/([^/?#%\\]+)/providers/(?:Microsoft\.HybridCompute/machines/[^/?#%\\]+|Microsoft\.Compute/virtualMachines/[^/?#%\\]+|Microsoft\.Compute/virtualMachineScaleSets/[^/?#%\\]+/virtualMachines/[^/?#%\\]+|Microsoft\.Compute/virtualMachineScaleSets/[^/?#%\\]+))/providers/Microsoft\.GuestConfiguration/guestConfigurationAssignments/(entraiddeviceid[^/?#%\\]*)$') {
        $parentId = $Matches[1].ToLowerInvariant()
        $subscriptionId = $Matches[2]
        $resourceGroup = $Matches[3]
        $assignmentName = $Matches[4]
        $config = Get-SyncConfig
        if (-not (Test-ResourceScope -Config $config -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup)) {
            Write-Information "Ignoring out-of-scope Guest Configuration assignment event: $Subject" -InformationAction Continue
            return 0
        }
        $gcResponse = Invoke-CloudRequest -Uri "https://management.azure.com${Subject}?api-version=2024-04-05" -Resource 'https://management.azure.com/' -AllowStatus @(404)
        if ($gcResponse.Status -eq 404) {
            Write-Information "Ignoring missing Guest Configuration assignment resource: $Subject" -InformationAction Continue
            return 0
        }
        $gc = Read-JsonResponse $gcResponse
        $provState = [string](Get-InventoryValue $gc @('properties', 'provisioningState'))
        if ($provState -and $provState -ine 'Succeeded') {
            Write-Information "Ignoring $assignmentName with provisioningState '$provState' on $parentId" -InformationAction Continue
            return 0
        }
        $complianceStatus = [string](Get-InventoryValue $gc @('properties', 'complianceStatus'))
        if ($complianceStatus -ine 'Compliant') {
            Write-Information "Ignoring $assignmentName with complianceStatus '$complianceStatus' on $parentId; Compliant is required." -InformationAction Continue
            return 0
        }
        if ($parentId -match '^/subscriptions/[0-9a-f-]{36}/resourcegroups/[^/]+/providers/microsoft\.compute/virtualmachinescalesets/[^/]+$') {
            $vmssLiteral = ConvertTo-Json -InputObject $parentId -Compress
            $query = @"
ComputeResources
| where type =~ 'microsoft.compute/virtualmachinescalesets/virtualmachines'
| extend vmssId = tolower(substring(id, 0, indexof(id, '/virtualMachines/')))
| where vmssId == $vmssLiteral
| where tostring(properties.extended.instanceView.powerState.displayStatus) !contains 'deallocated'
| project id
| order by id asc
"@
            $result = Read-JsonResponse (Invoke-CloudRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Resource 'https://management.azure.com/' -Method POST -Body @{
                subscriptions = @($subscriptionId)
                query = $query
                options = @{ resultFormat = 'objectArray' }
            })
            $count = 0
            foreach ($row in $result.data) {
                if ($row.id) {
                    Send-MachineWork ([string]$row.id) 'EventGrid'
                    $count++
                }
            }
            return $count
        }
        Send-MachineWork $parentId 'EventGrid'
        return 1
    }
    if ($Subject -notmatch '^(/subscriptions/([0-9a-f-]{36})/resourceGroups/([^/?#%\\]+)/providers/(?:Microsoft\.HybridCompute/machines/[^/?#%\\]+|Microsoft\.Compute/virtualMachines/[^/?#%\\]+|Microsoft\.Compute/virtualMachineScaleSets/[^/?#%\\]+/virtualMachines/[^/?#%\\]+|Microsoft\.Compute/virtualMachineScaleSets/[^/?#%\\]+))/extensions/(MDE\.(?:Windows|Linux))$') {
        throw 'Invalid GuestConfigurationAssignment or MDE.Windows / MDE.Linux extension resource ID.'
    }
    $parentId = $Matches[1].ToLowerInvariant()
    $subscriptionId = $Matches[2]
    $resourceGroup = $Matches[3]
    $extensionName = $Matches[4]
    $config = Get-SyncConfig
    if (-not (Test-ResourceScope -Config $config -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup)) {
        Write-Information "Ignoring out-of-scope MDE extension event: $Subject" -InformationAction Continue
        return 0
    }
    $apiVersion = if ($parentId.Contains('/providers/microsoft.hybridcompute/machines/')) { '2024-07-10' } else { '2024-07-01' }
    $extResponse = Invoke-CloudRequest -Uri "https://management.azure.com${Subject}?api-version=$apiVersion" -Resource 'https://management.azure.com/' -AllowStatus @(404)
    if ($extResponse.Status -eq 404) {
        Write-Information "Ignoring missing extension resource: $Subject" -InformationAction Continue
        return 0
    }
    $ext = Read-JsonResponse $extResponse
    $provState = [string](Get-InventoryValue $ext @('properties', 'provisioningState'))
    if ($provState -ine 'Succeeded') {
        Write-Information "Ignoring $extensionName with provisioningState '$provState' on $parentId" -InformationAction Continue
        return 0
    }
    if ($parentId -match '^/subscriptions/[0-9a-f-]{36}/resourcegroups/[^/]+/providers/microsoft\.compute/virtualmachinescalesets/[^/]+$') {
        $vmssLiteral = ConvertTo-Json -InputObject $parentId -Compress
        $query = @"
ComputeResources
| where type =~ 'microsoft.compute/virtualmachinescalesets/virtualmachines'
| extend vmssId = tolower(substring(id, 0, indexof(id, '/virtualMachines/')))
| where vmssId == $vmssLiteral
| where tostring(properties.extended.instanceView.powerState.displayStatus) !contains 'deallocated'
| project id
| order by id asc
"@
        $result = Read-JsonResponse (Invoke-CloudRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Resource 'https://management.azure.com/' -Method POST -Body @{
            subscriptions = @($subscriptionId)
            query = $query
            options = @{ resultFormat = 'objectArray' }
        })
        $count = 0
        foreach ($row in $result.data) {
            if ($row.id) {
                $null = Request-GuestConfigurationRefresh -ResourceId ([string]$row.id) -ExtensionName $extensionName -EventId $EventId -Config $config
                Send-MachineWork ([string]$row.id) 'EventGrid'
                $count++
            }
        }
        return $count
    }
    $null = Request-GuestConfigurationRefresh -ResourceId $parentId -ExtensionName $extensionName -EventId $EventId -Config $config
    Send-MachineWork $parentId 'EventGrid'
    return 1
}

function Send-MachineWork {
    param([string]$ResourceId, [string]$Source, [hashtable]$ResourceData = $null, [hashtable]$MdeData = $null)
    $id = ConvertTo-ArcId $ResourceId
    $namespace = Get-Setting 'ServiceBusConnection__fullyQualifiedNamespace'
    if ($namespace -notmatch '^[a-z0-9-]+\.servicebus\.windows\.net$') { throw 'Invalid Service Bus namespace.' }
    $runId = [guid]::NewGuid().ToString()
    $payload = @{
        ResourceId = $id; Source = $Source; RunId = $runId
    }
    if ($null -ne $ResourceData -and $ResourceData.ContainsKey('properties')) {
        $payload.ResourceData = $ResourceData
    }
    if ($null -ne $MdeData -and $MdeData.ContainsKey('Candidates')) {
        $payload.MdeData = $MdeData
    }
    $null = Invoke-CloudRequest -Uri "https://$namespace/machines/messages" -Resource 'https://servicebus.azure.net' -Method POST -Body $payload
    if ($Source -eq 'EventGrid') {
        try {
            Write-FunctionLog @{
                FunctionName = 'ArcEvent'
                TriggerReason = 'Event Grid (Compliant Machine Configuration assignment or succeeded MDE extension)'
                Status = 'Succeeded'
                Health = 'Healthy'
                Message = "Queued machine $(Get-MachineDisplayName $id) after a compliant Machine Configuration assignment or succeeded MDE extension event."
                RunId = $runId
                ResourceId = $id
            }
        }
        catch {
            Write-Warning "Could not persist function log for ArcEvent: $($_.Exception.Message)"
        }
    }
}

function Get-ScopeResourceGraphTargets {
    param([hashtable]$Config)
    $targets = @()
    if ($Config.Subscriptions.Count) {
        $targets += @{ Kind = 'subscriptions'; Values = @($Config.Subscriptions) }
    }
    if ($Config.ManagementGroups.Count) {
        $targets += @{ Kind = 'managementGroups'; Values = @($Config.ManagementGroups) }
    }
    return $targets
}

function Get-BulkMdeTelemetry {
    param([array]$DiscoveredMachines)
    $byResourceId = @{}
    if (-not $DiscoveredMachines.Count) { return $byResourceId }
    $modes = @{ '0' = 'Active'; '1' = 'Passive'; '2' = 'Disabled'; '3' = 'Other'; '4' = 'EDRBlocked'; '5' = 'PassiveAudit' }
    $batchSize = 200
    for ($offset = 0; $offset -lt $DiscoveredMachines.Count; $offset += $batchSize) {
        $batch = @($DiscoveredMachines | Select-Object -Skip $offset -First $batchSize)
        $resIds = [Collections.Generic.List[string]]::new()
        $vmIds = [Collections.Generic.List[string]]::new()
        $vmIdToResId = @{}
        foreach ($item in $batch) {
            $rid = ([string]$item.ResourceId).ToLowerInvariant()
            if ($rid -and $rid -notin $resIds) { $resIds.Add($rid) }
            $row = $item.Row
            $vid = if ($null -ne $row) { ([string](Get-InventoryValue $row @('properties', 'vmId'))).Trim().ToLowerInvariant() } else { '' }
            if ($vid) {
                if ($vid -notin $vmIds) { $vmIds.Add($vid) }
                $vmIdToResId[$vid] = $rid
            }
            $byResourceId[$rid] = @{
                Candidates = [Collections.Generic.List[hashtable]]::new()
                NetworkAddresses = @()
                Antivirus = @{ Mode = ''; Timestamp = ''; Status = 'NoData' }
            }
        }
        if (-not $resIds.Count) { continue }
        $resLiterals = @($resIds | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress }) -join ', '
        $vmClause = ''
        if ($vmIds.Count) {
            $vmLiterals = @($vmIds | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress }) -join ', '
            $vmClause = " or tolower(AzureVmId) in ($vmLiterals)"
        }
        $bulkQuery = @"
let MatchedDevices = DeviceInfo
| where Timestamp >= ago(7d)
| summarize arg_max(Timestamp, *) by DeviceId
| where tolower(AzureResourceId) in ($resLiterals)${vmClause}
| project Timestamp, DeviceId, DeviceName, AadDeviceId, OnboardingStatus, MergedToDeviceId,
    SensorHealthState, CloudPlatforms, AzureVmId, AzureResourceId, PublicIP,
    DeviceManualTags, DeviceDynamicTags, RegistryDeviceTag, MachineGroup;
let NetInfo = DeviceNetworkInfo
| where Timestamp >= ago(7d)
| where DeviceId in ((MatchedDevices | project DeviceId))
| summarize arg_max(Timestamp, *) by DeviceId, NetworkAdapterName, MacAddress
| summarize NetIPs = make_list(IPAddresses) by DeviceId;
let AvInfo = DeviceTvmSecureConfigurationAssessment
| where Timestamp >= ago(7d) and ConfigurationId == 'scid-2010'
| where DeviceId in ((MatchedDevices | project DeviceId))
| summarize arg_max(Timestamp, *) by DeviceId
| project DeviceId, AvTimestamp = Timestamp, AvMode = tostring(parse_json(Context)[0][0]);
MatchedDevices
| join kind=leftouter NetInfo on DeviceId
| join kind=leftouter AvInfo on DeviceId
"@
        try {
            Write-SyncTrace 'MDEHunting' "Executing bulk MDE hunting query for $($resIds.Count) machine(s)"
            $huntResult = Read-JsonResponse (Invoke-Graph -Path '/security/runHuntingQuery' -Method POST -Body @{ Query = $bulkQuery; Timespan = 'P7D' })
            if (-not $huntResult.ContainsKey('results')) { continue }
            $rows = @($huntResult.results)
            Write-SyncTrace 'MDEHunting' "Bulk MDE hunting query returned $($rows.Count) device row(s) for $($resIds.Count) machine(s)"
            foreach ($r in $rows) {
                $rowResId = ([string]$r['AzureResourceId']).Trim().ToLowerInvariant()
                $rowVmId = ([string]$r['AzureVmId']).Trim().ToLowerInvariant()
                $targetResId = ''
                if ($rowResId -and $byResourceId.ContainsKey($rowResId)) {
                    $targetResId = $rowResId
                }
                elseif ($rowVmId -and $vmIdToResId.ContainsKey($rowVmId)) {
                    $targetResId = $vmIdToResId[$rowVmId]
                }
                if (-not $targetResId) { continue }
                $entry = $byResourceId[$targetResId]
                $entry.Candidates.Add($r)

                $parsedIps = [Collections.Generic.List[string]]::new()
                $netIpsRaw = $r['NetIPs']
                $netIpList = if ($netIpsRaw -is [string] -and -not [string]::IsNullOrWhiteSpace($netIpsRaw)) {
                    try { ConvertFrom-Json -InputObject $netIpsRaw -AsHashtable } catch { @() }
                } elseif ($netIpsRaw -is [Collections.IEnumerable]) {
                    @($netIpsRaw)
                } else { @() }
                foreach ($adapterIps in $netIpList) {
                    $ips = if ($adapterIps -is [string] -and -not [string]::IsNullOrWhiteSpace($adapterIps)) {
                        try { ConvertFrom-Json -InputObject $adapterIps -AsHashtable } catch { @() }
                    } else { $adapterIps }
                    foreach ($ipObj in @($ips)) {
                        $addr = [string](Get-InventoryValue $ipObj @('IPAddress'))
                        if ($addr -and $addr -notin $parsedIps) { $parsedIps.Add($addr) }
                    }
                }
                $entry.NetworkAddresses = @($parsedIps | Sort-Object -Unique)

                $avCode = ([string]$r['AvMode']).Trim()
                $avTs = [string]$r['AvTimestamp']
                if (-not [string]::IsNullOrWhiteSpace($avCode) -and $modes.ContainsKey($avCode)) {
                    $entry.Antivirus = @{ Mode = $modes[$avCode]; Timestamp = $avTs; Status = 'Reported' }
                }
                else {
                    $entry.Antivirus = @{ Mode = ''; Timestamp = $avTs; Status = 'NoData' }
                }
            }
        }
        catch {
            Write-Warning "Bulk MDE hunting query failed (workers will fall back to per-machine query): $($_.Exception.Message)"
            return @{}
        }
    }
    $finalMap = @{}
    foreach ($k in $byResourceId.Keys) {
        $candList = [Collections.Generic.List[hashtable]]::new()
        foreach ($c in $byResourceId[$k].Candidates) { $candList.Add($c) }
        $netList = [Collections.Generic.List[string]]::new()
        foreach ($ip in $byResourceId[$k].NetworkAddresses) { $netList.Add([string]$ip) }
        $finalMap[$k] = @{
            Candidates = $candList
            NetworkAddresses = $netList
            Antivirus = $byResourceId[$k].Antivirus
        }
    }
    return $finalMap
}

function Invoke-InventorySync {
    param([string]$TriggerReason = 'Scheduled timer (NCRONTAB schedule)', [string]$RequestedAt = '')
    $job = Start-InventoryJob -TriggerReason $TriggerReason -RequestedAt $RequestedAt
    if (-not $job) {
        Write-Information 'Inventory request coalesced with an existing run.' -InformationAction Continue
        return
    }
    try {
        Invoke-InventoryRun -TriggerReason $TriggerReason -RunId $job.RunId
    }
    catch {
        $failure = $_
        try { Complete-InventoryJob -RunId $job.RunId -Status Failed -Message $failure.Exception.Message }
        catch { Write-Warning "Could not persist failed inventory status: $($_.Exception.Message)" }
        throw $failure
    }
    Complete-InventoryJob -RunId $job.RunId -Status Succeeded -Message 'Inventory completed; queued device processing may still be running.'
}

function Get-InventoryJobStatus {
    $response = Invoke-Table -Path "machines(PartitionKey='system',RowKey='inventory-job')" -AllowStatus @(404)
    if ($response.Status -eq 404) { return @{ Status = 'Unknown'; IsRunning = $false; Message = 'No monitored inventory run recorded yet.' } }
    $job = Read-JsonResponse $response
    $job.IsRunning = $job.Status -eq 'Running' -and [datetimeoffset]$job.ExpiresAt -gt [datetimeoffset]::UtcNow
    if ($job.Status -eq 'Running' -and -not $job.IsRunning) {
        $job.Status = 'Interrupted'
        $job.Message = 'No completion recorded within the execution limit. Check worker logs.'
    }
    return $job
}

function Start-InventoryJob {
    param([string]$TriggerReason, [string]$RequestedAt = '')
    # Expiry must exceed the enforced host timeout and worker termination grace period.
    $timeout = Get-OptionalSetting 'AzureFunctionsJobHost__functionTimeout'
    if (-not $timeout) {
        $hostPath = Join-Path $PSScriptRoot '..\..\host.json'
        if (-not (Test-Path -LiteralPath $hostPath)) { $hostPath = Join-Path $PSScriptRoot '..\worker\host.json' }
        $timeout = (Get-Content -LiteralPath $hostPath -Raw | ConvertFrom-Json).functionTimeout
    }
    if ([timespan]::Parse($timeout) -le [timespan]::Zero -or [timespan]::Parse($timeout) -gt [timespan]::FromMinutes(10)) {
        throw 'Inventory overlap protection requires a positive functionTimeout of at most 10 minutes.'
    }
    $now = [datetimeoffset]::UtcNow
    $path = "machines(PartitionKey='system',RowKey='inventory-job')"
    $existing = Invoke-Table -Path $path -AllowStatus @(404)
    $headers = @{}
    if ($existing.Status -ne 404) {
        $previous = Read-JsonResponse $existing
        if ($RequestedAt -and [datetimeoffset]$previous.StartedAt -ge [datetimeoffset]$RequestedAt) { return $null }
        if ($previous.Status -eq 'Running' -and [datetimeoffset]$previous.ExpiresAt -gt $now) { return $null }
        $headers['If-Match'] = [string]($existing.Headers.ETag | Select-Object -First 1)
        if (-not $headers['If-Match']) { throw 'Inventory job response has no ETag; refusing an unsafe lock update.' }
    }
    $job = @{
        PartitionKey = 'system'; RowKey = 'inventory-job'
        RunId = [guid]::NewGuid().ToString()
        Status = 'Running'; TriggerReason = $TriggerReason
        StartedAt = $now.ToString('o'); ExpiresAt = $now.AddMinutes(15).ToString('o')
        CompletedAt = ''; Message = 'Discovering machines, preparing groups, and queuing device synchronization.'
    }
    $claim = if ($existing.Status -eq 404) {
        Invoke-Table -Path 'machines' -Method POST -Body $job -AllowStatus @(409)
    } else {
        Invoke-Table -Path $path -Method PUT -Body $job -Headers $headers -AllowStatus @(412)
    }
    if ($claim.Status -in @(409, 412)) { return $null }
    return $job
}

function Complete-InventoryJob {
    param([string]$RunId, [ValidateSet('Succeeded', 'Failed')][string]$Status, [string]$Message)
    $path = "machines(PartitionKey='system',RowKey='inventory-job')"
    $response = Invoke-Table -Path $path
    $job = Read-JsonResponse $response
    if ($job.RunId -ne $RunId) { throw 'Inventory job ownership changed; refusing to overwrite another run.' }
    $etag = [string]($response.Headers.ETag | Select-Object -First 1)
    if (-not $etag) { throw 'Inventory job response has no ETag; refusing an unsafe completion update.' }
    $null = $job.Remove('odata.etag')
    $job.Status = $Status
    $job.CompletedAt = [datetimeoffset]::UtcNow.ToString('o')
    $job.Message = $Message.Substring(0, [math]::Min(500, $Message.Length))
    $null = Invoke-Table -Path $path -Method PUT -Body $job -Headers @{ 'If-Match' = $etag }
}

function New-ReportSyncRequest {
    $namespace = Get-Setting 'ServiceBusConnection__fullyQualifiedNamespace'
    if ($namespace -notmatch '^[a-z0-9-]+\.servicebus\.windows\.net$') { throw 'Invalid Service Bus namespace.' }
    $request = @{ RequestId = [guid]::NewGuid().ToString(); RequestedAt = [datetimeoffset]::UtcNow.ToString('o') }
    $null = Invoke-CloudRequest -Uri "https://$namespace/inventory-sync/messages" -Resource 'https://servicebus.azure.net' -Method POST -Body $request -DisableRetry
    return $request
}

function Invoke-InventoryRun {
    param([string]$TriggerReason, [string]$RunId)
    Start-SyncTranscript 'Inventory'
    try {
        $config = Get-SyncConfig
        Write-SyncTrace 'Inventory' "Starting inventory sync run=$runId reason='$TriggerReason'" @{
            Subscriptions = $config.Subscriptions
            ManagementGroups = $config.ManagementGroups
            ResourceGroups = $config.ResourceGroups
            Mode = $config.Mode
            DefaultGroupMode = $config.DefaultGroupMode
            AdminUnitId = $config.AdminUnitId
            AutoCreateGroups = $config.AutoCreateGroups
            FreshnessHours = $config.FreshnessHours
        }
        $discovered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $pendingQueue = [Collections.Generic.List[hashtable]]::new()
        $argMachineRows = 0
        $argVmssRows = 0
        $revisitedRows = 0
        $baseQuery = @"
Resources
| extend type = tolower(type)
| where type == 'microsoft.hybridcompute/machines'
    or (
        type in ('microsoft.compute/virtualmachines', 'microsoft.classiccompute/virtualmachines')
        and tostring(properties.extended.instanceView.powerState.displayStatus) !contains 'deallocated'
        and tostring(properties.virtualMachineProfile.extensionProfile) !contains 'Compute.AKS'
    )
"@
        $baseVmssQuery = @"
Resources
| extend type = tolower(type)
| where type == 'microsoft.compute/virtualmachinescalesets'
| extend extensions = tostring(properties.virtualMachineProfile.extensionProfile)
| where extensions !contains 'Compute.AKS'
"@
        $rgClause = ''
        if ($config.ResourceGroups.Count) {
            $literals = @($config.ResourceGroups | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress }) -join ', '
            $rgClause = "| where tolower(resourceGroup) in ($literals)`n"
        }
        $query = @"
${baseQuery}
${rgClause}| extend machineId = tolower(id)
| join kind=leftouter (
    ResourceContainers
    | where type =~ 'microsoft.resources/subscriptions'
    | extend mgId = tostring(properties.managementGroupAncestorsChain[0].name),
             mgDisplayName = tostring(properties.managementGroupAncestorsChain[0].displayName)
    | project subscriptionId, subscriptionName = name, managementGroup = iff(isempty(mgDisplayName) or mgDisplayName == mgId, mgId, strcat(mgDisplayName, ' (', mgId, ')'))
) on subscriptionId
| join kind=leftouter (
    Resources
    | where type in~ ('microsoft.hybridcompute/machines/extensions', 'microsoft.compute/virtualmachines/extensions')
    | extend machineId = tolower(substring(id, 0, indexof(tolower(id), '/extensions/')))
    | summarize argExtensions = make_list(strcat(name, ' (version: ', tostring(properties.typeHandlerVersion), '; state: ', tostring(properties.provisioningState), ')')) by machineId
) on machineId
| join kind=leftouter (
    GuestConfigurationResources
    | where type =~ 'microsoft.guestconfiguration/guestconfigurationassignments'
    | where tolower(name) startswith 'entraiddeviceid'
    | extend machineId = tolower(substring(id, 0, indexof(tolower(id), '/providers/microsoft.guestconfiguration/')))
    | extend reasonPhrase = tostring(properties.latestAssignmentReport.resources[0].reasons[0].phrase)
    | parse reasonPhrase with * "intuneDeviceId=" gcEntraDeviceId
    | where isnotempty(gcEntraDeviceId)
    | summarize arg_max(tostring(properties.lastComplianceStatusChecked), gcEntraDeviceId) by machineId
    | project machineId, gcEntraDeviceId
) on machineId
| project id, name, type, subscriptionId, subscriptionName, managementGroup, resourceGroup, tags, properties, systemData, argExtensions, gcEntraDeviceId
| order by id asc
"@
        $vmssQuery = @"
${baseVmssQuery}
${rgClause}| extend vmssId = tolower(id), vmssName = name, vmssTags = tags
| project id, vmssName, vmssId, subscriptionId, resourceGroup, vmssTags
| join kind=leftouter (
    ResourceContainers
    | where type =~ 'microsoft.resources/subscriptions'
    | extend mgId = tostring(properties.managementGroupAncestorsChain[0].name),
             mgDisplayName = tostring(properties.managementGroupAncestorsChain[0].displayName)
    | project subscriptionId, subscriptionName = name, managementGroup = iff(isempty(mgDisplayName) or mgDisplayName == mgId, mgId, strcat(mgDisplayName, ' (', mgId, ')'))
) on subscriptionId
| join (
    ComputeResources
    | where type =~ "microsoft.compute/virtualmachinescalesets/virtualmachines"
    | extend vmssId = tolower(substring(id, 0, indexof(id, "/virtualMachines/")))
    | where tostring(properties.extended.instanceView.powerState.displayStatus) !contains 'deallocated'
    | project vmssId, instId = id, instName = name, instType = type, instTags = tags, instProps = properties
) on vmssId
| project id = instId, name = instName, type = instType, subscriptionId, subscriptionName, managementGroup, resourceGroup, tags = iff(isnull(instTags) or tostring(instTags) == '{}', vmssTags, instTags), properties = instProps
| order by id asc
"@
        foreach ($target in @(Get-ScopeResourceGraphTargets $config)) {
            $queryIndex = 0
            foreach ($activeQuery in @($query, $vmssQuery)) {
                $queryLabel = if ($queryIndex -eq 0) { 'Arc+NativeVMs' } else { 'VMSSInstances' }
                $queryIndex++
                $pageNumber = 0
                $skipToken = ''
                do {
                    $pageNumber++
                    $options = @{ resultFormat = 'objectArray' }
                    if ($skipToken) { $options.'$skipToken' = $skipToken }
                    $body = @{
                        query = $activeQuery
                        options = $options
                    }
                    $body[$target.Kind] = $target.Values
                    Write-SyncTrace 'ResourceGraph' "Executing ARG query [$queryLabel] page=$pageNumber scopeKind=$($target.Kind) scopes=$($target.Values -join ',')" @{
                        Query = $activeQuery
                    }
                    $result = Read-JsonResponse (Invoke-CloudRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Resource 'https://management.azure.com/' -Method POST -Body $body)
                    $rows = @($result.data)
                    $returnedIds = @($rows | ForEach-Object {
                        if ($_.ContainsKey('id1') -and $_.id1) { [string]$_.id1 } else { [string]$_.id }
                    } | Where-Object { $_ })
                    if ($queryLabel -eq 'Arc+NativeVMs') { $argMachineRows += $returnedIds.Count } else { $argVmssRows += $returnedIds.Count }
                    Write-SyncTrace 'ResourceGraph' "ARG query [$queryLabel] page=$pageNumber returned $($returnedIds.Count) row(s) (totalRecords=$($result['totalRecords']), truncated=$($result['resultTruncated']))" @{
                        TotalRecords = $result['totalRecords']
                        ResultTruncated = $result['resultTruncated']
                        Data = $rows
                    }
                    foreach ($row in $rows) {
                        $rowId = if ($row.ContainsKey('id1') -and $row.id1) { [string]$row.id1 } else { [string]$row.id }
                        if ($rowId -and $discovered.Add($rowId)) {
                            Write-SyncTrace 'Inventory' "Discovered machine from [$queryLabel]: $rowId"
                            $pendingQueue.Add(@{ ResourceId = $rowId; Row = $row })
                        }
                    }
                    $skipToken = if ($result.ContainsKey('$skipToken')) { $result.'$skipToken' } else { '' }
                    if ($result.resultTruncated -eq 'true' -and -not $skipToken) { throw 'Resource Graph inventory was truncated without a continuation token.' }
                } while ($skipToken)
            }
        }
        # Revisit previously seen resources as well, so deletions are visible without removing membership.
        $cursor = ''
        do {
            $page = Get-TablePage -Filter "RowKey eq 'state'" -Cursor $cursor
            foreach ($item in $page.Items) {
                if ((Test-ResourceScope -Config $config -SubscriptionId $item.SubscriptionId -ResourceGroup $item.ResourceGroup) -and $discovered.Add($item.ArcResourceId)) {
                    $revisitedRows++
                    Write-SyncTrace 'Inventory' "Discovered previously tracked machine from Table storage: $($item.ArcResourceId)"
                    $pendingQueue.Add(@{ ResourceId = [string]$item.ArcResourceId; Row = $null })
                }
            }
            $cursor = $page.Cursor
        } while ($cursor)

        $bulkMdeMap = @{}
        if ($pendingQueue.Count -gt 0 -and (Get-OptionalSetting 'IDENTITY_ENDPOINT')) {
            $bulkMdeMap = Get-BulkMdeTelemetry -DiscoveredMachines @($pendingQueue)
        }
        $groupProvisioning = Initialize-InventoryGroups -Config $config -WorkItems @($pendingQueue) -MdeMap $bulkMdeMap
        foreach ($workItem in $pendingQueue) {
            $normKey = ([string]$workItem.ResourceId).ToLowerInvariant()
            $mdePayload = if ($bulkMdeMap.ContainsKey($normKey)) { $bulkMdeMap[$normKey] } else { $null }
            $source = if ($TriggerReason -like 'Manual*') { 'Manual' } else { 'Schedule' }
            Send-MachineWork -ResourceId $workItem.ResourceId -Source $source -ResourceData $workItem.Row -MdeData $mdePayload
        }
        $completedAt = [datetimeoffset]::UtcNow.ToString('o')
        $catalog = $null
        try {
            $catalog = Get-CoverageCatalog -Config $config
            Write-SyncTrace 'Inventory' "Coverage catalog collected: scopes=$(@($catalog.CloudScopes).Count), managedGroups=$(@($catalog.ManagedGroups).Count)"
        }
        catch {
            Write-Warning "Coverage catalog collection failed: $($_.Exception.Message)"
        }
        $permissionsReport = $null
        if (Get-OptionalSetting 'IDENTITY_ENDPOINT') {
            try {
                $permissionsReport = Get-PermissionsValidationReport -Config $config -DiscoveredMachinesCount $discovered.Count -ArgMachineRows $argMachineRows -ArgVmssRows $argVmssRows -Catalog $catalog
                $permEntity = @{
                    PartitionKey = 'system'
                    RowKey = 'permissions'
                    Data = ConvertTo-Json -InputObject $permissionsReport -Depth 15 -Compress
                }
                $null = Invoke-Table -Path "machines(PartitionKey='system',RowKey='permissions')" -Method PUT -Body $permEntity
                Write-SyncTrace 'Inventory' "Permissions validation report saved: checks=$(@($permissionsReport.Checks).Count)"
            }
            catch {
                Write-Warning "Permissions validation report failed: $($_.Exception.Message)"
            }
        }
        $rgSummary = if ($config.ResourceGroups.Count) { $config.ResourceGroups -join ',' } else { 'all' }
        $subSummary = if ($config.Subscriptions.Count) { $config.Subscriptions -join ',' } else { 'none' }
        $mgSummary = if ($config.ManagementGroups.Count) { $config.ManagementGroups -join ',' } else { 'none' }
        $summaryMessage = "Inventory pass completed: queued $($discovered.Count) machine(s) [ARG Arc/VM rows=$argMachineRows, ARG VMSS rows=$argVmssRows, revisited=$revisitedRows | Subs=$subSummary, MGs=$mgSummary, RGs=$rgSummary | Groups: existing=$($groupProvisioning.Existing), created=$($groupProvisioning.Created), wouldCreate=$($groupProvisioning.WouldCreate), missing=$($groupProvisioning.Missing)]."
        Write-SyncTrace 'Inventory' $summaryMessage
        Write-FunctionLog @{
            Timestamp = $completedAt
            FunctionName = 'Inventory'
            TriggerReason = $TriggerReason
            Status = 'Succeeded'
            Health = 'Healthy'
            Message = $summaryMessage
            RunId = $runId
            LastSuccessfulInventory = $completedAt
            MachinesQueued = $discovered.Count
            Catalog = $catalog
            PermissionsReport = $permissionsReport
            GroupProvisioning = $groupProvisioning
        }
        Write-Information "Inventory completed: queued=$($discovered.Count)" -InformationAction Continue
    }
    catch {
        Write-SyncTrace 'Inventory' "Inventory sync failed run=$runId`: $($_.Exception.Message)"
        try {
            Write-FunctionLog @{
                FunctionName = 'Inventory'
                TriggerReason = $TriggerReason
                Status = 'Failed'
                Health = 'Unhealthy'
                Message = $_.Exception.Message.Substring(0, [math]::Min(500, $_.Exception.Message.Length))
                RunId = $runId
            }
        }
        catch {
            Write-Warning "Could not persist function log for failed Inventory: $($_.Exception.Message)"
        }
        throw
    }
}

function Get-Correlation {
    param([array]$Candidates, [int]$FreshnessHours, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $current = @($Candidates | Where-Object {
        $null -ne $_ -and $_ -is [Collections.IDictionary] -and $_['OnboardingStatus'] -eq 'Onboarded' -and [string]::IsNullOrWhiteSpace([string]$_['MergedToDeviceId'])
    })
    if (-not $current.Count) { return @{ Status = 'PendingMde'; Candidate = $null } }
    $fresh = @($current | Where-Object {
        $time = [datetimeoffset]$_['Timestamp']
        $time -ge $Now.AddHours(-$FreshnessHours) -and $time -le $Now.AddMinutes(5)
    })
    if (-not $fresh.Count) { return @{ Status = 'StaleEvidence'; Candidate = $null } }
    if ($fresh.Count -ne 1) { return @{ Status = 'Ambiguous'; Candidate = $null } }
    $candidate = $fresh[0]
    if ([string]::IsNullOrWhiteSpace([string]$candidate['AadDeviceId'])) { return @{ Status = 'NoEntraDevice'; Candidate = $candidate } }
    $guid = [guid]::Empty
    if (-not [guid]::TryParse([string]$candidate['AadDeviceId'], [ref]$guid) -or $guid -eq [guid]::Empty) {
        return @{ Status = 'InvalidEntraIdentifier'; Candidate = $candidate }
    }
    return @{ Status = 'Matched'; Candidate = $candidate }
}

function Get-MdeCandidates {
    param([string]$ResourceId, [string]$VirtualMachineId = '')
    # Select latest telemetry per device BEFORE matching the resource ID (or VM ID), avoiding old mappings.
    $literal = ConvertTo-Json -InputObject $ResourceId -Compress
    $vmClause = ''
    if (-not [string]::IsNullOrWhiteSpace($VirtualMachineId)) {
        $vmLiteral = ConvertTo-Json -InputObject $VirtualMachineId.Trim() -Compress
        $vmClause = " or AzureVmId =~ $vmLiteral"
    }
    $query = @"
DeviceInfo
| where Timestamp >= ago(7d)
| summarize arg_max(Timestamp, *) by DeviceId
| where AzureResourceId =~ ${literal}${vmClause}
| project Timestamp, DeviceId, DeviceName, AadDeviceId, OnboardingStatus, MergedToDeviceId,
    SensorHealthState, CloudPlatforms, AzureVmId, PublicIP,
    DeviceManualTags, DeviceDynamicTags, RegistryDeviceTag, MachineGroup
| take 101
"@
    Write-SyncTrace 'MDEHunting' "Executing DeviceInfo hunting query for ResourceId=$ResourceId" @{ Query = $query }
    $result = Read-JsonResponse (Invoke-Graph -Path '/security/runHuntingQuery' -Method POST -Body @{ Query = $query; Timespan = 'P7D' })
    if (-not $result.ContainsKey('results')) { throw 'Hunting response is missing results.' }
    $rows = @($result.results)
    Write-SyncTrace 'MDEHunting' "DeviceInfo query for ResourceId=$ResourceId returned $($rows.Count) row(s)" @{
        Candidates = @($rows | ForEach-Object {
            @{
                DeviceId = $_['DeviceId']
                DeviceName = $_['DeviceName']
                AadDeviceId = $_['AadDeviceId']
                OnboardingStatus = $_['OnboardingStatus']
                MergedToDeviceId = $_['MergedToDeviceId']
                Timestamp = $_['Timestamp']
                SensorHealthState = $_['SensorHealthState']
                CloudPlatforms = $_['CloudPlatforms']
            }
        })
    }
    if ($rows.Count -gt 100) { throw 'Correlation candidate query exceeded its safety limit.' }
    return $rows
}

function Get-InventoryValue {
    param($InputObject, [string[]]$Path)
    $value = $InputObject
    foreach ($part in $Path) {
        if ($value -isnot [Collections.IDictionary] -or -not $value.Contains($part)) { return $null }
        $value = $value[$part]
    }
    return $value
}

function Invoke-InventoryStep {
    param([hashtable]$State, [string]$Source, [scriptblock]$Action)
    try { & $Action }
    catch {
        $message = "${Source}: $($_.Exception.Message)"
        $State.InventoryErrors += $message.Substring(0, [math]::Min(1000, $message.Length))
        $State.InventoryStatus = 'Partial'
        Write-Warning "Inventory enrichment failed for $($State.Key): $message"
    }
}

function ConvertTo-IsoTimestamp {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetimeoffset]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [datetime]) { return ([datetimeoffset]$Value.ToUniversalTime()).ToString('o') }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.ToUniversalTime().ToString('o')
    }
    return $text
}

function Get-ResourceKind {
    param([string]$ResourceId)
    $lower = $ResourceId.ToLowerInvariant()
    if ($lower.Contains('/providers/microsoft.compute/virtualmachinescalesets/')) { return 'VmssVm' }
    if ($lower.Contains('/providers/microsoft.compute/virtualmachines/')) { return 'AzureVm' }
    if ($lower.Contains('/providers/microsoft.classiccompute/virtualmachines/')) { return 'ClassicVm' }
    return 'Arc'
}

function Get-MachineDisplayName {
    param([string]$ResourceId)
    if ($ResourceId -match '/providers/microsoft\.compute/virtualmachinescalesets/([^/]+)/virtualmachines/([^/]+)$') {
        return "$($Matches[1])_$($Matches[2])"
    }
    return $ResourceId.Split('/')[-1]
}

function Get-MachineArmUri {
    param([string]$ResourceId)
    $kind = Get-ResourceKind $ResourceId
    if ($kind -in @('AzureVm', 'VmssVm')) { return "https://management.azure.com${ResourceId}?`$expand=instanceView&api-version=2024-07-01" }
    if ($kind -eq 'ClassicVm') { return "https://management.azure.com${ResourceId}?api-version=2016-11-01" }
    return "https://management.azure.com${ResourceId}?api-version=2024-07-10"
}

function Set-ArcInventory {
    param([hashtable]$State, [hashtable]$Arc)
    $kind = Get-ResourceKind ([string]$State.ArcResourceId)
    $State.ComputerName = [string](Get-InventoryValue $Arc @('properties', 'osProfile', 'computerName'))
    $State.Fqdn = [string](Get-InventoryValue $Arc @('properties', 'dnsFqdn'))
    $State.CloudProvider = [string](Get-InventoryValue $Arc @('properties', 'cloudMetadata', 'provider'))
    if (-not $State.CloudProvider -and $kind -ne 'Arc') { $State.CloudProvider = 'Azure' }
    $State.VirtualMachineId = [string](Get-InventoryValue $Arc @('properties', 'vmId'))
    $lastReported = ConvertTo-IsoTimestamp (Get-InventoryValue $Arc @('properties', 'lastStatusChange'))
    if (-not $lastReported) { $lastReported = ConvertTo-IsoTimestamp (Get-InventoryValue $Arc @('systemData', 'lastModifiedAt')) }
    if (-not $lastReported) { $lastReported = ConvertTo-IsoTimestamp (Get-InventoryValue $Arc @('properties', 'timeCreated')) }
    $State.ArcLastReportedAt = $lastReported
    $addedAt = ConvertTo-IsoTimestamp (Get-InventoryValue $Arc @('systemData', 'createdAt'))
    if (-not $addedAt) { $addedAt = ConvertTo-IsoTimestamp (Get-InventoryValue $Arc @('properties', 'timeCreated')) }
    if (-not $addedAt) { $addedAt = ConvertTo-IsoTimestamp $State.FirstSeen }
    $State.ArcAddedAt = $addedAt
    $addresses = foreach ($adapter in @(Get-InventoryValue $Arc @('properties', 'networkProfile', 'networkInterfaces'))) {
        foreach ($ip in @(Get-InventoryValue $adapter @('ipAddresses'))) {
            $address = [string](Get-InventoryValue $ip @('address'))
            if ($address) { $address }
        }
    }
    $State.IPAddresses = @($addresses | Sort-Object -Unique)
}

function Get-SubscriptionName {
    param([string]$SubscriptionId)
    if (-not $script:SubscriptionNames.ContainsKey($SubscriptionId)) {
        $response = Read-JsonResponse (Invoke-CloudRequest -Uri "https://management.azure.com/subscriptions/${SubscriptionId}?api-version=2022-12-01" -Resource 'https://management.azure.com/')
        if (-not $response.displayName) { throw 'Subscription response has no display name.' }
        $script:SubscriptionNames[$SubscriptionId] = $response.displayName
    }
    return $script:SubscriptionNames[$SubscriptionId]
}

function Get-ArcExtensions {
    param([string]$ResourceId, [hashtable]$MachineResource = $null)
    $kind = Get-ResourceKind $ResourceId
    if ($kind -eq 'ClassicVm') { return @() }
    if ($null -ne $MachineResource) {
        if ($MachineResource.ContainsKey('argExtensions') -and $null -ne $MachineResource['argExtensions']) {
            return @($MachineResource['argExtensions'] | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        }
        if ($kind -in @('AzureVm', 'VmssVm')) {
            $embedded = @(Get-InventoryValue $MachineResource @('resources'))
            if ($embedded.Count) {
                $items = foreach ($extension in $embedded) {
                    $version = Get-InventoryValue $extension @('properties', 'typeHandlerVersion')
                    $status = Get-InventoryValue $extension @('properties', 'provisioningState')
                    "$($extension.name) (version: $version; state: $status)"
                }
                return @($items | Sort-Object -Unique)
            }
        }
    }
    $apiVersion = if ($kind -in @('AzureVm', 'VmssVm')) { '2024-07-01' } else { '2024-07-10' }
    $prefix = "https://management.azure.com$ResourceId/extensions"
    $next = "${prefix}?api-version=$apiVersion"
    $seen = [Collections.Generic.HashSet[string]]::new()
    $extensions = @()
    while ($next) {
        if (-not $next.StartsWith("${prefix}?", [StringComparison]::OrdinalIgnoreCase) -or -not $seen.Add($next)) {
            throw 'Invalid or repeated Arc extension continuation link.'
        }
        $page = Read-JsonResponse (Invoke-CloudRequest -Uri $next -Resource 'https://management.azure.com/')
        if (-not $page.ContainsKey('value')) { throw 'Arc extension response is missing value.' }
        foreach ($extension in $page.value) {
            $version = Get-InventoryValue $extension @('properties', 'typeHandlerVersion')
            $status = Get-InventoryValue $extension @('properties', 'provisioningState')
            $extensions += "$($extension.name) (version: $version; state: $status)"
        }
        $next = [string](Get-InventoryValue $page @('nextLink'))
    }
    return @($extensions | Sort-Object -Unique)
}

function Test-MachineConnected {
    param([string]$Status)
    return ($Status -eq 'Connected' -or $Status -match '(?i)^VM running$|^Running$')
}

function Resolve-MachineStatusAndOS {
    param([string]$ResourceId, [hashtable]$Resource)
    $kind = Get-ResourceKind $ResourceId
    if ($kind -eq 'Arc') {
        return @{
            Status = [string](Get-InventoryValue $Resource @('properties', 'status'))
            OS = [string](Get-InventoryValue $Resource @('properties', 'osType'))
        }
    }
    $os = [string](Get-InventoryValue $Resource @('properties', 'storageProfile', 'osDisk', 'osType'))
    if (-not $os) {
        $os = if ($null -ne (Get-InventoryValue $Resource @('properties', 'osProfile', 'windowsConfiguration'))) { 'Windows' }
        elseif ($null -ne (Get-InventoryValue $Resource @('properties', 'osProfile', 'linuxConfiguration'))) { 'Linux' }
        else { '' }
    }
    $statuses = @(Get-InventoryValue $Resource @('properties', 'instanceView', 'statuses'))
    if (-not $statuses.Count) {
        $statuses = @(Get-InventoryValue $Resource @('properties', 'extended', 'instanceView', 'statuses'))
    }
    $powerDisplay = [string](Get-InventoryValue $Resource @('properties', 'extended', 'instanceView', 'powerState', 'displayStatus'))
    foreach ($s in $statuses) {
        $code = [string](Get-InventoryValue $s @('code'))
        if ($code.StartsWith('PowerState/', [StringComparison]::OrdinalIgnoreCase)) {
            $powerDisplay = [string](Get-InventoryValue $s @('displayStatus'))
            if (-not $powerDisplay) { $powerDisplay = $code }
        }
    }
    $status = if (-not [string]::IsNullOrWhiteSpace($powerDisplay)) { $powerDisplay.Trim() } else { 'VM running' }
    return @{ Status = $status; OS = $os }
}

function Get-DefenderExtensionStatus {
    param([array]$Extensions)
    $matches = foreach ($entry in @($Extensions)) {
        $text = [string]$entry
        if ($text -match '^\s*(MDE\.(?:Windows|Linux))\b(?:.*?\bstate:\s*([^);\s]+))?') {
            $name = $Matches[1]
            $state = if ($Matches[2]) { $Matches[2] } else { 'Installed' }
            "${name}: $state"
        }
    }
    $unique = @($matches | Sort-Object -Unique)
    if (-not $unique.Count) { return 'Not installed' }
    return ($unique -join '; ')
}

function Set-MdeInventory {
    param([hashtable]$State, [hashtable]$Candidate)
    $deviceName = [string]$Candidate.DeviceName
    $State.MdeDeviceId = $Candidate.DeviceId
    $State.MdeDeviceName = $deviceName
    $State.MdeLastSeen = ConvertTo-IsoTimestamp $Candidate.Timestamp
    $State.EntraDeviceId = $Candidate.AadDeviceId
    $State.MdeOnboardingStatus = $Candidate.OnboardingStatus
    $State.MdeSensorHealth = [string](Get-InventoryValue $Candidate @('SensorHealthState'))
    $State.MdeCloudPlatforms = [string](Get-InventoryValue $Candidate @('CloudPlatforms'))
    $State.MdeAzureVmId = [string](Get-InventoryValue $Candidate @('AzureVmId'))
    $State.MdeDeviceGroup = [string](Get-InventoryValue $Candidate @('MachineGroup'))
    if (-not $State.CloudProvider) { $State.CloudProvider = $State.MdeCloudPlatforms }
    if (-not $State.Fqdn -and $deviceName.Contains('.')) { $State.Fqdn = $deviceName }
    if (-not $State.ComputerName) { $State.ComputerName = $deviceName.Split('.')[0] }
    $publicIp = [string](Get-InventoryValue $Candidate @('PublicIP'))
    $State.IPAddresses = @(@($State.IPAddresses) + @($publicIp) | Where-Object { $_ } | Sort-Object -Unique)
}

function ConvertTo-TagList {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        if ($Value.TrimStart().StartsWith('[')) {
            $Value = ConvertFrom-Json -InputObject $Value -AsHashtable -NoEnumerate
        }
        else { $Value = $Value.Split(',') }
    }
    if ($Value -isnot [array]) { throw 'MDE tags must be a string list.' }
    $tags = foreach ($tag in $Value) {
        if ($tag -isnot [string]) { throw 'MDE tag values must be strings.' }
        if (-not [string]::IsNullOrWhiteSpace($tag)) { $tag.Trim() }
    }
    return @($tags | Sort-Object -CaseSensitive -Unique)
}

function Set-AzureTags {
    param([hashtable]$State, [hashtable]$Arc)
    $tags = Get-InventoryValue $Arc @('tags')
    $normalized = [ordered]@{}
    if ($null -ne $tags) {
        if ($tags -isnot [Collections.IDictionary]) { throw 'Azure resource tags must be a key/value object.' }
        foreach ($key in @($tags.Keys | Sort-Object -CaseSensitive)) {
            if ($tags[$key] -isnot [string]) { throw 'Azure resource tag values must be strings.' }
            $normalized[$key] = $tags[$key]
        }
    }
    $State.AzureTags = $normalized
}

function Set-MdeTags {
    param([hashtable]$State, [hashtable]$Candidate)
    $manual = @(ConvertTo-TagList (Get-InventoryValue $Candidate @('DeviceManualTags')))
    $dynamic = @(ConvertTo-TagList (Get-InventoryValue $Candidate @('DeviceDynamicTags')))
    $registry = @(ConvertTo-TagList (Get-InventoryValue $Candidate @('RegistryDeviceTag')))
    $State.MdeManualTags = $manual
    $State.MdeDynamicTags = $dynamic
    $State.MdeRegistryTags = $registry
    $State.MdeDeviceTags = @(@($manual) + @($dynamic) + @($registry) | Sort-Object -CaseSensitive -Unique)
}

function Get-MdeNetworkAddresses {
    param([string]$DeviceId)
    $literal = ConvertTo-Json -InputObject $DeviceId -Compress
    $query = @"
DeviceNetworkInfo
| where Timestamp >= ago(7d) and DeviceId == $literal
| summarize arg_max(Timestamp, *) by DeviceId, NetworkAdapterName, MacAddress
| project IPAddresses
| take 101
"@
    $result = Read-JsonResponse (Invoke-Graph -Path '/security/runHuntingQuery' -Method POST -Body @{ Query = $query; Timespan = 'P7D' })
    if (-not $result.ContainsKey('results') -or @($result.results).Count -gt 100) {
        throw 'Network inventory is missing results or exceeded its safety limit.'
    }
    $addresses = foreach ($row in $result.results) {
        $ips = if ($row.IPAddresses -is [string]) { ConvertFrom-Json -InputObject $row.IPAddresses -AsHashtable } else { $row.IPAddresses }
        foreach ($ip in $ips) {
            $address = [string](Get-InventoryValue $ip @('IPAddress'))
            if ($address) { $address }
        }
    }
    return @($addresses | Sort-Object -Unique)
}

function Get-MdeAntivirus {
    param([string]$DeviceId)
    $literal = ConvertTo-Json -InputObject $DeviceId -Compress
    $query = @"
DeviceTvmSecureConfigurationAssessment
| where Timestamp >= ago(7d) and DeviceId == $literal and ConfigurationId == 'scid-2010'
| summarize arg_max(Timestamp, *) by DeviceId
| project DeviceId, Timestamp, AvMode = tostring(parse_json(Context)[0][0])
| take 2
"@
    $result = Read-JsonResponse (Invoke-Graph -Path '/security/runHuntingQuery' -Method POST -Body @{ Query = $query; Timespan = 'P7D' })
    if (-not $result.ContainsKey('results')) { throw 'Antivirus hunting response is missing results.' }
    if (@($result.results).Count -gt 1) {
        throw 'Antivirus inventory returned multiple records for one device.'
    }
    if (-not @($result.results).Count) { return @{ Mode = ''; Timestamp = ''; Status = 'NoData' } }
    $row = $result.results[0]
    if ($row.DeviceId -ne $DeviceId) { throw 'Antivirus inventory returned a different device.' }
    $mode = [string]$row.AvMode
    if ([string]::IsNullOrWhiteSpace($mode)) { return @{ Mode = ''; Timestamp = $row.Timestamp; Status = 'NoData' } }
    $modes = @{ '0' = 'Active'; '1' = 'Passive'; '2' = 'Disabled'; '3' = 'Other'; '4' = 'EDRBlocked'; '5' = 'PassiveAudit' }
    if (-not $modes.ContainsKey($mode)) { throw "Antivirus inventory returned an unsupported mode code: $mode." }
    return @{ Mode = $modes[$mode]; Timestamp = $row.Timestamp; Status = 'Reported' }
}

function Test-Group {
    param([string]$GroupId, [switch]$AllowMissing)
    $allowStatus = if ($AllowMissing) { @(404) } else { @() }
    $response = Invoke-Graph -Path "/groups/${GroupId}?`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,isAssignableToRole" -AllowStatus $allowStatus
    if ($AllowMissing -and $response.Status -eq 404) { return $null }
    $group = Read-JsonResponse $response
    if ($group.securityEnabled -ne $true -or 'DynamicMembership' -in $group.groupTypes -or
        'Unified' -in $group.groupTypes -or $group.onPremisesSyncEnabled -eq $true -or $group.isAssignableToRole -eq $true) {
        throw 'Target must be a cloud-managed, assigned, non-role-assignable security group.'
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-InventoryValue $group @('displayName')))) {
        throw 'Target group response is missing its display name.'
    }
    return $group
}

function Test-DirectMembership {
    param([string]$GroupId, [string]$ObjectId)
    $response = Invoke-Graph -Path "/groups/$GroupId/members/${ObjectId}?`$select=id" -AllowStatus @(404)
    return $response.Status -eq 200
}

function Set-VerifiedMembership {
    param([hashtable]$State, [hashtable]$CloudTarget = $null, [hashtable]$Config = $null)
    if ($State['GroupId']) {
        $group = Test-Group $State.GroupId
        $State.GroupName = $group.displayName
    }
    else {
        $existingGroups = @(Get-DeviceCloudGroups -Config $Config -ObjectId ([string]$State['EntraObjectId']))
        if ($existingGroups.Count -gt 0) {
            # Device is already in one or more managed groups (Active, Passive, Multiple, or Wrong Account/Sub/Project).
            # Rules 2 & 3: if global flag is Passive and device is in an Active group, do NOT add to Passive;
            # if global flag is Active and device is in a Passive group, do NOT add to Active.
            # Rule 6: if in multiple groups, record all groups and flag.
            $State.MemberGroups = $existingGroups
            $State.GroupIds = @($existingGroups | ForEach-Object { [string]$_['Id'] })
            $State.GroupNames = @($existingGroups | ForEach-Object { [string]$_['DisplayName'] })
            $State.GroupId = $State.GroupIds[0]
            $State.GroupName = $State.GroupNames -join '; '
            $State.GroupAvMode = if ($existingGroups.Count -gt 1) { 'Multiple' } else { [string]$existingGroups[0]['GroupMode'] }
            $State.Membership = 'Present'
            $State.Status = 'Verified'
            $State.MembershipVerifiedAt = [datetimeoffset]::UtcNow.ToString('o')
            Update-GroupComplianceFlags $State
            return
        }
        if ($State['GroupName']) {
            $resolved = Resolve-GroupByDisplayName -DisplayName $State.GroupName -AdminUnitId $(if ($Config) { [string]$Config['AdminUnitId'] } else { '' })
            if ($null -eq $resolved) {
                if ($Config -and $Config['AutoCreateGroups'] -and $Config['AdminUnitId']) {
                    if ($State.Mode -eq 'Audit') {
                        $State.Membership = 'Absent'
                        $State.Status = 'WouldAdd'
                        $State.Action = 'WouldCreateGroupAndAdd'
                        return
                    }
                    $resolved = New-AdminUnitSecurityGroup -AdminUnitId $Config.AdminUnitId -DisplayName $State.GroupName -Description "Managed by Arc-to-Entra Sync ($($State['CloudGroupType']) $($State['CloudIdentifier']) - $($State['CloudGroupOS']) $($State['GroupAvMode']))" -State $State
                    if ($CloudTarget -and $CloudTarget['CounterpartGroupName']) {
                        $counterpartExisting = Resolve-GroupByDisplayName -DisplayName $CloudTarget.CounterpartGroupName -AdminUnitId ([string]$Config['AdminUnitId'])
                        if ($null -eq $counterpartExisting) {
                            $null = New-AdminUnitSecurityGroup -AdminUnitId $Config.AdminUnitId -DisplayName $CloudTarget.CounterpartGroupName -Description "Managed by Arc-to-Entra Sync ($($State['CloudGroupType']) $($State['CloudIdentifier']) - $($State['CloudGroupOS']) $($CloudTarget['CounterpartGroupMode']))" -State $State
                        }
                    }
                }
                else {
                    $State.Membership = 'GroupNotFound'
                    $State.Status = 'GroupNotFound'
                    return
                }
            }
            $State.GroupId = $resolved.Id
            $State.GroupName = $resolved.DisplayName
            if ($Config -and $Config.AdminUnitId -and $script:SharedAdminUnitGroups.ContainsKey($Config.AdminUnitId) -and $script:SharedAdminUnitGroups[$Config.AdminUnitId]) {
                $validatedGroup = Test-Group $State.GroupId
                if (-not [string]::Equals([string]$validatedGroup.displayName, $State.GroupName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Resolved group '$($State.GroupId)' no longer matches '$($State.GroupName)'; membership update is blocked."
                }
            }
        }
        else {
            $State.Membership = 'MissingIdentifier'
            $State.Status = 'MissingCloudIdentifier'
            return
        }
    }
    $effectiveMode = if ($State['GroupAvMode']) { [string]$State['GroupAvMode'] }
    elseif ($CloudTarget -and $CloudTarget['DefaultGroupMode']) { [string]$CloudTarget['DefaultGroupMode'] }
    else { Get-Setting 'SYNC_DEFAULT_GROUP_MODE' 'Passive' }
    $groupOSCategory = [string]$State['CloudGroupOS']
    if ($Config) {
        $parsedGroup = ConvertFrom-CloudGroupDisplayName -Config $Config -DisplayName $State.GroupName
        if ($parsedGroup.Matched) { $groupOSCategory = $parsedGroup.OSCategory }
    }
    if (Test-DirectMembership $State.GroupId $State.EntraObjectId) {
        $State.Membership = 'Present'
        $State.Status = 'Verified'
        $State.MembershipVerifiedAt = [datetimeoffset]::UtcNow.ToString('o')
        $State.GroupAvMode = $effectiveMode
        $State.MemberGroups = @(@{
            Id = $State.GroupId
            DisplayName = $State.GroupName
            CloudType = [string]$State['CloudGroupType']
            OSCategory = $groupOSCategory
            GroupMode = $effectiveMode
            CloudIdentifier = [string]$State['CloudIdentifier']
        })
        $State.GroupIds = @($State.GroupId)
        $State.GroupNames = @($State.GroupName)
        Update-GroupComplianceFlags $State
        return
    }
    $State.Membership = 'Absent'
    if ($State.Mode -eq 'Audit') { $State.Status = 'WouldAdd'; return }
    if ($Config -and $Config.AdminUnitId -and $script:SharedAdminUnitGroups.ContainsKey($Config.AdminUnitId) -and $script:SharedAdminUnitGroups[$Config.AdminUnitId]) {
        $filter = [uri]::EscapeDataString("id eq '$($State.GroupId)'")
        $auMembership = Invoke-Graph -Path "/directory/administrativeUnits/$($Config.AdminUnitId)/members?`$filter=$filter&`$select=id&`$count=true" -Headers @{ ConsistencyLevel = 'eventual' } -AllowStatus @(404)
        $auMembers = @(if ($auMembership.Status -ne 404) { (Read-JsonResponse $auMembership).value })
        if ($auMembers.Count -ne 1 -or [string]$auMembers[0]['id'] -ne [string]$State.GroupId) {
            throw "Resolved group '$($State.GroupId)' is no longer in Administrative Unit '$($Config.AdminUnitId)'; membership update is blocked."
        }
    }
    Write-MutationIntent $State.Key $State
    $response = Invoke-Graph -Path "/groups/$($State.GroupId)/members/`$ref" -Method POST -Body @{
        '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($State.EntraObjectId)"
    } -AllowStatus @(400)
    $present = $false
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $present = Test-DirectMembership $State.GroupId $State.EntraObjectId
        if ($present) { break }
        if ($attempt -lt 2) { Start-Sleep -Seconds 2 }
    }
    if (-not $present) { throw "Membership addition was not verified (write HTTP $($response.Status))." }
    $State.Membership = 'Present'
    $State.Status = 'Verified'
    $State.Action = if ($response.Status -eq 204) { 'AddedAndVerified' } else { 'PresentAfterConcurrentWrite' }
    $State.MembershipVerifiedAt = [datetimeoffset]::UtcNow.ToString('o')
    $State.GroupAvMode = $effectiveMode
    $State.MemberGroups = @(@{
        Id = $State.GroupId
        DisplayName = $State.GroupName
        CloudType = [string]$State['CloudGroupType']
        OSCategory = $groupOSCategory
        GroupMode = $effectiveMode
        CloudIdentifier = [string]$State['CloudIdentifier']
    })
    $State.GroupIds = @($State.GroupId)
    $State.GroupNames = @($State.GroupName)
    Update-GroupComplianceFlags $State
}

function Get-GuestConfigEntraDeviceId {
    param([string]$ResourceId, [string]$SubscriptionId, [hashtable]$MachineResource = $null)
    if ($null -ne $MachineResource -and $MachineResource.ContainsKey('gcEntraDeviceId') -and $MachineResource['gcEntraDeviceId']) {
        $preloadedGuid = [guid]::Empty
        if ([guid]::TryParse(([string]$MachineResource['gcEntraDeviceId']).Trim(), [ref]$preloadedGuid) -and $preloadedGuid -ne [guid]::Empty) {
            return $preloadedGuid.ToString()
        }
    }
    if (-not $ResourceId -or -not $SubscriptionId) { return '' }
    try {
        $machineLiteral = ConvertTo-Json -InputObject $ResourceId.ToLowerInvariant() -Compress
        $gcQuery = @"
GuestConfigurationResources
| where type =~ 'microsoft.guestconfiguration/guestconfigurationassignments'
| where tolower(name) startswith 'entraiddeviceid'
| extend machineId = tolower(substring(id, 0, indexof(tolower(id), '/providers/microsoft.guestconfiguration/')))
| where machineId == $machineLiteral
| extend reasonPhrase = tostring(properties.latestAssignmentReport.resources[0].reasons[0].phrase)
| parse reasonPhrase with * "intuneDeviceId=" gcEntraDeviceId
| where isnotempty(gcEntraDeviceId)
| project gcEntraDeviceId
| take 1
"@
        $gcResult = Read-JsonResponse (Invoke-CloudRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Resource 'https://management.azure.com/' -Method POST -Body @{
            subscriptions = @($SubscriptionId)
            query = $gcQuery
            options = @{ resultFormat = 'objectArray' }
        })
        foreach ($row in @($gcResult.data)) {
            $parsed = [guid]::Empty
            if ($row['gcEntraDeviceId'] -and [guid]::TryParse(([string]$row['gcEntraDeviceId']).Trim(), [ref]$parsed) -and $parsed -ne [guid]::Empty) {
                return $parsed.ToString()
            }
        }
    }
    catch {}
    return ''
}

function Resolve-EntraDeviceForMachine {
    param([hashtable]$State)
    $primaryNote = 'MDE DeviceInfo.AadDeviceId was empty (machine is not Entra joined / hybrid joined).'
    # 1. Primary path: MDE AadDeviceId -> Entra deviceId
    if (-not [string]::IsNullOrWhiteSpace([string]$State['EntraDeviceId'])) {
        $parsedGuid = [guid]::Empty
        if ([guid]::TryParse([string]$State['EntraDeviceId'], [ref]$parsedGuid) -and $parsedGuid -ne [guid]::Empty) {
            $deviceId = $parsedGuid.ToString()
            $filter = [uri]::EscapeDataString("deviceId eq '$deviceId'")
            $devices = Read-JsonResponse (Invoke-Graph -Path "/devices?`$filter=$filter&`$select=id,deviceId,accountEnabled&`$top=2")
            Write-SyncTrace 'MachineSync' "Entra /devices lookup for deviceId=$deviceId returned $(@($devices.value).Count) object(s)"
            if ($devices.ContainsKey('@odata.nextLink') -or @($devices.value).Count -gt 1) {
                return @{
                    Status = 'Ambiguous'
                    Device = $null
                    CorrelationPath = 'AadDeviceIdAmbiguous'
                    Diagnostic = "Multiple Entra ID device objects matched deviceId '$deviceId'. Sync failed closed to avoid ambiguity."
                }
            }
            if (@($devices.value).Count -eq 1) {
                return @{
                    Status = 'Found'
                    Device = $devices.value[0]
                    CorrelationPath = 'MdeAadDeviceId'
                    Diagnostic = "Correlated via MDE DeviceInfo.AadDeviceId ($deviceId) matching Entra ID deviceId."
                }
            }
            $primaryNote = "MDE reported AadDeviceId '$deviceId', but GET /v1.0/devices?`$filter=deviceId eq '$deviceId' returned 0 objects in this Entra tenant."
        }
    }

    # 2. Machine Configuration (GuestConfigurationResources) intuneDeviceId path:
    # Reads intuneDeviceId reported by entraiddeviceid / entraiddeviceidlinux DSC package (EnrollmentPayload / wdavstate) -> Entra deviceId
    $gcDeviceId = ([string]$State['GuestConfigEntraDeviceId']).Trim()
    $gcNote = 'Machine Configuration assignment (entraiddeviceid / entraiddeviceidlinux) has not reported an intuneDeviceId yet.'
    if (-not [string]::IsNullOrWhiteSpace($gcDeviceId)) {
        $gcGuid = [guid]::Empty
        if ([guid]::TryParse($gcDeviceId, [ref]$gcGuid) -and $gcGuid -ne [guid]::Empty) {
            $gcIdStr = $gcGuid.ToString()
            $filter = [uri]::EscapeDataString("deviceId eq '$gcIdStr'")
            $gcDevices = Read-JsonResponse (Invoke-Graph -Path "/devices?`$filter=$filter&`$select=id,deviceId,displayName,operatingSystem,managementType,accountEnabled&`$top=2")
            Write-SyncTrace 'MachineSync' "Entra /devices lookup for Machine Configuration intuneDeviceId=$gcIdStr returned $(@($gcDevices.value).Count) object(s)"
            if ($gcDevices.ContainsKey('@odata.nextLink') -or @($gcDevices.value).Count -gt 1) {
                return @{
                    Status = 'Ambiguous'
                    Device = $null
                    CorrelationPath = 'GuestConfigIntuneDeviceIdAmbiguous'
                    Diagnostic = "Multiple Entra ID device objects matched Machine Configuration intuneDeviceId '$gcIdStr'. Sync failed closed."
                }
            }
            if (@($gcDevices.value).Count -eq 1) {
                return @{
                    Status = 'Found'
                    Device = $gcDevices.value[0]
                    CorrelationPath = 'GuestConfigurationIntuneDeviceId'
                    Diagnostic = "Correlated via Azure Machine Configuration intuneDeviceId ($gcIdStr) matching Entra ID deviceId."
                }
            }
            $gcNote = "Machine Configuration reported intuneDeviceId '$gcIdStr', but GET /v1.0/devices?`$filter=deviceId eq '$gcIdStr' returned 0 objects in Entra ID."
        }
    }

    # 3. Fallback path (when both MDE AadDeviceId and Machine Configuration intuneDeviceId are empty or not found in Entra):
    # Query Entra /devices by candidate hostnames and match OS + managementType == 'MicrosoftSense'
    $candidateNames = [Collections.Generic.List[string]]::new()
    foreach ($rawName in @($State['ComputerName'], $State['MdeDeviceName'], $State['Fqdn'], $State['MachineName'])) {
        $clean = ([string]$rawName).Trim()
        if (-not [string]::IsNullOrWhiteSpace($clean)) {
            if ($clean -notin $candidateNames) { $candidateNames.Add($clean) }
            if ($clean.Contains('.')) {
                $short = ($clean -split '\.')[0].Trim()
                if ($short -and $short -notin $candidateNames) { $candidateNames.Add($short) }
            }
        }
    }
    $expectedOs = ([string]$State['OS']).Trim()
    $fallbackSelect = 'id,deviceId,displayName,operatingSystem,managementType,accountEnabled'
    $fallbackNotes = [Collections.Generic.List[string]]::new()
    foreach ($hostname in $candidateNames) {
        $escapedHost = $hostname.Replace("'", "''")
        $filter = [uri]::EscapeDataString("displayName eq '$escapedHost'")
        $response = Read-JsonResponse (Invoke-Graph -Path "/devices?`$filter=$filter&`$select=$fallbackSelect&`$top=25")
        if (-not $response.ContainsKey('value')) { continue }
        $matches = @($response.value)
        Write-SyncTrace 'MachineSync' "Entra MicrosoftSense fallback lookup for displayName='$hostname' (OS='$expectedOs') returned $($matches.Count) candidate(s)"
        if (-not $matches.Count) {
            $fallbackNotes.Add("displayName='$hostname' (0 matches)")
            continue
        }

        $senseMatches = @($matches | Where-Object {
            [string]$_['displayName'] -ieq $hostname -and
            (-not $expectedOs -or [string]$_['operatingSystem'] -ieq $expectedOs -or ([string]$_['operatingSystem']).StartsWith($expectedOs, [StringComparison]::OrdinalIgnoreCase)) -and
            [string]$_['managementType'] -ieq 'MicrosoftSense'
        })
        if ($senseMatches.Count -eq 1) {
            return @{
                Status = 'Found'
                Device = $senseMatches[0]
                CorrelationPath = 'MicrosoftSenseHostnameAndOS'
                Diagnostic = "Correlated via MicrosoftSense fallback (displayName='$hostname', operatingSystem='$expectedOs', managementType='MicrosoftSense')."
            }
        }
        if ($senseMatches.Count -gt 1) {
            $enabledSense = @($senseMatches | Where-Object { $_['accountEnabled'] -eq $true })
            if ($enabledSense.Count -eq 1) {
                return @{
                    Status = 'Found'
                    Device = $enabledSense[0]
                    CorrelationPath = 'MicrosoftSenseHostnameAndOS'
                    Diagnostic = "Correlated via unique enabled MicrosoftSense fallback device (displayName='$hostname', operatingSystem='$expectedOs')."
                }
            }
            return @{
                Status = 'Ambiguous'
                Device = $null
                CorrelationPath = 'MicrosoftSenseAmbiguous'
                Diagnostic = "Multiple ($($senseMatches.Count)) MicrosoftSense Entra devices matched displayName='$hostname' and operatingSystem='$expectedOs'. Sync failed closed."
            }
        }
        $foundSummary = @($matches | ForEach-Object { "OS=$([string]$_['operatingSystem'])/mgmt=$([string]$_['managementType'])" }) -join ', '
        $fallbackNotes.Add("displayName='$hostname' ($($matches.Count) found [$foundSummary], none matched OS='$expectedOs' + managementType='MicrosoftSense')")
    }

    $fallbackDetail = if ($fallbackNotes.Count) {
        "MicrosoftSense fallback checked $($fallbackNotes -join '; ')."
    }
    else {
        'No candidate hostnames were available for MicrosoftSense fallback lookup.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$State['EntraDeviceId']) -or -not [string]::IsNullOrWhiteSpace($gcDeviceId)) {
        return @{
            Status = 'EntraDeviceNotFound'
            Device = $null
            CorrelationPath = 'None'
            Diagnostic = "1. $primaryNote 2. $gcNote 3. $fallbackDetail"
        }
    }
    return @{
        Status = 'NoEntraDevice'
        Device = $null
        CorrelationPath = 'None'
        Diagnostic = "1. $primaryNote 2. $gcNote 3. $fallbackDetail"
    }
}

function Invoke-MachineSync {
    param([hashtable]$Work)
    Start-SyncTranscript 'MachineSync'
    $id = ConvertTo-ArcId ([string]$Work.ResourceId)
    $config = Get-SyncConfig
    $key = Get-MachineKey $id
    Write-SyncTrace 'MachineSync' "Starting machine sync for ResourceId=$id (Key=$key, Source=$($Work.Source), RunId=$($Work.RunId))"
    $previous = Get-MachineState $key
    $state = @{
        Key = $key; ArcResourceId = $id; MachineName = (Get-MachineDisplayName $id)
        SubscriptionId = $id.Split('/')[2]; ResourceGroup = $id.Split('/')[4]
        GroupId = ''; GroupName = ''; GroupIds = @(); GroupNames = @(); MemberGroups = @()
        GroupAvMode = $config.DefaultGroupMode; DefaultGroupMode = $config.DefaultGroupMode
        GroupFlags = @(); GroupFlagCodes = @(); GroupComplianceStatus = 'NotInGroup'
        CloudGroupType = ''; CloudGroupOS = ''; CloudIdentifier = ''
        Mode = $config.Mode; RunId = ([guid]$Work.RunId).ToString()
        Source = [string]$Work.Source; FirstSeen = [datetimeoffset]::UtcNow.ToString('o')
        LastChecked = [datetimeoffset]::UtcNow.ToString('o'); ArcStatus = 'Unknown'; OS = ''
        Status = 'PendingMde'; Membership = 'Unknown'; MembershipVerifiedAt = ''
        MdeDeviceId = ''; MdeDeviceName = ''; MdeLastSeen = ''; EntraDeviceId = ''; EntraObjectId = ''
        GuestConfigEntraDeviceId = ''; EntraCorrelationPath = ''; EntraDiagnostic = ''
        SubscriptionName = ''; ManagementGroup = ''; ComputerName = ''; Fqdn = ''; CloudProvider = ''; VirtualMachineId = ''
        ArcExtensions = @(); DefenderExtensionStatus = ''; IPAddresses = @(); MdeSensorHealth = ''; MdeOnboardingStatus = ''
        MdeAntivirusMode = ''; MdeAntivirusTimestamp = ''; MdeAntivirusStatus = 'NotCollected'
        MdeCloudPlatforms = ''; MdeAzureVmId = ''; InventoryStatus = 'NotCollected'; InventoryErrors = @()
        MdeDeviceTags = $null; MdeManualTags = $null; MdeDynamicTags = $null; MdeRegistryTags = $null
        MdeDeviceGroup = ''; AzureTags = $null; ArcLastReportedAt = ''; ArcAddedAt = ''
        Error = ''; Action = 'Observed'
    }
    if ($previous) {
        $state.FirstSeen = $previous.Data.FirstSeen
        $state.ArcAddedAt = [string]$previous.Data['ArcAddedAt']
    }
    try {
        $armUri = Get-MachineArmUri $id
        $preloadedArc = if ($Work.ContainsKey('ResourceData') -and $Work['ResourceData'] -is [Collections.IDictionary] -and $Work['ResourceData'].ContainsKey('properties')) {
            [hashtable]$Work['ResourceData']
        } else { $null }
        $arcResponse = if ($null -ne $preloadedArc) {
            @{ Status = 200; Preloaded = $true }
        } else {
            Invoke-CloudRequest -Uri $armUri -Resource 'https://management.azure.com/' -AllowStatus @(404)
        }
        if ($arcResponse.Status -eq 404) {
            $state.Status = 'ArcMissing'
            $state.ArcStatus = 'Missing'
        }
        else {
            $arc = if ($null -ne $preloadedArc) { $preloadedArc } else { Read-JsonResponse $arcResponse }
            $armName = [string](Get-InventoryValue $arc @('name'))
            if ($armName) { $state.MachineName = $armName }
            $resolvedMeta = Resolve-MachineStatusAndOS -ResourceId $id -Resource $arc
            $state.ArcStatus = $resolvedMeta.Status
            $state.OS = $resolvedMeta.OS
            $state.InventoryStatus = 'Collected'
            Set-ArcInventory $state $arc
            Invoke-InventoryStep $state 'Azure resource tags' { Set-AzureTags $state $arc }
            Invoke-InventoryStep $state 'Subscription name' {
                $argSubName = [string](Get-InventoryValue $arc @('subscriptionName'))
                if ($argSubName) {
                    $script:SubscriptionNames[$state.SubscriptionId] = $argSubName
                    $state.SubscriptionName = $argSubName
                } else {
                    $state.SubscriptionName = Get-SubscriptionName $state.SubscriptionId
                }
                $argMg = [string](Get-InventoryValue $arc @('managementGroup'))
                if ($argMg) {
                    $state.ManagementGroup = $argMg
                } elseif ($config.ManagementGroups.Count) {
                    $state.ManagementGroup = $config.ManagementGroups -join ', '
                }
            }
            Invoke-InventoryStep $state 'Arc extensions' {
                $state.ArcExtensions = @(Get-ArcExtensions -ResourceId $id -MachineResource $arc)
                $state.DefenderExtensionStatus = Get-DefenderExtensionStatus $state.ArcExtensions
            }
            $state.GuestConfigEntraDeviceId = Get-GuestConfigEntraDeviceId -ResourceId $id -SubscriptionId $state.SubscriptionId -MachineResource $arc
            Write-SyncTrace 'MachineSync' "ARM metadata collected for $($state.MachineName)" @{
                ArcStatus = $state.ArcStatus
                OS = $state.OS
                ComputerName = $state.ComputerName
                Fqdn = $state.Fqdn
                CloudProvider = $state.CloudProvider
                SubscriptionName = $state.SubscriptionName
                VirtualMachineId = $state.VirtualMachineId
                GuestConfigEntraDeviceId = $state.GuestConfigEntraDeviceId
                DefenderExtensionStatus = $state.DefenderExtensionStatus
                ArcExtensions = $state.ArcExtensions
                AzureTags = $state.AzureTags
            }
            $preloadedMde = if ($Work.ContainsKey('MdeData') -and $Work['MdeData'] -is [Collections.IDictionary] -and $Work['MdeData'].ContainsKey('Candidates')) {
                [hashtable]$Work['MdeData']
            } else { $null }
            $candidates = @(
                if ($null -ne $preloadedMde) {
                    $preloadedMde['Candidates']
                } else {
                    Get-MdeCandidates -ResourceId $id -VirtualMachineId $state.VirtualMachineId
                }
            ) | Where-Object { $null -ne $_ -and $_ -is [Collections.IDictionary] }
            $correlation = Get-Correlation -Candidates $candidates -FreshnessHours $config.FreshnessHours
            Write-SyncTrace 'MachineSync' "Correlation evaluated for $($state.MachineName): status=$($correlation.Status), candidates=$(@($candidates).Count), arcStatus=$($state.ArcStatus), os=$($state.OS)"
            $displayCandidate = $correlation.Candidate
            if (-not $displayCandidate) {
                $unmerged = @($candidates | Where-Object { $null -ne $_ -and $_ -is [Collections.IDictionary] -and -not $_['MergedToDeviceId'] })
                if ($unmerged.Count -eq 1) { $displayCandidate = $unmerged[0] }
            }
            if ($displayCandidate) {
                Set-MdeInventory $state $displayCandidate
                Invoke-InventoryStep $state 'MDE device tags' { Set-MdeTags $state $displayCandidate }
                Invoke-InventoryStep $state 'MDE network addresses' {
                    $netAddrs = if ($null -ne $preloadedMde -and $preloadedMde.ContainsKey('NetworkAddresses')) {
                        @($preloadedMde['NetworkAddresses'])
                    } else {
                        @(Get-MdeNetworkAddresses $state.MdeDeviceId)
                    }
                    $state.IPAddresses = @(@($state.IPAddresses) + $netAddrs | Sort-Object -Unique)
                }
                $state.MdeAntivirusStatus = 'Failed'
                Invoke-InventoryStep $state 'MDE antivirus mode' {
                    $av = if ($null -ne $preloadedMde -and $preloadedMde['Antivirus'] -is [Collections.IDictionary]) {
                        $preloadedMde['Antivirus']
                    } else {
                        Get-MdeAntivirus $state.MdeDeviceId
                    }
                    $state.MdeAntivirusMode = $av.Mode
                    $state.MdeAntivirusTimestamp = $av.Timestamp
                    $state.MdeAntivirusStatus = $av.Status
                }
            }
            $cloudTarget = Resolve-CloudGroupTarget -Config $config -State $state
            Write-SyncTrace 'MachineSync' "Resolved Cloud x OS group target for $($state.MachineName)" $cloudTarget
            $state.CloudGroupType = $cloudTarget.CloudType
            $state.CloudGroupOS = $cloudTarget.OSCategory
            $state.CloudIdentifier = $cloudTarget.CloudIdentifier
            $state.DefaultGroupMode = $cloudTarget.DefaultGroupMode
            $state.GroupAvMode = $cloudTarget.DefaultGroupMode
            $state.GroupName = $cloudTarget.GroupName
            if (-not $cloudTarget.Enabled) {
                $state.Membership = 'NotConfigured'
            }
            elseif (-not $cloudTarget.GroupName) {
                $state.Membership = 'MissingIdentifier'
            }
            if (-not (Test-MachineConnected $state.ArcStatus)) {
                $state.Status = 'ArcNotConnected'
                $state.EntraDiagnostic = "Machine status is '$($state.ArcStatus)' (not connected/running); Entra ID correlation was skipped."
            }
            else {
                $state.Status = $correlation.Status
                if ($state.Status -eq 'PendingMde') {
                    $state.EntraDiagnostic = "No onboarded MDE DeviceInfo record matched Resource ID '$id'$(if ($state.VirtualMachineId) { " or VM ID '$($state.VirtualMachineId)'" }) within the 7-day hunting window. Entra ID lookup requires MDE correlation first."
                }
                elseif ($state.Status -eq 'StaleEvidence') {
                    $state.EntraDiagnostic = "MDE DeviceInfo record matched ($($state.MdeDeviceName)), but its latest timestamp ($($state.MdeLastSeen)) is older than SYNC_FRESHNESS_HOURS ($($config.FreshnessHours)h)."
                }
                elseif ($state.Status -eq 'Ambiguous') {
                    $state.EntraDiagnostic = "Multiple ($($candidates.Count)) active MDE DeviceInfo records matched this machine within the freshness window. Sync paused until duplicates age out."
                }
                elseif ($state.Status -in @('Matched', 'NoEntraDevice')) {
                    $entraResolution = Resolve-EntraDeviceForMachine $state
                    $state.EntraCorrelationPath = [string]$entraResolution['CorrelationPath']
                    $state.EntraDiagnostic = [string]$entraResolution['Diagnostic']
                    if ($entraResolution.Status -ne 'Found') {
                        $state.Status = $entraResolution.Status
                    }
                    else {
                        $device = $entraResolution.Device
                        $state.EntraObjectId = ([guid]$device.id).ToString()
                        if ($device['deviceId']) {
                            $devGuid = [guid]::Empty
                            if ([guid]::TryParse([string]$device['deviceId'], [ref]$devGuid) -and $devGuid -ne [guid]::Empty) {
                                $state.EntraDeviceId = $devGuid.ToString()
                            }
                        }
                        if ($device.accountEnabled -ne $true) {
                            $state.Status = 'EntraDeviceDisabled'
                            $state.EntraDiagnostic = "Entra ID device object $($state.EntraObjectId) (deviceId=$($state.EntraDeviceId)) was found via $($state.EntraCorrelationPath), but accountEnabled is false."
                        }
                        elseif (-not $cloudTarget.Enabled) { $state.Status = 'GroupNotConfigured' }
                        elseif (-not $cloudTarget.GroupName) { $state.Status = 'MissingCloudIdentifier' }
                        else {
                            $state.Status = 'Matched'
                            # Recheck machine state immediately before evaluating a membership write.
                            $check = Read-JsonResponse (Invoke-CloudRequest -Uri $armUri -Resource 'https://management.azure.com/')
                            $recheckMeta = Resolve-MachineStatusAndOS -ResourceId $id -Resource $check
                            if (-not (Test-MachineConnected $recheckMeta.Status)) { $state.Status = 'ArcNotConnected'; $state.ArcStatus = $recheckMeta.Status }
                            else {
                                Set-VerifiedMembership $state $cloudTarget $config
                                Write-SyncTrace 'MachineSync' "Completed group evaluation for $($state.MachineName) (correlationPath=$($entraResolution.CorrelationPath)): status=$($state.Status), membership=$($state.Membership), groupName=$($state.GroupName), flags=$($state.GroupFlags -join '; ')"
                            }
                        }
                    }
                }
            }
        }
    }
    catch {
        $state.Status = 'Failed'
        $state.Membership = 'Unknown'
        $state.Error = $_.Exception.Message.Substring(0, [math]::Min(1000, $_.Exception.Message.Length))
        Save-MachineState $state $previous
        try {
            $reason = switch ($state.Source) {
                'EventGrid' { 'Event Grid (Compliant Machine Configuration assignment or succeeded MDE extension)' }
                'Schedule' { 'Scheduled inventory reconciliation' }
                default { "Service Bus queue ($($state.Source))" }
            }
            Write-FunctionLog @{
                Timestamp = $state.LastChecked
                FunctionName = 'Machine'
                TriggerReason = $reason
                Status = 'Failed'
                Health = 'Degraded'
                Message = "$($state.MachineName): $($state.Error)"
                RunId = $state.RunId
                ResourceId = $state.ArcResourceId
            }
        }
        catch {
            Write-Warning "Could not persist function failure log: $($_.Exception.Message)"
        }
        Write-Error "Sync failed for $key, run $($state.RunId): $($state.Error)" -ErrorAction Continue
        throw
    }
    Save-MachineState $state $previous
    try {
        $reason = switch ($state.Source) {
            'EventGrid' { 'Event Grid (Compliant Machine Configuration assignment or succeeded MDE extension)' }
            'Schedule' { 'Scheduled inventory reconciliation' }
            default { "Service Bus queue ($($state.Source))" }
        }
        $healthState = if ($state.InventoryStatus -eq 'Partial') { 'Degraded' } else { 'Healthy' }
        $detail = if ($state.InventoryErrors.Count) { " ($($state.InventoryErrors -join '; '))" } else { '' }
        Write-FunctionLog @{
            Timestamp = $state.LastChecked
            FunctionName = 'Machine'
            TriggerReason = $reason
            Status = $state.Status
            Health = $healthState
            Message = "$($state.MachineName): status=$($state.Status), membership=$($state.Membership)$detail"
            RunId = $state.RunId
            ResourceId = $state.ArcResourceId
        }
    }
    catch {
        Write-Warning "Could not persist function completion log: $($_.Exception.Message)"
    }
    Write-Information "Sync completed: key=$key status=$($state.Status) run=$($state.RunId)" -InformationAction Continue
}

function Test-ReportReader {
    param($Request)
    $encoded = $Request.Headers['X-MS-CLIENT-PRINCIPAL']
    if (-not $encoded) { return $false }
    $principal = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$encoded))) -AsHashtable
    if ($principal.auth_typ -ne 'aad') { return $false }
    $roles = @($principal.claims | Where-Object {
        $_.typ -eq 'roles' -or $_.typ -eq 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role'
    } | ForEach-Object { $_.val })
    $tenants = @($principal.claims | Where-Object {
        $_.typ -eq 'tid' -or $_.typ -eq 'http://schemas.microsoft.com/identity/claims/tenantid'
    } | ForEach-Object { $_.val })
    return 'Report.Reader' -in $roles -and (Get-Setting 'SYNC_TENANT_ID') -in $tenants
}

function Test-ReportSyncRequest {
    param($Request)
    if ($Request.Method -ne 'POST' -or $Request.Headers['X-Sync-Action'] -cne 'start') { return $false }
    $hostname = Get-Setting 'WEBSITE_HOSTNAME'
    return [string]$Request.Headers['Origin'] -ieq "https://$hostname"
}

Export-ModuleMember -Function Get-*, Resolve-*, Format-CloudGroupName, ConvertFrom-CloudGroupDisplayName, New-AdminUnitSecurityGroup, New-ReportSyncRequest, Update-GroupComplianceFlags, Set-VerifiedMembership, ConvertTo-ArcId, Invoke-MdeExtensionEvent, Invoke-InventorySync, Invoke-MachineSync, Test-ReportReader, Test-ReportSyncRequest, Write-FunctionLog, Write-WorkerConfiguration
