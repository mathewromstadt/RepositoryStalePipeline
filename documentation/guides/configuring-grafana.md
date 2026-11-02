# Grafana integration

Grafana queries your metrics and logs backends. The adapter publishes data to those backends; it does not create datasources or provision services. HTML works without Grafana.

## Configure ingestion

Use [remote-write/reporting.json](../../examples/reporting/remote-write/reporting.json). Inject these process variables from your secret store:

| Variable | Value |
| --- | --- |
| `METRICS_ENDPOINT` | HTTPS metrics base URL or complete remote-write endpoint |
| `METRICS_USERNAME` | Metrics instance username |
| `METRICS_TOKEN` | Metrics access token with write permission |
| `LOKI_ENDPOINT` | HTTPS Loki base URL or complete push endpoint |
| `LOKI_USERNAME` | Logs instance username |
| `LOKI_TOKEN` | Logs access token with write permission |

Usernames and tokens are independent for each destination. For Grafana Cloud, ingestion needs `metrics:write` or `logs:write` respectively; a query-only token cannot publish data. For bearer authentication, remove the corresponding username environment reference from your local configuration.

JSON settings ending in `Environment` contain the variable **name**, not the secret value. The remote-write example contains no tenant URLs or credentials.

~~~powershell
pwsh -NoProfile -File Invoke-BranchLifecycle.ps1 -DryRun -ReportingConfigPath examples/reporting/remote-write/reporting.json
~~~

Inspect both Events and Metrics results in `reports/adapter-results.json`. Their failure policy is `Continue` in this example; optional delivery failures do not fail an otherwise successful audit.

## Endpoints and protocols

- Loki base URLs gain `/loki/api/v1/push`. A full push URL is accepted.
- `metricsProtocol: "RemoteWrite"` sends protobuf with raw Snappy encoding. Base URLs gain `/api/prom/push`; complete `/api/prom/push`, `/api/v1/write`, or `/api/v1/push` endpoints are accepted.
- `metricsProtocol: "Pushgateway"` is the default when omitted. See [the Pushgateway example](../../examples/reporting/grafana/reporting.json). Configure a full HTTPS `/metrics/job/<stable-job-name>` endpoint and arrange for Prometheus to scrape it with `honor_labels: true`.

Use HTTPS without URL credentials, query strings, or fragments. Do not set a literal endpoint and its environment-reference setting together. Redirects are rejected. Requests time out after 30 seconds; `retryCount` defaults to 2 and accepts 0–3. Transport errors, 429, and 5xx can retry.

## Datasources and dashboards

Configure Prometheus and Loki datasources in Grafana using the backend query URLs and read credentials. Loki's query URL is the base URL, not its push path. These datasource credentials are distinct from the pipeline's ingestion configuration.

Choose one supplied dashboard:

- [governance.json](../../dashboards/grafana/governance.json): classic dashboard model.
- [governance.resource.json](../../dashboards/grafana/governance.resource.json): V1 resource envelope, with `metadata` and `spec`.

Both describe the same dashboard UID. Import only one. If an editor requires `metadata` and `spec`, select the V1 resource model and use the resource file. It is **not** a V2 dashboard. An editor requiring V2 needs a supported conversion/import path for your Grafana version.

Select your datasources through `DS_PROMETHEUS` and `DS_LOKI`. Run the audit with Loki enabled before expecting repository rows.

## Repository status

The table uses `RepositoryStatus` events and the same normalized status/counts as HTML. It groups by organization/project/repository and selects the latest observation in the time range. It is not a coherent snapshot of only the newest run: a removed repository may retain an older row. Inspect Last evaluated.

The query requests at most 5,000 newest events and may be further limited by the backend. Narrow the range when necessary. Repository and branch names remain JSON fields in Loki, not indexed stream labels or metric labels.

## Troubleshooting

| Outcome | Check |
| --- | --- |
| `Unauthorized` / 401 | Correct destination username and token |
| `Forbidden` / 403 | Write scope and tenant permissions |
| `EndpointNotFound` / 404 | Correct backend and ingestion path |
| `RequestRejected` / 400 | Backend payload/timestamp constraints |
| `PayloadTooLarge` / 413 | Batch and gateway size limits |
| `RateLimited` / 429 | Ingestion limits and exhausted retries |
| `DestinationUnavailable` / 5xx | Backend/gateway availability |
| `TransportFailure` / 0 | DNS, TLS, connectivity, timeout |

Successful metrics do not prove Loki delivery. If Events succeeds but rows are absent, check datasource tenant, time range, and query permissions.

All published metrics are per-run gauges. Weekly remote-write samples are sparse; repository-count and last-success stats use 30-day lookbacks. An instant query can be empty between runs. Alert on missing data and sample age. The publication-failure metric cannot report failure to publish itself; local adapter results contain the complete outcome.

Loki sends one batch per run; retries can duplicate accepted events after a lost response. Stable IDs allow consumer deduplication. There is no durable queue, automatic replay, chunking, or remote-write staleness lifecycle. Serialize runs for the same metrics job. Mocked tests validate payloads, not live Grafana rendering or deployment permissions.
