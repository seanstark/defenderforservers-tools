[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkerPrincipalId,
    [ValidateSet('Audit', 'Enforce')][string]$Mode = 'Audit',
    [guid]$AdminUnitId = [guid]::Empty,
    [guid[]]$TargetGroupIds = @(),
    [string[]]$GroupNamePrefixes = @(),
    [switch]$AssignGroupOwner
)
$ErrorActionPreference = 'Stop'
$ownerGroupIds = @($TargetGroupIds | Where-Object { $_ -ne [guid]::Empty } | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
if ($AssignGroupOwner -and -not $ownerGroupIds.Count -and -not @($GroupNamePrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count) {
    throw 'Specify -TargetGroupIds and/or -GroupNamePrefixes when using -AssignGroupOwner.'
}

function Invoke-AzJson {
    param([string[]]$Arguments, [string]$Body = '')
    if ($Body) {
        $tempFile = Join-Path ([IO.Path]::GetTempPath()) "az-rest-body-$([guid]::NewGuid().ToString('N')).json"
        try {
            [IO.File]::WriteAllText($tempFile, $Body, [Text.UTF8Encoding]::new($false))
            $output = & az @Arguments --headers 'Content-Type=application/json' --body "@$tempFile" --output json --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Azure CLI command failed.' }
            if (-not $output) { return @{} }
            return (($output -join "`n") | ConvertFrom-Json -AsHashtable)
        }
        finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
    $output = & az @Arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI command failed.' }
    if (-not $output) { return @{} }
    ($output -join "`n") | ConvertFrom-Json -AsHashtable
}
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graph = Invoke-AzJson @('ad', 'sp', 'show', '--id', $graphAppId)
$permissions = if ($AdminUnitId -ne [guid]::Empty) {
    # When scoped to an Administrative Unit, the Worker lists AU group members via AdministrativeUnit.Read.All and manages groups inside that AU via AU-scoped Groups Administrator.
    @('ThreatHunting.Read.All', 'Device.Read.All', 'AdministrativeUnit.Read.All')
}
elseif ($Mode -eq 'Enforce' -and -not $AssignGroupOwner) {
    @('ThreatHunting.Read.All', 'Device.ReadWrite.All', 'GroupMember.ReadWrite.All')
}
else {
    @('ThreatHunting.Read.All', 'Device.Read.All', 'GroupMember.Read.All')
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
        $null = Invoke-AzJson -Arguments @('rest', '--method', 'POST', '--url', $uri) -Body $body
        Write-Host "Granted $permission."
    }
}
if ($AdminUnitId -ne [guid]::Empty) {
    # Built-in Entra ID Groups Administrator roleTemplateId: fdd7a751-b60b-444a-984c-02652fe8fa1c
    $groupsAdminRoleId = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'
    $scopeId = "/administrativeUnits/$AdminUnitId"
    $filter = [uri]::EscapeDataString("principalId eq '$WorkerPrincipalId' and roleDefinitionId eq '$groupsAdminRoleId' and directoryScopeId eq '$scopeId'")
    $existingRole = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=$filter")
    if (@($existingRole.value).Count) {
        Write-Host "Worker principal $WorkerPrincipalId already has Groups Administrator on Administrative Unit $AdminUnitId."
    }
    elseif ($PSCmdlet.ShouldProcess("Administrative Unit $AdminUnitId", "Assign Groups Administrator role to worker principal $WorkerPrincipalId")) {
        $roleBody = @{
            principalId = $WorkerPrincipalId.ToString()
            roleDefinitionId = $groupsAdminRoleId
            directoryScopeId = $scopeId
        } | ConvertTo-Json -Compress
        $null = Invoke-AzJson -Arguments @('rest', '--method', 'POST', '--url', 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments') -Body $roleBody
        Write-Host "Assigned Groups Administrator role to $WorkerPrincipalId on Administrative Unit $AdminUnitId."
    }
}
if ($AssignGroupOwner) {
    foreach ($prefix in @($GroupNamePrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $escaped = $prefix.Trim().Replace("'", "''")
        $filter = [uri]::EscapeDataString("startsWith(displayName,'$escaped')")
        $groupsPage = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName")
        foreach ($g in @($groupsPage.value)) {
            if ($g.id) { $ownerGroupIds += ([guid]$g.id).ToString() }
        }
    }
    $ownerGroupIds = @($ownerGroupIds | Sort-Object -Unique)
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
            $null = Invoke-AzJson -Arguments @('rest', '--method', 'POST', '--url', "https://graph.microsoft.com/v1.0/groups/$groupId/owners/`$ref") -Body $ownerBody
            Write-Host "Added worker principal $WorkerPrincipalId as owner of group $groupId."
        }
    }
}
Write-Host 'Existing permissions are not removed. Reverting to Audit mode does not revoke previously granted write permissions.'
