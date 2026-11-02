
Set-StrictMode -Version Latest

function Get-OrganizationInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$Token
    )

    $ErrorActionPreference = 'Stop'

    #region Initialization

    $baseUrl = $OrganizationUrl.TrimEnd('/')

    $inventory = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()

    $repositoryInventory = [System.Collections.Generic.List[object]]::new()

    $projectCount = 0
    $repositoryCount = 0
    $branchCount = 0

    # Exclusions are opt-out. Everything is included by default.

    $excludedProjectIds = @(
        $Config.exclusions.projectIds |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $excludedRepositoryIds = @(
        $Config.exclusions.repositoryIds |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    #endregion

    #region Organization Project Discovery

    Write-Verbose "Discovering projects in organization: $baseUrl"

    $projectsUrl = (
        "$baseUrl/_apis/projects" +
        "?`$top=100&api-version=7.1"
    )

    try {
        # Get-AdoPaged must handle continuation tokens and return
        # the combined collection of all result pages.

        $projects = @(
            Get-AdoPaged `
                -Uri $projectsUrl `
                -Token $Token
        )
    }
    catch {
        throw "Unable to discover organization projects: $($_.Exception.Message)"
    }

    Write-Verbose "Discovered $($projects.Count) organization project(s)."

    #endregion

    #region Project Processing

    foreach ($project in $projects) {

        # Skip explicitly excluded projects.

        if ([string]$project.id -in $excludedProjectIds) {

            Write-Verbose "Excluded project: $($project.name)"
            continue
        }

        $projectCount++

        Write-Verbose "Processing project: $($project.name)"

        #region Repository Discovery

        $repositoriesUrl = (
            "$baseUrl/$($project.id)/" +
            "_apis/git/repositories" +
            "?api-version=7.1"
        )

        try {
            $repositories = @(
                Get-AdoPaged `
                    -Uri $repositoriesUrl `
                    -Token $Token
            )
        }
        catch {
            $failures.Add(
                "Repository discovery failed for project " +
                "'$($project.name)': $($_.Exception.Message)"
            )
            continue
        }

        Write-Verbose (
            "Project '$($project.name)' contains " +
            "$($repositories.Count) repository/repositories."
        )

        #endregion

        #region Repository Processing

        foreach ($repository in $repositories) {

            # Skip explicitly excluded repositories.

            if ([string]$repository.id -in $excludedRepositoryIds) {

                Write-Verbose (
                    "Excluded repository: " +
                    "$($project.name)/$($repository.name)"
                )

                continue
            }

            $repositoryCount++
            $repositoryInventory.Add(@{ project = [string]$project.name; repository = [string]$repository.name })

            Write-Verbose (
                "Processing repository: " +
                "$($project.name)/$($repository.name)"
            )

            #region Branch and Pull Request Discovery

            $branchesUrl = (
                "$baseUrl/$($project.id)/" +
                "_apis/git/repositories/$($repository.id)/refs" +
                "?filter=heads/&api-version=7.1"
            )

            $pullRequestsUrl = (
                "$baseUrl/$($project.id)/" +
                "_apis/git/repositories/$($repository.id)/pullrequests" +
                "?searchCriteria.status=active" +
                "&`$top=100&api-version=7.1"
            )

            try {
                $branches = @(
                    Get-AdoPaged `
                        -Uri $branchesUrl `
                        -Token $Token
                )

                $activePullRequests = @(
                    Get-AdoPaged `
                        -Uri $pullRequestsUrl `
                        -Token $Token
                )
            }
            catch {
                $failures.Add(
                    "Branch/PR discovery failed for " +
                    "'$($project.name)/$($repository.name)': " +
                    "$($_.Exception.Message)"
                )

                continue
            }

            Write-Verbose (
                "Repository '$($repository.name)': " +
                "$($branches.Count) branch(es), " +
                "$($activePullRequests.Count) active PR(s)."
            )

            #endregion

            #region Inventory Construction

            foreach ($branch in $branches) {

                $inventory.Add(
                    [pscustomobject]@{
                        ProjectId     = [string]$project.id
                        ProjectName   = [string]$project.name
                        RepoId        = [string]$repository.id
                        RepoName      = [string]$repository.name
                        DefaultBranch = [string]$repository.defaultBranch
                        Ref           = [string]$branch.name
                        ObjectId      = [string]$branch.objectId
                        ActivePRs     = @($activePullRequests)
                    }
                )

                $branchCount++
            }

            #endregion
        }

        #endregion
    }

    #endregion

    #region Results

    Write-Verbose "Organization inventory completed."
    Write-Verbose "Projects evaluated: $projectCount"
    Write-Verbose "Repositories evaluated: $repositoryCount"
    Write-Verbose "Branches discovered: $branchCount"
    Write-Verbose "Discovery failures: $($failures.Count)"

    return [pscustomobject]@{
        OrganizationUrl = $baseUrl
        ProjectCount    = $projectCount
        RepositoryCount = $repositoryCount
        BranchCount     = $branchCount
        Branches        = $inventory.ToArray()
        Repositories    = $repositoryInventory.ToArray()
        Failures        = $failures.ToArray()
    }

    #endregion
}

Export-ModuleMember -Function Get-OrganizationInventory
