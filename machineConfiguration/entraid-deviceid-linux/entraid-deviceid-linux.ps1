Configuration entraiddeviceidlinux {
    Import-DscResource -ModuleName EntraIdDeviceIdLinux -ModuleVersion '1.0.1'

    Node localhost {
        EntraIdDeviceIdLinux entraiddeviceidlinux {
            Name = 'wdavstate'
        }
    }
}
