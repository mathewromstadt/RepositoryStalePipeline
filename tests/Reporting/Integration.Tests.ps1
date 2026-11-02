BeforeAll {
    $root = (Resolve-Path "$PSScriptRoot/../..").Path
}
Describe 'Audit-only orchestrator integration with synthetic discovery' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        Copy-Item "$root/Modules" $fixture -Recurse -Force
        Copy-Item "$root/schemas" $fixture -Recurse -Force
        Copy-Item "$root/Invoke-BranchLifecycle.ps1" $fixture -Force
        New-Item -ItemType Directory "$fixture/config" -Force | Out-Null
        Copy-Item "$root/config/reporting.json" "$fixture/config/reporting.json" -Force
        @{ organization = @{ name = 'Example'; url = 'https://example.org' }; branchPolicy = @{ protectedBranches = @('main'); warningGraceDays = 7; staleAfterDays = 30 }; exclusions = @{ projectIds = @(); repositoryIds = @() } } |
            ConvertTo-Json -Depth 10 | Set-Content "$fixture/config/organization.json"
        @'
function Get-OrganizationInventory {
    [CmdletBinding()]
    param($OrganizationUrl, $Config, $Token)
    return @{ ProjectCount = 1; Repositories = @(@{project='Example';repository='Service'},@{project='Example';repository='Empty'}); Failures = @(); Branches = @(
        @{ProjectId='p';RepoId='r';ProjectName='Example';RepoName='Service';Ref='refs/heads/main';DefaultBranch='refs/heads/main';ObjectId='abc';ActivePRs=@()}
    ) }
}
Export-ModuleMember -Function Get-OrganizationInventory
'@ | Set-Content "$fixture/Modules/BranchLifecycle/Discovery.psm1"
        $savedToken = $env:ADO_PAT
        $env:ADO_PAT = 'synthetic-test-token'
    }
    AfterEach { $env:ADO_PAT = $savedToken }
    It 'persists audit and reports and keeps deletion disabled' {
        $null = & "$fixture/Invoke-BranchLifecycle.ps1" -DryRun -StatePath "$fixture/state.json" -AuditPath "$fixture/audit.jsonl"
        (Get-Content "$fixture/audit.jsonl" -Raw | ConvertFrom-Json).decision | Should -Be 'Protected'
        $snapshot = Get-Content "$fixture/reports/snapshot.json" -Raw | ConvertFrom-Json
        $snapshot.results.summary.repositories | Should -Be 2
        $snapshot.evaluationStatus | Should -Be 'Succeeded'
        Test-Path "$fixture/reports/branch-lifecycle.html" | Should -BeTrue
        (Get-Content "$fixture/Invoke-BranchLifecycle.ps1" -Raw) | Should -Not -Match 'Remove-AdoBranchSafely\s+-'
    }
    It 'reports a discovery failure and fails closed' {
        @'
function Get-OrganizationInventory { [CmdletBinding()] param($OrganizationUrl,$Config,$Token) throw 'SECRET-TRANSPORT' }
Export-ModuleMember -Function Get-OrganizationInventory
'@ | Set-Content "$fixture/Modules/BranchLifecycle/Discovery.psm1"
        { & "$fixture/Invoke-BranchLifecycle.ps1" -DryRun -StatePath "$fixture/state.json" -AuditPath "$fixture/audit.jsonl" } | Should -Throw '*GovernanceExecutionFailure*'
        $json = Get-Content "$fixture/reports/snapshot.json" -Raw
        $json | Should -Not -Match 'SECRET'
        ($json | ConvertFrom-Json).results.summary.discoveryFailures | Should -Be 1
    }
    It 'distinguishes mandatory audit failure from reporting failure' {
        @'
function Write-LifecycleAudit { param($Path,$Record) throw 'SECRET-AUDIT' }
Export-ModuleMember -Function Write-LifecycleAudit
'@ | Set-Content "$fixture/Modules/BranchLifecycle/Auditing.psm1"
        { & "$fixture/Invoke-BranchLifecycle.ps1" -DryRun -StatePath "$fixture/state.json" -AuditPath "$fixture/audit.jsonl" } | Should -Throw '*AuditPersistenceFailure*'
        (Get-Content "$fixture/reports/execution-summary.json" -Raw | ConvertFrom-Json).failureCategory | Should -Be 'AuditPersistenceFailure'
    }
    It 'retains audit evidence when required adapter delivery fails' {
        $config = Get-Content "$fixture/config/reporting.json" -Raw | ConvertFrom-Json -AsHashtable
        $config.adapters[0].settings.outputPath = $fixture
        $config | ConvertTo-Json -Depth 10 | Set-Content "$fixture/config/reporting.json"
        { & "$fixture/Invoke-BranchLifecycle.ps1" -DryRun -StatePath "$fixture/state.json" -AuditPath "$fixture/audit.jsonl" } | Should -Throw '*Reporting failure policy*'
        (Get-Content "$fixture/audit.jsonl" -Raw | ConvertFrom-Json).action | Should -Be 'Skip'
        (Get-Content "$fixture/reports/snapshot.json" -Raw | ConvertFrom-Json).evaluationStatus | Should -Be 'Succeeded'
    }
    It 'distinguishes reporting artifact persistence failure' {
        'block the report directory' | Set-Content "$fixture/reports"
        { & "$fixture/Invoke-BranchLifecycle.ps1" -DryRun -StatePath "$fixture/state.json" -AuditPath "$fixture/audit.jsonl" } | Should -Throw '*ReportingPersistenceFailure*'
        Test-Path "$fixture/audit.jsonl" | Should -BeTrue
    }
    It 'preserves the original audit failure if reporting artifacts also fail' {
        'block the report directory' | Set-Content "$fixture/reports"
        @'
function Write-LifecycleAudit { param($Path,$Record) throw 'audit failed' }
Export-ModuleMember -Function Write-LifecycleAudit
'@ | Set-Content "$fixture/Modules/BranchLifecycle/Auditing.psm1"
        { & "$fixture/Invoke-BranchLifecycle.ps1" -DryRun -StatePath "$fixture/state.json" -AuditPath "$fixture/audit.jsonl" } | Should -Throw '*AuditPersistenceFailure*'
    }
    It 'suppresses notifications only for dry runs (DryRun=<DryRun>)' -TestCases @(
        @{ DryRun = $true; ExpectedDelivery = $false }
        @{ DryRun = $false; ExpectedDelivery = $true }
    ) {
        param($DryRun, $ExpectedDelivery)
        $discovery = Get-Content "$fixture/Modules/BranchLifecycle/Discovery.psm1" -Raw
        $discovery.Replace("Ref='refs/heads/main'", "Ref='refs/heads/feature/old'") |
            Set-Content "$fixture/Modules/BranchLifecycle/Discovery.psm1"
        @"
function Invoke-AdoApi {
    param(`$Uri, `$Token)
    return @{ Data = @{ committer = @{ date = '2000-01-01T00:00:00Z' } } }
}
Export-ModuleMember -Function Invoke-AdoApi
"@ | Set-Content "$fixture/Modules/BranchLifecycle/AzureDevOps.psm1"
        @"
function Send-LifecycleNotification {
    param(`$Config, `$Payload)
    Set-Content "`$PSScriptRoot/../../notification-called.txt" 'called'
    return `$true
}
Export-ModuleMember -Function Send-LifecycleNotification
"@ | Set-Content "$fixture/Modules/BranchLifecycle/Notifications.psm1"
        $null = & "$fixture/Invoke-BranchLifecycle.ps1" -DryRun:$DryRun -StatePath "$fixture/state.json" -AuditPath "$fixture/audit.jsonl"
        Test-Path "$fixture/notification-called.txt" | Should -Be $ExpectedDelivery
        (Get-Content "$fixture/audit.jsonl" -Raw | ConvertFrom-Json).decision | Should -Be 'Stale'
        Test-Path "$fixture/reports/branch-lifecycle.html" | Should -BeTrue
    }
}
