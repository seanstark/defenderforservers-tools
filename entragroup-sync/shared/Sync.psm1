Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Tokens = @{}
$script:SubscriptionNames = @{}
$script:ManagementGroupSubscriptions = @{}
$script:ManagementGroupCacheExpires = [datetimeoffset]::MinValue

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

function Get-SyncConfig {
    $rawSubscriptions = Get-OptionalSetting 'SYNC_SUBSCRIPTION_IDS'
    $subscriptions = @()
    if ($rawSubscriptions) {
        $subscriptions = @($rawSubscriptions.Split(',', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
            ([guid]$_.Trim()).ToString().ToLowerInvariant()
        } | Sort-Object -Unique)
    }
    $rawManagementGroups = Get-OptionalSetting 'SYNC_MANAGEMENT_GROUP_IDS'
    $managementGroups = @()
    if ($rawManagementGroups) {
        $managementGroups = @($rawManagementGroups.Split(',', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
            $mg = $_.Trim()
            if ($mg -notmatch '^[A-Za-z0-9._()-]{1,90}$') { throw "Invalid management group ID '$mg'." }
            $mg
        } | Sort-Object -Unique)
    }
    if (-not $subscriptions.Count -and -not $managementGroups.Count) {
        throw "At least one of 'SYNC_SUBSCRIPTION_IDS' or 'SYNC_MANAGEMENT_GROUP_IDS' must be configured."
    }
    $rawResourceGroups = Get-OptionalSetting 'SYNC_RESOURCE_GROUP_NAMES'
    $resourceGroups = @()
    if ($rawResourceGroups) {
        $resourceGroups = @($rawResourceGroups.Split(',', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
            $rg = $_.Trim().ToLowerInvariant()
            if ($rg -notmatch '^[a-z0-9._()-]{1,90}$') { throw "Invalid resource group name '$rg'." }
            $rg
        } | Sort-Object -Unique)
    }
    $defaultGroup = Get-OptionalSetting 'SYNC_GROUP_ID'
    $groupId = if ($defaultGroup) { ([guid]$defaultGroup).ToString() } else { '' }
    $rawWindowsGroup = Get-OptionalSetting 'SYNC_WINDOWS_GROUP_ID'
    $windowsGroupId = if ($rawWindowsGroup) { ([guid]$rawWindowsGroup).ToString() } else { $groupId }
    $rawLinuxGroup = Get-OptionalSetting 'SYNC_LINUX_GROUP_ID'
    $linuxGroupId = if ($rawLinuxGroup) { ([guid]$rawLinuxGroup).ToString() } else { $groupId }
    if (-not $groupId -and -not $windowsGroupId -and -not $linuxGroupId) {
        throw "Configure 'SYNC_GROUP_ID' or OS-specific group IDs ('SYNC_WINDOWS_GROUP_ID' / 'SYNC_LINUX_GROUP_ID')."
    }
    $mode = Get-Setting 'SYNC_MODE' 'Audit'
    if ($mode -notin @('Audit', 'Enforce')) { throw 'SYNC_MODE must be Audit or Enforce.' }
    $hours = [int](Get-Setting 'SYNC_FRESHNESS_HOURS' '24')
    if ($hours -lt 1 -or $hours -gt 168) { throw 'SYNC_FRESHNESS_HOURS must be between 1 and 168.' }
    @{
        Subscriptions = $subscriptions
        ManagementGroups = $managementGroups
        ResourceGroups = $resourceGroups
        GroupId = $groupId
        WindowsGroupId = $windowsGroupId
        LinuxGroupId = $linuxGroupId
        Mode = $mode
        FreshnessHours = $hours
    }
}

function Resolve-TargetGroupId {
    param([hashtable]$Config, [string]$OSType)
    $os = $OSType.Trim().ToLowerInvariant()
    if ($os.Contains('win') -and $Config.WindowsGroupId) { return $Config.WindowsGroupId }
    if (($os.Contains('lin') -or $os.Contains('ubuntu') -or $os.Contains('redhat') -or $os.Contains('suse') -or $os.Contains('debian') -or $os.Contains('centos')) -and $Config.LinuxGroupId) {
        return $Config.LinuxGroupId
    }
    return $Config.GroupId
}

