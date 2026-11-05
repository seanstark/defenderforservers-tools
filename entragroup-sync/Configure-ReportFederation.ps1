[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$ReportClientId,
    [Parameter(Mandatory)][guid]$IdentityPrincipalId,
    [Parameter(Mandatory)][guid]$TenantId
)
$ErrorActionPreference = 'Stop'
if ($ReportClientId -eq [guid]::Empty -or $IdentityPrincipalId -eq [guid]::Empty -or $TenantId -eq [guid]::Empty) {
    throw 'Report client ID, managed identity principal ID, and tenant ID must be nonempty GUIDs.'
}
$raw = & az account get-access-token --resource-type ms-graph --tenant $TenantId.ToString() --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Unable to acquire a Microsoft Graph token. Run az login with an account allowed to update the report app registration credentials.' }
$token = ($raw -join "`n") | ConvertFrom-Json
if ($token.tenant -ne $TenantId.ToString()) { throw 'The Microsoft Graph token tenant does not match the managed identity tenant.' }
$headers = @{ Authorization = "Bearer $($token.accessToken)" }
$graph = 'https://graph.microsoft.com/v1.0'
function Invoke-ReportGraph {
    param([string]$Uri, [string]$Method = 'GET', [hashtable]$Body)
    if (-not $Uri.StartsWith("$graph/", [StringComparison]::Ordinal)) { throw 'Unexpected Microsoft Graph continuation URL.' }
    $args = @{ Uri = $Uri; Method = $Method; Headers = $headers; TimeoutSec = 60 }
    if ($Body) { $args.ContentType = 'application/json'; $args.Body = $Body | ConvertTo-Json -Compress }
    Invoke-RestMethod @args
}
$filter = [uri]::EscapeDataString("appId eq '$ReportClientId'")
$apps = Invoke-ReportGraph "$graph/applications?`$filter=$filter&`$select=id,appId"
if (@($apps.value).Count -ne 1) { throw 'Expected exactly one report app registration in the managed identity tenant.' }
$uri = "$graph/applications/$($apps.value[0].id)/federatedIdentityCredentials"
$expected = @{
    name = "report-login-$IdentityPrincipalId"
    issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
    subject = $IdentityPrincipalId.ToString()
    audiences = @('api://AzureADTokenExchange')
    description = 'Dedicated report Function App user-assigned managed identity for App Service Authentication.'
}
$existing = @()
$next = $uri
while ($next) {
    $page = Invoke-ReportGraph $next
    $existing += @($page.value)
    $next = $page.'@odata.nextLink'
}
foreach ($credential in $existing) {
    if ($credential.issuer -ceq $expected.issuer -and $credential.subject -ceq $expected.subject) {
        if (@($credential.audiences).Count -ne 1 -or $credential.audiences[0] -cne $expected.audiences[0]) {
            throw 'An existing trust for this identity has an unexpected audience; review it before continuing.'
        }
        return [pscustomobject]@{ Name = $credential.name; Status = 'Existing'; PrincipalId = $IdentityPrincipalId }
    }
}
if (@($existing | Where-Object name -CEQ $expected.name).Count) { throw 'The expected credential name already exists with different trust settings; no credentials were changed.' }
if ($PSCmdlet.ShouldProcess($ReportClientId, "Trust report login identity $IdentityPrincipalId")) {
    $created = Invoke-ReportGraph -Uri $uri -Method POST -Body $expected
    if ($created.issuer -cne $expected.issuer -or $created.subject -cne $expected.subject -or
        @($created.audiences).Count -ne 1 -or $created.audiences[0] -cne $expected.audiences[0]) {
        throw 'Microsoft Graph did not confirm the expected federated identity credential.'
    }
    [pscustomobject]@{ Name = $created.name; Status = 'Created'; PrincipalId = $IdentityPrincipalId }
}
