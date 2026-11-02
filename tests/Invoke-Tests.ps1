#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.7.1
$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
# Tests use only filesystem fixtures; do not require registry writes on Windows.
$configuration.TestRegistry.Enabled = $false
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) { exit 1 }
