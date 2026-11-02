
Set-StrictMode -Version Latest

#region Protected Branch Evaluation

function Test-ProtectedBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Ref,

        [Parameter(Mandatory)]
        [string[]]$Patterns,

        [string]$DefaultBranch
    )

    # Always protect the repository's default branch,
    # regardless of whether it matches a configured pattern.

    if ($Ref -eq $DefaultBranch) {
        return $true
    }

    # Convert the full Git reference into a branch name.
    #
    # Example:
    # refs/heads/feature/new-dashboard
    # becomes:
    # feature/new-dashboard

    $branchName = $Ref -replace '^refs/heads/', ''

    foreach ($pattern in $Patterns) {

        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }

        if ($branchName -like $pattern) {
            return $true
        }
    }

    return $false
}

#endregion

#region Active Pull Request Evaluation

function Test-ActivePullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Branch
    )

    # A branch is protected from cleanup when it participates
    # in an active pull request as either the source or target.

    foreach ($pullRequest in @($Branch.ActivePRs)) {

        if (
            $pullRequest.sourceRefName -eq $Branch.Ref -or
            $pullRequest.targetRefName -eq $Branch.Ref
        ) {
            return $true
        }
    }

    return $false
}

#endregion

#region Branch Activity Evaluation

function Get-BranchDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Branch,

        [Parameter(Mandatory)]
        [datetime]$CommitDate,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Config,

        [datetime]$Now = [datetime]::UtcNow
    )

    #region Protected Branch Check

    $isProtected = Test-ProtectedBranch `
        -Ref $Branch.Ref `
        -Patterns @($Config.branchPolicy.protectedBranches) `
        -DefaultBranch $Branch.DefaultBranch

    if ($isProtected) {
        return 'Protected'
    }

    #endregion

    #region Active Pull Request Check

    if (Test-ActivePullRequest -Branch $Branch) {
        return 'ActivePR'
    }

    #endregion

    #region Commit Date Validation

    # Unknown commit dates must never be treated as stale.

    if ($CommitDate -eq [datetime]::MinValue) {
        return 'UnknownCommitDate'
    }

    $utcNow = $Now.ToUniversalTime()
    $utcCommitDate = $CommitDate.ToUniversalTime()

    # Future-dated commits may indicate clock skew or invalid data.
    # Treat them as unknown rather than eligible for cleanup.

    if ($utcCommitDate -gt $utcNow) {
        return 'UnknownCommitDate'
    }

    #endregion

    #region Inactivity Evaluation

    $staleThresholdDays = [int]$Config.branchPolicy.staleAfterDays

    if ($staleThresholdDays -le 0) {
        throw 'branchPolicy.staleAfterDays must be greater than zero.'
    }

    $inactiveDays = ($utcNow - $utcCommitDate).TotalDays

    if ($inactiveDays -ge $staleThresholdDays) {
        return 'Stale'
    }

    return 'Active'

    #endregion
}

#endregion

Export-ModuleMember -Function @(
    'Test-ProtectedBranch'
    'Test-ActivePullRequest'
    'Get-BranchDecision'
)
