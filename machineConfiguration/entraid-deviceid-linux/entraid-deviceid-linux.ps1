Configuration entraiddeviceidlinux_1.0.2 {
    Import-DscResource -ModuleName EntraIdDeviceIdLinux -ModuleVersion '1.0.2'

    Node localhost {
        EntraIdDeviceIdLinux entraiddeviceidlinux_1.0.2 {
            Name = 'wdavstate'
        }
    }
}
