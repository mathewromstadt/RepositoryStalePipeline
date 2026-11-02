# Documentation

RepositoryStalePipeline audits Azure DevOps branch activity and publishes repository status.

## Use and operate

- [Getting started](guides/getting-started.md): offline demo and first audit.
- [Configuration](guides/configuration.md): policy, credentials, outputs, and adapters.
- [Grafana integration](guides/configuring-grafana.md): metrics, Loki, dashboards, diagnostics.
- [Running and troubleshooting](operations/running.md): scheduling, state, failures, limitations.

## Understand and contribute

- [Architecture](architecture/overview.md): discovery, evaluation, retention, reporting.
- [Reporting internals](architecture/reporting-adapters.md): contracts, dispatch, and trust.
- [Creating an adapter](guides/creating-reporting-adapters.md): extension interface and example.
- [Testing](guides/testing.md): local checks and CI.
- [Contributing](../CONTRIBUTING.md), [Security](../SECURITY.md), [Code of conduct](../CODE_OF_CONDUCT.md).
- [Release checklist](operations/releasing.md).

Hosting services, secrets, backend provisioning, and production state storage are operator responsibilities.
