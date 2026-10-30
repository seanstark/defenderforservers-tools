Configuration entraiddeviceidlinux {
    Import-DscResource -ModuleName EntraIdDeviceIdLinux -ModuleVersion '1.0.0'

    Node localhost {
        EntraIdDeviceIdLinux entraiddeviceidlinux {
            Name = 'wdavstate'
        }
    }
}
