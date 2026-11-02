BeforeAll {
    $root = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$root/Modules/Reporting/Contracts/Contracts.psm1" -Force
    Import-Module "$root/Modules/Reporting/AdapterHost.psm1" -Force
    function New-TestSnapshot {
        New-BranchReportingSnapshot -RunId 'test-run' -Events @(
            @{ project = 'Example'; repository = 'Service'; ref = 'refs/heads/<script>'; decision = 'Stale'; action = 'Warn' },
            @{ project = 'Example'; repository = 'Service'; ref = 'refs/heads/main'; decision = 'Protected'; action = 'Skip' }
        ) -Repositories @(@{ project = 'Example'; repository = 'Empty' })
    }
    function New-TestConfig {
        $config = Get-Content "$root/config/reporting.json" -Raw | ConvertFrom-Json -AsHashtable
        $config.adapters[0].settings.outputPath = "$TestDrive/report.html"
        return $config
    }
}

Describe 'Versioned reporting contracts' {
    It 'validates all checked-in samples and configurations' {
        foreach ($kind in @('event', 'result')) {
            $payload = Get-Content "$root/examples/reporting/$kind.json" -Raw | ConvertFrom-Json -AsHashtable
            { Assert-ReportingContract $payload -Kind $kind } | Should -Not -Throw
        }
        $snapshot = Get-Content "$root/examples/reporting/snapshot.json" -Raw | ConvertFrom-Json -AsHashtable
        { Assert-ReportingContract $snapshot } | Should -Not -Throw
        foreach ($path in Get-ChildItem "$root/examples/reporting" -Filter reporting.json -Recurse) {
            $config = Get-Content $path.FullName -Raw | ConvertFrom-Json -AsHashtable
            { Assert-ReportingContract $config -Kind configuration } | Should -Not -Throw
        }
    }
    It 'validates snapshots, summary counts and stable event identities' {
        $snapshot = New-TestSnapshot
        { Assert-ReportingContract $snapshot } | Should -Not -Throw
        $snapshot.results.summary.repositories | Should -Be 2
        $snapshot.results.summary.healthyRepositories | Should -Be 1
        $snapshot.results.summary.attentionRepositories | Should -Be 1
        $events = @(ConvertTo-ReportingEvents $snapshot)
        $events.Count | Should -Be 7
        $events[0].id | Should -Be 'test-run/event/0'
    }
    It 'rejects invalid versions and missing required fields' {
        $snapshot = New-TestSnapshot
        $snapshot.schemaVersion = '2.0'
        { Assert-ReportingContract $snapshot } | Should -Throw '*Invalid reporting*'
        $snapshot.schemaVersion = '1.0'; $snapshot.Remove('runId')
        { Assert-ReportingContract $snapshot } | Should -Throw
    }
    It 'supports empty inventories and future domain envelopes' {
        { New-BranchReportingSnapshot } | Should -Not -Throw
        $snapshot = New-TestSnapshot; $snapshot.domain = 'release-promotion'; $snapshot.results = @{ outcome = 'example' }
        { Assert-ReportingContract $snapshot } | Should -Not -Throw
        { ConvertTo-ReportingEvents $snapshot } | Should -Not -Throw
    }
    It 'does not mark incomplete repositories healthy' {
        $snapshot = New-BranchReportingSnapshot -Status Failed -Repositories @(@{ project = 'Example'; repository = 'Unknown' })
        $snapshot.results.repositories[0].status | Should -Be 'Unknown'
        $snapshot.results.summary.healthyRepositories | Should -Be 0
    }
    It 'drops arbitrary transport fields' {
        $snapshot = New-BranchReportingSnapshot -Events @(@{ project = 'p'; repository = 'r'; ref = 'b'; decision = 'Active'; action = 'Skip'; token = 'secret'; url = 'https://private.example' })
        ($snapshot | ConvertTo-Json -Depth 20) | Should -Not -Match 'secret|private.example'
    }
    It 'publishes the same repository statuses and counts as HTML including empty repositories' {
        $snapshot = New-TestSnapshot
        $rows = @(ConvertTo-ReportingEvents $snapshot | Where-Object type -eq 'RepositoryStatus')
        $rows.Count | Should -Be 2
        foreach ($row in $rows) {
            { Assert-ReportingContract $row -Kind event } | Should -Not -Throw
            $repository = @($snapshot.results.repositories | Where-Object repository -eq $row.results.repository)[0]
            $row.results.status | Should -Be $repository.status
            $row.results.branchCount | Should -Be $repository.branchCount
            $row.results.attentionCount | Should -Be $repository.attentionCount
            $row.results.evaluatedAt | Should -Be $snapshot.timestamp
            $row.results.runId | Should -Be $snapshot.runId
            $row.results.organization | Should -Be $snapshot.results.organization
        }
        $empty = @($rows | Where-Object { $_.results.repository -eq 'Empty' })[0]
        $empty.results.status | Should -Be 'Healthy'
        $empty.results.branchCount | Should -Be 0
    }
    It 'publishes unknown repository status after an incomplete evaluation' {
        $snapshot = New-BranchReportingSnapshot -Status Incomplete -Repositories @(@{ project = 'Example'; repository = 'Empty' })
        $row = @(ConvertTo-ReportingEvents $snapshot | Where-Object type -eq 'RepositoryStatus')[0]
        $row.results.status | Should -Be 'Unknown'
        $row.evaluationStatus | Should -Be 'Incomplete'
    }
    It 'rejects unsupported capabilities' {
        $metadata = Get-Content "$root/Modules/Reporting/Adapters/Html/Html.json" -Raw | ConvertFrom-Json -AsHashtable
        $metadata.capabilities += 'Delete'
        { Assert-ReportingContract $metadata -Kind adapter } | Should -Throw
    }
}

