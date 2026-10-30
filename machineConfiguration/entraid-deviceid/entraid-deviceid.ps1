Configuration entraiddeviceid {
    Import-DscResource -ModuleName EntraIdDeviceId -ModuleVersion '1.0.1'

    Node localhost {
        EntraIdDeviceId entraiddeviceid {
            Name = 'EnrollmentPayload'
        }
    }
}
