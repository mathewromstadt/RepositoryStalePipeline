#Requires -Version 7.0
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/RemoteWrite.psm1"

function Resolve-GrafanaSettings {
    param([System.Collections.IDictionary]$Settings)
    $resolved = @{}
    foreach ($key in $Settings.Keys) { $resolved[$key] = $Settings[$key] }
    foreach ($kind in @('loki', 'metrics')) {
        $reference = "${kind}EndpointEnvironment"
        $endpoint = "${kind}Endpoint"
        if ($resolved.ContainsKey($reference)) {
            if ($resolved.ContainsKey($endpoint) -or $resolved[$reference] -notmatch '^[A-Z_][A-Z0-9_]*$') {
                throw 'Invalid endpoint configuration.'
            }
            $resolved[$endpoint] = [Environment]::GetEnvironmentVariable($resolved[$reference])
            $resolved.Remove($reference)
            if ([string]::IsNullOrWhiteSpace($resolved[$endpoint])) { throw 'Missing endpoint environment variable.' }
        }
    }
    if ($resolved.ContainsKey('lokiEndpoint')) {
        $uri = $null
        if (-not [uri]::TryCreate($resolved.lokiEndpoint, [UriKind]::Absolute, [ref]$uri)) { throw 'Invalid Loki endpoint.' }
        # Accept a backend base URL or the complete push URL. Other paths remain invalid.
        if ($uri.AbsolutePath -eq '/' -and -not $uri.Query -and -not $uri.Fragment) {
            $resolved.lokiEndpoint = $resolved.lokiEndpoint.TrimEnd('/') + '/loki/api/v1/push'
        }
    }
    if (-not $resolved.ContainsKey('metricsProtocol')) { $resolved.metricsProtocol = 'Pushgateway' }
    if ($resolved.metricsProtocol -eq 'RemoteWrite' -and $resolved.ContainsKey('metricsEndpoint')) {
        $uri = $null
        if (-not [uri]::TryCreate($resolved.metricsEndpoint, [UriKind]::Absolute, [ref]$uri)) { throw 'Invalid metrics endpoint.' }
        if ($uri.AbsolutePath -eq '/' -and -not $uri.Query -and -not $uri.Fragment) {
            $resolved.metricsEndpoint = $resolved.metricsEndpoint.TrimEnd('/') + '/api/prom/push'
        }
    }
    return $resolved
}

function Test-AdapterConfiguration {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Settings)
    try { $Settings = Resolve-GrafanaSettings $Settings }
    catch { return $false }
    $allowed = @('metricsEndpoint', 'lokiEndpoint', 'metricsTokenEnvironment', 'lokiTokenEnvironment', 'retryCount',
        'metricsUsernameEnvironment', 'lokiUsernameEnvironment', 'metricsProtocol', 'metricsJob')
    foreach ($key in $Settings.Keys) { if ($key -notin $allowed) { return $false } }
    if (-not $Settings.Contains('metricsEndpoint') -and -not $Settings.Contains('lokiEndpoint')) { return $false }
    if ($Settings.metricsProtocol -notin @('Pushgateway', 'RemoteWrite')) { return $false }
    if ($Settings.Contains('metricsJob') -and $Settings.metricsJob -notmatch '^[a-zA-Z0-9_-]{1,64}$') { return $false }
    foreach ($kind in @('metrics', 'loki')) {
        if ($Settings.Contains("${kind}Endpoint")) {
            $uri = $null
            if (-not [uri]::TryCreate($Settings["${kind}Endpoint"], [UriKind]::Absolute, [ref]$uri)) { return $false }
            if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $false }
            if ($kind -eq 'metrics') {
                if ($Settings.metricsProtocol -eq 'Pushgateway' -and $uri.AbsolutePath -notmatch '^/metrics/job/[a-zA-Z0-9_-]+$') { return $false }
                if ($Settings.metricsProtocol -eq 'RemoteWrite' -and $uri.AbsolutePath -notin @('/api/prom/push', '/api/v1/write', '/api/v1/push')) { return $false }
            }
            if ($kind -eq 'loki' -and $uri.AbsolutePath -ne '/loki/api/v1/push') { return $false }
        }
        if ($Settings.Contains("${kind}TokenEnvironment")) {
            $name = $Settings["${kind}TokenEnvironment"]
            if ($name -notmatch '^[A-Z_][A-Z0-9_]*$' -or [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { return $false }
            if ([Environment]::GetEnvironmentVariable($name) -match '[\r\n]|^\$\(') { return $false }
        }
        if ($Settings.Contains("${kind}UsernameEnvironment")) {
            $name = $Settings["${kind}UsernameEnvironment"]
            if ($name -notmatch '^[A-Z_][A-Z0-9_]*$' -or -not $Settings.Contains("${kind}TokenEnvironment")) { return $false }
            $username = [Environment]::GetEnvironmentVariable($name)
            if ([string]::IsNullOrWhiteSpace($username) -or $username -match '[:\r\n]' -or $username -match '^\$\(') { return $false }
        }
    }
    if ($Settings.Contains('retryCount') -and ($Settings.retryCount -isnot [long] -and $Settings.retryCount -isnot [int] -or $Settings.retryCount -lt 0 -or $Settings.retryCount -gt 3)) { return $false }
    return $true
}

