Configuration entraiddeviceid {
    Import-DscResource -ModuleName EntraIdDeviceId -ModuleVersion '1.0.0'

    Node localhost {
        EntraIdDeviceId entraiddeviceid {
            Name = 'EnrollmentPayload'
        }
    }
}
