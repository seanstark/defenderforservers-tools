using namespace System.Net
param($Request, $TriggerMetadata)
if (-not ($global:ReportStaticCache -is [hashtable])) { $global:ReportStaticCache = @{} }
if (-not ($global:ReportApiCache -is [hashtable])) { $global:ReportApiCache = @{} }
$headers = @{
    'Cache-Control' = 'no-store'
    'X-Content-Type-Options' = 'nosniff'
    'Referrer-Policy' = 'no-referrer'
    'Content-Security-Policy' = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
}
function New-HttpResponse {
    param([int]$StatusCode, [string]$ContentType, [string]$Body, [hashtable]$Headers)
    $responseHeaders = @{}
    foreach ($k in $Headers.Keys) { $responseHeaders[$k] = $Headers[$k] }
    $responseHeaders['Content-Type'] = $ContentType
    $payload = @{
        StatusCode = $StatusCode
        ContentType = $ContentType
        Headers = $responseHeaders
        Body = $Body
    }
    if ('HttpResponseContext' -as [type]) {
        return ([HttpResponseContext]$payload)
    }
    return $payload
}
try {
    if (-not (Test-ReportReader $Request)) {
        Push-OutputBinding -Name Response -Value (New-HttpResponse -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body 'Report.Reader role required.' -Headers $headers)
        return
    }
    $rawPath = ([string]$Request.Params.path).Trim('/')
    $path = ($rawPath -replace '^(?i)api/report/?', '').Trim('/')
    $content = switch ($path) {
        '' { @{ File = 'index.html'; Type = 'text/html; charset=utf-8' } }
        'index.html' { @{ File = 'index.html'; Type = 'text/html; charset=utf-8' } }
        'coverage.html' { @{ File = 'coverage.html'; Type = 'text/html; charset=utf-8' } }
        'permissions.html' { @{ File = 'permissions.html'; Type = 'text/html; charset=utf-8' } }
        'docs.html' { @{ File = 'docs.html'; Type = 'text/html; charset=utf-8' } }
        'app.js' { @{ File = 'app.js'; Type = 'text/javascript; charset=utf-8' } }
        'coverage.js' { @{ File = 'coverage.js'; Type = 'text/javascript; charset=utf-8' } }
        'permissions.js' { @{ File = 'permissions.js'; Type = 'text/javascript; charset=utf-8' } }
        'docs.js' { @{ File = 'docs.js'; Type = 'text/javascript; charset=utf-8' } }
        'theme.js' { @{ File = 'theme.js'; Type = 'text/javascript; charset=utf-8' } }
        'style.css' { @{ File = 'style.css'; Type = 'text/css; charset=utf-8' } }
        default { $null }
    }
    if ($content) {
        $fileName = $content.File
        if (-not $global:ReportStaticCache.ContainsKey($fileName)) {
            $global:ReportStaticCache[$fileName] = Get-Content -LiteralPath "$PSScriptRoot\..\www\$fileName" -Raw
        }
        $staticHeaders = @{}
        foreach ($k in $headers.Keys) { $staticHeaders[$k] = $headers[$k] }
        $staticHeaders['Cache-Control'] = 'private, max-age=300, stale-while-revalidate=3600'
        Push-OutputBinding -Name Response -Value (New-HttpResponse -StatusCode 200 -ContentType $content.Type -Body $global:ReportStaticCache[$fileName] -Headers $staticHeaders)
        return
    }
    $cursor = [string]$Request.Query.cursor
    $forceRefresh = [string]$Request.Query.refresh -in @('1', 'true')
    try {
        $null = Get-TableContinuation $cursor
    }
    catch [ArgumentException] {
        Write-Warning 'Report request supplied an invalid continuation cursor.'
        Push-OutputBinding -Name Response -Value (New-HttpResponse -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body '{"error":"Invalid continuation cursor."}' -Headers $headers)
        return
    }
    $cacheKey = "${path}:$([string]$Request.Query.key):${cursor}"
    $now = [datetimeoffset]::UtcNow
    if (-not $forceRefresh -and $global:ReportApiCache.ContainsKey($cacheKey) -and $global:ReportApiCache[$cacheKey].Expires -gt $now) {
        $cachedHeaders = @{}
        foreach ($k in $headers.Keys) { $cachedHeaders[$k] = $headers[$k] }
        $cachedHeaders['Cache-Control'] = 'private, max-age=30, stale-while-revalidate=120'
        Push-OutputBinding -Name Response -Value (New-HttpResponse -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $global:ReportApiCache[$cacheKey].Body -Headers $cachedHeaders)
        return
    }
    if ($path -eq 'data') {
        $result = Get-TablePage -Filter "RowKey eq 'state'" -Cursor $cursor
    }
    elseif ($path -eq 'history' -and [string]$Request.Query.key -cmatch '^[a-f0-9]{64}$') {
        $result = Get-ReportHistoryPage -Key ([string]$Request.Query.key) -Cursor $cursor
    }
    elseif ($path -eq 'health') {
        $result = Get-ReportHealthResponse $Request
    }
    elseif ($path -eq 'logs') {
        $result = Get-TablePage -Filter "PartitionKey eq 'system' and RowKey ge 'log_' and RowKey lt 'loh'" -Top 50 -Cursor $cursor
    }
    elseif ($path -eq 'permissions') {
        $result = Get-ReportPermissionsResponse $Request
    }
    else {
        Push-OutputBinding -Name Response -Value (New-HttpResponse -StatusCode 404 -ContentType 'application/json; charset=utf-8' -Body '{"error":"Route not found."}' -Headers $headers)
        return
    }
    $serializedBody = ConvertTo-Json -InputObject $result -Depth 30 -Compress
    $global:ReportApiCache[$cacheKey] = @{
        Body = $serializedBody
        Expires = $now.AddSeconds(60)
    }
    $apiHeaders = @{}
    foreach ($k in $headers.Keys) { $apiHeaders[$k] = $headers[$k] }
    if (-not $forceRefresh) {
        $apiHeaders['Cache-Control'] = 'private, max-age=30, stale-while-revalidate=120'
    }
    Push-OutputBinding -Name Response -Value (New-HttpResponse -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $serializedBody -Headers $apiHeaders)
}
catch {
    Write-Error "Report request failed: $($_.Exception.Message)" -ErrorAction Continue
    Push-OutputBinding -Name Response -Value (New-HttpResponse -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body '{"error":"Report data is unavailable. Review application logs."}' -Headers $headers)
}
