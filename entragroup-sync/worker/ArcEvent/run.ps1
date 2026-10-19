param($EventGridEvent)
$event = if ($EventGridEvent -is [string]) { ConvertFrom-Json $EventGridEvent -AsHashtable } else { $EventGridEvent }
if ($event.eventType -ne 'Microsoft.Resources.ResourceWriteSuccess' -or
    $event.data.operationName -ine 'Microsoft.HybridCompute/machines/write') {
    throw 'Unexpected event type or operation.'
}
& (Get-Module ArcEntraSync) {
    param($id)
    if ($id -notmatch '^/subscriptions/([0-9a-f-]{36})/resourceGroups/([^/?#%\\]+)/providers/Microsoft\.HybridCompute/machines/([^/?#%\\]+)$') {
        throw 'Invalid Arc machine resource ID.'
    }
    $config = Get-SyncConfig
    if (-not (Test-ResourceScope -Config $config -SubscriptionId $Matches[1] -ResourceGroup $Matches[2])) {
        Write-Information "Ignoring out-of-scope Arc event: $id" -InformationAction Continue
        return
    }
    Send-MachineWork $id 'EventGrid'
} $event.subject
