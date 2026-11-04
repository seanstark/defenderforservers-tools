using module ..\Modules\EntraIdDeviceIdLinux\EntraIdDeviceIdLinux.psd1

$ErrorActionPreference = 'Stop'
$passed = 0
$failed = 0
$id = 'ab7ad7df-4aeb-4468-a3d8-00c9503ebab5'
$otherId = '11111111-2222-3333-4444-555555555555'
$sample = '[35790][2026-11-03 22:37:14.604691 UTC][info]: SenseCM: enrollment result was received, MemEnrollmentPayload:{"checkinUrl":"https://edr-eus3.us.endpoint.security.microsoft.com/edr/endpointconfigmanagement/proxy/checkin/?memurl=https://checkin.dm.microsoft.com/devicecheckinfeatp/atp","intuneDeviceId":"ab7ad7df-4aeb-4468-a3d8-00c9503ebab5","errorCode":null,"message":null}'
$root = Join-Path ([IO.Path]::GetTempPath()) "entra-linux-tests-$([guid]::NewGuid())"
$null = New-Item -Path $root -ItemType Directory
$statePath = Join-Path $root 'wdavstate'
$logPath = Join-Path $root 'sensecm.log'

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected'; received '$Actual'." }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name`: $($_.Exception.Message)" }
}
function Enrollment-Line($DeviceId, $ErrorCode = $null) {
    'SenseCM: enrollment result was received, MemEnrollmentPayload:' +
        (@{ intuneDeviceId = $DeviceId; errorCode = $ErrorCode; message = $null } | ConvertTo-Json -Compress)
}
function Wdav-Content($DeviceId, $ErrorCode = $null) {
    @{ mEnrollmentPayload = (@{ intuneDeviceId = $DeviceId; errorCode = $ErrorCode } | ConvertTo-Json -Compress) } | ConvertTo-Json -Compress
}
function Read-Fixture {
    Get-LinuxEnrollmentState -StatePath $statePath -LogPath $logPath
}

