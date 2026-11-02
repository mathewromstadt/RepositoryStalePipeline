# Configuration reference

The entrypoint is [Invoke-BranchLifecycle.ps1](../../Invoke-BranchLifecycle.ps1). Create its ignored local organization config from [organization.example.json](../../config/organization.example.json).

## Organization and policy

| JSON field | Meaning |
| --- | --- |
| `organization.name` | Display name in reports and events |
| `organization.url` | Azure DevOps organization URL |
| `exclusions.projectIds` | Project IDs to exclude; empty includes all accessible projects |
| `exclusions.repositoryIds` | Repository IDs to exclude |
| `branchPolicy.staleAfterDays` | Positive inactivity threshold in days |
| `branchPolicy.warningGraceDays` | Days from first recorded warning state to eligibility; 1–365 |
| `branchPolicy.protectedBranches` | PowerShell wildcard branch-name patterns without `refs/heads/` |

Default branches are always protected. Branches participating as source or target in an active pull request are protected from stale evaluation. The example uses 30 inactivity days, 7 grace days, and common default/release patterns; customize these choices.

There is no supported deletion setting. `Eligible` is informational only.

## Command parameters

| Parameter | Default / behavior |
| --- | --- |
| `ConfigPath` | `config/organization.json` relative to the script |
| `DryRun` | Suppresses notification webhooks; still discovers, writes files, and reports |
| `StatePath` | `.state/state.json` |
| `AuditPath` | `.state/audit.jsonl`, append-only records |
| `ReportingConfigPath` | `config/reporting.json`, HTML only |

Use full paths for custom state/audit destinations. Do not share state files between concurrent runs.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `ADO_PAT` | Discovery credential consumed by the entrypoint |
| `ADO_AUTH_MODE` | `PAT` selects Basic authentication; otherwise bearer authentication |
| `BRANCH_LIFECYCLE_WEBHOOK` | Optional notification endpoint; absent or dry-run means no delivery |
| `METRICS_ENDPOINT`, `METRICS_TOKEN`, `METRICS_USERNAME` | Remote-write example inputs |
| `LOKI_ENDPOINT`, `LOKI_TOKEN`, `LOKI_USERNAME` | Loki example inputs |

For a pipeline job token, map it into `ADO_PAT` and use a non-PAT mode. The variable name does not select the authentication mode.

## Reporting

[config/reporting.json](../../config/reporting.json) enables HTML. The host validates [configuration.schema.json](../../schemas/reporting/configuration.schema.json). Registrations declare `id`, `enabled`, `module`, `failurePolicy`, and `settings`. The exact module path must appear in `trustedModules`.

`Continue` records optional publication failures without failing an otherwise successful audit. `FailPipeline` applies after all phases complete. Mandatory audit/report persistence failures are fatal.

~~~powershell
pwsh -NoProfile -File Invoke-BranchLifecycle.ps1 -DryRun -ReportingConfigPath examples/reporting/remote-write/reporting.json
~~~

Inject all six backend variables before using this example. It uses independent Basic authentication for metrics and logs. For bearer authentication, remove the username reference from a local copy. For one destination only, remove all settings for the other destination.

See [Grafana integration](configuring-grafana.md).
