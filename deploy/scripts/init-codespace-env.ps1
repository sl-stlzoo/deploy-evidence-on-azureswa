# =============================================================================
# init-codespace-env.ps1 — Bootstrap deploy/.env from Codespace secrets
# =============================================================================
# PURPOSE
#   GitHub Codespace secrets are injected as environment variables before the
#   container starts. This script reads those variables and writes them into
#   deploy/.env so that deploy.ps1 can find them via Import-EnvFile.
#
#   Import-EnvFile (in helpers.ps1) never overwrites already-set env vars
#   (unless -Force is passed), so Codespace secrets always take precedence
#   over whatever is written in .env. This script just ensures the file exists
#   with the right structure.
#
# WHEN TO RUN
#   • Automatically: called by .devcontainer/post-create.sh on first build
#   • Manually: run any time you add/change a Codespace secret and want to
#     reflect it in .env without rebuilding the container:
#       pwsh ./deploy/scripts/init-codespace-env.ps1
#
# WHAT IT DOES
#   1. Reads each known variable from the live process environment
#   2. Merges with any values already in deploy/.env (preserves auto-populated
#      secrets like AAD_CLIENT_SECRET from a previous deploy run)
#   3. Writes the merged result back to deploy/.env
#   4. Prints a status table — green = set, yellow = missing (needs action)
#
# WHAT IT DOES NOT DO
#   • Never reads or writes to any file outside deploy/.env
#   • Never calls Azure, GitHub, or any external service
#   • Never overwrites a value that is already set in deploy/.env unless the
#     Codespace secret provides a non-empty replacement
# =============================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── Resolve paths ─────────────────────────────────────────────────────────────
$deployDir   = $PSScriptRoot | Split-Path -Parent    # .../deploy/
$envFilePath = Join-Path $deployDir '.env'
$examplePath = Join-Path $deployDir '.env.example'

# ── Colour helpers (inline — helpers.ps1 not sourced here intentionally) ──────
function _step { Write-Host "`n▶  $args" -ForegroundColor Cyan }
function _ok   { Write-Host "   ✔  $args" -ForegroundColor Green }
function _warn { Write-Host "   ⚠  $args" -ForegroundColor Yellow }
function _info { Write-Host "   ℹ  $args" -ForegroundColor Gray }
function _fail { Write-Host "   ✖  $args" -ForegroundColor Red }

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Codespace Env Init — deploy/.env bootstrap            ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── Variable manifest ─────────────────────────────────────────────────────────
# Each entry:
#   Key        — environment variable / .env key name
#   Required   — must be non-empty before deploy.ps1 will succeed
#   AutoSet    — written back by deploy scripts; do NOT set as Codespace secret
#   Default    — value to use when not set and no user input expected
#   Secret     — true = displayed as masked in the status table
$variables = @(
    # ── Azure identity ─────────────────────────────────────────────────────
    @{ Key='AZURE_SUBSCRIPTION_ID'; Required=$true;  AutoSet=$false; Default='';        Secret=$false;
       Hint='az account show --query id -o tsv' }

    @{ Key='AZURE_TENANT_ID';       Required=$true;  AutoSet=$false; Default='';        Secret=$false;
       Hint='az account show --query tenantId -o tsv' }

    @{ Key='AZURE_LOCATION';        Required=$true;  AutoSet=$false; Default='eastus2'; Secret=$false;
       Hint='e.g. eastus2, westeurope, australiaeast' }

    @{ Key='AZURE_RESOURCE_GROUP';  Required=$true;  AutoSet=$false; Default='';        Secret=$false;
       Hint='e.g. rg-evidence-prod' }

    @{ Key='AZURE_RESOURCE_TAGS';   Required=$false; AutoSet=$false; Default='';        Secret=$false;
       Hint='optional: environment=prod,owner=team (comma-separated key=value)' }

    # ── SWA ────────────────────────────────────────────────────────────────
    @{ Key='SWA_NAME';              Required=$true;  AutoSet=$false; Default='';        Secret=$false;
       Hint='globally unique, e.g. swa-evidence-prod' }

    @{ Key='SWA_SKU';               Required=$false; AutoSet=$false; Default='Standard';Secret=$false;
       Hint='must be Standard for custom auth — scripts enforce this' }

    @{ Key='SWA_DEPLOYMENT_TOKEN';  Required=$false; AutoSet=$true;  Default='';        Secret=$true;
       Hint='auto-populated by 01-provision-azure.ps1 — do not set manually' }

    @{ Key='SWA_DEFAULT_HOSTNAME';  Required=$false; AutoSet=$true;  Default='';        Secret=$false;
       Hint='auto-populated by 01-provision-azure.ps1 — do not set manually' }

    # ── Entra / AAD ────────────────────────────────────────────────────────
    @{ Key='AAD_APP_NAME';          Required=$true;  AutoSet=$false; Default='';        Secret=$false;
       Hint='display name for the app registration, e.g. evidence-swa-prod' }

    @{ Key='AAD_CLIENT_ID';         Required=$false; AutoSet=$true;  Default='';        Secret=$false;
       Hint='auto-populated by 02-register-app.ps1 — do not set manually' }

    @{ Key='AAD_CLIENT_SECRET';     Required=$false; AutoSet=$true;  Default='';        Secret=$true;
       Hint='auto-populated by 02-register-app.ps1 — do not set manually' }

    @{ Key='EVIDENCE_ADMIN_USERS';  Required=$false; AutoSet=$false; Default='';        Secret=$false;
       Hint='optional: alice@example.com,bob@example.com' }

    @{ Key='EVIDENCE_ALLOWED_GROUP_ID'; Required=$false; AutoSet=$false; Default='';   Secret=$false;
       Hint='optional: Entra security group Object ID' }

    # ── GitHub ─────────────────────────────────────────────────────────────
    @{ Key='GITHUB_REPO_URL';       Required=$true;  AutoSet=$false; Default='';        Secret=$false;
       Hint='https://github.com/your-org/your-repo' }

    @{ Key='GITHUB_BRANCH';         Required=$false; AutoSet=$false; Default='main';    Secret=$false;
       Hint='branch to deploy from' }

    # ── Evidence.dev build ─────────────────────────────────────────────────
    @{ Key='NODE_VERSION';          Required=$false; AutoSet=$false; Default='20';      Secret=$false;
       Hint='Evidence.dev requires Node 18+' }

    @{ Key='EVIDENCE_PROJECT_ROOT'; Required=$false; AutoSet=$false; Default='..';      Secret=$false;
       Hint='relative path from deploy/ to Evidence.dev project root' }

    # ── Custom domain (future use) ─────────────────────────────────────────
    @{ Key='CUSTOM_DOMAIN_APEX';    Required=$false; AutoSet=$false; Default='';        Secret=$false;
       Hint='optional: e.g. example.com — out of scope for initial deploy' }

    @{ Key='CUSTOM_DOMAIN_SUBDOMAIN';Required=$false;AutoSet=$false; Default='';        Secret=$false;
       Hint='optional: e.g. analytics — out of scope for initial deploy' }

    @{ Key='CUSTOM_DOMAIN';         Required=$false; AutoSet=$false; Default='';        Secret=$false;
       Hint='optional: e.g. analytics.example.com — out of scope for initial deploy' }
)

