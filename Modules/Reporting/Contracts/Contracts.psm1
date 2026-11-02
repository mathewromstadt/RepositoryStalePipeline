#Requires -Version 7.0
Set-StrictMode -Version Latest

function Assert-ReportingContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Payload,
        [ValidateSet('report', 'event', 'adapter', 'result', 'configuration')][string]$Kind = 'report')
    $schema = Join-Path $PSScriptRoot "../../../schemas/reporting/$Kind.schema.json"
    try {
        $valid = Test-Json -Json ($Payload | ConvertTo-Json -Depth 40 -Compress) -SchemaFile $schema -ErrorAction Stop
        if (-not $valid) { throw 'Invalid' }
    }
    catch { throw "Invalid reporting $Kind contract." }
}

function New-BranchReportingSnapshot {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Events = @(),
        [AllowEmptyCollection()][object[]]$Repositories = @(),
        [string]$Organization = 'Example Organization',
        [string]$RunId = ([guid]::NewGuid().ToString()),
        [string]$PolicyId = 'branch-lifecycle', [string]$PolicyVersion = '1.0.0',
        [ValidateSet('Succeeded', 'Failed', 'Incomplete')][string]$Status = 'Succeeded',
        [int]$DiscoveryFailures = 0, [int]$EvaluationFailures = 0,
        [int]$ProjectCount = -1, [double]$DurationSeconds = 0,
        [datetime]$Timestamp = [datetime]::UtcNow)
    # Select known fields only. Never copy transport objects, URLs, tokens or exceptions.
    $details = @($Events | ForEach-Object {
        @{ project = [string]$_.project; repository = [string]$_.repository
           ref = [string]$_.ref; decision = [string]$_.decision; action = [string]$_.action }
    })
    $inventory = @($Repositories | ForEach-Object {
        @{ project = [string]$_.project; repository = [string]$_.repository }
    }) + @($details | ForEach-Object { @{ project = $_.project; repository = $_.repository } })
    $seen = @{}
    $repos = @($inventory | ForEach-Object {
        $entry = $_
        $key = @($entry.project, $entry.repository) | ConvertTo-Json -Compress
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $branches = @($details | Where-Object { $_.project -ceq $entry.project -and $_.repository -ceq $entry.repository })
            $attention = @($branches | Where-Object { $_.decision -eq 'Stale' -or $_.action -in @('Warn', 'Pending', 'Eligible') }).Count
            @{ project = $entry.project; repository = $entry.repository
               status = $(if ($attention -gt 0) { 'Attention' } elseif ($Status -ne 'Succeeded') { 'Unknown' } else { 'Healthy' })
               branchCount = $branches.Count; attentionCount = $attention }
        }
    })
    if ($ProjectCount -lt 0) { $ProjectCount = @($repos | ForEach-Object { $_.project } | Select-Object -Unique).Count }
    $summary = @{
        projects = $ProjectCount; repositories = $repos.Count; branches = $details.Count
        healthyRepositories = @($repos | Where-Object status -eq 'Healthy').Count
        attentionRepositories = @($repos | Where-Object status -eq 'Attention').Count
        protected = @($details | Where-Object decision -eq 'Protected').Count
        active = @($details | Where-Object { $_.decision -in @('Active', 'ActivePR') }).Count
        stale = @($details | Where-Object decision -eq 'Stale').Count
        warnings = @($details | Where-Object action -eq 'Warn').Count
        pending = @($details | Where-Object action -eq 'Pending').Count
        eligible = @($details | Where-Object action -eq 'Eligible').Count
        discoveryFailures = $DiscoveryFailures; evaluationFailures = $EvaluationFailures
        durationSeconds = $DurationSeconds
    }
    $report = @{
        schemaVersion = '1.0'; id = "$RunId/snapshot"; runId = $RunId
        timestamp = $Timestamp.ToUniversalTime().ToString('o'); domain = 'branch-lifecycle'
        sourceProvider = 'azure-devops'; evaluationStatus = $Status
        policy = @{ id = $PolicyId; version = $PolicyVersion }
        results = @{ organization = $Organization; summary = $summary; repositories = $repos; branches = $details }
    }
    Assert-ReportingContract $report
    return $report
}

function ConvertTo-ReportingEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [object[]]$AdapterResults = @())
    $items = @(@{ type = 'EvaluationOutcome'; data = $Snapshot.results })
    $branches = @()
    if ($Snapshot.domain -eq 'branch-lifecycle') {
        $items[0].data = @{ summary = $Snapshot.results.summary }
        $branches = $Snapshot.results.branches
    }
    foreach ($branch in $branches) {
        $items += @{ type = 'BranchDecision'; data = $branch }
        if ($branch.action -eq 'Warn') { $items += @{ type = 'WarningAction'; data = $branch } }
        if ($branch.action -in @('Warn', 'Pending', 'Eligible')) {
            $items += @{ type = 'RetentionState'; data = $branch }
        }
    }
    foreach ($result in $AdapterResults) {
        if ($result.status -eq 'Failed') {
            $items += @{ type = 'ReportingFailure'; data = @{ adapterId = $result.adapterId; code = $result.code } }
        }
    }
    if ($Snapshot.domain -eq 'branch-lifecycle') {
        foreach ($repository in $Snapshot.results.repositories) {
            # Reuse the same normalized status/counts as HTML, including empty repositories.
            $items += @{ type = 'RepositoryStatus'; data = @{
                organization = $Snapshot.results.organization
                project = $repository.project; repository = $repository.repository
                status = $repository.status; branchCount = $repository.branchCount
                attentionCount = $repository.attentionCount
                evaluatedAt = $Snapshot.timestamp; runId = $Snapshot.runId
            } }
        }
    }
    $index = 0
    foreach ($item in $items) {
        $record = @{}
        foreach ($key in @('schemaVersion', 'runId', 'timestamp', 'domain', 'sourceProvider', 'evaluationStatus', 'policy')) {
            $record[$key] = $Snapshot[$key]
        }
        $record.id = "$($Snapshot.runId)/event/$index"
        $record.type = $item.type; $record.results = $item.data
        Assert-ReportingContract $record -Kind event
        $record
        $index++
    }
}

Export-ModuleMember -Function Assert-ReportingContract, New-BranchReportingSnapshot, ConvertTo-ReportingEvents
