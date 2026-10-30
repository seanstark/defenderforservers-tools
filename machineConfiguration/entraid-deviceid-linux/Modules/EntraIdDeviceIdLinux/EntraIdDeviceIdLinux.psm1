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

    if (-not [string]::IsNullOrWhiteSpace($intuneDeviceId)) {
        return @{
            Status         = 'Present'
            IntuneDeviceId = $intuneDeviceId
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
        $path = '/var/opt/microsoft/mdatp/wdavstate'

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $current.Reasons = @([EntraIdDeviceIdLinuxReason] @{
                Code   = 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:FileMissing'
                Phrase = "MDE state file '$path' does not exist."
            })
            return $current
        }

        try {
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        }
        catch {
            $current.Reasons = @([EntraIdDeviceIdLinuxReason] @{
                Code   = 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:ReadError'
                Phrase = "MDE state file '$path' could not be read. $($_.Exception.Message)"
            })
            return $current
        }

        $state = ConvertFrom-WdavStateContent -Content ([string] $content)
        $current.IntuneDeviceId = [string] $state.IntuneDeviceId

        switch ($state.Status) {
            'EmptyFile' {
                $current.Reasons = @([EntraIdDeviceIdLinuxReason] @{
                    Code   = 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:EmptyFile'
                    Phrase = "MDE state file '$path' is empty."
                })
            }
            'PayloadMissing' {
                $current.Reasons = @([EntraIdDeviceIdLinuxReason] @{
                    Code   = 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:PayloadMissing'
                    Phrase = "MDE state file '$path' does not contain mEnrollmentPayload."
                })
            }
            'IntuneDeviceIdMissing' {
                $current.Reasons = @([EntraIdDeviceIdLinuxReason] @{
                    Code   = 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:IntuneDeviceIdMissing'
                    Phrase = "mEnrollmentPayload in '$path' does not contain a non-empty intuneDeviceId value (errorCode='$($state.ErrorCode)', message='$($state.Message)')."
                })
            }
            default {
                $current.Reasons = @([EntraIdDeviceIdLinuxReason] @{
                    Code   = 'EntraIdDeviceIdLinux:EntraIdDeviceIdLinux:Compliant'
                    Phrase = "intuneDeviceId=$($state.IntuneDeviceId)"
                })
            }
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
        throw "MDE state file '/var/opt/microsoft/mdatp/wdavstate' is managed by Microsoft Defender for Endpoint on Linux and cannot be synthesized manually."
    }
}
