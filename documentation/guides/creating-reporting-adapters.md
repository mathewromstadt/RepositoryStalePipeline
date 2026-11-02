# Creating a reporting adapter

Start with `examples/reporting/custom-adapter/Example.psm1` and its adjacent `Example.json`.
The example is deliberately a successful no-op and has no optional capabilities. It runs
without private configuration. The host does not need modification for a new adapter.

1. Place the reviewed module under the repository root. Create adjacent metadata with an
   identifier, semantic module version, contract versions, capabilities, repository-relative
   module path, and required configuration keys.
2. Export `Test-AdapterConfiguration -Settings`, returning exactly one Boolean. Do not print
   diagnostic objects, secrets, endpoint URLs, or arbitrary exception messages.
3. Export `Publish-Snapshot -Payload -Settings`, returning exactly `@{ success = $true }`
   or `@{ success = $false }`. Throwing is also recorded as a sanitized publication failure.
4. Optionally declare `Events` and/or `Metrics` and export `Publish-Events` / `Publish-Metrics`.
   Events receives an array of validated event envelopes. Metrics receives
   `@{ snapshot = <validated snapshot>; publicationFailures = <prior failed deliveries> }`.
   Snapshot is required; unsupported optional functions are never called.
5. Add the exact path to `trustedModules` and add a registration with `id`, `enabled`,
   `module`, `failurePolicy` (`Continue` or `FailPipeline`), and `settings`.

The configuration envelope has `schemaVersion: "1.0"`. Adapter calls execute with the
repository root as their working directory, restoring the previous location afterward.
Use a dedicated destination path; never target audit, state, configuration, or source files.

```powershell
Import-Module ./Modules/Reporting/Contracts/Contracts.psm1
Import-Module ./Modules/Reporting/AdapterHost.psm1
$config = Get-Content ./examples/reporting/custom-adapter/reporting.json -Raw | ConvertFrom-Json -AsHashtable
$hostContext = Initialize-ReportingHost -Configuration $config -Root $PWD
$snapshot = New-BranchReportingSnapshot -Organization 'Example Organization'
$delivery = Invoke-ReportingAdapters -HostContext $hostContext -Snapshot $snapshot -ResultsPath ./reports/example-results.json
if ($delivery.failPipeline) { throw 'Required reporting failed.' }
```

Use `id` as the destination idempotency key. Re-dispatching the same snapshot preserves event
IDs and evaluation timestamps; a new governance run has a new GUID. Do not mutate inputs,
perform governance operations, persist mandatory audit records, or infer that Warn means a
warning was delivered. Treat policy versions as opaque identifiers. Future domain-specific
result schemas should be added without adding transport dependencies to the contracts.

Validate with `Assert-ReportingContract`, and use mocked backend tests for authentication,
timeouts, transient retries, permanent errors, malformed settings, and repeated publication.
Run `pwsh -File tests/Invoke-Tests.ps1` with Pester 5.7.1 or later. The tests use synthetic data
and require no backend credentials. See [architecture](../architecture/reporting-adapters.md)
for the full-trust execution model.
