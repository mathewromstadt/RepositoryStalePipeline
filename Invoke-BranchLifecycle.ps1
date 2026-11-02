
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot/config/organization.json",

    [switch]$DryRun,

    [string]$StatePath = "$PSScriptRoot/.state/state.json",

    [string]$AuditPath = "$PSScriptRoot/.state/audit.jsonl",

    [string]$ReportingConfigPath = "$PSScriptRoot/config/reporting.json"
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Module Imports

$modulePath = Join-Path $PSScriptRoot 'Modules/BranchLifecycle'

$modules = @(
    'AzureDevOps'
    'Discovery'
    'Evaluation'
    'Retention'
    'Notifications'
    'Auditing'
)

foreach ($module in $modules) {

    $moduleFile = Join-Path $modulePath "$module.psm1"

    if (-not (Test-Path -LiteralPath $moduleFile)) {
        throw "Required module not found: $moduleFile"
    }

    Import-Module -Name $moduleFile -Force -ErrorAction Stop
}

#endregion

#region Configuration

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json

$token = $env:ADO_PAT

if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'ADO_PAT is required.'
}

$now = [datetime]::UtcNow

Write-Verbose "Organization: $($config.organization.name)"
Write-Verbose "Execution time: $($now.ToString('o'))"
Write-Verbose "Dry run: $DryRun"

#endregion

#region State Initialization

$state = @{}

# Local state is intended for development only.
# Production requires durable storage with concurrency protection.

if (Test-Path -LiteralPath $StatePath) {

    Write-Verbose "Loading retention state: $StatePath"

    $savedState = Get-Content -LiteralPath $StatePath -Raw |
        ConvertFrom-Json -AsHashtable

    if ($null -ne $savedState) {
        foreach ($key in $savedState.Keys) {
            $state[$key] = $savedState[$key]
        }
    }
}

#endregion

