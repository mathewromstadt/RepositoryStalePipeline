#Requires -Version 7.0
[CmdletBinding()]
param([string[]]$ForbiddenText = @())

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$failures = [System.Collections.Generic.List[string]]::new()

# Do not walk Git internals or generated output.
function Get-SourceFiles {
    param([string]$Directory)
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($item.PSIsContainer) {
            if ($item.Name -notin @('.git', '.state', 'reports')) {
                Get-SourceFiles -Directory $item.FullName
            }
        }
        elseif ($item.Name -ne 'TestResults.xml') { $item }
    }
}

$files = @(Get-SourceFiles -Directory $root)
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($root, $file.FullName)
    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($file.Extension -in @('.ps1', '.psm1', '.psd1')) {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in $parseErrors) {
            $failures.Add("PowerShell parse error: $relative, line $($parseError.Extent.StartLineNumber)")
        }
    }
    if ($file.Extension -eq '.json') {
        try { $null = $content | ConvertFrom-Json -Depth 100 }
        catch { $failures.Add("Invalid JSON: $relative") }
    }
    if ($content -match '(glc_[A-Za-z0-9+/=]{40,}|gh[pousr]_[A-Za-z0-9]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)') {
        $failures.Add("Potential credential material: $relative")
    }
    foreach ($forbidden in $ForbiddenText) {
        if ($forbidden -and $content.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $failures.Add("Forbidden identifier: $relative")
        }
    }
    if ($file.Extension -eq '.md') {
        foreach ($match in [regex]::Matches($content, '\[[^\]]+\]\(([^)]+)\)')) {
            $target = $match.Groups[1].Value
            if ($target -match '^(https?://|mailto:|#)') { continue }
            $target = ($target -split '#', 2)[0]
            if ($target -and -not (Test-Path -LiteralPath (Join-Path $file.DirectoryName $target))) {
                $failures.Add("Broken Markdown link: $relative -> $target")
            }
        }
    }
}

Import-Module PSScriptAnalyzer -MinimumVersion 1.24.0 -ErrorAction Stop
foreach ($file in $files | Where-Object Extension -in @('.ps1', '.psm1')) {
    foreach ($finding in Invoke-ScriptAnalyzer -Path $file.FullName -Severity Error) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName)
        $failures.Add("Analyzer error: $relative, $($finding.RuleName), line $($finding.Line)")
    }
}
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output $_ }
    throw "$($failures.Count) distribution checks failed."
}
Write-Output "Distribution checks passed for $($files.Count) source files."
