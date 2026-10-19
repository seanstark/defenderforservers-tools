[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkerPrincipalId,
    [ValidateSet('Audit', 'Enforce')][string]$Mode = 'Audit',
    [guid]$TargetGroupId = [guid]::Empty,
    [guid]$WindowsTargetGroupId = [guid]::Empty,
    [guid]$LinuxTargetGroupId = [guid]::Empty,
    [switch]$AssignGroupOwner
)
$ErrorActionPreference = 'Stop'
$ownerGroupIds = @(@($TargetGroupId, $WindowsTargetGroupId, $LinuxTargetGroupId) | Where-Object { $_ -ne [guid]::Empty } | Sort-Object -Unique)
if ($AssignGroupOwner -and -not $ownerGroupIds.Count) {
    throw 'Specify -TargetGroupId, -WindowsTargetGroupId, and/or -LinuxTargetGroupId when using -AssignGroupOwner.'
}

function Invoke-AzJson {
    param([string[]]$Arguments)
    $output = & az @Arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI command failed.' }
    ($output -join "`n") | ConvertFrom-Json -AsHashtable
}
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graph = Invoke-AzJson @('ad', 'sp', 'show', '--id', $graphAppId)
$permissions = @('ThreatHunting.Read.All', 'Device.Read.All', 'GroupMember.Read.All')
if ($Mode -eq 'Enforce') {
    $permissions = if ($AssignGroupOwner) {
        @('ThreatHunting.Read.All', 'Device.Read.All', 'GroupMember.Read.All')
    } else {
        @('ThreatHunting.Read.All', 'Device.ReadWrite.All', 'GroupMember.ReadWrite.All')
    }
}
$uri = "https://graph.microsoft.com/v1.0/servicePrincipals/$WorkerPrincipalId/appRoleAssignments"
$existing = @()
$next = $uri
while ($next) {
    $page = Invoke-AzJson @('rest', '--method', 'GET', '--url', $next)
    $existing += @($page.value)
    $next = if ($page.ContainsKey('@odata.nextLink')) { $page.'@odata.nextLink' } else { '' }
}
foreach ($permission in $permissions) {
    $role = @($graph.appRoles | Where-Object { $_.value -eq $permission -and $_.isEnabled -and 'Application' -in $_.allowedMemberTypes })
    if ($role.Count -ne 1) { throw "Unable to resolve Graph application permission $permission." }
    if (@($existing | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $role[0].id }).Count) {
        Write-Host "$permission already assigned."
        continue
    }
    if ($PSCmdlet.ShouldProcess($WorkerPrincipalId, "Grant Microsoft Graph $permission")) {
        $body = @{
            principalId = $WorkerPrincipalId.ToString()
            resourceId = $graph.id
            appRoleId = $role[0].id
        } | ConvertTo-Json -Compress
        $null = Invoke-AzJson @('rest', '--method', 'POST', '--url', $uri, '--body', $body)
        Write-Host "Granted $permission."
    }
}
if ($AssignGroupOwner) {
    foreach ($groupId in $ownerGroupIds) {
        $ownersUri = "https://graph.microsoft.com/v1.0/groups/$groupId/owners?`$select=id"
        $ownersPage = Invoke-AzJson @('rest', '--method', 'GET', '--url', $ownersUri)
        if (@($ownersPage.value | Where-Object { $_.id -eq $WorkerPrincipalId.ToString() }).Count) {
            Write-Host "Worker principal $WorkerPrincipalId is already an owner of group $groupId."
        }
        elseif ($PSCmdlet.ShouldProcess("Group $groupId", "Add worker principal $WorkerPrincipalId as group owner")) {
            $ownerBody = @{
                '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$WorkerPrincipalId"
            } | ConvertTo-Json -Compress
            $null = & az rest --method POST --url "https://graph.microsoft.com/v1.0/groups/$groupId/owners/`$ref" --headers 'Content-Type=application/json' --body $ownerBody --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw "Failed to add $WorkerPrincipalId as owner of group $groupId." }
            Write-Host "Added worker principal $WorkerPrincipalId as owner of group $groupId."
        }
    }
}
Write-Host 'Existing permissions are not removed. Reverting to Audit mode does not revoke previously granted write permissions.'