function Get-FunctionParametersSummary {
    $rawSubs = Get-OptionalSetting 'SYNC_SUBSCRIPTION_IDS'
    $rawMgs = Get-OptionalSetting 'SYNC_MANAGEMENT_GROUP_IDS'
    $rawRgs = Get-OptionalSetting 'SYNC_RESOURCE_GROUP_NAMES'
    $defaultGroup = Get-OptionalSetting 'SYNC_GROUP_ID'
    $winGroup = Get-OptionalSetting 'SYNC_WINDOWS_GROUP_ID'
    $linGroup = Get-OptionalSetting 'SYNC_LINUX_GROUP_ID'
    [ordered]@{
        SYNC_MODE = Get-Setting 'SYNC_MODE' 'Audit'
        SYNC_SCHEDULE = Get-Setting 'SYNC_SCHEDULE' '0 */30 * * * *'
        SYNC_FRESHNESS_HOURS = Get-Setting 'SYNC_FRESHNESS_HOURS' '24'
        SYNC_GROUP_ID = if ($defaultGroup) { $defaultGroup } else { 'Not configured (using OS-specific groups)' }
        SYNC_WINDOWS_GROUP_ID = if ($winGroup) { $winGroup } elseif ($defaultGroup) { "$defaultGroup (inherited from SYNC_GROUP_ID)" } else { 'Not configured' }
        SYNC_LINUX_GROUP_ID = if ($linGroup) { $linGroup } elseif ($defaultGroup) { "$defaultGroup (inherited from SYNC_GROUP_ID)" } else { 'Not configured' }
        SYNC_SUBSCRIPTION_IDS = if ($rawSubs) { $rawSubs } else { 'None (using Management Group scope)' }
        SYNC_MANAGEMENT_GROUP_IDS = if ($rawMgs) { $rawMgs } else { 'None' }
        SYNC_RESOURCE_GROUP_NAMES = if ($rawRgs) { $rawRgs } else { 'All resource groups in scope' }
        SYNC_TENANT_ID = Get-OptionalSetting 'SYNC_TENANT_ID'
        SYNC_STORAGE_ACCOUNT = Get-OptionalSetting 'SYNC_STORAGE_ACCOUNT'
        ServiceBusNamespace = Get-OptionalSetting 'ServiceBusConnection__fullyQualifiedNamespace'
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
    if ($ResourceId -notmatch '^/subscriptions/([0-9a-f-]{36})/resourceGroups/([^/?#%\\]+)/providers/Microsoft\.HybridCompute/machines/([^/?#%\\]+)$') {
        throw 'Invalid Arc machine resource ID.'
    }
    $subscription = ([guid]$Matches[1]).ToString()
    $resourceGroup = [string]$Matches[2]
    $config = Get-SyncConfig
    if (-not (Test-ResourceScope -Config $config -SubscriptionId $subscription -ResourceGroup $resourceGroup)) {
        throw 'Arc resource is outside the configured management group, subscription, or resource group scope.'
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

function Invoke-CloudRequest {
    param(
        [string]$Uri, [string]$Resource, [string]$Method = 'GET',
        $Body, [hashtable]$Headers = @{}, [int[]]$AllowStatus = @(),
        [string]$ContentType = 'application/json'
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
        if ($status -in @(408, 429, 500, 502, 503, 504) -and $attempt -lt 3) {
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
        # Do not put access tokens, request bodies, or raw upstream errors in logs or reports.
        throw "HTTP $status from $(([uri]$Uri).Host) for $Method request."
    }
}

function Read-JsonResponse {
    param($Response)
    if ([string]::IsNullOrWhiteSpace($Response.Content)) { throw 'Expected a JSON response body.' }
    ConvertFrom-Json -InputObject $Response.Content -AsHashtable
}

function Invoke-Graph {
    param([string]$Path, [string]$Method = 'GET', $Body, [int[]]$AllowStatus = @())
    if ($Path.StartsWith('https://graph.microsoft.com/v1.0/')) { $uri = $Path }
    elseif ($Path.StartsWith('/')) { $uri = "https://graph.microsoft.com/v1.0$Path" }
    else { throw 'Graph path must use the configured Microsoft Graph v1.0 endpoint.' }
    Invoke-CloudRequest -Uri $uri -Resource 'https://graph.microsoft.com/' -Method $Method -Body $Body -AllowStatus $AllowStatus
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
        if ($response.Headers.ContainsKey($header)) {
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
    param([string]$Key, [hashtable]$State)
    $intent = @{
        Timestamp = [datetimeoffset]::UtcNow.ToString('o'); Action = 'MembershipAddRequested'
        RunId = $State.RunId; ArcResourceId = $State.ArcResourceId
        EntraObjectId = $State.EntraObjectId; GroupId = $State.GroupId; GroupName = $State['GroupName']
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
    $fields = @('Status', 'Membership', 'MdeDeviceId', 'EntraDeviceId', 'EntraObjectId', 'GroupId', 'GroupName', 'Mode', 'ArcStatus', 'Error',
        'ComputerName', 'Fqdn', 'SubscriptionName', 'CloudProvider', 'MdeSensorHealth', 'MdeOnboardingStatus',
        'MdeAntivirusMode', 'VirtualMachineId', 'ArcExtensions', 'DefenderExtensionStatus', 'IPAddresses', 'InventoryStatus', 'InventoryErrors',
        'MdeDeviceTags', 'MdeManualTags', 'MdeDynamicTags', 'MdeRegistryTags', 'MdeDeviceGroup', 'AzureTags',
        'ArcLastReportedAt', 'ArcAddedAt')
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
    $history = New-HistoryEntity $key (@{ Timestamp = $State.LastChecked; Action = 'StateChanged'; State = $State })
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
    $statuses = [regex]::Matches($response.Content, 'HTTP/1\.1 (\d{3})')
    if ($statuses.Count -ne 2 -or @($statuses | Where-Object { [int]$_.Groups[1].Value -ge 300 }).Count) {
        throw 'Table transaction failed or conflicted; retry is required.'
    }
}

function Get-FunctionAppResourceId {
    $configured = Get-OptionalSetting 'SYNC_WORKER_FUNCTION_RESOURCE_ID'
    if ($configured) { return $configured }
    $owner = Get-OptionalSetting 'WEBSITE_OWNER_NAME'
    $rg = Get-OptionalSetting 'WEBSITE_RESOURCE_GROUP'
    $site = Get-OptionalSetting 'WEBSITE_SITE_NAME'
    if ($owner -match '^([0-9a-fA-F-]{36})' -and $rg -and $site) {
        return "/subscriptions/$($Matches[1])/resourceGroups/$rg/providers/Microsoft.Web/sites/$site"
    }
    return ''
}

function Write-FunctionLog {
    param([hashtable]$Entry)
    $reverseTicks = [long]::MaxValue - [datetime]::UtcNow.Ticks
    $log = @{
        Timestamp = if ($Entry['Timestamp']) { [string]$Entry['Timestamp'] } else { [datetimeoffset]::UtcNow.ToString('o') }
        FunctionName = [string]$Entry['FunctionName']
        TriggerReason = [string]$Entry['TriggerReason']
        Status = [string]$Entry['Status']
        Health = if ($Entry['Health']) { [string]$Entry['Health'] } else { 'Healthy' }
        Message = [string]$Entry['Message']
        RunId = [string]$Entry['RunId']
        ResourceId = [string]$Entry['ResourceId']
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
    $current.FunctionAppStatus = 'Running'
    $current.Health = $log.Health
    $current.LastRunTime = $log.Timestamp
    $current.LastRunFunction = $log.FunctionName
    $current.LastRunReason = $log.TriggerReason
    $current.LastRunStatus = $log.Status
    $current.LastRunMessage = $log.Message
    $current.Parameters = Get-FunctionParametersSummary
    if ($Entry['LastSuccessfulInventory']) {
        $current.LastSuccessfulInventory = [string]$Entry['LastSuccessfulInventory']
    }
    if ($Entry.ContainsKey('MachinesQueued')) {
        $current.MachinesQueued = [int]$Entry['MachinesQueued']
    }
    $summaryEntity = @{
        PartitionKey = 'system'; RowKey = 'inventory'
        Data = ConvertTo-Json -InputObject $current -Depth 10 -Compress
    }
    $null = Invoke-Table -Path "machines(PartitionKey='system',RowKey='inventory')" -Method PUT -Body $summaryEntity
}

function Send-MachineWork {
    param([string]$ResourceId, [string]$Source)
    $id = ConvertTo-ArcId $ResourceId
    $namespace = Get-Setting 'ServiceBusConnection__fullyQualifiedNamespace'
    if ($namespace -notmatch '^[a-z0-9-]+\.servicebus\.windows\.net$') { throw 'Invalid Service Bus namespace.' }
    $runId = [guid]::NewGuid().ToString()
    $null = Invoke-CloudRequest -Uri "https://$namespace/machines/messages" -Resource 'https://servicebus.azure.net' -Method POST -Body @{
        ResourceId = $id; Source = $Source; RunId = $runId
    }
    if ($Source -eq 'EventGrid') {
        try {
            Write-FunctionLog @{
                FunctionName = 'ArcEvent'
                TriggerReason = 'Event Grid (Microsoft.HybridCompute/machines/write)'
                Status = 'Succeeded'
                Health = 'Healthy'
                Message = "Queued Arc machine event for $($id.Split('/')[-1])."
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

function Invoke-InventorySync {
    param([string]$TriggerReason = 'Scheduled timer (NCRONTAB schedule)')
    $runId = [guid]::NewGuid().ToString()
    try {
        $config = Get-SyncConfig
        $discovered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $rgFilter = ''
        if ($config.ResourceGroups.Count) {
            $literals = @($config.ResourceGroups | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress }) -join ', '
            $rgFilter = " | where tolower(resourceGroup) in ($literals)"
        }
        $query = "Resources | where type =~ 'microsoft.hybridcompute/machines'${rgFilter} | project id | order by id asc"
        foreach ($target in @(Get-ScopeResourceGraphTargets $config)) {
            $skipToken = ''
            do {
                $options = @{ resultFormat = 'objectArray' }
                if ($skipToken) { $options.'$skipToken' = $skipToken }
                $body = @{
                    query = $query
                    options = $options
                }
                $body[$target.Kind] = $target.Values
                $result = Read-JsonResponse (Invoke-CloudRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Resource 'https://management.azure.com/' -Method POST -Body $body)
                foreach ($row in $result.data) {
                    if ($discovered.Add($row.id)) { Send-MachineWork $row.id 'Schedule' }
                }
                $skipToken = if ($result.ContainsKey('$skipToken')) { $result.'$skipToken' } else { '' }
                if ($result.resultTruncated -eq 'true' -and -not $skipToken) { throw 'Resource Graph inventory was truncated without a continuation token.' }
            } while ($skipToken)
        }
        # Revisit previously seen resources as well, so deletions are visible without removing membership.
        $cursor = ''
        do {
            $page = Get-TablePage -Filter "RowKey eq 'state'" -Cursor $cursor
            foreach ($item in $page.Items) {
                if ((Test-ResourceScope -Config $config -SubscriptionId $item.SubscriptionId -ResourceGroup $item.ResourceGroup) -and $discovered.Add($item.ArcResourceId)) {
                    Send-MachineWork $item.ArcResourceId 'Schedule'
                }
            }
            $cursor = $page.Cursor
        } while ($cursor)
        $completedAt = [datetimeoffset]::UtcNow.ToString('o')
        Write-FunctionLog @{
            Timestamp = $completedAt
            FunctionName = 'Inventory'
            TriggerReason = $TriggerReason
            Status = 'Succeeded'
            Health = 'Healthy'
            Message = "Inventory pass completed: queued $($discovered.Count) machine(s)."
            RunId = $runId
            LastSuccessfulInventory = $completedAt
            MachinesQueued = $discovered.Count
        }
        Write-Information "Inventory completed: queued=$($discovered.Count)" -InformationAction Continue
    }
    catch {
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
        $_.OnboardingStatus -eq 'Onboarded' -and [string]::IsNullOrWhiteSpace([string]$_.MergedToDeviceId)
    })
    if (-not $current.Count) { return @{ Status = 'PendingMde'; Candidate = $null } }
    $fresh = @($current | Where-Object {
        $time = [datetimeoffset]$_.Timestamp
        $time -ge $Now.AddHours(-$FreshnessHours) -and $time -le $Now.AddMinutes(5)
    })
    if (-not $fresh.Count) { return @{ Status = 'StaleEvidence'; Candidate = $null } }
    if ($fresh.Count -ne 1) { return @{ Status = 'Ambiguous'; Candidate = $null } }
    $candidate = $fresh[0]
    if ([string]::IsNullOrWhiteSpace([string]$candidate.AadDeviceId)) { return @{ Status = 'NoEntraDevice'; Candidate = $candidate } }
    $guid = [guid]::Empty
    if (-not [guid]::TryParse([string]$candidate.AadDeviceId, [ref]$guid) -or $guid -eq [guid]::Empty) {
        return @{ Status = 'InvalidEntraIdentifier'; Candidate = $candidate }
    }
    return @{ Status = 'Matched'; Candidate = $candidate }
}

function Get-MdeCandidates {
    param([string]$ResourceId)
    # Select latest telemetry per device BEFORE matching the resource ID, avoiding old mappings.
    $literal = ConvertTo-Json -InputObject $ResourceId -Compress
    $query = @"
DeviceInfo
| where Timestamp >= ago(7d)
| summarize arg_max(Timestamp, *) by DeviceId
| where AzureResourceId =~ $literal
| project Timestamp, DeviceId, DeviceName, AadDeviceId, OnboardingStatus, MergedToDeviceId,
    SensorHealthState, CloudPlatforms, AzureVmId, PublicIP,
    DeviceManualTags, DeviceDynamicTags, RegistryDeviceTag, MachineGroup
| take 101
"@
    $result = Read-JsonResponse (Invoke-Graph -Path '/security/runHuntingQuery' -Method POST -Body @{ Query = $query; Timespan = 'P7D' })
    if (-not $result.ContainsKey('results')) { throw 'Hunting response is missing results.' }
    if (@($result.results).Count -gt 100) { throw 'Correlation candidate query exceeded its safety limit.' }
    return @($result.results)
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

function Set-ArcInventory {
    param([hashtable]$State, [hashtable]$Arc)
    $State.ComputerName = [string](Get-InventoryValue $Arc @('properties', 'osProfile', 'computerName'))
    $State.Fqdn = [string](Get-InventoryValue $Arc @('properties', 'dnsFqdn'))
    $State.CloudProvider = [string](Get-InventoryValue $Arc @('properties', 'cloudMetadata', 'provider'))
    $State.VirtualMachineId = [string](Get-InventoryValue $Arc @('properties', 'vmId'))
    $lastReported = ConvertTo-IsoTimestamp (Get-InventoryValue $Arc @('properties', 'lastStatusChange'))
    if (-not $lastReported) { $lastReported = ConvertTo-IsoTimestamp (Get-InventoryValue $Arc @('systemData', 'lastModifiedAt')) }
    $State.ArcLastReportedAt = $lastReported
    $addedAt = ConvertTo-IsoTimestamp (Get-InventoryValue $Arc @('systemData', 'createdAt'))
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
    param([string]$ResourceId)
    $prefix = "https://management.azure.com$ResourceId/extensions"
    $next = "${prefix}?api-version=2024-07-10"
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
    param([string]$GroupId)
    $group = Read-JsonResponse (Invoke-Graph -Path "/groups/${GroupId}?`$select=id,displayName,securityEnabled,groupTypes,onPremisesSyncEnabled,isAssignableToRole")
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
    param([hashtable]$State)
    $group = Test-Group $State.GroupId
    $State.GroupName = $group.displayName
    if (Test-DirectMembership $State.GroupId $State.EntraObjectId) {
        $State.Membership = 'Present'
        $State.Status = 'Verified'
        $State.MembershipVerifiedAt = [datetimeoffset]::UtcNow.ToString('o')
        return
    }
    $State.Membership = 'Absent'
    if ($State.Mode -eq 'Audit') { $State.Status = 'WouldAdd'; return }
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
}

function Invoke-MachineSync {
    param([hashtable]$Work)
    $id = ConvertTo-ArcId ([string]$Work.ResourceId)
    $config = Get-SyncConfig
    $key = Get-MachineKey $id
    $previous = Get-MachineState $key
    $state = @{
        Key = $key; ArcResourceId = $id; MachineName = $id.Split('/')[-1]
        SubscriptionId = $id.Split('/')[2]; ResourceGroup = $id.Split('/')[4]
        GroupId = $config.GroupId; GroupName = ''; Mode = $config.Mode; RunId = ([guid]$Work.RunId).ToString()
        Source = [string]$Work.Source; FirstSeen = [datetimeoffset]::UtcNow.ToString('o')
        LastChecked = [datetimeoffset]::UtcNow.ToString('o'); ArcStatus = 'Unknown'; OS = ''
        Status = 'PendingMde'; Membership = 'Unknown'; MembershipVerifiedAt = ''
        MdeDeviceId = ''; MdeDeviceName = ''; MdeLastSeen = ''; EntraDeviceId = ''; EntraObjectId = ''
        SubscriptionName = ''; ComputerName = ''; Fqdn = ''; CloudProvider = ''; VirtualMachineId = ''
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
        $arcResponse = Invoke-CloudRequest -Uri "https://management.azure.com${id}?api-version=2024-07-10" -Resource 'https://management.azure.com/' -AllowStatus @(404)
        if ($arcResponse.Status -eq 404) {
            $state.Status = 'ArcMissing'
            $state.ArcStatus = 'Missing'
        }
        else {
            $arc = Read-JsonResponse $arcResponse
            $state.ArcStatus = $arc.properties.status
            $state.OS = $arc.properties.osType
            $targetGroup = Resolve-TargetGroupId -Config $config -OSType ([string]$state.OS)
            if (-not $targetGroup) { throw "No target Entra security group is configured for OS '$($state.OS)'." }
            $state.GroupId = $targetGroup
            $state.InventoryStatus = 'Collected'
            Set-ArcInventory $state $arc
            Invoke-InventoryStep $state 'Azure resource tags' { Set-AzureTags $state $arc }
            Invoke-InventoryStep $state 'Subscription name' { $state.SubscriptionName = Get-SubscriptionName $state.SubscriptionId }
            Invoke-InventoryStep $state 'Arc extensions' {
                $state.ArcExtensions = @(Get-ArcExtensions $id)
                $state.DefenderExtensionStatus = Get-DefenderExtensionStatus $state.ArcExtensions
            }
            $candidates = @(Get-MdeCandidates $id)
            $correlation = Get-Correlation -Candidates $candidates -FreshnessHours $config.FreshnessHours
            $displayCandidate = $correlation.Candidate
            if (-not $displayCandidate) {
                $unmerged = @($candidates | Where-Object { -not $_.MergedToDeviceId })
                if ($unmerged.Count -eq 1) { $displayCandidate = $unmerged[0] }
            }
            if ($displayCandidate) {
                Set-MdeInventory $state $displayCandidate
                Invoke-InventoryStep $state 'MDE device tags' { Set-MdeTags $state $displayCandidate }
                Invoke-InventoryStep $state 'MDE network addresses' {
                    $state.IPAddresses = @(@($state.IPAddresses) + @(Get-MdeNetworkAddresses $state.MdeDeviceId) | Sort-Object -Unique)
                }
                $state.MdeAntivirusStatus = 'Failed'
                Invoke-InventoryStep $state 'MDE antivirus mode' {
                    $av = Get-MdeAntivirus $state.MdeDeviceId
                    $state.MdeAntivirusMode = $av.Mode
                    $state.MdeAntivirusTimestamp = $av.Timestamp
                    $state.MdeAntivirusStatus = $av.Status
                }
            }
            if ($state.ArcStatus -ne 'Connected') { $state.Status = 'ArcNotConnected' }
            else {
                $state.Status = $correlation.Status
                if ($state.Status -eq 'Matched') {
                    $deviceId = ([guid]$state.EntraDeviceId).ToString()
                    $filter = [uri]::EscapeDataString("deviceId eq '$deviceId'")
                    $devices = Read-JsonResponse (Invoke-Graph -Path "/devices?`$filter=$filter&`$select=id,deviceId,accountEnabled&`$top=2")
                    if ($devices.ContainsKey('@odata.nextLink') -or @($devices.value).Count -gt 1) { $state.Status = 'Ambiguous' }
                    elseif (-not @($devices.value).Count) { $state.Status = 'EntraDeviceNotFound' }
                    else {
                        $device = $devices.value[0]
                        $state.EntraObjectId = ([guid]$device.id).ToString()
                        if ($device.accountEnabled -ne $true) { $state.Status = 'EntraDeviceDisabled' }
                        else {
                            # Recheck Arc immediately before evaluating a membership write.
                            $check = Read-JsonResponse (Invoke-CloudRequest -Uri "https://management.azure.com${id}?api-version=2024-07-10" -Resource 'https://management.azure.com/')
                            if ($check.properties.status -ne 'Connected') { $state.Status = 'ArcNotConnected'; $state.ArcStatus = $check.properties.status }
                            else { Set-VerifiedMembership $state }
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
                'EventGrid' { 'Event Grid (Arc machine connected/updated)' }
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
            'EventGrid' { 'Event Grid (Arc machine connected/updated)' }
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

Export-ModuleMember -Function Get-*, Resolve-TargetGroupId, ConvertTo-ArcId, Invoke-InventorySync, Invoke-MachineSync, Test-ReportReader, Write-FunctionLog
