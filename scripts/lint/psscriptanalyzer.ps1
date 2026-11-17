#Requires -Version 7.4
<#
.SYNOPSIS
    Runs PSScriptAnalyzer on the given files for scripts/lint/psscriptanalyzer.sh.
.DESCRIPTION
    Installs the pinned PSScriptAnalyzer from the PowerShell Gallery unless that
    version is present, then analyzes each file with the repository's
    PSScriptAnalyzerSettings.psd1, when present. Findings are annotated on the
    PR and, with -SarifFile, written as SARIF. Errors and warnings fail the run;
    information findings are reported only.
.PARAMETER Version
    The exact PSScriptAnalyzer version to use.
.PARAMETER SarifFile
    Also write the findings to this SARIF file.
.PARAMETER PathList
    A file listing the repository-relative files to analyze, NUL-separated.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Version,

    [Parameter(Mandatory)]
    [string] $PathList,

    [string] $SarifFile
)

$ErrorActionPreference = 'Stop'
$Path = [IO.File]::ReadAllText($PathList).Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries)

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object { $_.Version -eq [version] $Version })) {
    Install-PSResource -Name PSScriptAnalyzer -Version $Version -Repository PSGallery -TrustRepository -Scope CurrentUser -Quiet
}
Import-Module -Name PSScriptAnalyzer -RequiredVersion $Version

$analyzerArgs = @{}
if (Test-Path -LiteralPath PSScriptAnalyzerSettings.psd1) {
    $analyzerArgs.Settings = (Resolve-Path -LiteralPath PSScriptAnalyzerSettings.psd1).Path
}
# -Path expands wildcards: escape them, so deploy[1].ps1 means that file.
$findings = @(foreach ($file in $Path) {
        Invoke-ScriptAnalyzer -Path ([WildcardPattern]::Escape($file)) @analyzerArgs
    })

# SARIF levels by PSScriptAnalyzer severity, and workflow commands by level.
$levels = @{ ParseError = 'error'; Error = 'error'; Warning = 'warning'; Information = 'note' }
$commands = @{ error = 'error'; warning = 'warning'; note = 'notice' }

function ConvertTo-CommandValue {
    param([string] $Value, [switch] $Property)
    $escaped = $Value.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Property) { $escaped = $escaped.Replace(':', '%3A').Replace(',', '%2C') }
    $escaped
}

$annotations = [Collections.Generic.List[string]]::new()
$results = foreach ($finding in $findings) {
    $file = [IO.Path]::GetRelativePath($PWD.Path, $finding.ScriptPath).Replace('\', '/')
    # SARIF wants a URI: percent-encode each segment (# or % in a file name).
    $uri = ($file.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $level = $levels["$($finding.Severity)"]
    $line = [Math]::Max(1, $finding.Line)
    $column = [Math]::Max(1, $finding.Column)
    $properties = "file=$(ConvertTo-CommandValue $file -Property),line=$line,col=$column," +
        "title=$(ConvertTo-CommandValue $finding.RuleName -Property)"
    $annotations.Add("::$($commands[$level]) ${properties}::$(ConvertTo-CommandValue $finding.Message)")
    [ordered]@{
        ruleId    = $finding.RuleName
        level     = $level
        message   = @{ text = $finding.Message }
        locations = @(@{ physicalLocation = @{
                    artifactLocation = @{ uri = $uri }
                    region           = @{ startLine = $line; startColumn = $column }
                }
            })
    }
}
$annotations

if ($SarifFile) {
    $rules = @($findings | ForEach-Object RuleName | Sort-Object -Unique | ForEach-Object { @{ id = $_ } })
    $driver = [ordered]@{
        name           = 'PSScriptAnalyzer'
        version        = $Version
        informationUri = 'https://github.com/PowerShell/PSScriptAnalyzer'
        rules          = $rules
    }
    $sarif = [ordered]@{
        '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
        version   = '2.1.0'
        runs      = @(@{ tool = @{ driver = $driver }; results = @($results) })
    }
    $sarif | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $SarifFile -Encoding utf8NoBOM
}

$failing = @($findings | Where-Object { $levels["$($_.Severity)"] -ne 'note' })
Write-Output "PSScriptAnalyzer $Version checked $($Path.Count) file(s): $($findings.Count) finding(s), $($failing.Count) failing."
exit [int] ($failing.Count -gt 0)
