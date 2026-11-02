
Set-StrictMode -Version Latest

#region Branch State Identification

function Get-StateKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Branch
    )

    # Create a unique state key for each branch.
    #
    # Format:
    # ProjectId/RepositoryId/BranchReference
    #
    # Example:
    # project-guid/repository-guid/refs/heads/feature/example

    $stateKey = (
        "$($Branch.ProjectId)/" +
        "$($Branch.RepoId)/" +
        "$($Branch.Ref)"
    )

    return $stateKey
}

#endregion

#region Branch Retention Lifecycle

function Update-BranchRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Branch,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Protected',
            'ActivePR',
            'UnknownCommitDate',
            'Active',
            'Stale'
        )]
        [string]$Decision,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [datetime]$Now,

        [Parameter(Mandatory)]
        [ValidateRange(1, 365)]
        [int]$GraceDays
    )

    #region Initialization

    $stateKey = Get-StateKey -Branch $Branch

    $utcNow = $Now.ToUniversalTime()

    #endregion

    #region Non-Stale Branches

    # Only stale branches participate in retention.
    #
    # If a previously stale branch is now active, protected,
    # or associated with an active PR, clear its warning state.

    if ($Decision -ne 'Stale') {

        if ($State.ContainsKey($stateKey)) {

            $State.Remove($stateKey)

            Write-Verbose (
                "Cleared retention state for '$($Branch.Ref)'. " +
                "Decision: $Decision"
            )
        }

        return 'Skip'
    }

    #endregion

    #region Initial Warning

    # A stale branch without existing retention state
    # must receive a warning before becoming eligible.

    if (-not $State.ContainsKey($stateKey)) {

        $State[$stateKey] = @{
            firstWarned  = $utcNow.ToString('o')
            objectId     = $Branch.ObjectId
            lastNotified = $null
        }

        Write-Verbose (
            "Created retention state for '$($Branch.Ref)'. " +
            "Initial warning required."
        )

        return 'Warn'
    }

    #endregion

    #region Branch Change Detection

    $retentionEntry = $State[$stateKey]

    # If the branch tip changed, restart the warning period.
    #
    # This prevents a branch from being deleted based on
    # an outdated warning.

    if ($retentionEntry.objectId -ne $Branch.ObjectId) {

        $State[$stateKey] = @{
            firstWarned  = $utcNow.ToString('o')
            objectId     = $Branch.ObjectId
            lastNotified = $null
        }

        Write-Verbose (
            "Branch '$($Branch.Ref)' changed since its warning. " +
            "Restarting retention grace period."
        )

        return 'Warn'
    }

    #endregion

    #region Grace Period Evaluation

    $firstWarnedUtc = [datetime]::Parse(
        [string]$retentionEntry.firstWarned
    ).ToUniversalTime()

    $elapsedDays = (
        $utcNow - $firstWarnedUtc
    ).TotalDays

    if ($elapsedDays -ge $GraceDays) {

        Write-Verbose (
            "Branch '$($Branch.Ref)' completed its " +
            "$GraceDays-day grace period."
        )

        return 'Eligible'
    }

    #endregion

    #region Pending Retention

    Write-Verbose (
        "Branch '$($Branch.Ref)' remains in its grace period. " +
        "Elapsed: $([math]::Round($elapsedDays, 2)) day(s)."
    )

    return 'Pending'

    #endregion
}

#endregion

Export-ModuleMember -Function @(
    'Get-StateKey'
    'Update-BranchRetention'
)
