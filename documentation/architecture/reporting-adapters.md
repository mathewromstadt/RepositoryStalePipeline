# Reporting adapter architecture

The governance evaluator owns branch decisions and retention. Reporting consumes detached,
versioned snapshots after required JSONL audit writes. No adapter receives state, credentials
for discovery, raw API responses, or an audit writer. PowerShell 7 remains the execution runtime.

## Execution

1. Load `config/reporting.json` (override with `-ReportingConfigPath`).
2. Validate explicit registrations, allowlisted paths, adjacent JSON metadata, contract
   compatibility, exported capabilities, and settings before discovery.
3. Discover and evaluate branches using the existing lifecycle modules; persist each audit
   record and retention state using the existing mechanisms.
4. Build a snapshot with policy identity and a SHA-256 fingerprint of the configured branch
   policy as its version. Preserve failed execution status when discovery, evaluation, audit,
   state persistence, or notification fails. Never include raw exceptions.
5. Save `reports/snapshot.json`, then dispatch Snapshot, Events, and Metrics phases, in that
   order. Each invocation receives a separate JSON copy. A failure never stops other adapters.
6. Save `reports/adapter-results.json` and `reports/execution-summary.json`. Only then apply
   `FailPipeline`. The original governance failure takes precedence over an adapter failure.

HTML is the only default adapter. An explicit empty `adapters` list disables reporting;
`enabled: false` disables an individual registration. Malformed host configuration fails
before evaluation. Per-adapter configuration/initialization failures are recorded using the
registration's policy. `Continue` never changes the governance exit status; `FailPipeline`
fails an otherwise successful run after every delivery attempt. Failure to save reporting
artifacts is fatal regardless of optional destination policies.

The example Azure pipeline publishes reports and audit artifacts even after failures. Automatic deletion is not implemented in this distribution.

## Contracts and responsibilities

`schemas/reporting` contains draft-07 schemas for snapshots, events, metadata, and execution
results. Payload version `1.0` is validated with PowerShell `Test-Json`. Adapters declare exact
supported contract versions; unsupported versions fail before their module is loaded.
Breaking changes require a major version increase and explicit migration. New governance
domains can define their own `results` objects within the common envelope. Only the current
branch lifecycle domain is implemented. Grafana and HTML currently render that domain.

Branch results contain explicit repository inventory, including empty repositories, plus
normalized branch decisions and a single centrally computed summary. HTML and Grafana reuse
that summary. Failed/partial runs mark repositories without known attention as `Unknown`,
not healthy. A discovery exception before inventory returns cannot reconstruct missing
inventory; it reports a discovery failure and zero known repositories.

Event types are `EvaluationOutcome`, `BranchDecision`, `WarningAction`, `RetentionState`,
`RepositoryStatus`, and `ReportingFailure`. Repository events carry the same status/counts
as HTML plus organization, run ID, and evaluation time, including empty inventory repositories.
Retention events describe the evaluated state (Warn/Pending/Eligible),
not confirmed notification delivery or deletion. Comparing stable branch identifiers across
runs provides state transitions. No future release/approval/hotfix logic is implemented.

The legacy `Modules/BranchLifecycle/Reporting.psm1` entrypoint remains a compatibility shim:
it builds the normalized snapshot and invokes the same HTML renderer. New integrations use
the host. The shim uses a generic default organization; the operational entrypoint supplies the configured organization.

## Security boundary

Adapter registrations and source files are trusted deployment inputs. Exact relative module
paths must appear in `trustedModules`; absolute paths, traversal outside the root, and
symlinks/junctions are rejected. Metadata is validated before module import. Nothing is
downloaded or evaluated from configuration. Protect configuration and module files with
review and filesystem permissions; the allowlist is not a signing mechanism.

**Third-party PowerShell adapters execute with all permissions of the hosting process.**
Detached payloads prevent accidental object mutation, but this is not a hostile-code sandbox.
A malicious trusted module can access process secrets or files. Review code and dependencies;
use a separate low-privilege process/service boundary if untrusted extensions are required.
Adapters must never write retention/audit files, approve actions, or invoke deletion.

The host drops raw adapter errors and suppresses auxiliary output streams. Only fixed
configuration, initialization, publication, and delivery codes reach outcome files. Built-in
Grafana code accepts environment-variable references for tokens and optional Basic-auth usernames, rejects inline
secrets, requires HTTPS without embedded credentials/query strings, suppresses HTTP verbose
logging, bounds retries/timeouts, and rejects redirects. Reports select known business fields
instead of serializing discovery objects. Reports still contain private operational names
and branch data: protect artifacts and backend access/retention accordingly.

## Deliberate limits

Delivery is sequential and synchronous. Third-party adapters must implement bounded execution;
the host does not terminate hung arbitrary PowerShell code. HTTP calls are limited to 30 seconds
per attempt and at most three retries. HTML overwrites its snapshot file; Pushgateway replaces
a stable job group; remote-write posts timestamped samples; Loki retries can duplicate events, with stable IDs available for consumer deduplication. Exhausted retries can lose a batch; no durable delivery guarantee is provided.
Local retention durability and notification confirmation retain their existing limitations.
Reporting does not make automatic branch deletion production-ready.
