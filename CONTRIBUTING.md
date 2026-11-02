# Contributing

Contributions to documentation, tests, reporting adapters, and Azure DevOps audit behavior are welcome.

## Development setup

Use PowerShell 7 and a checkout. Runtime code has no external PowerShell module dependency; development checks require Pester and PSScriptAnalyzer.

~~~powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope CurrentUser -Force
pwsh -NoProfile -File tests/Invoke-Tests.ps1
pwsh -NoProfile -File scripts/Test-Distribution.ps1
pwsh -NoProfile -File examples/Invoke-Demo.ps1
~~~

Tests use synthetic fixtures and mocked services. Do not use production credentials or inventories.

## Proposing a change

1. Open an issue for substantial behavior or contract changes.
2. Create a branch with a focused change. Keep PowerShell readable: descriptive names, explicit parameters, and small functions where they clarify responsibilities.
3. Add meaningful regression coverage. Keep audit failures distinguishable from optional reporting failures.
4. Update the relevant page under `documentation/`, examples, and `CHANGELOG.md`.
5. Run the checks above and submit a pull request describing the problem, behavior, validation, and remaining limitations.

Do not include real endpoints, tenant identifiers, secrets, audit logs, or generated reports. Redact screenshots and attachments. Explain dependency additions.

## Compatibility and safety

Reporting payloads use contract version `1.0`. Adapters declare supported versions explicitly. Breaking changes require a version and migration discussion. Only the branch-lifecycle domain is implemented.

Automatic deletion is outside scope. Destructive operations require a separate design and review, not a configuration toggle. Review third-party adapters as executable code; the host is not a sandbox.

## Review and releases

Maintainers review scope, correctness, documentation, and tests before merging. Passing CI does not authorize a release. Release review must check licensing, dependencies, examples, sensitive-data scans, and final archive contents.

Submit only material you have the right to contribute under the project's MIT license. See [Testing](documentation/guides/testing.md) and [Creating adapters](documentation/guides/creating-reporting-adapters.md).
