BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/Reporting/Adapters/Grafana/RemoteWrite.psm1" -Force
}

Describe 'Remote-write wire encoding' {
    # Reference vectors independently assembled with Python struct.pack('<d') and
    # the published prometheus.WriteRequest protobuf tags / raw Snappy specification.
    It 'encodes a short literal, fixed64 sample and zero timestamp' {
        $bytes = ConvertTo-RemoteWritePayload -Metrics 'governance_x 1' -TimestampMilliseconds 0 -Job x
        [Convert]::ToBase64String($bytes) | Should -Be 'M8gKMQoYCghfX25hbWVfXxIMZ292ZXJuYW5jZV94CggKA2pvYhIBeBILCQAAAAAAAPA/EAA='
    }
    It 'encodes sorted labels, extended literal length and a millisecond timestamp' {
        $bytes = ConvertTo-RemoteWritePayload -Metrics 'governance_branch_decisions{decision="Stale"} 3' -TimestampMilliseconds 1767225600000
        [Convert]::ToBase64String($bytes) | Should -Be 'Y/BiCmEKJwoIX19uYW1lX18SG2dvdmVybmFuY2VfYnJhbmNoX2RlY2lzaW9ucwoRCghkZWNpc2lvbhIFU3RhbGUKEQoDam9iEgpnb3Zlcm5hbmNlEhAJAAAAAAAACEAQgNDqtrcz'
    }
    It 'rejects arbitrary metric labels and invalid samples' {
        { ConvertTo-RemoteWritePayload -Metrics 'governance_x{branch="private"} 1' -TimestampMilliseconds 0 } | Should -Throw
        { ConvertTo-RemoteWritePayload -Metrics 'governance_x NaN' -TimestampMilliseconds 0 } | Should -Throw
        { ConvertTo-RemoteWritePayload -Metrics 'governance_x 1' -TimestampMilliseconds -1 } | Should -Throw
    }
    It 'is deterministic and independent of current number formatting culture' {
        $previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            $first = ConvertTo-RemoteWritePayload -Metrics 'governance_x 1.5' -TimestampMilliseconds 42
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
            $second = ConvertTo-RemoteWritePayload -Metrics 'governance_x 1.5' -TimestampMilliseconds 42
            [Convert]::ToBase64String($first) | Should -Be ([Convert]::ToBase64String($second))
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture }
    }
}