Describe 'Adapter host and HTML compatibility' {
    It 'renders default HTML with encoding, empty repositories and repeatable output' {
        $config = New-TestConfig
        $hostContext = Initialize-ReportingHost $config $root
        $snapshot = New-TestSnapshot
        $first = Invoke-ReportingAdapters $hostContext $snapshot "$TestDrive/results.json"
        $first.failPipeline | Should -BeFalse
        $html = Get-Content "$TestDrive/report.html" -Raw
        $html | Should -Match 'Attention|Healthy'
        $html | Should -Match 'Empty'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Not -Match '<script>'
        $null = Invoke-ReportingAdapters $hostContext $snapshot "$TestDrive/results.json"
        (Get-Content "$TestDrive/report.html" -Raw) | Should -Be $html
        $result = @(Get-Content "$TestDrive/results.json" -Raw | ConvertFrom-Json -AsHashtable)
        { Assert-ReportingContract $result[0] -Kind result } | Should -Not -Throw
    }
    It 'supports legacy renderer entrypoint' {
        Import-Module "$root/Modules/BranchLifecycle/Reporting.psm1" -Force
        New-BranchLifecycleReport -Events @() -OutputPath "$TestDrive/legacy.html" | Should -Be "$TestDrive/legacy.html"
    }
    It 'supports no adapters and disabled adapters' {
        $config = New-TestConfig; $config.adapters[0].enabled = $false
        $hostContext = Initialize-ReportingHost $config $root
        (Invoke-ReportingAdapters $hostContext (New-TestSnapshot) "$TestDrive/disabled.json").results.Count | Should -Be 0
        $config.adapters = @()
        (Initialize-ReportingHost $config $root).entries.Count | Should -Be 0
    }
    It 'records configuration failures and continues other adapters before enforcing policy' {
        $config = New-TestConfig
        $config.adapters += @{ id = 'missing'; enabled = $true; module = '../outside.psm1'; failurePolicy = 'FailPipeline'; settings = @{} }
        $hostContext = Initialize-ReportingHost $config $root
        $result = Invoke-ReportingAdapters $hostContext (New-TestSnapshot) "$TestDrive/multiple.json"
        $result.failPipeline | Should -BeTrue
        $result.results[0].status | Should -Be 'Succeeded'
        $result.results[1].code | Should -Be 'ConfigurationFailure'
    }
    It 'records missing required settings without loading an adapter' {
        $config = New-TestConfig; $config.adapters[0].settings = @{}
        (Initialize-ReportingHost $config $root).entries[0].code | Should -Be 'ConfigurationFailure'
    }
    It 'isolates publication failures and obeys Continue' {
        $config = New-TestConfig
        $config.adapters[0].settings.outputPath = $TestDrive
        $config.adapters[0].failurePolicy = 'Continue'
        $hostContext = Initialize-ReportingHost $config $root
        $result = Invoke-ReportingAdapters $hostContext (New-TestSnapshot) "$TestDrive/failure.json"
        $result.failPipeline | Should -BeFalse
        $result.results[0].code | Should -Be 'PublicationFailure'
    }
    It 'rejects invalid failure policies' {
        $config = New-TestConfig; $config.adapters[0].failurePolicy = 'Ignore'
        { Initialize-ReportingHost $config $root } | Should -Throw
    }
    It 'rejects allowlisted paths that escape the repository' {
        $config = New-TestConfig
        $config.adapters[0].module = '../escape.psm1'
        $config.trustedModules += '../escape.psm1'
        (Initialize-ReportingHost $config $root).entries[0].code | Should -Be 'ConfigurationFailure'
    }
}

