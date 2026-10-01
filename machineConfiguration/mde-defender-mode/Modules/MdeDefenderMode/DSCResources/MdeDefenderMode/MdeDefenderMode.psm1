$registrySubKey = 'SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
$registryValueName = 'ForceDefenderPassiveMode'

function Get-RegistryState {
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
            return @{ Status = 'KeyNotPresent'; Value = $null; Type = '' }
        }

        $valueNames = @($registryKey.GetValueNames())
        if ($registryValueName -notin $valueNames) {
            return @{ Status = 'ValueNotPresent'; Value = $null; Type = '' }
        }

        $valueType = $registryKey.GetValueKind($registryValueName).ToString()
        $value = $registryKey.GetValue($registryValueName)
        if ($valueType -ne [Microsoft.Win32.RegistryValueKind]::DWord.ToString()) {
            return @{ Status = 'WrongType'; Value = $value; Type = $valueType }
        }

        return @{ Status = 'Present'; Value = [int] $value; Type = $valueType }
    }
    catch {
        return @{
            Status = 'ReadError'
            Value = $null
            Type = ''
            Error = $_.Exception.Message
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
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Active', 'Passive')]
        [string] $Mode
    )

    $state = Get-RegistryState
    $expectedValue = if ($Mode -eq 'Passive') { 1 } else { 0 }
    $reason = switch ($state.Status) {
        'KeyNotPresent' {
            @{
                Code = 'MdeDefenderMode:MdeDefenderMode:KeyNotPresent'
                Phrase = "Registry key HKEY_LOCAL_MACHINE\$registrySubKey is not present. Expected REG_DWORD $registryValueName=$expectedValue for $Mode mode."
            }
        }
        'ValueNotPresent' {
            @{
                Code = 'MdeDefenderMode:MdeDefenderMode:ValueNotPresent'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName is not present. Expected REG_DWORD $expectedValue for $Mode mode."
            }
        }
        'WrongType' {
            @{
                Code = 'MdeDefenderMode:MdeDefenderMode:WrongType'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName has type '$($state.Type)' and value '$($state.Value)'. Expected REG_DWORD $expectedValue for $Mode mode."
            }
        }
        'ReadError' {
            @{
                Code = 'MdeDefenderMode:MdeDefenderMode:ReadError'
                Phrase = "Unable to read HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName. $($state.Error)"
            }
        }
        default {
            $identifier = if ($state.Value -eq $expectedValue) { 'Compliant' } else { 'ValueMismatch' }
            @{
                Code = "MdeDefenderMode:MdeDefenderMode:$identifier"
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName is REG_DWORD $($state.Value). Expected $expectedValue for $Mode mode."
            }
        }
    }

    return @{
        Reasons = @($reason)
    }
}

function Test-TargetResource {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Active', 'Passive')]
        [string] $Mode
    )

    $state = Get-RegistryState
    $expectedValue = if ($Mode -eq 'Passive') { 1 } else { 0 }
    return $state.Status -eq 'Present' -and $state.Value -eq $expectedValue
}

function Set-TargetResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Active', 'Passive')]
        [string] $Mode
    )

    $expectedValue = if ($Mode -eq 'Passive') { 1 } else { 0 }
    $baseKey = $null
    $registryKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $registryKey = $baseKey.CreateSubKey($registrySubKey, $true)
        $registryKey.SetValue(
            $registryValueName,
            $expectedValue,
            [Microsoft.Win32.RegistryValueKind]::DWord
        )
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

Export-ModuleMember -Function Get-TargetResource, Test-TargetResource, Set-TargetResource