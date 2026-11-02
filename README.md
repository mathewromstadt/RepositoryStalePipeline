# RepositoryStalePipeline

Find stale branches across Azure DevOps repositories and review their current status in HTML or Grafana. This PowerShell project discovers accessible projects and repositories, evaluates configurable branch policies, records an audit trail, and publishes optional metrics and events.

**This is an audit and warning tool. It does not delete branches.** No branch-deletion module is included.

## Try it without credentials

Install PowerShell 7, open a terminal at the repository root, and run:

~~~powershell
pwsh -NoProfile -File examples/Invoke-Demo.ps1
~~~

Open `reports/branch-lifecycle.html`. The demo uses synthetic repositories and makes no network requests with the supplied default reporting configuration.

## Audit your organization

~~~powershell
Copy-Item config/organization.example.json config/organization.json
# Edit organization name, URL, exclusions, and branch policy in the local copy.
# Inject ADO_PAT from your secret store into this process.
$env:ADO_AUTH_MODE = 'PAT'
pwsh -NoProfile -File Invoke-BranchLifecycle.ps1 -DryRun
~~~

`config/organization.json` is ignored by Git. Grant the token read access only to the projects and repositories you intend to audit. All accessible projects are included unless excluded.

`-DryRun` suppresses notification webhooks. It still queries Azure DevOps, writes local state and audit files, and publishes configured reporting adapters. Neither mode deletes branches.

## Features

- Repository status: Healthy, Attention, or Unknown, including empty repositories.
- Protection for default branches, configured name patterns, and active pull-request branches.
- Configurable inactivity and warning-grace periods.
- HTML reports, JSON snapshots, JSONL audit records, and delivery outcomes.
- Optional Loki events and Prometheus metrics through Grafana-compatible backends.
- A documented adapter interface for other reporting destinations.

Start with [Getting started](documentation/guides/getting-started.md), [Configuration](documentation/guides/configuration.md), and [Grafana](documentation/guides/configuring-grafana.md). See the [documentation index](documentation/index.md) for architecture, operations, and extension.

## Limitations

Commit age is a signal, not proof that a branch is abandoned. Only repositories visible to the identity can be discovered. Local retention state has no concurrency protection and does not survive disposable agents unless separately persisted. Warning state does not prove delivery. Review the [operating guide](documentation/operations/running.md) before scheduling runs.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Distributed under the existing [MIT license](LICENSE).