function Send-GrafanaPayload {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Settings, [ValidateSet('metrics', 'loki')][string]$Kind,
        [object]$Body, [string]$ContentType, [string]$Method)
    $ErrorActionPreference = 'Stop'
    if (-not (Test-AdapterConfiguration $Settings)) { return @{ success = $false } }
    try { $Settings = Resolve-GrafanaSettings $Settings }
    catch { return @{ success = $false } }
    if (-not $Settings.Contains("${Kind}Endpoint")) { return @{ success = $true } }
    $headers = @{}
    if ($Settings.Contains("${Kind}TokenEnvironment")) {
        $token = [Environment]::GetEnvironmentVariable($Settings["${Kind}TokenEnvironment"])
        if ($Settings.Contains("${Kind}UsernameEnvironment")) {
            $username = [Environment]::GetEnvironmentVariable($Settings["${Kind}UsernameEnvironment"])
            $headers.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${username}:$token"))
        }
        else { $headers.Authorization = 'Bearer ' + $token }
    }
    if ($Kind -eq 'metrics' -and $Settings.metricsProtocol -eq 'RemoteWrite') {
        $headers['Content-Encoding'] = 'snappy'
        $headers['X-Prometheus-Remote-Write-Version'] = '0.1.0'
        $headers['User-Agent'] = 'GovernanceReporting/1.0'
    }
    $bodyBytes = if ($Body -is [byte[]]) { $Body } else { [Text.Encoding]::UTF8.GetBytes([string]$Body) }
    $retryCount = if ($Settings.Contains('retryCount')) { [int]$Settings.retryCount } else { 2 }
    try {
        for ($attempt = 0; $attempt -le $retryCount; $attempt++) {
            try {
                # No redirects: never forward credentials to an unexpected destination.
                $httpResponse = Invoke-WebRequest -Uri $Settings["${Kind}Endpoint"] -Method $Method -Headers $headers -Body ([byte[]]$bodyBytes) -ContentType $ContentType -TimeoutSec 30 -MaximumRedirection 0 -ErrorAction Stop -Verbose:$false -Debug:$false
                return @{ success = $true; httpStatusCode = [int]$httpResponse.StatusCode; attempts = $attempt + 1 }
            }
            catch {
                $status = 0
                if ($_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
                if ($attempt -eq $retryCount -or ($status -ne 0 -and $status -ne 429 -and $status -lt 500)) {
                    # Fixed categories only: never expose response bodies, URLs, or exception messages.
                    $diagnostic = switch ($status) {
                        0 { 'TransportFailure' }
                        400 { 'RequestRejected' }
                        401 { 'Unauthorized' }
                        403 { 'Forbidden' }
                        404 { 'EndpointNotFound' }
                        413 { 'PayloadTooLarge' }
                        429 { 'RateLimited' }
                        { $_ -ge 500 } { 'DestinationUnavailable' }
                        default { 'HttpFailure' }
                    }
                    return @{ success = $false; httpStatusCode = $status; attempts = $attempt + 1; diagnosticCode = $diagnostic }
                }
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
            }
        }
    }
    finally { $headers.Clear() }
    return @{ success = $false }
}

