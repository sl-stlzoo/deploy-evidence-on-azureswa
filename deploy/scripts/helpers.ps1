# =============================================================================
# helpers.ps1 — Shared utilities for Evidence.dev → Azure SWA deployment
# =============================================================================
# Dot-source this file from any script:  . "$PSScriptRoot\helpers.ps1"
# =============================================================================

# ── Colour-coded console output ───────────────────────────────────────────────

function Write-Step   { param([string]$Msg) Write-Host "`n▶  $Msg" -ForegroundColor Cyan }
function Write-OK     { param([string]$Msg) Write-Host "   ✔  $Msg" -ForegroundColor Green }
function Write-Warn   { param([string]$Msg) Write-Host "   ⚠  $Msg" -ForegroundColor Yellow }
function Write-Fail   { param([string]$Msg) Write-Host "   ✖  $Msg" -ForegroundColor Red }
function Write-Info   { param([string]$Msg) Write-Host "   ℹ  $Msg" -ForegroundColor Gray }
function Write-Banner {
    param([string]$Title)
    $line = "─" * ($Title.Length + 6)
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host "   $Title" -ForegroundColor White
    Write-Host "$line`n" -ForegroundColor DarkCyan
}

# ── Environment helpers ───────────────────────────────────────────────────────

<#
.SYNOPSIS Loads a .env file into the current process environment.
.DESCRIPTION Parses KEY=VALUE lines, ignores comments (#) and blanks.
             Already-set variables are NOT overwritten unless -Force is used.
#>
function Import-EnvFile {
    param(
        [string]$Path = ".env",
        [switch]$Force
    )

    if (-not (Test-Path $Path)) {
        Write-Fail "Env file not found: $Path"
        Write-Info  "Copy .env.example → .env and populate it, then re-run."
        exit 1
    }

    $loaded = 0
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                $key   = $parts[0].Trim()
                $value = $parts[1].Trim().Trim('"').Trim("'")
                if ($Force -or -not [System.Environment]::GetEnvironmentVariable($key)) {
                    [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
                    $loaded++
                }
            }
        }
    }
    Write-OK "Loaded $loaded variable(s) from $Path"
}

<#
.SYNOPSIS Writes/updates a KEY=VALUE pair in a .env file.
#>
function Set-EnvFileLine {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )

    $content = if (Test-Path $Path) { Get-Content $Path } else { @() }
    $updated  = $false
    $newLines = $content | ForEach-Object {
        if ($_ -match "^$Key\s*=") {
            "$Key=$Value"
            $updated = $true
        } else { $_ }
    }
    if (-not $updated) { $newLines += "$Key=$Value" }
    $newLines | Set-Content $Path
    [System.Environment]::SetEnvironmentVariable($Key, $Value, 'Process')
}

<#
.SYNOPSIS Returns env var value or exits with a clear message if unset/empty.
#>
function Require-EnvVar {
    param([string]$Name, [string]$Hint = "")
    $val = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($val)) {
        Write-Fail "Required env var '$Name' is not set."
        if ($Hint) { Write-Info $Hint }
        exit 1
    }
    return $val
}

<#
.SYNOPSIS Returns env var or a default value (no exit).
#>
function Get-EnvOrDefault {
    param([string]$Name, [string]$Default = "")
    $val = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

# ── CLI helpers ───────────────────────────────────────────────────────────────

<#
.SYNOPSIS Returns $true if a command exists on PATH.
#>
function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS Runs an az CLI command, throws if exit code != 0.
         Suppresses noisy 'WARNING: ...' lines from stderr.
#>
function Invoke-Az {
    param([string[]]$Args)
    $result = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errText = ($result | Where-Object { $_ -notmatch '^WARNING:' }) -join "`n"
        throw "az $($Args -join ' ') failed (exit $LASTEXITCODE):`n$errText"
    }
    return $result
}

<#
.SYNOPSIS Prompts for confirmation unless -NonInteractive is set in env.
#>
function Confirm-Step {
    param([string]$Message)
    if ([System.Environment]::GetEnvironmentVariable('DEPLOY_NON_INTERACTIVE') -eq 'true') {
        return $true
    }
    $answer = Read-Host "$Message [y/N]"
    return ($answer -match '^[Yy]')
}
