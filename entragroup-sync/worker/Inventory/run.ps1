param($Timer)
$reason = if ($Timer -and $Timer.IsPastDue) {
    'Scheduled timer (past-due catch-up)'
} else {
    'Scheduled timer (NCRONTAB schedule)'
}
Invoke-InventorySync -TriggerReason $reason
