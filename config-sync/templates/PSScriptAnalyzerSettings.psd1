@{
    # Template - adapt per repo. Settings for PSScriptAnalyzer, which the shared
    # Lint workflow (lint-psscriptanalyzer) runs on the repository's *.ps1, *.psm1
    # and *.psd1 files. Errors and warnings fail the check; information findings
    # are annotated only. Based on DevSecNinja/windows-iso-maker's settings.

    # Start from the full built-in rule set, then tighten a few rules.
    IncludeDefaultRules = $true

    # ParseError must stay listed: without it, a script that doesn't parse passes.
    Severity = @('ParseError', 'Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Files are UTF-8 without a BOM (.editorconfig), the same on Linux and
        # Windows; non-ASCII characters in comments would trip this rule.
        'PSUseBOMForUnicodeEncodedFile',

        # PSScriptAnalyzer bug (as of 1.25.0): when a command has no parameter
        # set, this rule throws a NullReferenceException that aborts the whole
        # run, not just the finding. Re-enable it once
        # https://github.com/PowerShell/PSScriptAnalyzer/issues/1708 is fixed.
        'PSUseCorrectCasing'
    )

    Rules = @{
        PSUseApprovedVerbs = @{
            Enable = $true
        }

        # Comment-based help on every exported function.
        PSProvideCommentHelp = @{
            Enable                  = $true
            ExportedOnly            = $true
            BlockComment            = $true
            VSCodeSnippetCorrection = $false
            Placement               = 'begin'
        }

        # No aliases: full command names only.
        PSAvoidUsingCmdletAliases = @{
            Enable    = $true
            AllowList = @()
        }

        # Honour -WhatIf in functions that change state.
        PSUseShouldProcessForStateChangingFunctions = @{
            Enable = $true
        }

        # Syntax that runs on both Windows PowerShell 5.1 and PowerShell 7.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
