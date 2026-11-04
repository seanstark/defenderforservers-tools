class EntraIdDeviceIdLinuxReason {
    [DscProperty()]
    [string] $Code

    [DscProperty()]
    [string] $Phrase
}

function Find-EnrollmentPayloadValue {
    param([object] $InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ($key -in @('mEnrollmentPayload', 'EnrollmentPayload')) {
                return $InputObject[$key]
            }
        }
        foreach ($key in $InputObject.Keys) {
            $found = Find-EnrollmentPayloadValue -InputObject $InputObject[$key]
            if ($null -ne $found) { return $found }
        }
    }
    elseif ($InputObject -is [pscustomobject]) {
        foreach ($prop in $InputObject.PSObject.Properties) {
            if ($prop.Name -in @('mEnrollmentPayload', 'EnrollmentPayload')) {
                return $prop.Value
            }
        }
        foreach ($prop in $InputObject.PSObject.Properties) {
            $found = Find-EnrollmentPayloadValue -InputObject $prop.Value
            if ($null -ne $found) { return $found }
        }
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        foreach ($item in $InputObject) {
            $found = Find-EnrollmentPayloadValue -InputObject $item
            if ($null -ne $found) { return $found }
        }
    }
    return $null
}

function ConvertFrom-WdavStateContent {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @{
            Status         = 'EmptyFile'
            IntuneDeviceId = ''
            ErrorCode      = ''
            Message        = ''
        }
    }

    $payloadObj = $null
    $payloadRaw = ''

    # 1. Try parsing the outer document as JSON first
    try {
        $doc = $Content | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        $rawPayload = Find-EnrollmentPayloadValue -InputObject $doc
        if ($rawPayload -is [string] -and -not [string]::IsNullOrWhiteSpace($rawPayload)) {
            $payloadRaw = $rawPayload
            try {
                $payloadObj = $rawPayload | ConvertFrom-Json -Depth 20 -ErrorAction Stop
            }
            catch {}
        }
        elseif ($null -ne $rawPayload) {
            $payloadObj = $rawPayload
        }
    }
    catch {}

    # 2. Fallback regex extraction if outer wdavstate has partial/escaped mEnrollmentPayload string
    if ($null -eq $payloadObj) {
        if ($Content -match '"mEnrollmentPayload"\s*:\s*"((?:\\.|[^"\\])*)"') {
            $payloadRaw = $Matches[1] -replace '\\"', '"' -replace '\\\\', '\'
            try {
                $payloadObj = $payloadRaw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
            }
            catch {}
        }
    }

    $intuneDeviceId = ''
    $errorCode = ''
    $message = ''

    if ($null -ne $payloadObj) {
        $idProp = $payloadObj.PSObject.Properties['intuneDeviceId']
        if ($null -ne $idProp -and $null -ne $idProp.Value) {
            $intuneDeviceId = ([string] $idProp.Value).Trim()
        }
        $errProp = $payloadObj.PSObject.Properties['errorCode']
        if ($null -ne $errProp -and $null -ne $errProp.Value) {
            $errorCode = [string] $errProp.Value
        }
        $msgProp = $payloadObj.PSObject.Properties['message']
        if ($null -ne $msgProp -and $null -ne $msgProp.Value) {
            $message = [string] $msgProp.Value
        }
    }

    # 3. Direct regex fallback on raw/unescaped content for "mEnrollmentPayload":..."intuneDeviceId":"<id>"
    if ([string]::IsNullOrWhiteSpace($intuneDeviceId)) {
        $searchSource = if ($payloadRaw) { $payloadRaw } else { $Content }
        if ($searchSource -match '\\?"mEnrollmentPayload\\?"[\s\S]*?\\?"intuneDeviceId\\?"\s*:\s*\\?"([^"\\]+)\\?"') {
            $intuneDeviceId = $Matches[1].Trim()
        }
        elseif ($searchSource -match '\\?"intuneDeviceId\\?"\s*:\s*\\?"([^"\\]+)\\?"') {
            $intuneDeviceId = $Matches[1].Trim()
        }
    }

    $deviceGuid = [guid]::Empty
    if ([guid]::TryParse($intuneDeviceId, [ref] $deviceGuid) -and $deviceGuid -ne [guid]::Empty -and
        $errorCode -in @('', '0')) {
        return @{
            Status         = 'Present'
            IntuneDeviceId = $deviceGuid.ToString('D')
            ErrorCode      = $errorCode
            Message        = $message
        }
    }

    if ($Content -notmatch 'mEnrollmentPayload') {
        return @{
            Status         = 'PayloadMissing'
            IntuneDeviceId = ''
            ErrorCode      = ''
            Message        = ''
        }
    }

    return @{
        Status         = 'IntuneDeviceIdMissing'
        IntuneDeviceId = ''
        ErrorCode      = $errorCode
        Message        = $message
    }
}

