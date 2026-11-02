#Requires -Version 7.0
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/../Reporting/Contracts/Contracts.psm1"
# Compatibility entrypoint. New integrations use AdapterHost.psm1.
function New-BranchLifecycleReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$OrganizationName = 'Example Organization')
    $snapshot = New-BranchReportingSnapshot -Events $Events -Organization $OrganizationName
    $adapter = Import-Module "$PSScriptRoot/../Reporting/Adapters/Html/Html.psm1" -Force -PassThru
    $null = & $adapter { param($payload, $path) Publish-Snapshot -Payload $payload -Settings @{ outputPath = $path } } $snapshot $OutputPath
    return $OutputPath
}
Export-ModuleMember -Function New-BranchLifecycleReport