function ConvertTo-GovernanceMetrics {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Payload)
    $snapshot = $Payload.snapshot
    $summary = $snapshot.results.summary
    $lines = [Collections.Generic.List[string]]::new()
    $mapping = @{
        repositories = 'repositories'; healthy_repositories = 'healthyRepositories'
        attention_repositories = 'attentionRepositories'; execution_duration_seconds = 'durationSeconds'
        discovery_failures = 'discoveryFailures'; evaluation_failures = 'evaluationFailures'
    }
    foreach ($name in ($mapping.Keys | Sort-Object)) {
        $value = ([double]$summary[$mapping[$name]]).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        $lines.Add("# TYPE governance_$name gauge")
        $lines.Add("governance_$name $value")
    }
    $lines.Add('# TYPE governance_branch_decisions gauge')
    # Fixed enumeration is the entire label vocabulary; names and run IDs never become labels.
    foreach ($decision in @('Protected', 'ActivePR', 'UnknownCommitDate', 'Active', 'Stale')) {
        $count = @($snapshot.results.branches | Where-Object decision -eq $decision).Count
        $lines.Add("governance_branch_decisions{decision=`"$decision`"} $count")
    }
    $lines.Add('# TYPE governance_adapter_publication_failures gauge')
    $lines.Add("governance_adapter_publication_failures $($Payload.publicationFailures)")
    $lines.Add('# TYPE governance_execution_failed gauge')
    $lines.Add("governance_execution_failed $([int]($snapshot.evaluationStatus -ne 'Succeeded'))")
    if ($snapshot.evaluationStatus -eq 'Succeeded') {
        $seconds = ([DateTimeOffset]::Parse($snapshot.timestamp)).ToUnixTimeSeconds()
        $lines.Add('# TYPE governance_last_successful_evaluation_timestamp_seconds gauge')
        $lines.Add("governance_last_successful_evaluation_timestamp_seconds $seconds")
    }
    return ($lines -join "`n") + "`n"
}

function ConvertTo-LokiPayload {
    [CmdletBinding()]
    param([object[]]$Events)
    $values = @($Events | ForEach-Object {
        $ticks = ([DateTimeOffset]::Parse($_.timestamp)).UtcTicks - [DateTimeOffset]::UnixEpoch.UtcTicks
        ,@(([string]([long]$ticks * 100)), ($_ | ConvertTo-Json -Depth 40 -Compress))
    })
    return @{ streams = @(@{ stream = @{ application = 'governance' }; values = $values }) } | ConvertTo-Json -Depth 45 -Compress
}

function Publish-Snapshot {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Payload, [System.Collections.IDictionary]$Settings)
    # Delivery is implemented by the optional event and metric capabilities.
    return @{ success = ($Payload.domain -eq 'branch-lifecycle' -and (Test-AdapterConfiguration $Settings)) }
}

function Publish-Events {
    [CmdletBinding()]
    param([object[]]$Payload, [System.Collections.IDictionary]$Settings)
    if ($Payload.Count -eq 0) { return @{ success = $true } }
    return Send-GrafanaPayload -Settings $Settings -Kind loki -Body (ConvertTo-LokiPayload $Payload) -ContentType 'application/json' -Method Post
}

function Publish-Metrics {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Payload, [System.Collections.IDictionary]$Settings)
    if (-not (Test-AdapterConfiguration $Settings)) { return @{ success = $false } }
    $Settings = Resolve-GrafanaSettings $Settings
    if (-not $Settings.Contains('metricsEndpoint')) { return @{ success = $true } }
    if ($Settings.metricsProtocol -eq 'RemoteWrite') {
        $job = if ($Settings.Contains('metricsJob')) { $Settings.metricsJob } else { 'governance' }
        $timestamp = ([DateTimeOffset]::Parse($Payload.snapshot.timestamp)).ToUnixTimeMilliseconds()
        $body = ConvertTo-RemoteWritePayload -Metrics (ConvertTo-GovernanceMetrics $Payload) -TimestampMilliseconds $timestamp -Job $job
        return Send-GrafanaPayload -Settings $Settings -Kind metrics -Body $body -ContentType 'application/x-protobuf' -Method Post
    }
    # PUT atomically replaces the stable job grouping; retrying does not add counters.
    return Send-GrafanaPayload -Settings $Settings -Kind metrics -Body (ConvertTo-GovernanceMetrics $Payload) -ContentType 'text/plain; version=0.0.4; charset=utf-8' -Method Put
}

Export-ModuleMember -Function Test-AdapterConfiguration, Publish-Snapshot, Publish-Events, Publish-Metrics, ConvertTo-GovernanceMetrics, ConvertTo-LokiPayload
