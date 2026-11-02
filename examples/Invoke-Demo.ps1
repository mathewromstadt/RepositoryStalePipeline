#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/Reporting/Contracts/Contracts.psm1" -Force
Import-Module "$root/Modules/Reporting/AdapterHost.psm1" -Force

# Synthetic inventory demonstrates healthy, attention, and empty repositories.
$repositories = @(
    @{ project = 'Example'; repository = 'Website' }
    @{ project = 'Example'; repository = 'Library' }
    @{ project = 'Example'; repository = 'Empty' }
)
$events = @(
    @{ project = 'Example'; repository = 'Website'; ref = 'refs/heads/main'; decision = 'Protected'; action = 'Skip' }
    @{ project = 'Example'; repository = 'Library'; ref = 'refs/heads/feature/old'; decision = 'Stale'; action = 'Warn' }
)
$snapshot = New-BranchReportingSnapshot -Organization 'Example Organization' -Repositories $repositories -Events $events
$configuration = Get-Content "$root/config/reporting.json" -Raw | ConvertFrom-Json -AsHashtable
$hostContext = Initialize-ReportingHost -Configuration $configuration -Root $root
$reportDirectory = Join-Path $root 'reports'
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
$snapshot | ConvertTo-Json -Depth 40 | Set-Content "$reportDirectory/snapshot.json" -Encoding utf8
$delivery = Invoke-ReportingAdapters -HostContext $hostContext -Snapshot $snapshot -ResultsPath "$reportDirectory/adapter-results.json"
if ($delivery.failPipeline) { throw 'Demo reporting failed. See reports/adapter-results.json.' }
Write-Output "Open $reportDirectory/branch-lifecycle.html"
