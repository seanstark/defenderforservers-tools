[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,17}$')][string]$NamePrefix,
    [guid[]]$SubscriptionIds = @(),
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')][string[]]$ManagementGroupIds = @(),
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')][string[]]$ResourceGroupNames = @(),
    [string]$AwsWindowsGroupPrefix = 'dfs-aws-{id}-windows-{mode}',
    [string]$AwsLinuxGroupPrefix = 'dfs-aws-{id}-linux-{mode}',
    [string]$GcpWindowsGroupPrefix = 'dfs-gcp-{id}-windows-{mode}',
    [string]$GcpLinuxGroupPrefix = 'dfs-gcp-{id}-linux-{mode}',
    [string]$AzureWindowsGroupPrefix = 'dfs-azure-{id}-windows-{mode}',
    [string]$AzureLinuxGroupPrefix = 'dfs-azure-{id}-linux-{mode}',
    [ValidateSet('Passive', 'Active')][string]$DefaultGroupMode = 'Passive',
    [guid]$AdminUnitId = [guid]::Empty,
    [bool]$AutoCreateGroups = $false,
    [Parameter(Mandatory)][guid]$ReportClientId,
    [ValidateSet('Audit', 'Enforce')][string]$SyncMode = 'Audit',
    [string]$Schedule = '0 */30 * * * *',
    [ValidateRange(1, 168)][int]$FreshnessHours = 24,
    [ValidateSet('B1', 'S1', 'P1v3')][string]$PlanSku = 'B1',
    [string[]]$AlertActionGroupIds = @()
)
$ErrorActionPreference = 'Stop'
if (-not $SubscriptionIds.Count -and -not $ManagementGroupIds.Count) {
    throw 'At least one source subscription (-SubscriptionIds) or management group (-ManagementGroupIds) is required.'
}
if (-not ($AwsWindowsGroupPrefix -or $AwsLinuxGroupPrefix -or $GcpWindowsGroupPrefix -or $GcpLinuxGroupPrefix -or $AzureWindowsGroupPrefix -or $AzureLinuxGroupPrefix)) {
    throw 'Specify at least one cloud OS group prefix (-AwsWindowsGroupPrefix, -AwsLinuxGroupPrefix, -GcpWindowsGroupPrefix, -GcpLinuxGroupPrefix, -AzureWindowsGroupPrefix, or -AzureLinuxGroupPrefix).'
}

function Invoke-Az {
    param([string[]]$Arguments)
    $output = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed: $($Arguments[0]) $($Arguments[1])" }
    return ($output -join "`n")
}
function Invoke-Deployment {
    param([string]$Scope, [string]$Name, $Template, [hashtable]$Parameters, [string]$Location)
    $token = Invoke-Az @('account', 'get-access-token', '--resource', 'https://management.azure.com/', '--query', 'accessToken', '--output', 'tsv')
    $headers = @{ Authorization = "Bearer $token" }
    $body = @{
        properties = @{
            mode = 'Incremental'; template = $Template
            parameters = $Parameters
        }
    }
    if ($Location) { $body.location = $Location }
    $uri = "https://management.azure.com$Scope/providers/Microsoft.Resources/deployments/${Name}?api-version=2022-09-01"
    $null = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 100 -Compress) -TimeoutSec 120
    $deadline = [datetime]::UtcNow.AddMinutes(45)
    do {
        Start-Sleep -Seconds 10
        $deployment = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60
        $state = $deployment.properties.provisioningState
        if ($state -in @('Failed', 'Canceled')) { throw "Deployment '$Name' $state. Inspect its Azure deployment operations." }
        if ([datetime]::UtcNow -gt $deadline) { throw "Deployment '$Name' timed out locally. Check Azure before retrying." }
    } while ($state -ne 'Succeeded')
    return $deployment.properties.outputs
}

