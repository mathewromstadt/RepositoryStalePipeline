# Running and troubleshooting

## Azure Pipelines

Use [examples/azure-pipelines/audit.yml](../../examples/azure-pipelines/audit.yml) as a manual pipeline template. Define `organizationName`, `organizationUrl`, and secret `ADO_PAT` in the pipeline UI. The template creates local configuration, audits, and publishes reports/audit artifacts even after failure.

The template uses PAT authentication and HTML only. For remote reporting, select `examples/reporting/remote-write/reporting.json` and explicitly map all six backend variables from [Configuration](../guides/configuration.md). Secret variables require environment mappings.

Add a schedule only after validating scope and artifact access. Do not expose live inventory artifacts from public CI. The GitHub workflow runs synthetic checks only.

## State and notifications

The hosted-agent template does not restore retention state; a new agent can generate fresh Warn states. Design durable storage, access controls, serialized execution, backup, and recovery before relying on cross-run timing.

Without `-DryRun`, Warn and Eligible events can generate a JSON POST to `BRANCH_LIFECYCLE_WEBHOOK`. Missing webhooks produce warnings. Recipient routing and human delivery confirmation are not implemented. Pending branches do not generate a new notification in that run.

## Failure triage

| Symptom | Check |
| --- | --- |
| Missing config/token | Create local config and inject `ADO_PAT` |
| `GovernanceExecutionFailure` | Permissions, API, commit lookup, state persistence, notifications |
| `AuditPersistenceFailure` | Audit directory access and disk |
| `ReportingPersistenceFailure` | Report directory access, collisions, disk |
| Reporting failure policy error | Required adapter in `reports/adapter-results.json` |
| Metrics present but table empty | Events delivery, Loki datasource/time range |
| Missing repositories | Visibility, exclusions, partial discovery, query limits |

`reports/execution-summary.json` records evaluation status and adapter failure count when reporting persistence succeeds. Adapter results include sanitized transport diagnostics. Preserve local evidence; do not upload real artifacts to public issues.

## Data handling

Reports, state, and events contain organization/project/repository/branch information. Configure retention and access for files, artifacts, and backends. Git ignore rules do not protect externally stored data.
