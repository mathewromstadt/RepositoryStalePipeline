#Requires -Version 7.0
Set-StrictMode -Version Latest

function Test-AdapterConfiguration {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Settings)
    return ($Settings.Count -eq 0)
}

function Publish-Snapshot {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Payload, [System.Collections.IDictionary]$Settings)
    # Replace this no-op with destination-specific delivery. Use Payload.id as the
    # idempotency key. Never access governance state or mandatory audit files.
    return @{ success = ($Payload.schemaVersion -eq '1.0' -and $Settings.Count -eq 0) }
}

Export-ModuleMember -Function Test-AdapterConfiguration, Publish-Snapshot