$account = (Invoke-Az @('account', 'show', '--output', 'json')) | ConvertFrom-Json
$group = (Invoke-Az @('group', 'show', '--name', $ResourceGroupName, '--output', 'json')) | ConvertFrom-Json
$template = (Invoke-Az @('bicep', 'build', '--file', "$PSScriptRoot\infra\main.bicep", '--stdout')) | ConvertFrom-Json -AsHashtable
$eventTemplate = (Invoke-Az @('bicep', 'build', '--file', "$PSScriptRoot\infra\subscription.bicep", '--stdout')) | ConvertFrom-Json -AsHashtable
$parameters = @{
    namePrefix = @{ value = $NamePrefix }; tenantId = @{ value = $account.tenantId }
    subscriptionIds = @{ value = @($SubscriptionIds | ForEach-Object ToString) }
    managementGroupIds = @{ value = @($ManagementGroupIds) }
    resourceGroupNames = @{ value = @($ResourceGroupNames) }
    awsWindowsGroupPrefix = @{ value = $AwsWindowsGroupPrefix }
    awsLinuxGroupPrefix = @{ value = $AwsLinuxGroupPrefix }
    gcpWindowsGroupPrefix = @{ value = $GcpWindowsGroupPrefix }
    gcpLinuxGroupPrefix = @{ value = $GcpLinuxGroupPrefix }
    azureWindowsGroupPrefix = @{ value = $AzureWindowsGroupPrefix }
    azureLinuxGroupPrefix = @{ value = $AzureLinuxGroupPrefix }
    defaultGroupMode = @{ value = $DefaultGroupMode }
    adminUnitId = @{ value = if ($AdminUnitId -ne [guid]::Empty) { $AdminUnitId.ToString() } else { '' } }
    autoCreateGroups = @{ value = [bool]($AutoCreateGroups -or ($AdminUnitId -ne [guid]::Empty)) }
    reportClientId = @{ value = $ReportClientId.ToString() }
    syncMode = @{ value = $SyncMode }; schedule = @{ value = $Schedule }
    freshnessHours = @{ value = $FreshnessHours }; planSku = @{ value = $PlanSku }
    alertActionGroupIds = @{ value = $AlertActionGroupIds }
}
$outputs = Invoke-Deployment -Scope $group.id -Name "$NamePrefix-infra" -Template $template -Parameters $parameters
$federation = & "$PSScriptRoot\Configure-ReportFederation.ps1" -ReportClientId $ReportClientId `
    -IdentityPrincipalId $outputs.reportLoginIdentityPrincipalId.value -TenantId $account.tenantId
Write-Host "Report sign-in federated credential: $($federation.Name)"

$packageDirectory = Join-Path ([IO.Path]::GetTempPath()) "arc-entra-deploy-$([guid]::NewGuid().ToString('N'))"
try {
    $packages = & "$PSScriptRoot\Build-Packages.ps1" -OutputDirectory $packageDirectory
    foreach ($app in @('worker', 'report')) {
        $appName = if ($app -eq 'worker') { $outputs.workerAppName.value } else { $outputs.reportAppName.value }
        $package = $packages | Where-Object Name -eq "$app.zip"
        $null = Invoke-Az @('functionapp', 'deployment', 'source', 'config-zip', '--resource-group', $ResourceGroupName, '--name', $appName, '--src', $package.FullName)
    }
    $eventSubscriptions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($subscription in $SubscriptionIds) {
        $null = $eventSubscriptions.Add($subscription.ToString())
    }
    if ($ManagementGroupIds.Count) {
        $mgQuery = "ResourceContainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId"
        $mgArgs = @('graph', 'query', '-q', $mgQuery, '--management-groups') + $ManagementGroupIds + @('--output', 'json')
        $mgResult = (Invoke-Az $mgArgs) | ConvertFrom-Json
        foreach ($row in $mgResult.data) {
            if ($row.subscriptionId) { $null = $eventSubscriptions.Add([string]$row.subscriptionId) }
        }
    }
    foreach ($subscription in $eventSubscriptions) {
        $eventParameters = @{
            workerPrincipalId = @{ value = $outputs.workerPrincipalId.value }
            workerFunctionId = @{ value = $outputs.workerFunctionId.value }
            eventSubscriptionName = @{ value = "$NamePrefix-arc-sync" }
            resourceGroupNames = @{ value = @($ResourceGroupNames) }
        }
        $null = Invoke-Deployment -Scope "/subscriptions/$subscription" -Name "$NamePrefix-events" -Template $eventTemplate -Parameters $eventParameters -Location $group.location
    }
}
finally {
    if (Test-Path -LiteralPath $packageDirectory) { Remove-Item -LiteralPath $packageDirectory -Recurse -Force }
}

Write-Host "Report: $($outputs.reportUrl.value)"
Write-Host "Set the report registration's Web redirect URI to: $($outputs.reportRedirectUri.value)"
Write-Host 'Next grant the worker Graph permissions and assign Report.Reader to users authorized to view the report and start sync.'
[pscustomobject]@{
    WorkerAppName = $outputs.workerAppName.value
    WorkerPrincipalId = $outputs.workerPrincipalId.value
    ReportLoginIdentityResourceId = $outputs.reportLoginIdentityResourceId.value
    ReportLoginIdentityClientId = $outputs.reportLoginIdentityClientId.value
    ReportLoginIdentityPrincipalId = $outputs.reportLoginIdentityPrincipalId.value
    ReportAppName = $outputs.reportAppName.value
    ReportUrl = $outputs.reportUrl.value
    ReportRedirectUri = $outputs.reportRedirectUri.value
}