# ── Read existing .env into a hashtable (preserve any already-saved values) ───
_step "Reading existing deploy/.env"
$existing = @{}

if (Test-Path $envFilePath) {
    Get-Content $envFilePath | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                $k = $parts[0].Trim()
                $v = $parts[1].Trim().Trim('"').Trim("'")
                $existing[$k] = $v
            }
        }
    }
    _ok "Found existing .env with $($existing.Count) entr(y/ies) — will merge."
} else {
    _info "No existing .env found — will create from scratch."
    # Seed from .env.example structure if available
    if (-not (Test-Path $examplePath)) {
        _warn ".env.example not found at $examplePath — creating minimal .env."
    }
}

# ── Merge: env var → existing .env → default ─────────────────────────────────
_step "Merging values: Codespace secrets → existing .env → defaults"

$resolved = [ordered]@{}
$missingRequired  = @()
$autoSetPresent   = @()

foreach ($v in $variables) {
    $key = $v.Key

    # Priority 1: live process environment (Codespace secrets / shell exports)
    $envVal = [System.Environment]::GetEnvironmentVariable($key)

    # Priority 2: existing .env file
    $fileVal = $existing[$key]

    # Priority 3: built-in default
    $default = $v.Default

    # Determine winning value
    $winner = if ($envVal)  { $envVal  }
              elseif ($fileVal) { $fileVal }
              elseif ($default) { $default }
              else              { '' }

    $resolved[$key] = $winner

    # Track state for status table
    if ($v.AutoSet) {
        if ($winner) { $autoSetPresent += $key }
        # AutoSet vars being blank is expected on first run — not a warning
    } elseif ($v.Required -and -not $winner) {
        $missingRequired += $key
    }
}

# ── Write .env file ───────────────────────────────────────────────────────────
_step "Writing deploy/.env"

$lines = @(
    "# ============================================================================="
    "# deploy/.env — generated by init-codespace-env.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC"
    "# DO NOT COMMIT — this file is gitignored."
    "# To regenerate: pwsh ./deploy/scripts/init-codespace-env.ps1"
    "# ============================================================================="
    ""
)

