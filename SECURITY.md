# Security

## Reporting a vulnerability

Do not post credentials, exploitable details, or private operational data in a public issue. Use the hosting repository's private vulnerability reporting feature when enabled. If unavailable, open an issue containing only a request for a private security contact; wait for a private channel before sending details.

A dedicated security contact and response-time commitment have not yet been established. Maintainers should configure private reporting before the first public release.

## Deployment boundaries

- Use read-scoped Azure DevOps credentials. Supply secrets through process environment or the CI secret store.
- Review reporting adapters and dependencies before allowlisting them. They run with the process's permissions and can access its environment and files.
- Protect configuration and source files against unauthorized changes.
- Treat generated reports, audit records, state, and logs as sensitive inventory data. Restrict artifact access and retention.
- Grant ingestion tokens write permission only for their destination. Dashboard query credentials are separate.
- Rotate disclosed credentials. Never attach real tokens to issues or tests.

## Support

This initial source distribution has no long-term support branch or guaranteed response SLA. Security fixes should target the current development version; maintainers will document supported release lines when releases are established.
