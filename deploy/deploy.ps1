<#
.SYNOPSIS
    One-liner deployment script — Evidence.dev → Azure Static Web Apps (Entra auth)

.DESCRIPTION
    Orchestrates the full deployment pipeline:
      Step 0  Prerequisite checks
      Step 1  Azure resource provisioning (idempotent)
      Step 2  Entra ID app registration (idempotent)
      Step 3  SWA auth/route configuration + GitHub Actions setup
      Step 4  Evidence.dev build + SWA CLI deployment

    All configuration is read from the .env file in this directory.
    Run `Copy-Item .env.example .env` and populate values before first run.

.PARAMETER EnvFile
    Path to the .env file. Defaults to deploy\.env (this directory).

.PARAMETER Steps
    Comma-separated list of steps to run (0,1,2,3,4). Default: all.
    Example: -Steps "3,4" to re-deploy without re-provisioning.

.PARAMETER SkipBuild
    Pass through to step 4: deploy existing build/ without rebuilding.

.PARAMETER Fix
    Pass through to step 0: attempt automatic prerequisite installs.

.EXAMPLE
    # Full deployment (one-liner from project root):
    .\deploy\deploy.ps1

    # Re-deploy only (skip provisioning):
    .\deploy\deploy.ps1 -Steps "4"

    # Fix missing tools then deploy:
    .\deploy\deploy.ps1 -Fix

    # Check prerequisites only:
    .\deploy\deploy.ps1 -Steps "0"
#>
[CmdletBinding()]
param(
    [string]  $EnvFile   = "$PSScriptRoot\.env",
    [string]  $Steps     = "0,1,2,3,4",
    [switch]  $SkipBuild,
    [switch]  $Fix
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── Bootstrap ─────────────────────────────────────────────────────────────────
. "$PSScriptRoot\scripts\helpers.ps1"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Evidence.dev  →  Azure Static Web Apps  (Entra Auth)  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$startTime   = Get-Date
$stepList    = $Steps -split ',' | ForEach-Object { $_.Trim() }

# ── Ensure .env file exists ───────────────────────────────────────────────────
if (-not (Test-Path $EnvFile)) {
    Write-Fail ".env file not found at: $EnvFile"
    Write-Info  "Create it from the example:"
    Write-Info  "  Copy-Item `"$PSScriptRoot\.env.example`" `"$PSScriptRoot\.env`""
    Write-Info  "  Then populate all required values and re-run."
    exit 1
}

Import-EnvFile -Path (Resolve-Path $EnvFile)

# ── Helper: run a step script and handle failures ─────────────────────────────
function Invoke-Step {
    param([string]$Number, [string]$Label, [scriptblock]$Action)
    if ($Number -notin $stepList) {
        Write-Info "Skipping step $Number ($Label)"
        return
    }
    try {
        & $Action
    } catch {
        Write-Host ""
        Write-Fail "Step $Number ($Label) failed with error:"
        Write-Host "  $_" -ForegroundColor Red
        Write-Host ""
        Write-Info "Fix the issue above, then resume from this step:"
        Write-Info "  .\deploy\deploy.ps1 -Steps `"$Number,$([string]::Join(',', ($stepList | Where-Object { [int]$_ -gt [int]$Number })))`""
        exit 1
    }
}

# ── Steps ─────────────────────────────────────────────────────────────────────
Invoke-Step '0' 'Prerequisites' {
    $fixSwitch = if ($Fix) { '-Fix' } else { '' }
    & "$PSScriptRoot\scripts\00-prerequisites.ps1" @(if ($Fix) { '-Fix' })
}

Invoke-Step '1' 'Azure Provisioning' {
    & "$PSScriptRoot\scripts\01-provision-azure.ps1" -EnvFile $EnvFile
    # Reload .env to pick up SWA_DEFAULT_HOSTNAME + SWA_DEPLOYMENT_TOKEN
    Import-EnvFile -Path (Resolve-Path $EnvFile) -Force
}

Invoke-Step '2' 'Entra App Registration' {
    & "$PSScriptRoot\scripts\02-register-app.ps1" -EnvFile $EnvFile
    Import-EnvFile -Path (Resolve-Path $EnvFile) -Force
}

Invoke-Step '3' 'SWA Configuration' {
    & "$PSScriptRoot\scripts\03-configure-swa.ps1" -EnvFile $EnvFile
}

Invoke-Step '4' 'Build & Deploy' {
    $buildSwitch = if ($SkipBuild) { @('-SkipBuild') } else { @() }
    & "$PSScriptRoot\scripts\04-build-deploy.ps1" -EnvFile $EnvFile @buildSwitch
}

# ── Done ──────────────────────────────────────────────────────────────────────
$elapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-OK   "Deployment pipeline complete in $([math]::Round($elapsed.TotalSeconds))s"

$hostname = [System.Environment]::GetEnvironmentVariable('SWA_DEFAULT_HOSTNAME')
if ($hostname) {
    Write-Host ""
    Write-Host "  🌐  https://$hostname" -ForegroundColor White
    Write-Host ""
}

Write-Info "Next steps:"
Write-Info "  1. Verify login at the URL above (Entra credentials required)."
Write-Info "  2. Commit .github/workflows/azure-static-web-apps-deploy.yml for CI/CD."
Write-Info "  3. Optionally add AZURE_STATIC_WEB_APPS_API_TOKEN to GitHub secrets."
Write-Info "  4. See README.md for Key Vault migration and custom domain setup."
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
