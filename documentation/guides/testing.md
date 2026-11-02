# Testing

Install the development modules in [CONTRIBUTING.md](../../CONTRIBUTING.md), then run:

~~~powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
pwsh -NoProfile -File scripts/Test-Distribution.ps1
pwsh -NoProfile -File examples/Invoke-Demo.ps1
~~~

Pester covers branch protection/retention, synthetic orchestration failures, schemas, adapter isolation, HTML escaping, dashboard structure, authentication, retries, safe diagnostics, and remote-write reference vectors.

The distribution check parses PowerShell/JSON, runs PSScriptAnalyzer error checks, checks local Markdown file links, and rejects obvious credential material outside ignored directories. It is not a comprehensive secret scanner or security certification.

CI is configured for Windows and Linux with synthetic data. Tests must not call live services. Mocked HTTP and dashboard structure checks do not prove deployed backend compatibility or rendering. Validate live ingestion, permissions, and backend limits in a controlled deployment.

For adapter changes, test configuration rejection, failure/retry behavior, repeated publication, and safe diagnostics. For evaluation changes, cover protection, active PRs, time boundaries, and incomplete discovery.
