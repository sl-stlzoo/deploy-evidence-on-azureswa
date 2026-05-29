<#
.SYNOPSIS
    One-liner teardown — removes all resources created by deploy.ps1

.DESCRIPTION
    Reverses the full deployment pipeline in safe dependency order:

      Step 10  Remove generated files from the Evidence.dev project root
               (staticwebapp.config.json, api/, GitHub Actions workflow)
      Step 11  Delete the Entra ID app registration and service principal
               (also removes the GitHub Actions secret if gh CLI is present)
      Step 12  Delete the Azure Static Web App and resource group

    Each step prompts for confirmation before any destructive action.
    Use -Force to suppress all prompts (e.g. for automated workshop cleanup).

    All values are read from the same .env file used during deployment.
    After teardown, auto-generated secrets are blanked in .env — the file
    itself is preserved so the project can be redeployed from scratch.

.PARAMETER EnvFile
    Path to the .env file. Defaults to deploy\.env.

.PARAMETER Steps
    Comma-separated steps to run (10, 11, 12). Default: all.
    Example: -Steps "12" to remove only Azure resources.

.PARAMETER Force
    Skip all confirmation prompts. USE WITH CARE — deletions are permanent.

.PARAMETER KeepResourceGroup
    Delete the SWA resource but leave the Azure resource group intact.
    Passed through to step 12.

.EXAMPLE
    # Full teardown (one-liner from project root):
    .\deploy\teardown.ps1

    # Non-interactive full teardown (workshop/CI cleanup):
    .\deploy\teardown.ps1 -Force

    # Remove Azure resources only (skip file cleanup and Entra app):
    .\deploy\teardown.ps1 -Steps "12"

    # Delete SWA but keep the resource group:
    .\deploy\teardown.ps1 -Steps "12" -KeepResourceGroup

    # Remove only generated project files (no Azure changes):
    .\deploy\teardown.ps1 -Steps "10"
#>
[CmdletBinding()]
param(
    [string]$EnvFile           = "$PSScriptRoot\.env",
    [string]$Steps             = "10,11,12",
    [switch]$Force,
    [switch]$KeepResourceGroup
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── Bootstrap ─────────────────────────────────────────────────────────────────
. "$PSScriptRoot\scripts\helpers.ps1"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║   Evidence.dev SWA — TEARDOWN                           ║" -ForegroundColor Red
Write-Host "║   Removes all resources created by deploy.ps1            ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

$startTime = Get-Date
$stepList  = $Steps -split ',' | ForEach-Object { $_.Trim() }

# ── Ensure .env file exists ───────────────────────────────────────────────────
if (-not (Test-Path $EnvFile)) {
    Write-Fail ".env file not found at: $EnvFile"
    Write-Info  "The teardown scripts read resource names from .env."
    Write-Info  "If .env is gone, set values manually and re-run, or delete resources via the Azure portal."
    exit 1
}

Import-EnvFile -Path (Resolve-Path $EnvFile)

# ── Pre-flight summary ────────────────────────────────────────────────────────
$swaName       = Get-EnvOrDefault 'SWA_NAME'              '(not set)'
$resourceGroup = Get-EnvOrDefault 'AZURE_RESOURCE_GROUP'  '(not set)'
$clientId      = Get-EnvOrDefault 'AAD_CLIENT_ID'         '(not set)'
$appName       = Get-EnvOrDefault 'AAD_APP_NAME'          '(not set)'
$hostname      = Get-EnvOrDefault 'SWA_DEFAULT_HOSTNAME'  '(not set)'
$githubRepo    = Get-EnvOrDefault 'REPO_URL'       '(not set)'

Write-Host "  The following resources are targeted for removal:" -ForegroundColor Yellow
Write-Host ""

if ('10' -in $stepList) {
    Write-Host "  Step 10 — Generated project files" -ForegroundColor Cyan
    Write-Host "    static/staticwebapp.config.json" -ForegroundColor Gray
    Write-Host "    api/  (GetRoles Azure Function)" -ForegroundColor Gray
    Write-Host "    .github/workflows/azure-static-web-apps-deploy.yml" -ForegroundColor Gray
}
if ('11' -in $stepList) {
    Write-Host "  Step 11 — Entra ID app registration" -ForegroundColor Cyan
    Write-Host "    App : $appName  ($clientId)" -ForegroundColor Gray
    Write-Host "    GH  : AZURE_STATIC_WEB_APPS_API_TOKEN secret in $githubRepo" -ForegroundColor Gray
}
if ('12' -in $stepList) {
    if ($KeepResourceGroup) {
        Write-Host "  Step 12 — Azure SWA only (resource group kept)" -ForegroundColor Cyan
        Write-Host "    SWA : $swaName  ($hostname)" -ForegroundColor Gray
    } else {
        Write-Host "  Step 12 — Azure resource group + ALL contents" -ForegroundColor Cyan
        Write-Host "    RG  : $resourceGroup  ← ALL resources inside will be deleted" -ForegroundColor Red
        Write-Host "    SWA : $swaName  ($hostname)" -ForegroundColor Gray
    }
}

Write-Host ""

if (-not $Force) {
    $proceed = Confirm-Step "Proceed with teardown of the items listed above?"
    if (-not $proceed) {
        Write-Warn "Teardown cancelled by user."
        exit 0
    }
}

# ── Helper: run a teardown step ───────────────────────────────────────────────
function Invoke-TeardownStep {
    param([string]$Number, [string]$Label, [scriptblock]$Action)
    if ($Number -notin $stepList) {
        Write-Info "Skipping step $Number ($Label)"
        return
    }
    try {
        & $Action
    } catch {
        Write-Host ""
        Write-Fail "Step $Number ($Label) encountered an error:"
        Write-Host "  $_" -ForegroundColor Red
        Write-Host ""
        Write-Warn "Continuing to next step — review the error above."
        # Teardown continues on error (best-effort cleanup)
    }
}

# ── Steps (reverse order of deployment) ──────────────────────────────────────
$forceArgs = if ($Force) { @('-Force') } else { @() }

Invoke-TeardownStep '10' 'Remove generated project files' {
    & "$PSScriptRoot\scripts\10-remove-files.ps1" `
        -EnvFile $EnvFile `
        @forceArgs
}

Invoke-TeardownStep '11' 'Remove Entra app registration' {
    & "$PSScriptRoot\scripts\11-remove-entra-app.ps1" `
        -EnvFile $EnvFile `
        @forceArgs
}

Invoke-TeardownStep '12' 'Remove Azure resources' {
    $rgFlag = if ($KeepResourceGroup) { @('-KeepResourceGroup') } else { @() }
    & "$PSScriptRoot\scripts\12-remove-azure-resources.ps1" `
        -EnvFile $EnvFile `
        @forceArgs `
        @rgFlag
}

# ── Done ──────────────────────────────────────────────────────────────────────
$elapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-OK   "Teardown complete in $([math]::Round($elapsed.TotalSeconds))s"
Write-Host ""
Write-Info "What was preserved:"
Write-Info "  • deploy\.env (auto-generated secrets blanked, static config retained)"
Write-Info "  • All Evidence.dev source files (pages/, sources/, etc.)"
Write-Info "  • This deploy/ directory"
Write-Host ""
Write-Info "To redeploy from scratch, repopulate deploy\.env and run:"
Write-Info "  .\deploy\deploy.ps1"
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