# Reporting initialization precedes governance execution. Configuration is trusted code deployment input.
Import-Module "$PSScriptRoot/Modules/Reporting/Contracts/Contracts.psm1" -Force
Import-Module "$PSScriptRoot/Modules/Reporting/AdapterHost.psm1" -Force
try { $reportingConfig = Get-Content -LiteralPath $ReportingConfigPath -Raw | ConvertFrom-Json -AsHashtable }
catch { throw 'Reporting configuration could not be loaded.' }
$reportingHost = Initialize-ReportingHost -Configuration $reportingConfig -Root $PSScriptRoot
$runId = [guid]::NewGuid().ToString()
$policyBytes = [Text.Encoding]::UTF8.GetBytes(($config.branchPolicy | ConvertTo-Json -Depth 20 -Compress))
$policyHasher = [Security.Cryptography.SHA256]::Create()
try { $policyVersion = [BitConverter]::ToString($policyHasher.ComputeHash($policyBytes)).Replace('-', '').ToLowerInvariant() }
finally { $policyHasher.Dispose() }
$timer = [Diagnostics.Stopwatch]::StartNew()
$events = [System.Collections.Generic.List[object]]::new()
$inventory = $null
$executionFailure = $null
$reportingFailure = $false
$delivery = $null
$failureCategory = 'GovernanceExecutionFailure'
$stage = 'Discovery'
$deletionCandidates = [System.Collections.Generic.List[object]]::new()
try {
#region Organization Discovery

Write-Verbose 'Discovering Azure DevOps projects and repositories.'

$inventory = Get-OrganizationInventory `
    -OrganizationUrl $config.organization.url `
    -Config $config `
    -Token $token `
    -Verbose:$true

# Fail closed when inventory is incomplete.

if (@($inventory.Failures).Count -gt 0) {

    $failureDetails = $inventory.Failures -join '; '

    throw "Inventory incomplete; no deletion permitted: $failureDetails"
}

Write-Verbose "Discovered branches: $(@($inventory.Branches).Count)"

#endregion

#region Branch Evaluation

$stage = 'Evaluation'

foreach ($branch in $inventory.Branches) {

    Write-Verbose "Evaluating $($branch.RepoName)/$($branch.Ref)"

    $decision = 'UnknownCommitDate'

    # Check protected branches first.

    $isProtected = Test-ProtectedBranch `
        -Ref $branch.Ref `
        -Patterns @($config.branchPolicy.protectedBranches) `
        -DefaultBranch $branch.DefaultBranch

    if ($isProtected) {

        $decision = 'Protected'
    }
    elseif (Test-ActivePullRequest -Branch $branch) {

        $decision = 'ActivePR'
    }
    else {

        # Retrieve the latest commit for inactivity evaluation.

        try {

            $organizationUrl = $config.organization.url.TrimEnd('/')

            $commitUrl = (
                "$organizationUrl/" +
                "$($branch.ProjectId)/" +
                "_apis/git/repositories/" +
                "$($branch.RepoId)/" +
                "commits/$($branch.ObjectId)" +
                "?api-version=7.1"
            )

            $commitResponse = Invoke-AdoApi `
                -Uri $commitUrl `
                -Token $token

            $commit = $commitResponse.Data

            $commitDate = [datetime]::Parse(
                [string]$commit.committer.date,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )

            $decision = Get-BranchDecision `
                -Branch $branch `
                -CommitDate $commitDate `
                -Config $config `
                -Now $now
        }
        catch {

            throw (
                "Commit lookup failed for " +
                "$($branch.RepoName)/$($branch.Ref): " +
                "$($_.Exception.Message)"
            )
        }
    }

    # Update the retention lifecycle state.

    $action = Update-BranchRetention `
        -Branch $branch `
        -Decision $decision `
        -State $state `
        -Now $now `
        -GraceDays ([int]$config.branchPolicy.warningGraceDays)

    # Build the audit record.

    $record = [pscustomobject]@{
        timestamp  = $now.ToString('o')
        project    = $branch.ProjectName
        repository = $branch.RepoName
        ref        = $branch.Ref
        objectId   = $branch.ObjectId
        decision   = $decision
        action     = $action
    }

    $events.Add($record)

    try {
        Write-LifecycleAudit -Path $AuditPath -Record $record
    }
    catch {
        $failureCategory = 'AuditPersistenceFailure'
        throw 'Required audit persistence failed.'
    }

    if ($action -eq 'Eligible') {
        $deletionCandidates.Add($branch)
    }
}

#endregion

$stage = 'StatePersistence'
#region State Persistence

# Persist state before attempting notifications.
#
# Production implementation must use durable storage
# with lease or ETag-based concurrency protection.

$stateDirectory = Split-Path -Parent $StatePath

if (-not (Test-Path -LiteralPath $stateDirectory)) {

    New-Item `
        -ItemType Directory `
        -Path $stateDirectory `
        -Force | Out-Null
}

$state |
    ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath $StatePath -Encoding utf8

Write-Verbose "Retention state saved: $StatePath"

#endregion

$stage = 'Notifications'
#region Notifications

$notificationEvents = @(
    $events | Where-Object {
        $_.action -in @('Warn', 'Eligible')
    }
)

if ($notificationEvents.Count -gt 0 -and -not $DryRun) {

    $notificationPayload = @{
        organization = $config.organization.name
        generatedAt  = $now.ToString('o')
        events       = $notificationEvents
    }

    try {

        $delivered = Send-LifecycleNotification `
            -Config $config `
            -Payload $notificationPayload
    }
    catch {

        throw "Notification failed; deletion blocked: $($_.Exception.Message)"
    }

    if (-not $delivered) {

        Write-Warning (
            'Notifications are not configured. ' +
            'Automatic deletion remains blocked.'
        )
    }
}

#endregion
# Reporting runs after required branch audit writes, independently of notification success.
}
catch {
    # Do not export raw transport exception text to reports or pipeline error output.
    $executionFailure = $failureCategory
}
finally {
    try {
        $timer.Stop()
        $reportDirectory = Join-Path $PSScriptRoot 'reports'
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
        $status = if ($executionFailure) { 'Failed' } else { 'Succeeded' }
        $discoveryFailures = if ($executionFailure -and $stage -eq 'Discovery') { 1 } else { 0 }
        if ($null -ne $inventory -and @($inventory.Failures).Count -gt 0) { $discoveryFailures = @($inventory.Failures).Count }
        $evaluationFailures = if ($executionFailure -and $stage -eq 'Evaluation' -and $failureCategory -ne 'AuditPersistenceFailure') { 1 } else { 0 }
        $repositories = @(if ($null -ne $inventory) { $inventory.Repositories })
        $projects = if ($null -ne $inventory) { $inventory.ProjectCount } else { 0 }
        $snapshot = New-BranchReportingSnapshot -Events $events.ToArray() -Repositories $repositories `
            -Organization $config.organization.name -RunId $runId -Status $status -PolicyVersion $policyVersion `
            -DiscoveryFailures $discoveryFailures -EvaluationFailures $evaluationFailures `
            -ProjectCount $projects -DurationSeconds $timer.Elapsed.TotalSeconds
        $snapshot | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $reportDirectory 'snapshot.json') -Encoding utf8
        $delivery = Invoke-ReportingAdapters -HostContext $reportingHost -Snapshot $snapshot -ResultsPath (Join-Path $reportDirectory 'adapter-results.json')
        @{ runId = $runId; evaluationStatus = $status; failureCategory = $executionFailure; adapterFailures = @($delivery.results | Where-Object status -eq 'Failed').Count } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reportDirectory 'execution-summary.json') -Encoding utf8
    }
    catch { $reportingFailure = $true }
}
if ($executionFailure) { throw "Governance stopped: $executionFailure. See persisted audit evidence." }
if ($reportingFailure) { throw 'ReportingPersistenceFailure: reporting artifacts could not be completed.' }
if ($delivery.failPipeline) { throw 'Reporting failure policy failed the pipeline. See adapter-results.json.' }

#region Deletion Safety Gate

# Automatic deletion is intentionally disabled.
#
# Before enabling production deletion, implement:
#
# 1. Durable retention state
# 2. Confirmed warning delivery
# 3. Complete pull-request checks
# 4. Just-in-time branch revalidation
# 5. Atomic Git ref deletion using the expected object ID
# 6. Concurrency protection and audit persistence

if ($deletionCandidates.Count -gt 0) {

    Write-Warning (
        "$($deletionCandidates.Count) branch(es) eligible for deletion. " +
        'Automatic deletion is intentionally disabled.'
    )
}

#endregion

#region Results

Write-Verbose "Branch evaluation completed. Events: $($events.Count)"

# Return structured results for Azure Pipelines and local execution.

$events |
    ConvertTo-Json -Depth 12 |
    Write-Output

#endregion