function ConvertFrom-SenseCmEnrollmentLog {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $Line
    )
    begin {
        $seen = $false
        $latestPayload = ''
    }
    process {
        if ($Line -match 'SenseCM:\s*enrollment result was received\b') {
            $seen = $true
            $latestPayload = if ($Line -match 'MemEnrollmentPayload:\s*(.*)$') { $Matches[1] } else { '' }
        }
    }
    end {
        $state = @{ Status = 'PayloadMissing'; IntuneDeviceId = ''; ErrorCode = ''; Message = 'No SenseCM enrollment-result line was found.' }
        if ($seen) {
            $payload = $null
            try {
                if ([string]::IsNullOrWhiteSpace($latestPayload)) { throw 'Enrollment payload is empty.' }
                $payload = ConvertFrom-Json -InputObject $latestPayload -Depth 20 -NoEnumerate -ErrorAction Stop
                if ($null -eq $payload -or $payload.GetType() -ne [System.Management.Automation.PSCustomObject]) {
                    throw 'Enrollment payload is not a JSON object.'
                }
            }
            catch {
                $state.Status = 'InvalidPayload'
                $state.Message = 'The newest SenseCM enrollment-result line has an invalid JSON payload.'
            }
            if ($null -ne $payload -and $state.Status -ne 'InvalidPayload') {
                $state.ErrorCode = [string] $payload.errorCode
                $state.Message = [string] $payload.message
                $deviceGuid = [guid]::Empty
                if ($state.ErrorCode -notin @('', '0')) {
                    $state.Status = 'EnrollmentError'
                    $state.Message = "The newest SenseCM enrollment failed (errorCode='$($state.ErrorCode)')."
                }
                elseif ([guid]::TryParse([string] $payload.intuneDeviceId, [ref] $deviceGuid) -and $deviceGuid -ne [guid]::Empty) {
                    $state.Status = 'Present'
                    $state.IntuneDeviceId = $deviceGuid.ToString('D')
                }
                else {
                    $state.Status = 'IntuneDeviceIdMissing'
                    $state.Message = 'The newest SenseCM enrollment result has no valid, non-zero intuneDeviceId GUID.'
                }
            }
        }
        return $state
    }
}

function Get-LinuxEnrollmentState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $StatePath = '/var/opt/microsoft/mdatp/wdavstate',
        [string] $LogPath = '/var/log/microsoft/mdatp/microsoft_defender_enterprise_sensecm.log'
    )
    $state = @{ Status = 'FileMissing'; IntuneDeviceId = ''; Message = "MDE state file '$StatePath' does not exist." }
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $state = ConvertFrom-WdavStateContent -Content ([string] (Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop))
        }
        catch {
            $state = @{ Status = 'ReadError'; IntuneDeviceId = ''; Message = "MDE state file '$StatePath' could not be read: $($_.Exception.Message)" }
            Write-Warning $state.Message
        }
    }
    if ($state.Status -eq 'Present') {
        $state.Source = 'wdavstate'
        return $state
    }

    $logState = @{ Status = 'FileMissing'; IntuneDeviceId = ''; Message = "SenseCM log '$LogPath' does not exist." }
    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        try {
            $logState = Get-Content -LiteralPath $LogPath -ErrorAction Stop | ConvertFrom-SenseCmEnrollmentLog
        }
        catch {
            $logState = @{ Status = 'ReadError'; IntuneDeviceId = ''; Message = "SenseCM log '$LogPath' could not be read: $($_.Exception.Message)" }
            Write-Warning $logState.Message
        }
    }
    if ($logState.Status -eq 'Present') {
        $logState.Source = 'SenseCM'
        return $logState
    }
    return @{
        Status = 'EnrollmentUnavailable'
        IntuneDeviceId = ''
        Message = "wdavstate: $($state.Status) $($state.Message) SenseCM log: $($logState.Status) $($logState.Message)"
    }
}

[DscResource()]
class EntraIdDeviceIdLinux {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(NotConfigurable)]
    [string] $IntuneDeviceId

    [DscProperty(NotConfigurable)]
    [EntraIdDeviceIdLinuxReason[]] $Reasons

    [EntraIdDeviceIdLinux] Get() {
        $current = [EntraIdDeviceIdLinux]::new()
        $current.Name = $this.Name
        $current.IntuneDeviceId = ''
        $state = Get-LinuxEnrollmentState
        $current.IntuneDeviceId = [string] $state.IntuneDeviceId
        if ($state.Status -eq 'Present') {
            $current.Reasons = @([EntraIdDeviceIdLinuxReason] @{
                Code   = 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:Compliant'
                Phrase = "intuneDeviceId=$($state.IntuneDeviceId)"
            })
        }
        else {
            $current.Reasons = @([EntraIdDeviceIdLinuxReason] @{
                Code   = "EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:$($state.Status)"
                Phrase = $state.Message
            })
        }

        return $current
    }

    [bool] Test() {
        $current = $this.Get()
        return $current.Reasons.Count -eq 1 -and
            $current.Reasons[0].Code -eq 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:Compliant' -and
            -not [string]::IsNullOrWhiteSpace($current.IntuneDeviceId)
    }

    [void] Set() {
        if ($this.Test()) {
            return
        }
        throw 'MDE enrollment state and SenseCM logs are managed by Microsoft Defender for Endpoint on Linux and cannot be synthesized manually.'
    }
}