# Group variables into sections matching .env.example for readability
$sections = [ordered]@{
    'Azure Subscription & Identity' = @('AZURE_SUBSCRIPTION_ID','AZURE_TENANT_ID','AZURE_LOCATION','AZURE_RESOURCE_GROUP','AZURE_RESOURCE_TAGS')
    'Azure Static Web App'          = @('SWA_NAME','SWA_SKU','SWA_DEPLOYMENT_TOKEN','SWA_DEFAULT_HOSTNAME')
    'Entra ID App Registration'     = @('AAD_APP_NAME','AAD_CLIENT_ID','AAD_CLIENT_SECRET','EVIDENCE_ADMIN_USERS','EVIDENCE_ALLOWED_GROUP_ID')
    'GitHub'                        = @('GITHUB_REPO_URL','GITHUB_BRANCH')
    'Evidence.dev Build'            = @('NODE_VERSION','EVIDENCE_PROJECT_ROOT')
    'Custom Domain (future)'        = @('CUSTOM_DOMAIN_APEX','CUSTOM_DOMAIN_SUBDOMAIN','CUSTOM_DOMAIN')
}

foreach ($section in $sections.GetEnumerator()) {
    $lines += "# $('─' * 77)"
    $lines += "# $($section.Key)"
    $lines += "# $('─' * 77)"
    foreach ($key in $section.Value) {
        $val = $resolved[$key]
        $lines += "$key=$val"
    }
    $lines += ""
}

$lines | Set-Content $envFilePath -Encoding UTF8
_ok "Written to: $envFilePath"

# ── Status table ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Variable                        Source              Status" -ForegroundColor White
Write-Host "  $('─' * 70)" -ForegroundColor DarkGray

foreach ($v in $variables) {
    if ($v.AutoSet) { continue }  # Auto-set vars shown separately below

    $key    = $v.Key
    $val    = $resolved[$key]
    $envVal = [System.Environment]::GetEnvironmentVariable($key)
    $fileVal= $existing[$key]

    $source = if ($envVal)        { 'Codespace secret' }
              elseif ($fileVal)   { 'existing .env    ' }
              elseif ($v.Default -and $val) { 'default           ' }
              else                { '—                 ' }

    $display = if ($v.Secret -and $val) { '(set — masked)' }
               elseif ($val)            { $val }
               else                     { '(not set)' }

    $label   = $key.PadRight(32)
    $srcPad  = $source.PadRight(20)

    if ($val) {
        Write-Host "  $label  $srcPad  " -NoNewline
        Write-Host "$display" -ForegroundColor Green
    } elseif ($v.Required) {
        Write-Host "  $label  $srcPad  " -NoNewline
        Write-Host "MISSING — $($v.Hint)" -ForegroundColor Yellow
    } else {
        Write-Host "  $label  $srcPad  " -NoNewline
        Write-Host "(optional — $($v.Hint))" -ForegroundColor DarkGray
    }
}

# Auto-set vars (shown as a group)
Write-Host ""
Write-Host "  Auto-populated by deploy scripts (do not set these as secrets):" -ForegroundColor DarkGray
foreach ($v in $variables | Where-Object { $_.AutoSet }) {
    $key = $v.Key
    $val = $resolved[$key]
    $display = if ($v.Secret -and $val) { '(present — masked)' } elseif ($val) { $val } else { '(will be set by step 1 or 2)' }
    $colour  = if ($val) { 'Green' } else { 'DarkGray' }
    Write-Host "    $($key.PadRight(28))  $display" -ForegroundColor $colour
}

# ── Final verdict ─────────────────────────────────────────────────────────────
Write-Host ""
if ($missingRequired.Count -gt 0) {
    Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │  Action required — missing required values:          │" -ForegroundColor Yellow
    foreach ($m in $missingRequired) {
        Write-Host "  │    • $($m.PadRight(50))│" -ForegroundColor Yellow
    }
    Write-Host "  │                                                      │" -ForegroundColor Yellow
    Write-Host "  │  Set these as Codespace secrets (repo Settings), or  │" -ForegroundColor Yellow
    Write-Host "  │  edit deploy/.env directly:  code deploy/.env        │" -ForegroundColor Yellow
    Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor Yellow
} else {
    Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │  ✔  All required values are set.                     │" -ForegroundColor Green
    Write-Host "  │                                                      │" -ForegroundColor Green
    Write-Host "  │  Next:  az login --use-device-code                   │" -ForegroundColor Green
    Write-Host "  │  Then:  pwsh ./deploy/deploy.ps1                     │" -ForegroundColor Green
    Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor Green
}
Write-Host ""
