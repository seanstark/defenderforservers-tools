$registrySubKeys = @(
    'SOFTWARE\Microsoft\SenseCM',
    'SOFTWARE\Microsoft\SenseCM\MemConfiguration'
)
$registryValueName = 'EnrollmentPayload'

function Get-EnrollmentPayloadState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $baseKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $anyKeyFound = $false
        $matchedSubKey = $registrySubKeys[0]
        $rawValue = ''
        $valueType = ''
        $valueFound = $false

        foreach ($subKeyPath in $registrySubKeys) {
            $registryKey = $null
            try {
                $registryKey = $baseKey.OpenSubKey($subKeyPath)
                if ($null -ne $registryKey) {
                    $anyKeyFound = $true
                    $matchedSubKey = $subKeyPath
                    $valueNames = @($registryKey.GetValueNames())
                    if ($registryValueName -in $valueNames) {
                        $valueType = $registryKey.GetValueKind($registryValueName).ToString()
                        $rawValue = [string] $registryKey.GetValue($registryValueName)
                        $valueFound = $true
                        break
                    }
                }
            }
            finally {
                if ($null -ne $registryKey) {
                    $registryKey.Dispose()
                }
            }
        }

        if (-not $anyKeyFound) {
            return @{
                Status         = 'KeyNotPresent'
                SubKey         = $registrySubKeys[0]
                RawValue       = ''
                IntuneDeviceId = ''
                ErrorCode      = ''
                Message        = ''
                Type           = ''
            }
        }

        if (-not $valueFound) {
            return @{
                Status         = 'ValueNotPresent'
                SubKey         = $matchedSubKey
                RawValue       = ''
                IntuneDeviceId = ''
                ErrorCode      = ''
                Message        = ''
                Type           = ''
            }
        }

        if ($valueType -ne [Microsoft.Win32.RegistryValueKind]::String.ToString()) {
            return @{
                Status         = 'WrongType'
                SubKey         = $matchedSubKey
                RawValue       = $rawValue
                IntuneDeviceId = ''
                ErrorCode      = ''
                Message        = ''
                Type           = $valueType
            }
        }

        try {
            $payload = $rawValue | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return @{
                Status         = 'InvalidJson'
                SubKey         = $matchedSubKey
                RawValue       = $rawValue
                IntuneDeviceId = ''
                ErrorCode      = ''
                Message        = ''
                Type           = $valueType
                Error          = $_.Exception.Message
            }
        }

        $intuneIdProp = if ($null -ne $payload) { $payload.PSObject.Properties['intuneDeviceId'] } else { $null }
        $intuneDeviceId = if ($null -ne $intuneIdProp -and $null -ne $intuneIdProp.Value) { ([string] $intuneIdProp.Value).Trim() } else { '' }
        $errorCodeProp = if ($null -ne $payload) { $payload.PSObject.Properties['errorCode'] } else { $null }
        $errorCode = if ($null -ne $errorCodeProp -and $null -ne $errorCodeProp.Value) { [string] $errorCodeProp.Value } else { '' }
        $messageProp = if ($null -ne $payload) { $payload.PSObject.Properties['message'] } else { $null }
        $message = if ($null -ne $messageProp -and $null -ne $messageProp.Value) { [string] $messageProp.Value } else { '' }

        if ([string]::IsNullOrWhiteSpace($intuneDeviceId)) {
            return @{
                Status         = 'IntuneDeviceIdMissing'
                SubKey         = $matchedSubKey
                RawValue       = $rawValue
                IntuneDeviceId = ''
                ErrorCode      = $errorCode
                Message        = $message
                Type           = $valueType
            }
        }

        return @{
            Status         = 'Present'
            SubKey         = $matchedSubKey
            RawValue       = $rawValue
            IntuneDeviceId = $intuneDeviceId
            ErrorCode      = $errorCode
            Message        = $message
            Type           = $valueType
        }
    }
    catch {
        return @{
            Status         = 'ReadError'
            SubKey         = $registrySubKeys[0]
            RawValue       = ''
            IntuneDeviceId = ''
            ErrorCode      = ''
            Message        = ''
            Type           = ''
            Error          = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $baseKey) {
            $baseKey.Dispose()
        }
    }
}

function Get-TargetResource {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $state = Get-EnrollmentPayloadState
    $subKey = if ($state.SubKey) { $state.SubKey } else { $registrySubKeys[0] }
    $reason = switch ($state.Status) {
        'KeyNotPresent' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:KeyNotPresent'
                Phrase = "Registry key HKEY_LOCAL_MACHINE\$subKey is not present."
            }
        }
        'ValueNotPresent' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:ValueNotPresent'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$subKey\$registryValueName is not present."
            }
        }
        'WrongType' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:WrongType'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$subKey\$registryValueName has type '$($state.Type)'. Expected REG_SZ JSON payload."
            }
        }
        'InvalidJson' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:InvalidJson'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$subKey\$registryValueName does not contain valid JSON. $($state.Error)"
            }
        }
        'IntuneDeviceIdMissing' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:IntuneDeviceIdMissing'
                Phrase = "EnrollmentPayload in HKEY_LOCAL_MACHINE\$subKey\$registryValueName does not contain a non-empty intuneDeviceId value (errorCode='$($state.ErrorCode)', message='$($state.Message)')."
            }
        }
        'ReadError' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:ReadError'
                Phrase = "Unable to read HKEY_LOCAL_MACHINE\$subKey\$registryValueName. $($state.Error)"
            }
        }
        default {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:Compliant'
                Phrase = "intuneDeviceId=$($state.IntuneDeviceId)"
            }
        }
    }

    return @{
        Name           = $Name
        IntuneDeviceId = $state.IntuneDeviceId
        Reasons        = @($reason)
    }
}

function Test-TargetResource {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $state = Get-EnrollmentPayloadState
    return $state.Status -eq 'Present' -and -not [string]::IsNullOrWhiteSpace($state.IntuneDeviceId)
}

function Set-TargetResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $state = Get-EnrollmentPayloadState
    if ($state.Status -eq 'Present' -and -not [string]::IsNullOrWhiteSpace($state.IntuneDeviceId)) {
        return
    }

    $subKey = if ($state.SubKey) { $state.SubKey } else { $registrySubKeys[0] }
    throw "HKEY_LOCAL_MACHINE\$subKey\$registryValueName is managed by Microsoft Defender for Endpoint Security Settings Management (SenseCM) and cannot be synthesized manually (current status: $($state.Status))."
}

Export-ModuleMember -Function Get-TargetResource, Test-TargetResource, Set-TargetResource
