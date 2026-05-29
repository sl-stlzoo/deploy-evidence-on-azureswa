# =============================================================================
# 00-prerequisites.ps1 — Verify all tooling is present and correctly versioned
# =============================================================================
# Run standalone:  .\deploy\scripts\00-prerequisites.ps1
# Called by:       deploy.ps1
# =============================================================================
param([switch]$Fix)   # Pass -Fix to attempt automatic installs via npm/winget

. "$PSScriptRoot\helpers.ps1"

Write-Banner "Step 0 — Prerequisites"

$errors = 0

# ── PowerShell version ────────────────────────────────────────────────────────
Write-Step "PowerShell version"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warn "PowerShell 7+ is recommended (current: $($PSVersionTable.PSVersion))."
    Write-Info  "Install: winget install Microsoft.PowerShell"
    # Non-fatal — PS 5.1 mostly works but colour codes differ.
} else {
    Write-OK "PowerShell $($PSVersionTable.PSVersion)"
}

# ── Node.js ───────────────────────────────────────────────────────────────────
Write-Step "Node.js"
if (-not (Test-CommandExists 'node')) {
    Write-Fail "node not found. Install Node.js $($env:NODE_VERSION ?? '20') LTS from https://nodejs.org"
    $errors++
} else {
    $nodeVer = (node --version).TrimStart('v')
    $nodeMajor = [int]($nodeVer -split '\.')[0]
    if ($nodeMajor -lt 18) {
        Write-Fail "Node.js $nodeVer is too old. Evidence.dev requires ≥ 18."
        $errors++
    } else {
        Write-OK "node $nodeVer"
    }
}

# ── npm ───────────────────────────────────────────────────────────────────────
Write-Step "npm"
if (-not (Test-CommandExists 'npm')) {
    Write-Fail "npm not found — it ships with Node.js."
    $errors++
} else {
    Write-OK "npm $(npm --version)"
}

# ── Azure CLI ─────────────────────────────────────────────────────────────────
Write-Step "Azure CLI (az)"
if (-not (Test-CommandExists 'az')) {
    Write-Fail "az CLI not found."
    Write-Info  "Install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    if ($Fix) {
        Write-Info "Attempting install via winget..."
        winget install Microsoft.AzureCLI
    }
    $errors++
} else {
    $azVer = (az version --query '"azure-cli"' -o tsv 2>$null)
    Write-OK "az $azVer"

    # Check login
    Write-Step "Azure CLI — login status"
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        Write-Warn "Not logged in to Azure. Run: az login"
        Write-Info  "For non-interactive / codespace environments: az login --use-device-code"
        $errors++
    } else {
        Write-OK "Logged in as: $($account.user.name)"
        Write-Info  "Subscription: $($account.name) ($($account.id))"
        if ($env:AZURE_SUBSCRIPTION_ID -and $account.id -ne $env:AZURE_SUBSCRIPTION_ID) {
            Write-Warn "Active subscription differs from AZURE_SUBSCRIPTION_ID in .env."
            Write-Info  "The provisioning script will call 'az account set' to correct this."
        }
    }
}

# ── SWA CLI ───────────────────────────────────────────────────────────────────
Write-Step "Azure Static Web Apps CLI (swa)"
if (-not (Test-CommandExists 'swa')) {
    Write-Warn "swa CLI not found."
    if ($Fix) {
        Write-Info "Installing @azure/static-web-apps-cli globally..."
        npm install -g @azure/static-web-apps-cli
        if ($LASTEXITCODE -ne 0) { $errors++; Write-Fail "swa CLI install failed." }
        else { Write-OK "swa CLI installed." }
    } else {
        Write-Info "Install: npm install -g @azure/static-web-apps-cli"
        Write-Info "Or re-run with: .\deploy\scripts\00-prerequisites.ps1 -Fix"
        $errors++
    }
} else {
    Write-OK "swa $(swa --version 2>$null)"
}

# ── GitHub CLI (gh) — optional ────────────────────────────────────────────────
Write-Step "GitHub CLI (gh)  [optional — needed to auto-register Actions secret]"
if (-not (Test-CommandExists 'gh')) {
    Write-Warn "gh CLI not found. GitHub Actions secret must be set manually."
    Write-Info  "Install: winget install GitHub.cli  or  https://cli.github.com"
} else {
    $ghStatus = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "gh CLI found but not authenticated. Run: gh auth login"
    } else {
        Write-OK "gh $(gh --version | Select-Object -First 1)"
    }
}

# ── Git ───────────────────────────────────────────────────────────────────────
Write-Step "Git"
if (-not (Test-CommandExists 'git')) {
    Write-Fail "git not found. Install from https://git-scm.com"
    $errors++
} else {
    Write-OK "git $(git --version)"
}

# ── Summary ───────────────────────────────────────────────────────────────────
if ($errors -gt 0) {
    Write-Host "`n──────────────────────────────────────────────────" -ForegroundColor Red
    Write-Fail  "$errors prerequisite(s) failed. Resolve them before continuing."
    Write-Host "──────────────────────────────────────────────────`n" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n──────────────────────────────────────────────────" -ForegroundColor Green
    Write-OK    "All required prerequisites satisfied."
    Write-Host "──────────────────────────────────────────────────`n" -ForegroundColor Green
}
