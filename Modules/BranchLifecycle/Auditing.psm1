
Set-StrictMode -Version Latest

function Write-LifecycleAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Record
    )

    $ErrorActionPreference = 'Stop'

    #region Directory Initialization

    $directory = Split-Path -Path $Path -Parent

    if (-not [string]::IsNullOrWhiteSpace($directory)) {

        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item `
                -ItemType Directory `
                -Path $directory `
                -Force | Out-Null
        }
    }

    #endregion

    #region Audit Serialization

    # Serialize the audit record as a single JSON line.
    # JSONL allows each event to be processed independently.

    $jsonRecord = $Record |
        ConvertTo-Json -Depth 12 -Compress

    #endregion

    #region Audit Persistence

    Add-Content `
        -LiteralPath $Path `
        -Value $jsonRecord `
        -Encoding utf8

    #endregion
}

Export-ModuleMember -Function Write-LifecycleAudit
