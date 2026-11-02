# Architecture

## Execution flow

[Invoke-BranchLifecycle.ps1](../../Invoke-BranchLifecycle.ps1) loads configuration and reporting registrations before discovery. [AzureDevOps.psm1](../../Modules/BranchLifecycle/AzureDevOps.psm1) handles authentication, continuation headers, and bounded retries. [Discovery.psm1](../../Modules/BranchLifecycle/Discovery.psm1) inventories accessible repositories and branches, including empty repositories.

[Evaluation.psm1](../../Modules/BranchLifecycle/Evaluation.psm1) checks default/configured protection and active PRs before commit age. [Retention.psm1](../../Modules/BranchLifecycle/Retention.psm1) records Warn, Pending, or Eligible states. A changed branch tip resets the grace period; a non-stale decision clears state.

Each evaluated branch is written to JSONL audit. Local retention state is persisted before optional notification delivery. Dry runs suppress notifications. No deletion implementation is included.

## Reporting boundary

Contracts select normalized fields rather than exporting raw discovery responses. The host sends detached payloads to allowlisted adapters. HTML and Grafana share the same repository status calculation.

Reports preserve failure status and fixed failure categories. Discovery failure before inventory returns cannot reconstruct missing repositories. See [Reporting internals](reporting-adapters.md).

## Limits

Local JSON state has no lease, locking, transaction, or notification confirmation. Transitions describe evaluation, not proof that a human received a warning. Disposable agents start fresh unless state is restored. Do not use eligibility as deletion approval.

Only Azure DevOps branch lifecycle audits are implemented. Other providers and domains need explicit implementations and tests.
