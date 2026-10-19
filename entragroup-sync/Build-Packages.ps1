[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) "arc-entra-packages-$([guid]::NewGuid().ToString('N'))")
)
$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $output -Force
foreach ($app in @('worker', 'report')) {
    $staging = Join-Path $output "$app-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $staging
    try {
        Copy-Item -Path "$PSScriptRoot\$app\*" -Destination $staging -Recurse
        $module = Join-Path $staging 'Modules\ArcEntraSync'
        $null = New-Item -ItemType Directory -Path $module -Force
        Copy-Item -LiteralPath "$PSScriptRoot\shared\Sync.psm1" -Destination (Join-Path $module 'ArcEntraSync.psm1')
        $zip = Join-Path $output "$app.zip"
        Compress-Archive -Path "$staging\*" -DestinationPath $zip -Force
        Get-Item -LiteralPath $zip
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
