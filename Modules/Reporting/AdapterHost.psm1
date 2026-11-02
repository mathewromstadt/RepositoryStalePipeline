#Requires -Version 7.0
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Contracts/Contracts.psm1"

function Resolve-TrustedAdapterPath {
    param([string]$Root, [string]$RelativePath, [string[]]$TrustedModules)
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -notin $TrustedModules) { throw 'Untrusted adapter.' }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $path.StartsWith($rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Untrusted adapter.' }
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.Extension -ne '.psm1') { throw 'Invalid adapter module.' }
    # Reject symlinks/junctions in every ancestor, including the configured root.
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked adapter paths are not trusted.' }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
    return $path
}

function Initialize-ReportingHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][string]$Root)
    $ErrorActionPreference = 'Stop'
    $entries = [Collections.Generic.List[object]]::new()
    Assert-ReportingContract $Configuration -Kind configuration
    if (-not $Configuration.Contains('adapters') -or -not $Configuration.Contains('trustedModules')) { throw 'Invalid reporting configuration.' }
    $ids = @{}
    foreach ($registration in $Configuration.adapters) {
        if ($registration.enabled -isnot [bool] -or $registration.failurePolicy -notin @('Continue', 'FailPipeline') -or
            $registration.id -notmatch '^[a-z][a-z0-9-]{0,63}$' -or $ids.ContainsKey($registration.id)) { throw 'Invalid adapter registration.' }
        $ids[$registration.id] = $true
        if (-not $registration.enabled) { continue }
        $entry = @{ id = $registration.id; failurePolicy = $registration.failurePolicy; module = $null
            settings = $registration.settings; metadata = $null; code = 'ConfigurationFailure' }
        try {
            $path = Resolve-TrustedAdapterPath $Root $registration.module $Configuration.trustedModules
            $metadataPath = [IO.Path]::ChangeExtension($path, '.json')
            if ((Get-Item -LiteralPath $metadataPath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked metadata.' }
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-ReportingContract $metadata -Kind adapter
            if ($metadata.id -ne $registration.id -or $metadata.module -ne $registration.module -or '1.0' -notin $metadata.contractVersions) { throw 'Incompatible adapter.' }
            foreach ($field in $metadata.requiredConfiguration) {
                if (-not $registration.settings.Contains($field)) { throw 'Missing adapter setting.' }
            }
            $entry.metadata = $metadata
            $entry.code = 'InitializationFailure'
            $module = Import-Module -Name $path -Force -PassThru -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null
            $entry.module = $module
            foreach ($command in @('Test-AdapterConfiguration', 'Publish-Snapshot') + @($metadata.capabilities | Where-Object { $_ -ne 'Snapshot' } | ForEach-Object { "Publish-$_" })) {
                if (-not $module.ExportedCommands.ContainsKey($command)) { throw 'Missing adapter command.' }
            }
            $entry.code = 'ConfigurationFailure'
            $valid = & $module { param($settings) Test-AdapterConfiguration -Settings $settings } $registration.settings 3>$null 4>$null 5>$null 6>$null
            if ($valid -isnot [bool] -or -not $valid) { throw 'Invalid settings.' }
            $entry.code = 'Ready'
        }
        catch { # Retain only the fixed phase code, never arbitrary exception text.
            $entry.module = $null
        }
        $entries.Add($entry)
    }
    return @{ entries = $entries.ToArray(); root = [IO.Path]::GetFullPath($Root) }
}

function Invoke-ReportingAdapters {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$HostContext,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][string]$ResultsPath)
    $ErrorActionPreference = 'Stop'
    Assert-ReportingContract $Snapshot
    $results = [Collections.Generic.List[object]]::new()
    # Snapshot phase completes for all adapters before optional event/metric delivery.
    foreach ($capability in @('Snapshot', 'Events', 'Metrics')) {
        foreach ($entry in $HostContext.entries) {
            if ($capability -ne 'Snapshot' -and ($entry.code -ne 'Ready' -or $capability -notin $entry.metadata.capabilities)) { continue }
            $status = 'Failed'; $code = $entry.code
            $response = $null
            if ($code -eq 'Ready') {
                try {
                    $payload = switch ($capability) {
                        'Snapshot' { $Snapshot }
                        'Events' { ,@(ConvertTo-ReportingEvents $Snapshot -AdapterResults $results.ToArray()) }
                        'Metrics' { @{ snapshot = $Snapshot; publicationFailures = @($results | Where-Object status -eq 'Failed').Count } }
                    }
                    # Every invocation gets a detached copy; no evaluation or retention state is exposed.
                    $copy = ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -InputObject $payload -Depth 40)
                    $settings = ConvertFrom-Json -AsHashtable -InputObject ($entry.settings | ConvertTo-Json -Depth 20)
                    $response = & $entry.module {
                        param($command, $payload, $settings, $root)
                        Push-Location -LiteralPath $root
                        try { & $command -Payload $payload -Settings $settings }
                        finally { Pop-Location }
                    } "Publish-$capability" $copy $settings $HostContext.root 3>$null 4>$null 5>$null 6>$null
                    if ($response -isnot [System.Collections.IDictionary] -or $response.success -isnot [bool] -or -not $response.success) { throw 'Publication failed.' }
                    $status = 'Succeeded'; $code = 'Delivered'
                }
                catch { $code = 'PublicationFailure' }
            }
            $result = @{
                schemaVersion = '1.0'; runId = $Snapshot.runId; adapterId = $entry.id
                capability = $capability; timestamp = [datetime]::UtcNow.ToString('o')
                status = $status; code = $code; failurePolicy = $entry.failurePolicy
            }
            if ($response -is [System.Collections.IDictionary]) {
                # Optional transport diagnostics are constrained before they cross the log boundary.
                if ($response.Contains('httpStatusCode') -and $response.httpStatusCode -is [int] -and $response.httpStatusCode -ge 0 -and $response.httpStatusCode -le 599) {
                    $result.httpStatusCode = $response.httpStatusCode
                }
                if ($response.Contains('attempts') -and $response.attempts -is [int] -and $response.attempts -ge 1 -and $response.attempts -le 4) {
                    $result.attempts = $response.attempts
                }
                if ($response.Contains('diagnosticCode') -and $response.diagnosticCode -is [string] -and $response.diagnosticCode -cin @('TransportFailure', 'RequestRejected', 'Unauthorized', 'Forbidden', 'EndpointNotFound', 'PayloadTooLarge', 'RateLimited', 'DestinationUnavailable', 'HttpFailure')) {
                    $result.diagnosticCode = $response.diagnosticCode
                }
            }
            Assert-ReportingContract $result -Kind result
            $results.Add($result)
            if ($status -eq 'Failed') {
                $detail = if ($result.ContainsKey('diagnosticCode')) { $result.diagnosticCode } else { $code }
                $httpStatus = if ($result.ContainsKey('httpStatusCode')) { " HTTP $($result.httpStatusCode)." } else { '' }
                Write-Warning "Reporting adapter '$($entry.id)' capability '$capability' failed: $detail.$httpStatus See adapter-results.json."
            }
        }
    }
    $directory = Split-Path -Parent $ResultsPath
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    ConvertTo-Json -InputObject @($results.ToArray()) -Depth 20 | Set-Content -LiteralPath $ResultsPath -Encoding utf8
    return @{ results = $results.ToArray(); failPipeline = @($results | Where-Object { $_.status -eq 'Failed' -and $_.failurePolicy -eq 'FailPipeline' }).Count -gt 0 }
}

Export-ModuleMember -Function Initialize-ReportingHost, Invoke-ReportingAdapters
