#Requires -Version 7.0
Set-StrictMode -Version Latest

function Write-UnsignedVarint {
    param([IO.Stream]$Stream, [ulong]$Value)
    while ($Value -ge 128) {
        $Stream.WriteByte([byte](($Value -band 127) -bor 128))
        $Value = $Value -shr 7
    }
    $Stream.WriteByte([byte]$Value)
}

function Write-ProtobufBytes {
    param([IO.Stream]$Stream, [int]$Field, [byte[]]$Bytes)
    Write-UnsignedVarint $Stream (($Field -shl 3) -bor 2)
    Write-UnsignedVarint $Stream $Bytes.Length
    $Stream.Write($Bytes, 0, $Bytes.Length)
}

function ConvertTo-RemoteWritePayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Metrics,
        [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long]$TimestampMilliseconds,
        [ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')][string]$Job = 'governance')
    # Encode only the bounded gauge vocabulary emitted by ConvertTo-GovernanceMetrics.
    # Wire schema: prometheus.WriteRequest -> TimeSeries(labels, samples).
    $request = [IO.MemoryStream]::new()
    try {
        foreach ($line in ($Metrics -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            if ($line -cnotmatch '^(governance_[a-z_]+)(?:\{decision="(Protected|ActivePR|UnknownCommitDate|Active|Stale)"\})? ([0-9.eE+-]+)$') {
                throw 'Invalid governance metric sample.'
            }
            $labels = @{ __name__ = $Matches[1]; job = $Job }
            if ($Matches[2]) { $labels.decision = $Matches[2] }
            $value = [double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture)
            if ([double]::IsInfinity($value) -or [double]::IsNaN($value)) { throw 'Invalid governance metric value.' }
            $series = [IO.MemoryStream]::new()
            try {
                [string[]]$names = @($labels.Keys)
                [Array]::Sort($names, [StringComparer]::Ordinal)
                foreach ($name in $names) {
                    $label = [IO.MemoryStream]::new()
                    try {
                        Write-ProtobufBytes $label 1 ([Text.Encoding]::UTF8.GetBytes($name))
                        Write-ProtobufBytes $label 2 ([Text.Encoding]::UTF8.GetBytes($labels[$name]))
                        Write-ProtobufBytes $series 1 $label.ToArray()
                    }
                    finally { $label.Dispose() }
                }
                $sample = [IO.MemoryStream]::new()
                try {
                    $sample.WriteByte(9) # double value, field 1, fixed64 wire type
                    $doubleBytes = [BitConverter]::GetBytes($value)
                    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($doubleBytes) }
                    $sample.Write($doubleBytes, 0, 8)
                    $sample.WriteByte(16) # int64 timestamp, field 2, varint wire type
                    Write-UnsignedVarint $sample $TimestampMilliseconds
                    Write-ProtobufBytes $series 2 $sample.ToArray()
                }
                finally { $sample.Dispose() }
                Write-ProtobufBytes $request 1 $series.ToArray()
            }
            finally { $series.Dispose() }
        }
        # Raw Snappy block, using a literal-only encoding. Valid Snappy with no native
        # dependency; the small fixed set of aggregate gauges does not need compression.
        $bytes = $request.ToArray()
        $snappy = [IO.MemoryStream]::new()
        try {
            Write-UnsignedVarint $snappy $bytes.Length
            if ($bytes.Length -gt 0) {
                $lengthMinusOne = $bytes.Length - 1
                if ($lengthMinusOne -lt 60) { $snappy.WriteByte([byte]($lengthMinusOne -shl 2)) }
                else {
                    $lengthBytes = [Collections.Generic.List[byte]]::new()
                    do {
                        $lengthBytes.Add([byte]($lengthMinusOne -band 255))
                        $lengthMinusOne = $lengthMinusOne -shr 8
                    } while ($lengthMinusOne -gt 0)
                    $snappy.WriteByte([byte]((59 + $lengthBytes.Count) -shl 2))
                    foreach ($item in $lengthBytes) { $snappy.WriteByte($item) }
                }
                $snappy.Write($bytes, 0, $bytes.Length)
            }
            return ,$snappy.ToArray()
        }
        finally { $snappy.Dispose() }
    }
    finally { $request.Dispose() }
}

Export-ModuleMember -Function ConvertTo-RemoteWritePayload