Describe 'Custom adapter isolation and initialization' {
    BeforeEach {
        $modulePath = "$TestDrive/Custom.psm1"
        $metadata = @{ schemaVersion = '1.0'; id = 'custom'; version = '1.0.0'; module = 'Custom.psm1'; contractVersions = @('1.0'); capabilities = @('Snapshot'); requiredConfiguration = @() }
        $metadata | ConvertTo-Json | Set-Content "$TestDrive/Custom.json"
        $customConfig = @{ schemaVersion = '1.0'; trustedModules = @('Custom.psm1'); adapters = @(@{ id = 'custom'; enabled = $true; module = 'Custom.psm1'; settings = @{}; failurePolicy = 'Continue' }) }
    }
    It 'does not expose mutable governance objects or raw exception text' {
        @'
function Test-AdapterConfiguration { param($Settings) return $true }
function Publish-Snapshot { param($Payload, $Settings) $Payload.results.branches[0].decision = 'Active'; throw 'SECRET-123' }
Export-ModuleMember -Function Test-AdapterConfiguration, Publish-Snapshot
'@ | Set-Content $modulePath
        $snapshot = New-TestSnapshot
        $hostContext = Initialize-ReportingHost $customConfig $TestDrive
        $result = Invoke-ReportingAdapters $hostContext $snapshot "$TestDrive/custom-results.json"
        $snapshot.results.branches[0].decision | Should -Be 'Stale'
        ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'SECRET-123'
        $result.results[0].code | Should -Be 'PublicationFailure'
    }
    It 'records initialization errors' {
        "throw 'SECRET-INIT'" | Set-Content $modulePath
        (Initialize-ReportingHost $customConfig $TestDrive).entries[0].code | Should -Be 'InitializationFailure'
    }
    It 'rejects contract incompatibility before executing code' {
        "throw 'must not execute'" | Set-Content $modulePath
        $metadata.contractVersions = @('2.0'); $metadata | ConvertTo-Json | Set-Content "$TestDrive/Custom.json"
        (Initialize-ReportingHost $customConfig $TestDrive).entries[0].code | Should -Be 'ConfigurationFailure'
    }
}

