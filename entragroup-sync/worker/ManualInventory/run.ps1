param($SyncRequest, $TriggerMetadata)
if ($SyncRequest -is [string]) { $SyncRequest = ConvertFrom-Json -InputObject $SyncRequest -AsHashtable }
$null = [guid]::Parse([string]$SyncRequest.RequestId)
$requestedAt = [datetimeoffset]::Parse([string]$SyncRequest.RequestedAt)
if ($requestedAt -gt [datetimeoffset]::UtcNow.AddMinutes(1)) { throw 'Manual inventory request timestamp is in the future.' }
if ($requestedAt -lt [datetimeoffset]::UtcNow.AddMinutes(-15)) {
    Write-Warning "Expired manual inventory request $($SyncRequest.RequestId) was not executed."
    return
}
Invoke-InventorySync -TriggerReason 'Manual sync (Device inventory)' -RequestedAt $requestedAt.ToString('o')
