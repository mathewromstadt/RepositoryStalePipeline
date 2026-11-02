
Set-StrictMode -Version Latest

function Test-AdapterConfiguration {
    param([System.Collections.IDictionary]$Settings)
    return ($Settings.Contains('outputPath') -and -not [string]::IsNullOrWhiteSpace($Settings.outputPath))
}

function Publish-Snapshot {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Payload, [System.Collections.IDictionary]$Settings)
    $OutputPath = $Settings.outputPath
    $ErrorActionPreference = 'Stop'

    $reportDirectory = Split-Path -Path $OutputPath -Parent

    if ($reportDirectory) {
        New-Item -ItemType Directory `
            -Path $reportDirectory `
            -Force | Out-Null
    }

    # HTML-encode all values originating from Azure DevOps.

    function ConvertTo-HtmlText {
        param([object]$Value)

        return [System.Net.WebUtility]::HtmlEncode(
            [string]$Value
        )
    }

    $repositories = @($Payload.results.repositories | Sort-Object project, repository)
    $rows = [System.Collections.Generic.List[string]]::new()

    $healthyCount = 0
    $attentionCount = 0

    foreach ($repository in $repositories) {
        $branches = @($Payload.results.branches | Where-Object { $_.project -ceq $repository.project -and $_.repository -ceq $repository.repository })
        $hasAttention = $repository.status -eq 'Attention'
        if ($hasAttention) {
            $attentionCount++
            $status = '<span class="status red">Attention</span>'
        } elseif ($repository.status -eq 'Healthy') {
            $healthyCount++
            $status = '<span class="status green">Healthy</span>'
        } else {
            $status = '<span class="status">Unknown</span>'
        }
        $projectName = ConvertTo-HtmlText $repository.project
        $repositoryName = ConvertTo-HtmlText $repository.repository
        $branchDetails = [System.Collections.Generic.List[string]]::new()

        foreach ($branch in ($branches | Sort-Object ref)) {

            $branchName = ConvertTo-HtmlText (
                [string]$branch.ref -replace '^refs/heads/', ''
            )

            $decision = ConvertTo-HtmlText $branch.decision
            $action = ConvertTo-HtmlText $branch.action

            $branchDetails.Add(
                "<li><code>$branchName</code> &mdash; $decision ($action)</li>"
            )
        }

        $detailsHtml = $branchDetails -join "`n"

        $rows.Add(@"
<tr>
    <td>$projectName</td>
    <td>$repositoryName</td>
    <td>$status</td>
    <td>$($branches.Count)</td>
    <td>$($repository.attentionCount)</td>
    <td>
        <details>
            <summary>View branches</summary>
            <ul>$detailsHtml</ul>
        </details>
    </td>
</tr>
"@)
    }

    $generatedAt = ([datetime]$Payload.timestamp).ToUniversalTime().ToString(
        'yyyy-MM-dd HH:mm:ss'
    )

    $safeOrganizationName = ConvertTo-HtmlText $Payload.results.organization
    $tableRows = $rows -join "`n"

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Branch Lifecycle Report</title>

    <style>
        body {
            font-family: Arial, sans-serif;
            background: #f5f6f8;
            color: #222;
            margin: 0;
            padding: 32px;
        }

        main {
            max-width: 1200px;
            margin: auto;
        }

        h1 {
            margin-bottom: 6px;
        }

        .subtitle {
            color: #666;
            margin-bottom: 24px;
        }

        .summary {
            display: flex;
            gap: 16px;
            margin-bottom: 24px;
            flex-wrap: wrap;
        }

        .summary-card {
            background: white;
            padding: 18px 24px;
            border-radius: 8px;
            min-width: 150px;
            border: 1px solid #ddd;
        }

        .summary-card strong {
            display: block;
            font-size: 28px;
            margin-top: 8px;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            background: white;
        }

        th, td {
            padding: 14px;
            border-bottom: 1px solid #e5e5e5;
            text-align: left;
            vertical-align: top;
        }

        th {
            background: #e9edf2;
        }

        .status {
            display: inline-block;
            padding: 6px 12px;
            border-radius: 20px;
            font-weight: bold;
            font-size: 12px;
        }

        .green {
            background: #d9f5e3;
            color: #176b38;
        }

        .red {
            background: #fde0e0;
            color: #a61b1b;
        }

        details {
            cursor: pointer;
        }

        ul {
            padding-left: 20px;
            line-height: 1.8;
        }

        code {
            overflow-wrap: anywhere;
        }
    </style>
</head>

<body>
<main>
    <h1>$safeOrganizationName Branch Lifecycle</h1>
    <p class="subtitle">Generated $generatedAt UTC</p>
    <p>Evaluation: $(ConvertTo-HtmlText $Payload.evaluationStatus)</p>

    <div class="summary">
        <div class="summary-card">
            Repositories
            <strong>$($repositories.Count)</strong>
        </div>

        <div class="summary-card">
            Healthy
            <strong>$healthyCount</strong>
        </div>

        <div class="summary-card">
            Attention
            <strong>$attentionCount</strong>
        </div>
    </div>

    <table>
        <thead>
            <tr>
                <th>Project</th>
                <th>Repository</th>
                <th>Status</th>
                <th>Branches</th>
                <th>Stale</th>
                <th>Details</th>
            </tr>
        </thead>

        <tbody>
            $tableRows
        </tbody>
    </table>
</main>
</body>
</html>
"@

    Set-Content `
        -LiteralPath $OutputPath `
        -Value $html `
        -Encoding utf8

    Write-Verbose "HTML report generated: $OutputPath"

    return @{ success = $true }
}

Export-ModuleMember -Function Test-AdapterConfiguration, Publish-Snapshot
