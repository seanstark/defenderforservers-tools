$registrySubKey = 'SOFTWARE\Microsoft\SenseCM\MemConfiguration'
$registryValueName = 'EnrollmentPayload'

function Get-EnrollmentPayloadState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $baseKey = $null
    $registryKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $registryKey = $baseKey.OpenSubKey($registrySubKey)
        if ($null -eq $registryKey) {
            return @{
                Status         = 'KeyNotPresent'
                RawValue       = ''
                IntuneDeviceId = ''
                ErrorCode      = ''
                Message        = ''
                Type           = ''
            }
        }

        $valueNames = @($registryKey.GetValueNames())
        if ($registryValueName -notin $valueNames) {
            return @{
                Status         = 'ValueNotPresent'
                RawValue       = ''
                IntuneDeviceId = ''
                ErrorCode      = ''
                Message        = ''
                Type           = ''
            }
        }

        $valueType = $registryKey.GetValueKind($registryValueName).ToString()
        $rawValue = [string] $registryKey.GetValue($registryValueName)
        if ($valueType -ne [Microsoft.Win32.RegistryValueKind]::String.ToString()) {
            return @{
                Status         = 'WrongType'
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
                RawValue       = $rawValue
                IntuneDeviceId = ''
                ErrorCode      = $errorCode
                Message        = $message
                Type           = $valueType
            }
        }

        return @{
            Status         = 'Present'
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
            RawValue       = ''
            IntuneDeviceId = ''
            ErrorCode      = ''
            Message        = ''
            Type           = ''
            Error          = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $registryKey) {
            $registryKey.Dispose()
        }
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
    $reason = switch ($state.Status) {
        'KeyNotPresent' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:KeyNotPresent'
                Phrase = "Registry key HKEY_LOCAL_MACHINE\$registrySubKey is not present."
            }
        }
        'ValueNotPresent' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:ValueNotPresent'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName is not present."
            }
        }
        'WrongType' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:WrongType'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName has type '$($state.Type)'. Expected REG_SZ JSON payload."
            }
        }
        'InvalidJson' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:InvalidJson'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName does not contain valid JSON. $($state.Error)"
            }
        }
        'IntuneDeviceIdMissing' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:IntuneDeviceIdMissing'
                Phrase = "EnrollmentPayload in HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName does not contain a non-empty intuneDeviceId value (errorCode='$($state.ErrorCode)', message='$($state.Message)')."
            }
        }
        'ReadError' {
            @{
                Code   = 'EntraIdDeviceId:EntraIdDeviceId:ReadError'
                Phrase = "Unable to read HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName. $($state.Error)"
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

    throw "HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName is managed by Microsoft Defender for Endpoint Security Settings Management (SenseCM) and cannot be synthesized manually (current status: $($state.Status))."
}

Export-ModuleMember -Function Get-TargetResource, Test-TargetResource, Set-TargetResource