try {
    Test-Case 'Native DSC configuration uses the version-named package identity' {
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\Modules\EntraIdDeviceIdLinux\EntraIdDeviceIdLinux.psd1')
        $name = "entraiddeviceidlinux_$($manifest.ModuleVersion)"
        $configuration = Get-Content (Join-Path $PSScriptRoot '..\entraid-deviceid-linux.ps1') -Raw
        $builder = Get-Content (Join-Path $PSScriptRoot '..\Build-entraid-deviceid-linux.ps1') -Raw
        Assert-Equal ([regex]::Match($configuration, '^\s*Configuration\s+(\S+)\s*\{').Groups[1].Value) $name
        Assert-Equal ([regex]::Match($configuration, 'EntraIdDeviceIdLinux\s+(\S+)\s*\{').Groups[1].Value) $name
        Assert-Equal $builder.Contains('& $configurationName -OutputPath $compiledPath') $true
    }
    Test-Case 'Package metadata and packaged module match the source module version' {
        $manifestPath = Join-Path $PSScriptRoot '..\Modules\EntraIdDeviceIdLinux\EntraIdDeviceIdLinux.psd1'
        $manifest = Import-PowerShellDataFile $manifestPath
        $packageName = "entraiddeviceidlinux_$($manifest.ModuleVersion)"
        $packagePath = Join-Path $PSScriptRoot "..\output\$packageName.zip"
        $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
        try {
            $metadataReader = [IO.StreamReader]::new($archive.GetEntry("$packageName.metaconfig.json").Open())
            try { $metadata = $metadataReader.ReadToEnd() | ConvertFrom-Json }
            finally { $metadataReader.Dispose() }
            Assert-Equal $metadata.Version $manifest.ModuleVersion
            Assert-Equal $metadata.Type 'Audit'
            $manifestReader = [IO.StreamReader]::new($archive.GetEntry('Modules/EntraIdDeviceIdLinux/EntraIdDeviceIdLinux.psd1').Open())
            try { Assert-Equal $manifestReader.ReadToEnd() (Get-Content $manifestPath -Raw) }
            finally { $manifestReader.Dispose() }
        }
        finally { $archive.Dispose() }
    }
    Test-Case 'Provided SenseCM line extracts the expected device GUID' {
        $r = $sample | ConvertFrom-SenseCmEnrollmentLog
        Assert-Equal $r.Status 'Present'
        Assert-Equal $r.IntuneDeviceId $id
    }
    Test-Case 'Only the newest enrollment result supplies the ID' {
        $r = @($sample, 'unrelated line', (Enrollment-Line $otherId)) | ConvertFrom-SenseCmEnrollmentLog
        Assert-Equal $r.IntuneDeviceId $otherId
    }
    Test-Case 'A newer failed enrollment never reuses an older ID' {
        $r = @($sample, (Enrollment-Line $otherId 42)) | ConvertFrom-SenseCmEnrollmentLog
        Assert-Equal $r.Status 'EnrollmentError'
        Assert-Equal $r.IntuneDeviceId ''
    }
    foreach ($invalid in @('', 'not-a-guid', [guid]::Empty.ToString())) {
        Test-Case "Invalid latest ID '$invalid' never reuses an older ID" {
            $r = @($sample, (Enrollment-Line $invalid)) | ConvertFrom-SenseCmEnrollmentLog
            Assert-Equal $r.Status 'IntuneDeviceIdMissing'
            Assert-Equal $r.IntuneDeviceId ''
        }
    }
    Test-Case 'A null newest ID is noncompliant' {
        $r = @($sample, (Enrollment-Line $null)) | ConvertFrom-SenseCmEnrollmentLog
        Assert-Equal $r.Status 'IntuneDeviceIdMissing'
    }
    Test-Case 'A malformed newest payload is not skipped for an older success' {
        $r = @($sample, 'SenseCM: enrollment result was received, MemEnrollmentPayload:{broken') | ConvertFrom-SenseCmEnrollmentLog
        Assert-Equal $r.Status 'InvalidPayload'
        Assert-Equal $r.IntuneDeviceId ''
    }
    Test-Case 'Enrollment line without its payload is explicitly invalid' {
        $r = 'SenseCM: enrollment result was received' | ConvertFrom-SenseCmEnrollmentLog
        Assert-Equal $r.Status 'InvalidPayload'
    }
    Test-Case 'Non-object enrollment JSON is rejected' {
        foreach ($json in @('[]', '[{"intuneDeviceId":"ab7ad7df-4aeb-4468-a3d8-00c9503ebab5"}]', 'null', '"not an object"')) {
            $r = "SenseCM: enrollment result was received, MemEnrollmentPayload:$json" | ConvertFrom-SenseCmEnrollmentLog
            Assert-Equal $r.Status 'InvalidPayload'
        }
    }
    Test-Case 'Unrelated lines containing intuneDeviceId are ignored' {
        $r = 'other component: MemEnrollmentPayload:{"intuneDeviceId":"ab7ad7df-4aeb-4468-a3d8-00c9503ebab5"}' | ConvertFrom-SenseCmEnrollmentLog
        Assert-Equal $r.Status 'PayloadMissing'
    }
    Test-Case 'Mixed-case GUID and zero success error code are normalized' {
        $r = (Enrollment-Line $id.ToUpperInvariant() 0) | ConvertFrom-SenseCmEnrollmentLog
        Assert-Equal $r.Status 'Present'
        Assert-Equal $r.IntuneDeviceId $id
    }
    Test-Case 'Existing escaped wdavstate extraction is preserved' {
        $r = ConvertFrom-WdavStateContent (Wdav-Content $id)
        Assert-Equal $r.Status 'Present'
        Assert-Equal $r.IntuneDeviceId $id
    }
    Test-Case 'Invalid or failed wdavstate enrollment is not compliant' {
        foreach ($content in @((Wdav-Content 'not-a-guid'), (Wdav-Content $id 42))) {
            if ((ConvertFrom-WdavStateContent $content).Status -eq 'Present') { throw 'Invalid enrollment was accepted.' }
        }
    }
    Test-Case 'Missing wdavstate falls back to the real log fixture' {
        Set-Content -LiteralPath $logPath -Value $sample
        $r = Read-Fixture
        Assert-Equal $r.Source 'SenseCM'
        Assert-Equal $r.IntuneDeviceId $id
    }
    foreach ($content in @('', 'not JSON', '{"mEnrollmentPayload":"{}"}')) {
        Test-Case "Unusable wdavstate '$content' falls back to the log" {
            Set-Content -LiteralPath $statePath -Value $content
            $r = Read-Fixture
            Assert-Equal $r.Source 'SenseCM'
            Assert-Equal $r.IntuneDeviceId $id
        }
    }
    Test-Case 'A working wdavstate ID retains priority' {
        Set-Content -LiteralPath $statePath -Value (Wdav-Content $otherId)
        $r = Read-Fixture
        Assert-Equal $r.Source 'wdavstate'
        Assert-Equal $r.IntuneDeviceId $otherId
    }
    Test-Case 'A wdavstate read error is surfaced while the log still works' {
        $lock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $r = Get-LinuxEnrollmentState -StatePath $statePath -LogPath $logPath -WarningVariable warnings -WarningAction SilentlyContinue
            Assert-Equal $r.Source 'SenseCM'
            if (-not $warnings) { throw 'Read failure was not reported.' }
        } finally { $lock.Dispose() }
    }
    Test-Case 'An unreadable log is noncompliant and explicit' {
        Set-Content -LiteralPath $statePath -Value '{}'
        $lock = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $r = Get-LinuxEnrollmentState -StatePath $statePath -LogPath $logPath -WarningAction SilentlyContinue
            Assert-Equal $r.Status 'EnrollmentUnavailable'
            if ($r.Message -notmatch 'ReadError') { throw 'Log read error was hidden.' }
        } finally { $lock.Dispose() }
    }
    Test-Case 'Both missing sources remain noncompliant' {
        $r = Get-LinuxEnrollmentState -StatePath (Join-Path $root 'missing-state') -LogPath (Join-Path $root 'missing-log')
        Assert-Equal $r.Status 'EnrollmentUnavailable'
        Assert-Equal $r.IntuneDeviceId ''
        if ($r.Message -notmatch 'wdavstate: FileMissing.*SenseCM log: FileMissing') { throw 'Missing source diagnostics were lost.' }
    }
    Test-Case 'An empty current log remains noncompliant' {
        Set-Content -LiteralPath $logPath -Value '' -NoNewline
        $r = Read-Fixture
        Assert-Equal $r.Status 'EnrollmentUnavailable'
        if ($r.Message -notmatch 'SenseCM log: PayloadMissing') { throw 'Empty log diagnostics were lost.' }
        Set-Content -LiteralPath $logPath -Value $sample
    }

    $module = Get-Module EntraIdDeviceIdLinux
    & $module {
        param($StatePath, $LogPath)
        $script:FixtureStatePath = $StatePath
        $script:FixtureLogPath = $LogPath
        $script:OriginalEnrollmentState = (Get-Command Get-LinuxEnrollmentState).ScriptBlock
        function script:Get-LinuxEnrollmentState {
            & $script:OriginalEnrollmentState -StatePath $script:FixtureStatePath -LogPath $script:FixtureLogPath
        }
    } $statePath $logPath
    try {
        Test-Case 'DSC fallback preserves the exact correlation report shape' {
            $resource = [EntraIdDeviceIdLinux]::new()
            $resource.Name = 'wdavstate'
            $current = $resource.Get()
            Assert-Equal $current.IntuneDeviceId $id
            Assert-Equal $current.Reasons.Count 1
            Assert-Equal $current.Reasons[0].Code 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:Compliant'
            Assert-Equal $current.Reasons[0].Phrase "intuneDeviceId=$id"
            Assert-Equal $resource.Test() $true
        }
        Test-Case 'DSC failed latest enrollment is noncompliant and read-only' {
            Set-Content -LiteralPath $logPath -Value @($sample, (Enrollment-Line $null 42))
            $before = (Get-FileHash -LiteralPath $logPath).Hash
            $resource = [EntraIdDeviceIdLinux]::new()
            $resource.Name = 'wdavstate'
            Assert-Equal $resource.Test() $false
            $threw = $false
            try { $resource.Set() } catch { $threw = $true }
            Assert-Equal $threw $true
            Assert-Equal (Get-FileHash -LiteralPath $logPath).Hash $before
        }
    } finally {
        & $module { Set-Item Function:script:Get-LinuxEnrollmentState -Value $script:OriginalEnrollmentState }
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Output "$passed passed; $failed failed."
if ($failed) { throw 'Linux enrollment regression tests failed.' }
