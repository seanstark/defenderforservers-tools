param($EventGridEvent)
$event = if ($EventGridEvent -is [string]) { ConvertFrom-Json $EventGridEvent -AsHashtable } else { $EventGridEvent }
$validOps = @(
    'Microsoft.GuestConfiguration/guestConfigurationAssignments/write',
    'Microsoft.HybridCompute/machines/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/write',
    'Microsoft.Compute/virtualMachines/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/write',
    'Microsoft.Compute/virtualMachineScaleSets/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/write',
    'Microsoft.HybridCompute/machines/extensions/write',
    'Microsoft.Compute/virtualMachines/extensions/write',
    'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/extensions/write',
    'Microsoft.Compute/virtualMachineScaleSets/extensions/write'
)
if ($event.eventType -ne 'Microsoft.Resources.ResourceWriteSuccess' -or
    $event.data.operationName -notin $validOps) {
    throw 'Unexpected event type or operation.'
}
$null = Invoke-MdeExtensionEvent -Subject ([string]$event.subject)

