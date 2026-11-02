# Release checklist

This is a source distribution. No automatic publication job is included.

Before a public release:

1. Confirm ownership/distribution rights for every file and dependency. Preserve the MIT license and required notices.
2. Configure private vulnerability reporting and a reachable conduct/security contact.
3. Run tests, distribution checks, and the offline demo from a clean checkout.
4. Review archive contents. Exclude local configuration, credentials, state, logs, reports, and Git internals.
5. Run a dedicated secret scan and review organization identifiers and deployment assumptions.
6. Validate backend integrations and document unverified environments and limitations.
7. Update the changelog, choose a version, and document contract migrations.
8. Have a maintainer approve the exact revision and contents before tagging or publishing.

No package-registry publication pipeline is provided. Internal helpers do not have a backwards-compatibility guarantee. Reporting contract changes follow the explicit compatibility policy in the architecture guide.
