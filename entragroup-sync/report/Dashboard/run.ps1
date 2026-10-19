using namespace System.Net
param($Request, $TriggerMetadata)
$headers = @{
    'Cache-Control' = 'no-store'
    'X-Content-Type-Options' = 'nosniff'
    'Referrer-Policy' = 'no-referrer'
    'Content-Security-Policy' = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
}
try {
    if (-not (Test-ReportReader $Request)) {
        Push-OutputBinding -Name Response -Value @{ StatusCode = [HttpStatusCode]::Forbidden; Headers = $headers; Body = 'Report.Reader role required.' }
        return
    }
    $path = [string]$Request.Params.path
    $content = switch ($path) {
        '' { @{ File = 'index.html'; Type = 'text/html; charset=utf-8' } }
        'index.html' { @{ File = 'index.html'; Type = 'text/html; charset=utf-8' } }
        'app.js' { @{ File = 'app.js'; Type = 'text/javascript; charset=utf-8' } }
        'theme.js' { @{ File = 'theme.js'; Type = 'text/javascript; charset=utf-8' } }
        'style.css' { @{ File = 'style.css'; Type = 'text/css; charset=utf-8' } }
        default { $null }
    }
    if ($content) {
        $headers['Content-Type'] = $content.Type
        Push-OutputBinding -Name Response -Value @{ StatusCode = [HttpStatusCode]::OK; Headers = $headers; Body = Get-Content -LiteralPath "$PSScriptRoot\..\www\$($content.File)" -Raw }
        return
    }
    $headers['Content-Type'] = 'application/json; charset=utf-8'
    $cursor = [string]$Request.Query.cursor
    try {
        $null = Get-TableContinuation $cursor
    }
    catch [ArgumentException] {
        Write-Warning 'Report request supplied an invalid continuation cursor.'
        Push-OutputBinding -Name Response -Value @{ StatusCode = 400; Headers = $headers; Body = '{"error":"Invalid continuation cursor."}' }
        return
    }
    if ($path -eq 'data') {
        $result = Get-TablePage -Filter "RowKey eq 'state'" -Cursor $cursor
    }
    elseif ($path -eq 'history' -and [string]$Request.Query.key -cmatch '^[a-f0-9]{64}$') {
        $result = Get-TablePage -Filter "PartitionKey eq '$($Request.Query.key)' and RowKey ge 'h_' and RowKey lt 'i'" -Top 50 -Cursor $cursor
    }
    elseif ($path -eq 'health') {
        $result = & (Get-Module ArcEntraSync) {
            $appResourceId = Get-FunctionAppResourceId
            $response = Invoke-Table -Path "machines(PartitionKey='system',RowKey='inventory')" -AllowStatus @(404)
            if ($response.Status -eq 404) {
                return @{
                    FunctionAppName = if ($appResourceId) { $appResourceId.Split('/')[-1] } else { '' }
                    FunctionAppResourceId = $appResourceId
                    FunctionAppStatus = 'Idle'
                    Health = 'Unknown'
                    LastSuccessfulInventory = $null
                    MachinesQueued = 0
                    LastRunTime = $null
                    LastRunFunction = ''
                    LastRunReason = 'No function runs recorded yet'
                    LastRunStatus = ''
                    LastRunMessage = ''
                    Parameters = Get-FunctionParametersSummary
                }
            }
            $data = ConvertFrom-Json -InputObject (Read-JsonResponse $response).Data -AsHashtable
            if ($appResourceId -and -not $data['FunctionAppResourceId']) { $data.FunctionAppResourceId = $appResourceId }
            if ($appResourceId -and -not $data['FunctionAppName']) { $data.FunctionAppName = $appResourceId.Split('/')[-1] }
            if (-not $data['Parameters']) { $data.Parameters = Get-FunctionParametersSummary }
            $data
        }
    }
    elseif ($path -eq 'logs') {
        $result = Get-TablePage -Filter "PartitionKey eq 'system' and RowKey ge 'log_' and RowKey lt 'loh'" -Top 50 -Cursor $cursor
    }
    else {
        Push-OutputBinding -Name Response -Value @{ StatusCode = 404; Headers = $headers; Body = '{"error":"Route not found."}' }
        return
    }
    Push-OutputBinding -Name Response -Value @{ StatusCode = 200; Headers = $headers; Body = ConvertTo-Json -InputObject $result -Depth 30 -Compress }
}
catch {
    Write-Error "Report request failed: $($_.Exception.Message)" -ErrorAction Continue
    Push-OutputBinding -Name Response -Value @{ StatusCode = 500; Headers = $headers; Body = '{"error":"Report data is unavailable. Review application logs."}' }
}
