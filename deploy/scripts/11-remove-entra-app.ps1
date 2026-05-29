# =============================================================================
# 11-remove-entra-app.ps1 — Delete Entra ID app registration + service principal
# =============================================================================
# Removes:
#   • Service principal associated with the app registration
#   • App registration itself (AAD_CLIENT_ID)
#   • Optionally removes GitHub Actions secret (AZURE_STATIC_WEB_APPS_API_TOKEN)
#
# Idempotency: each resource is checked for existence before deletion.
# After deletion, blanks AAD_CLIENT_ID and AAD_CLIENT_SECRET in .env.
# =============================================================================
param(
    [string]$EnvFile = "$PSScriptRoot\..\.env",
    [switch]$Force
)

. "$PSScriptRoot\helpers.ps1"
Import-EnvFile -Path (Resolve-Path $EnvFile)

Write-Banner "Teardown Step 11 — Remove Entra App Registration"

$envFilePath  = Resolve-Path $EnvFile
$clientId     = Get-EnvOrDefault 'AAD_CLIENT_ID'   ''
$appName      = Get-EnvOrDefault 'AAD_APP_NAME'    ''
$githubRepo   = Get-EnvOrDefault 'REPO_URL' ''

# ── Resolve client ID — try env first, fall back to display-name lookup ───────
Write-Step "Locating app registration"

if (-not $clientId) {
    Write-Warn "AAD_CLIENT_ID is blank in .env — attempting lookup by display name."
    if (-not $appName) {
        Write-Fail "Neither AAD_CLIENT_ID nor AAD_APP_NAME is set. Cannot locate app."
        Write-Info  "If the registration was already deleted, this step can be skipped."
        exit 0   # Non-fatal during teardown
    }
    $clientId = az ad app list `
        --display-name $appName `
        --query "[0].appId" `
        -o tsv 2>$null
    if (-not $clientId) {
        Write-OK "No app registration found with display name '$appName' — already deleted."
        exit 0
    }
    Write-Info "Found by display name: $clientId"
} else {
    # Verify it still exists
    $exists = az ad app show --id $clientId --query "appId" -o tsv 2>$null
    if (-not $exists) {
        Write-OK "App registration ($clientId) not found in Entra — already deleted."
        Set-EnvFileLine -Path $envFilePath -Key 'AAD_CLIENT_ID'     -Value ''
        Set-EnvFileLine -Path $envFilePath -Key 'AAD_CLIENT_SECRET' -Value ''
        exit 0
    }
}

$resolvedName = az ad app show --id $clientId --query "displayName" -o tsv 2>$null
Write-Info "  App name   : $resolvedName"
Write-Info "  Client ID  : $clientId"

# ── Optional: remove GitHub Actions secret ────────────────────────────────────
Write-Step "GitHub Actions secret (AZURE_STATIC_WEB_APPS_API_TOKEN)"
if ((Test-CommandExists 'gh') -and $githubRepo) {
    $repoRef = $githubRepo -replace 'https://github.com/', '' -replace '\.git$', ''
    try {
        $secretExists = gh secret list --repo $repoRef 2>$null |
                        Select-String 'AZURE_STATIC_WEB_APPS_API_TOKEN'
        if ($secretExists) {
            if ($Force -or (Confirm-Step "  Remove GitHub secret 'AZURE_STATIC_WEB_APPS_API_TOKEN' from $repoRef?")) {
                gh secret delete AZURE_STATIC_WEB_APPS_API_TOKEN --repo $repoRef 2>$null
                Write-OK "GitHub Actions secret removed."
            } else {
                Write-Warn "GitHub secret left in place."
            }
        } else {
            Write-Info "Secret not found in $repoRef — skipping."
        }
    } catch {
        Write-Warn "Could not check/remove GitHub secret (non-fatal): $_"
    }
} else {
    Write-Info "gh CLI not available or REPO_URL not set — skipping."
    Write-Info "Remove the GitHub secret manually if needed:"
    Write-Info "  GitHub → repo → Settings → Secrets → AZURE_STATIC_WEB_APPS_API_TOKEN → Delete"
}

# ── Confirm before deleting Entra resources ───────────────────────────────────
Write-Host ""
Write-Host "   The following Entra resources will be PERMANENTLY deleted:" -ForegroundColor Yellow
Write-Host "     App registration : $resolvedName ($clientId)" -ForegroundColor Yellow
Write-Host "     Service principal: (associated SP for $clientId)" -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
    $ok = Confirm-Step "Permanently delete this app registration and its service principal?"
    if (-not $ok) { Write-Warn "Skipped by user."; exit 0 }
}

# ── Delete service principal first ────────────────────────────────────────────
Write-Step "Deleting service principal"
$spId = az ad sp show --id $clientId --query "id" -o tsv 2>$null
if ($spId) {
    try {
        Invoke-Az @('ad', 'sp', 'delete', '--id', $clientId)
        Write-OK "Service principal deleted."
    } catch {
        Write-Warn "Service principal deletion failed (may already be gone): $_"
    }
} else {
    Write-Info "Service principal not found — skipping."
}

# ── Delete app registration ───────────────────────────────────────────────────
Write-Step "Deleting app registration ($clientId)"
try {
    Invoke-Az @('ad', 'app', 'delete', '--id', $clientId)
    Write-OK "App registration deleted."
} catch {
    Write-Warn "App deletion failed (may already be gone): $_"
}

# ── Blank secrets in .env ─────────────────────────────────────────────────────
Write-Step "Clearing AAD_CLIENT_ID and AAD_CLIENT_SECRET from .env"
Set-EnvFileLine -Path $envFilePath -Key 'AAD_CLIENT_ID'     -Value ''
Set-EnvFileLine -Path $envFilePath -Key 'AAD_CLIENT_SECRET' -Value ''
Write-OK ".env updated — secrets cleared."
Write-Warn "The app registration is in Entra's soft-delete bin for 30 days."
Write-Info "To hard-delete immediately: az ad app delete --id $clientId (or via portal)."
