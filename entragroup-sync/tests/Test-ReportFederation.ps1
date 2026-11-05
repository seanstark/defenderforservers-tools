$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$passed = 0
$failed = 0
$tenant = '11111111-1111-1111-1111-111111111111'
$client = '22222222-2222-2222-2222-222222222222'
$principal = '33333333-3333-3333-3333-333333333333'
$expected = @{
    name = "report-login-$principal"
    issuer = "https://login.microsoftonline.com/$tenant/v2.0"
    subject = $principal
    audiences = @('api://AzureADTokenExchange')
}
$global:ReportFederationTest = @{}
function Assert-True($Value) { if (-not $Value) { throw 'Expected true.' } }
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', received '$Actual'." }
}
function Assert-Throws([scriptblock]$Body) {
    $failure = $null
    try { & $Body } catch { $failure = $_ }
    if (-not $failure) { throw 'Expected an explicit failure.' }
}
function az {
    $global:LASTEXITCODE = 0
    @{ accessToken = 'test-token'; tenant = $global:ReportFederationTest.TokenTenant } | ConvertTo-Json -Compress
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec)
    if (-not $Uri.StartsWith('https://graph.microsoft.com/v1.0/')) { throw 'Unexpected network request.' }
    $global:ReportFederationTest.Calls.Add(@{ Uri = $Uri; Method = $Method; Body = $Body })
    if ($global:ReportFederationTest.GraphFailure) { throw 'Simulated Graph authorization failure.' }
    if ($Uri.StartsWith('https://graph.microsoft.com/v1.0/applications?')) { return @{ value = @(@{ id = 'app-object' }) } }
    if ($Method -eq 'POST') {
        $global:ReportFederationTest.Created = $Body | ConvertFrom-Json -AsHashtable
        if ($global:ReportFederationTest.BadConfirmation) { return @{ issuer = 'unexpected' } }
        return $global:ReportFederationTest.Created
    }
    if ($Uri -like '*skiptoken=next') { return @{ value = $global:ReportFederationTest.Credentials } }
    if ($global:ReportFederationTest.Continuation) { return @{ value = @(); '@odata.nextLink' = $global:ReportFederationTest.Continuation } }
    @{ value = $global:ReportFederationTest.Credentials }
}
function Configure {
    & "$root\Configure-ReportFederation.ps1" -ReportClientId $client -IdentityPrincipalId $principal -TenantId $tenant @args
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    $global:ReportFederationTest = @{
        TokenTenant = $tenant
        Calls = [Collections.Generic.List[hashtable]]::new()
        Credentials = @()
        Created = $null
        Continuation = ''
        GraphFailure = $false
        BadConfirmation = $false
    }
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name`: $($_.Exception.Message)" }
}
Test-Case 'Creates the exact principal-bound federation without modifying roles or secrets' {
    $result = Configure
    Assert-Equal $result.Status 'Created'
    Assert-Equal $global:ReportFederationTest.Created.subject $principal
    Assert-Equal $global:ReportFederationTest.Created.issuer $expected.issuer
    Assert-Equal $global:ReportFederationTest.Created.audiences[0] 'api://AzureADTokenExchange'
    Assert-Equal @($global:ReportFederationTest.Calls | Where-Object Method -eq POST).Count 1
    Assert-True ($global:ReportFederationTest.Calls[-1].Uri.EndsWith('/federatedIdentityCredentials'))
}
Test-Case 'Reuses an equivalent trust under a different name across pagination' {
    $global:ReportFederationTest.Credentials = @($expected.Clone())
    $global:ReportFederationTest.Credentials[0].name = 'existing-report-trust'
    $global:ReportFederationTest.Continuation = 'https://graph.microsoft.com/v1.0/applications/app-object/federatedIdentityCredentials?$skiptoken=next'
    $result = Configure
    Assert-Equal $result.Status 'Existing'
    Assert-Equal $result.Name 'existing-report-trust'
    Assert-True ($null -eq $global:ReportFederationTest.Created)
    Assert-Equal $global:ReportFederationTest.Calls.Count 3
}
Test-Case 'Refuses a same-name credential with different trust' {
    $global:ReportFederationTest.Credentials = @($expected.Clone())
    $global:ReportFederationTest.Credentials[0].subject = $client
    Assert-Throws { Configure }
    Assert-True ($null -eq $global:ReportFederationTest.Created)
}
Test-Case 'Refuses an unexpected audience without overwriting existing trust' {
    $global:ReportFederationTest.Credentials = @($expected.Clone())
    $global:ReportFederationTest.Credentials[0].audiences = @('unexpected')
    Assert-Throws { Configure }
    Assert-True ($null -eq $global:ReportFederationTest.Created)
}
Test-Case 'WhatIf never writes a credential' {
    $null = Configure -WhatIf
    Assert-True ($null -eq $global:ReportFederationTest.Created)
}
Test-Case 'Tenant mismatch fails before Graph requests' {
    $global:ReportFederationTest.TokenTenant = $client
    Assert-Throws { Configure }
    Assert-Equal $global:ReportFederationTest.Calls.Count 0
}
Test-Case 'Untrusted pagination URL never receives Graph authorization headers' {
    $global:ReportFederationTest.Continuation = 'https://example.test/continuation'
    Assert-Throws { Configure }
    Assert-Equal $global:ReportFederationTest.Calls.Count 2
}
Test-Case 'Graph errors and incorrect creation confirmation fail explicitly' {
    $global:ReportFederationTest.GraphFailure = $true
    Assert-Throws { Configure }
    $global:ReportFederationTest.GraphFailure = $false
    $global:ReportFederationTest.BadConfirmation = $true
    Assert-Throws { Configure }
}
Test-Case 'ARM template isolates login identity and preserves system identity RBAC' {
    $template = Get-Content "$root\azuredeploy.json" -Raw | ConvertFrom-Json -AsHashtable
    Assert-True (-not $template.parameters.ContainsKey('reportClientSecret'))
    $identity = @($template.resources | Where-Object type -eq 'Microsoft.ManagedIdentity/userAssignedIdentities')
    Assert-Equal $identity.Count 1
    $apps = @($template.resources | Where-Object type -eq 'Microsoft.Web/sites')
    Assert-True ($apps[0].identity.Contains('SystemAssigned, UserAssigned'))
    Assert-True ($apps[0].identity.Contains('SystemAssigned'))
    Assert-True ($apps[0].identity.Contains('report-login-'))
    $auth = @($template.resources | Where-Object name -Like '*authsettingsV2*')
    Assert-Equal $auth[0].properties.identityProviders.azureActiveDirectory.registration.clientSecretSettingName 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
    Assert-True ($auth[0].properties.identityProviders.azureActiveDirectory.registration.clientId.Contains('reportClientId'))
    $sticky = @($template.resources | Where-Object name -Like '*slotConfigNames*')
    Assert-Equal $sticky[0].properties.appSettingNames[0] 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
    $json = Get-Content "$root\azuredeploy.json" -Raw
    Assert-True (-not $json.Contains('MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'))
    Assert-True (-not $json.Contains('AZURE_CLIENT_ID'))
    foreach ($role in @($template.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')) {
        Assert-True (-not $role.properties.principalId.Contains('report-login-'))
        Assert-True ($role.properties.principalId.Contains('Microsoft.Web/sites'))
        Assert-True ($role.properties.principalId.EndsWith('.identity.principalId]'))
    }
    Assert-True ($template.outputs.ContainsKey('reportLoginIdentityPrincipalId'))
    Assert-True ($template.outputs.ContainsKey('reportLoginIdentityClientId'))
}
Write-Output "$passed passed; $failed failed."
Remove-Variable -Name ReportFederationTest -Scope Global
if ($failed) { exit 1 }
