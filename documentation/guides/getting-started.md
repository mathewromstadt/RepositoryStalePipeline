# Getting started

## Requirements

Use PowerShell 7 on Windows or Linux. Run commands from the repository root. Runtime modules are included. Pester and PSScriptAnalyzer are needed only for development checks.

## Offline demonstration

~~~powershell
pwsh -NoProfile -File examples/Invoke-Demo.ps1
~~~

Open `reports/branch-lifecycle.html`. The synthetic inventory includes healthy, attention, and empty repositories. Inspect `reports/snapshot.json` and `reports/adapter-results.json` for payloads and delivery outcomes. The demo overwrites these reporting files; use a separate checkout if preserving an operational run.

## First Azure DevOps audit

1. Copy `config/organization.example.json` to `config/organization.json`.
2. Set the organization name and `https://dev.azure.com/<organization>` URL. Review protected patterns and excluded project/repository IDs.
3. Inject a PAT into the process environment as `ADO_PAT`. Set `ADO_AUTH_MODE` to `PAT`. The identity must be able to enumerate intended projects and read repositories, branches, commits, and pull requests.
4. Run the command below. Default reporting writes only local HTML.

~~~powershell
$env:ADO_AUTH_MODE = 'PAT'
pwsh -NoProfile -File Invoke-BranchLifecycle.ps1 -DryRun
~~~

Do not paste a PAT into a checked-in script. Missing credentials stop execution. Verify inventory coverage: inaccessible projects may not be visible at all.

## Review the result

Healthy means no evaluated branch currently needs attention. Attention means a stale branch or warning state was observed. Unknown identifies repositories affected by an unsuccessful evaluation unless attention is already known.

Review `reports/execution-summary.json`, `reports/adapter-results.json`, and `.state/audit.jsonl` when a run fails. A report can exist for an unsuccessful run; its presence alone does not prove success.

See [Configuration](configuration.md) and [Grafana integration](configuring-grafana.md).