Describe 'Grafana payloads and mocked transports' {
    BeforeEach { Import-Module "$root/Modules/Reporting/Adapters/Grafana/Grafana.psm1" -Force }
    It 'loads both pipeline endpoints and publishes authenticated metrics and Loki events' {
        $previousEndpoint = $env:LOKI_ENDPOINT
        $previousToken = $env:LOKI_TOKEN
        $previousMetricsEndpoint = $env:METRICS_ENDPOINT
        $previousMetricsToken = $env:METRICS_TOKEN
        $previousLokiUsername = $env:LOKI_USERNAME
        $previousMetricsUsername = $env:METRICS_USERNAME
        try {
            $env:LOKI_ENDPOINT = 'https://logs.example.org/'
            $env:LOKI_TOKEN = 'synthetic-pipeline-token'
            $env:METRICS_ENDPOINT = 'https://metrics.example.org'
            $env:METRICS_TOKEN = 'synthetic-metrics-token'
            $env:LOKI_USERNAME = 'logs-user'
            $env:METRICS_USERNAME = 'metrics-user'
            $config = Get-Content "$root/examples/reporting/remote-write/reporting.json" -Raw | ConvertFrom-Json -AsHashtable
            $config.adapters[0].settings.outputPath = "$TestDrive/pipeline.html"
            $hostContext = Initialize-ReportingHost $config $root
            $hostContext.entries[1].code | Should -Be 'Ready'
            Mock Invoke-WebRequest -ModuleName Grafana {
                $Headers.Authorization | Should -Match '^Basic '
                $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Headers.Authorization.Substring(6)))
                if ($Uri -match '/loki/') { $decoded | Should -Be 'logs-user:synthetic-pipeline-token' }
                else {
                    $decoded | Should -Be 'metrics-user:synthetic-metrics-token'
                    $Headers['Content-Encoding'] | Should -Be 'snappy'
                    $Headers['X-Prometheus-Remote-Write-Version'] | Should -Be '0.1.0'
                    $ContentType | Should -Be 'application/x-protobuf'
                    ,$Body | Should -BeOfType [byte[]]
                    $Body.Length | Should -BeGreaterThan 100
                }
                @{ StatusCode = 204 }
            }
            $result = Invoke-ReportingAdapters $hostContext (New-TestSnapshot) "$TestDrive/pipeline-results.json"
            @($result.results | Where-Object status -eq 'Failed').Count | Should -Be 0
            Should -Invoke Invoke-WebRequest -ModuleName Grafana -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://logs.example.org/loki/api/v1/push' -and $Method -eq 'Post'
            }
            Should -Invoke Invoke-WebRequest -ModuleName Grafana -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://metrics.example.org/api/prom/push' -and $Method -eq 'Post'
            }
            $config.adapters[1].settings.Contains('lokiEndpoint') | Should -BeFalse
            $config.adapters[1].settings.Contains('metricsEndpoint') | Should -BeFalse
            (Get-Content "$TestDrive/pipeline-results.json" -Raw) | Should -Not -Match 'synthetic-pipeline-token|synthetic-metrics-token'
        }
        finally {
            $env:LOKI_ENDPOINT = $previousEndpoint
            $env:LOKI_TOKEN = $previousToken
            $env:METRICS_ENDPOINT = $previousMetricsEndpoint
            $env:METRICS_TOKEN = $previousMetricsToken
            $env:LOKI_USERNAME = $previousLokiUsername
            $env:METRICS_USERNAME = $previousMetricsUsername
        }
    }
    It 'accepts a complete push URL and rejects missing or ambiguous endpoint settings' {
        $previousEndpoint = $env:TEST_LOKI_ENDPOINT
        try {
            $env:TEST_LOKI_ENDPOINT = 'https://logs.example.org/loki/api/v1/push'
            Test-AdapterConfiguration @{ lokiEndpointEnvironment = 'TEST_LOKI_ENDPOINT' } | Should -BeTrue
            Test-AdapterConfiguration @{ lokiEndpointEnvironment = 'TEST_LOKI_ENDPOINT'; lokiEndpoint = 'https://logs.example.org' } | Should -BeFalse
            $env:TEST_LOKI_ENDPOINT = '$(lokiEndpoint)'
            Test-AdapterConfiguration @{ lokiEndpointEnvironment = 'TEST_LOKI_ENDPOINT' } | Should -BeFalse
            $env:TEST_LOKI_ENDPOINT = $null
            Test-AdapterConfiguration @{ lokiEndpointEnvironment = 'TEST_LOKI_ENDPOINT' } | Should -BeFalse
        }
        finally { $env:TEST_LOKI_ENDPOINT = $previousEndpoint }
    }
    It 'validates metrics environment references and rejects incompatible remote-write endpoints' {
        $previousEndpoint = $env:TEST_METRICS_ENDPOINT
        try {
            $env:TEST_METRICS_ENDPOINT = 'https://metrics.example.org/metrics/job/governance'
            Test-AdapterConfiguration @{ metricsEndpointEnvironment = 'TEST_METRICS_ENDPOINT' } | Should -BeTrue
            Test-AdapterConfiguration @{ metricsEndpointEnvironment = 'TEST_METRICS_ENDPOINT'; metricsEndpoint = $env:TEST_METRICS_ENDPOINT } | Should -BeFalse
            $env:TEST_METRICS_ENDPOINT = 'https://metrics.example.org/api/prom/push'
            Test-AdapterConfiguration @{ metricsEndpointEnvironment = 'TEST_METRICS_ENDPOINT' } | Should -BeFalse
            $env:TEST_METRICS_ENDPOINT = '$(metricsEndpoint)'
            Test-AdapterConfiguration @{ metricsEndpointEnvironment = 'TEST_METRICS_ENDPOINT' } | Should -BeFalse
            $env:TEST_METRICS_ENDPOINT = $null
            Test-AdapterConfiguration @{ metricsEndpointEnvironment = 'TEST_METRICS_ENDPOINT' } | Should -BeFalse
        }
        finally { $env:TEST_METRICS_ENDPOINT = $previousEndpoint }
    }
    It 'generates bounded metric labels and all aggregate metrics' {
        $body = ConvertTo-GovernanceMetrics @{ snapshot = (New-TestSnapshot); publicationFailures = 2 }
        $body | Should -Match 'governance_repositories 2'
        $body | Should -Match 'governance_adapter_publication_failures 2'
        $body | Should -Match 'governance_last_successful_evaluation_timestamp_seconds'
        $body | Should -Not -Match 'Example|Service|script|test-run|repository='
        $body | Should -Match 'decision="Stale"} 1'
    }
    It 'requires a resolved username and token for configured Basic authentication' {
        $previousUsername = $env:TEST_BASIC_USER
        $previousToken = $env:TEST_BASIC_TOKEN
        try {
            $settings = @{ lokiEndpoint = 'https://logs.example.org'; lokiUsernameEnvironment = 'TEST_BASIC_USER'; lokiTokenEnvironment = 'TEST_BASIC_TOKEN' }
            $env:TEST_BASIC_USER = '123456'
            $env:TEST_BASIC_TOKEN = 'synthetic-token'
            Test-AdapterConfiguration $settings | Should -BeTrue
            $env:TEST_BASIC_USER = $null
            Test-AdapterConfiguration $settings | Should -BeFalse
            $env:TEST_BASIC_USER = '$(lokiUserName)'
            Test-AdapterConfiguration $settings | Should -BeFalse
            $env:TEST_BASIC_USER = 'invalid:user'
            Test-AdapterConfiguration $settings | Should -BeFalse
            $env:TEST_BASIC_USER = '123456'
            $env:TEST_BASIC_TOKEN = '$(lokiTokenEnvironment)'
            Test-AdapterConfiguration $settings | Should -BeFalse
        }
        finally { $env:TEST_BASIC_USER = $previousUsername; $env:TEST_BASIC_TOKEN = $previousToken }
    }
    It 'accepts explicit remote-write paths and rejects a pushgateway URL in remote-write mode' {
        Test-AdapterConfiguration @{ metricsProtocol = 'RemoteWrite'; metricsEndpoint = 'https://metrics.example.org/api/prom/push' } | Should -BeTrue
        Test-AdapterConfiguration @{ metricsProtocol = 'RemoteWrite'; metricsEndpoint = 'https://metrics.example.org/api/v1/write' } | Should -BeTrue
        Test-AdapterConfiguration @{ metricsProtocol = 'RemoteWrite'; metricsEndpoint = 'https://metrics.example.org/metrics/job/governance' } | Should -BeFalse
        Test-AdapterConfiguration @{ metricsProtocol = 'RemoteWrite'; metricsEndpoint = 'https://metrics.example.org/api/prom/push?token=private' } | Should -BeFalse
    }
    It 'retries an identical binary remote-write batch without changing timestamps' {
        $script:remoteBodies = [Collections.Generic.List[string]]::new()
        Mock Invoke-WebRequest -ModuleName Grafana {
            $script:remoteBodies.Add([Convert]::ToBase64String($Body))
            if ($script:remoteBodies.Count -eq 1) { throw 'temporary network failure' }
            @{ StatusCode = 204 }
        }
        Mock Start-Sleep -ModuleName Grafana {}
        $result = Publish-Metrics @{ snapshot = (New-TestSnapshot); publicationFailures = 0 } @{
            metricsProtocol = 'RemoteWrite'; metricsEndpoint = 'https://metrics.example.org/api/prom/push'; retryCount = 1
        }
        $result.success | Should -BeTrue
        $script:remoteBodies.Count | Should -Be 2
        $script:remoteBodies[0] | Should -Be $script:remoteBodies[1]
    }
    It 'encodes structured Loki entries with string nanosecond timestamps' {
        $payload = ConvertTo-LokiPayload @(ConvertTo-ReportingEvents (New-TestSnapshot)) | ConvertFrom-Json -AsHashtable
        $payload.streams[0].values[0][0] | Should -BeOfType [string]
        $payload.streams[0].values.Count | Should -Be 7
        ($payload.streams[0].values[0][1] | ConvertFrom-Json).type | Should -Be 'EvaluationOutcome'
        $repositoryRows = @($payload.streams[0].values | ForEach-Object { $_[1] | ConvertFrom-Json } | Where-Object type -eq 'RepositoryStatus')
        $repositoryRows.Count | Should -Be 2
        $payload.streams[0].stream.Keys.Count | Should -Be 1
    }
    It 'preserves nanosecond timestamps and the two-string Loki entry shape' {
        $payload = ConvertTo-LokiPayload @(@{ timestamp = '2026-11-02T15:25:30.1234567Z'; type = 'Example'; results = @{} }) | ConvertFrom-Json -AsHashtable
        $payload.streams[0].values[0].Count | Should -Be 2
        $payload.streams[0].values[0][0] | Should -Be '1793633130123456700'
        $payload.streams[0].values[0][1] | Should -BeOfType [string]
    }
    It 'persists safe Loki HTTP diagnostics through the host without exposing backend text' {
        $config = New-TestConfig
        $config.adapters += @{ id = 'grafana'; enabled = $true; module = 'Modules/Reporting/Adapters/Grafana/Grafana.psm1'; failurePolicy = 'Continue'; settings = @{ lokiEndpoint = 'https://logs.example.org'; retryCount = 0 } }
        $hostContext = Initialize-ReportingHost $config $root
        Mock Invoke-WebRequest -ModuleName Grafana {
            $exception = [Exception]::new('SECRET backend message https://private.example/token')
            $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 401 })
            throw $exception
        }
        $result = Invoke-ReportingAdapters $hostContext (New-TestSnapshot) "$TestDrive/http-results.json" -WarningVariable warnings
        $failed = @($result.results | Where-Object status -eq 'Failed')
        $failed.Count | Should -Be 1
        $failed[0].capability | Should -Be 'Events'
        $failed[0].httpStatusCode | Should -Be 401
        $failed[0].diagnosticCode | Should -Be 'Unauthorized'
        $failed[0].attempts | Should -Be 1
        $result.failPipeline | Should -BeFalse
        (Get-Content "$TestDrive/http-results.json" -Raw) | Should -Not -Match 'SECRET|private.example'
        ($warnings -join ' ') | Should -Match 'Events.*Unauthorized.*401'
        ($warnings -join ' ') | Should -Not -Match 'SECRET|private.example'
    }
    It 'maps HTTP <HttpStatus> to a fixed safe diagnostic' -TestCases @(
        @{ HttpStatus = 400; Diagnostic = 'RequestRejected' },
        @{ HttpStatus = 403; Diagnostic = 'Forbidden' },
        @{ HttpStatus = 404; Diagnostic = 'EndpointNotFound' },
        @{ HttpStatus = 413; Diagnostic = 'PayloadTooLarge' },
        @{ HttpStatus = 429; Diagnostic = 'RateLimited' },
        @{ HttpStatus = 503; Diagnostic = 'DestinationUnavailable' }
    ) {
        param($HttpStatus, $Diagnostic)
        Mock Invoke-WebRequest -ModuleName Grafana {
            $exception = [Exception]::new('SECRET')
            $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = $HttpStatus })
            throw $exception
        }
        $result = Publish-Events @(ConvertTo-ReportingEvents (New-TestSnapshot)) @{ lokiEndpoint = 'https://logs.example.org'; retryCount = 0 }
        $result.success | Should -BeFalse
        $result.httpStatusCode | Should -Be $HttpStatus
        $result.diagnosticCode | Should -Be $Diagnostic
    }
    It 'rejects insecure endpoints, inline secrets and missing environment credentials' {
        Test-AdapterConfiguration @{ metricsEndpoint = 'http://example.org/metrics/job/governance' } | Should -BeFalse
        Test-AdapterConfiguration @{ lokiEndpoint = 'https://user:password@example.org/loki/api/v1/push' } | Should -BeFalse
        Test-AdapterConfiguration @{ lokiEndpoint = 'https://example.org/loki/api/v1/push?secret=x' } | Should -BeFalse
        Test-AdapterConfiguration @{ lokiEndpoint = 'https://example.org/loki/api/v1/push'; token = 'secret' } | Should -BeFalse
        Test-AdapterConfiguration @{ lokiEndpoint = 'https://example.org/loki/api/v1/push'; lokiTokenEnvironment = 'MISSING_TEST_GOVERNANCE_SECRET' } | Should -BeFalse
    }
    It 'retries backend failure without leaking secrets' {
        Mock Invoke-WebRequest -ModuleName Grafana { throw 'SECRET-backend' }
        Mock Start-Sleep -ModuleName Grafana {}
        $result = Publish-Metrics @{ snapshot = (New-TestSnapshot); publicationFailures = 0 } @{ metricsEndpoint = 'https://example.org/metrics/job/governance'; retryCount = 2 }
        $result.success | Should -BeFalse
        ($result | ConvertTo-Json) | Should -Not -Match 'SECRET'
        Should -Invoke Invoke-WebRequest -ModuleName Grafana -Times 3 -Exactly
    }
    It 'publishes HTML and both Grafana capabilities in the same run' {
        $config = New-TestConfig
        $config.adapters += @{ id = 'grafana'; enabled = $true; module = 'Modules/Reporting/Adapters/Grafana/Grafana.psm1'; failurePolicy = 'Continue'; settings = @{ metricsEndpoint = 'https://example.org/metrics/job/governance'; lokiEndpoint = 'https://example.org/loki/api/v1/push' } }
        $hostContext = Initialize-ReportingHost $config $root
        Mock Invoke-WebRequest -ModuleName Grafana { @{ StatusCode = 204 } }
        $result = Invoke-ReportingAdapters $hostContext (New-TestSnapshot) "$TestDrive/combined.json"
        $result.results.Count | Should -Be 4
        @($result.results | Where-Object status -eq 'Failed').Count | Should -Be 0
        Should -Invoke Invoke-WebRequest -ModuleName Grafana -Times 2 -Exactly
    }
    It 'recovers from a transient failure with a bounded retry' {
        # Count transport attempts inside the adapter's scope.
        InModuleScope Grafana { $script:attempts = 0 }
        Mock Invoke-WebRequest -ModuleName Grafana { $script:attempts++; if ($script:attempts -eq 1) { throw 'transient' }; @{ StatusCode = 204 } }
        Mock Start-Sleep -ModuleName Grafana {}
        (Publish-Metrics @{ snapshot = (New-TestSnapshot); publicationFailures = 0 } @{ metricsEndpoint = 'https://example.org/metrics/job/governance'; retryCount = 1 }).success | Should -BeTrue
        Should -Invoke Invoke-WebRequest -ModuleName Grafana -Times 2 -Exactly
    }
    It 'does not retry permanent authentication errors' {
        Mock Invoke-WebRequest -ModuleName Grafana {
            $exception = [Exception]::new('private backend message')
            $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 401 })
            throw $exception
        }
        Mock Start-Sleep -ModuleName Grafana {}
        (Publish-Metrics @{ snapshot = (New-TestSnapshot); publicationFailures = 0 } @{ metricsEndpoint = 'https://example.org/metrics/job/governance' }).success | Should -BeFalse
        Should -Invoke Invoke-WebRequest -ModuleName Grafana -Times 1 -Exactly
        Should -Invoke Start-Sleep -ModuleName Grafana -Times 0 -Exactly
    }
    It 'publishes with environment authentication and disables redirects' {
        $env:TEST_GOVERNANCE_TOKEN = 'synthetic-token'
        try {
            Mock Invoke-WebRequest -ModuleName Grafana {
                $Headers.Authorization | Should -Be 'Bearer synthetic-token'
                return @{ StatusCode = 204 }
            }
            $result = Publish-Events @(ConvertTo-ReportingEvents (New-TestSnapshot)) @{ lokiEndpoint = 'https://example.org/loki/api/v1/push'; lokiTokenEnvironment = 'TEST_GOVERNANCE_TOKEN' }
            $result.success | Should -BeTrue
            Should -Invoke Invoke-WebRequest -ModuleName Grafana -Times 1 -ParameterFilter { $MaximumRedirection -eq 0 -and $Method -eq 'Post' }
        }
        finally { Remove-Item Env:TEST_GOVERNANCE_TOKEN }
    }
}
