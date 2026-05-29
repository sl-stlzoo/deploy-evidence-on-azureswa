# =============================================================================
# 02-register-app.ps1 — Idempotent Entra ID app registration for SWA auth
# =============================================================================
# Creates (or locates) a single-tenant app registration and a client secret,
# then writes AAD_CLIENT_ID and AAD_CLIENT_SECRET back to the .env file.
#
# Idempotency: looks up existing app by display name before creating.
# Secret rotation: a new secret is only generated if AAD_CLIENT_SECRET is blank.
# =============================================================================
param(
    [string]$EnvFile = "$PSScriptRoot\..\.env"
)

. "$PSScriptRoot\helpers.ps1"
Import-EnvFile -Path (Resolve-Path $EnvFile)

Write-Banner "Step 2 — Entra ID App Registration"

# ── Validate required vars ────────────────────────────────────────────────────
$appName      = Require-EnvVar 'AAD_APP_NAME'
$tenantId     = Require-EnvVar 'AZURE_TENANT_ID'
$swaHostname  = Require-EnvVar 'SWA_DEFAULT_HOSTNAME' `
    -Hint "Run 01-provision-azure.ps1 first to populate SWA_DEFAULT_HOSTNAME."
$envFilePath  = Resolve-Path $EnvFile

$redirectUri  = "https://$swaHostname/.auth/login/aad/callback"
$logoutUri    = "https://$swaHostname/.auth/logout"

Write-Info "App name     : $appName"
Write-Info "Redirect URI : $redirectUri"

# ── Check for existing app registration ──────────────────────────────────────
Write-Step "Looking up existing app registration: '$appName'"
$existingClientId = az ad app list `
    --display-name $appName `
    --query "[0].appId" `
    -o tsv 2>$null

if ($existingClientId) {
    Write-OK "App registration found (Client ID: $existingClientId)."
    $clientId = $existingClientId

    # Ensure redirect URIs are up-to-date
    Write-Step "Ensuring redirect URI is registered"
    $currentUris = az ad app show `
        --id    $clientId `
        --query "web.redirectUris" `
        -o json 2>$null | ConvertFrom-Json

    if ($redirectUri -notin $currentUris) {
        Write-Info "Adding redirect URI..."
        az ad app update `
            --id                   $clientId `
            --web-redirect-uris    $redirectUri | Out-Null
        Write-OK "Redirect URI added."
    } else {
        Write-OK "Redirect URI already registered."
    }
} else {
    # ── Create new app registration ───────────────────────────────────────────
    Write-Step "Creating new app registration"
    try {
        $appJson = Invoke-Az @(
            'ad', 'app', 'create',
            '--display-name',      $appName,
            '--sign-in-audience',  'AzureADMyOrg',   # Single-tenant only
            '--web-redirect-uris', $redirectUri,
            '--enable-id-token-issuance', 'true'
        )
        $app      = $appJson | ConvertFrom-Json
        $clientId = $app.appId
        Write-OK "App created (Client ID: $clientId)."
    } catch {
        Write-Fail "Failed to create app registration: $_"
        exit 1
    }

    # ── Create service principal ──────────────────────────────────────────────
    Write-Step "Creating service principal"
    $spExists = az ad sp show --id $clientId --query "appId" -o tsv 2>$null
    if (-not $spExists) {
        try {
            Invoke-Az @('ad', 'sp', 'create', '--id', $clientId) | Out-Null
            Write-OK "Service principal created."
        } catch {
            Write-Warn "Service principal creation failed (may already exist): $_"
        }
    } else {
        Write-OK "Service principal already exists."
    }
}

# ── Save Client ID to .env ────────────────────────────────────────────────────
Set-EnvFileLine -Path $envFilePath -Key 'AAD_CLIENT_ID' -Value $clientId

# ── Client Secret ─────────────────────────────────────────────────────────────
Write-Step "Client secret"
$existingSecret = [System.Environment]::GetEnvironmentVariable('AAD_CLIENT_SECRET')

if ($existingSecret) {
    Write-OK "AAD_CLIENT_SECRET already set in .env — skipping secret creation."
    Write-Warn "To rotate: delete AAD_CLIENT_SECRET from .env, then re-run this script."
} else {
    Write-Info "Creating new client secret (valid 2 years)..."
    try {
        $secretJson = Invoke-Az @(
            'ad', 'app', 'credential', 'reset',
            '--id',          $clientId,
            '--display-name', 'swa-auth-secret',
            '--years',       '2',
            '--append'
        )
        $secretValue = ($secretJson | ConvertFrom-Json).password

        if (-not $secretValue) { throw "Empty secret returned." }

        Set-EnvFileLine -Path $envFilePath -Key 'AAD_CLIENT_SECRET' -Value $secretValue
        Write-OK "Client secret saved to .env."
        Write-Warn "This secret value cannot be retrieved again from Azure."
        Write-Warn "It is stored in .env only — keep it safe."
    } catch {
        Write-Fail "Failed to create client secret: $_"
        exit 1
    }
}

# ── Optional: expose openid / profile / email API permissions ─────────────────
Write-Step "Verifying Microsoft Graph permissions (openid, profile, email)"
$requiredScopes = @(
    @{ api = "00000003-0000-0000-c000-000000000000"; scope = "37f7f235-527c-4136-accd-4a02d197296e" }  # openid
    @{ api = "00000003-0000-0000-c000-000000000000"; scope = "14dad69e-099b-42c9-810b-d002981feec1" }  # profile
    @{ api = "00000003-0000-0000-c000-000000000000"; scope = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0" }  # email
)

$accessList = $requiredScopes | ForEach-Object {
    @{ resourceAppId = $_.api; resourceAccess = @(@{ id = $_.scope; type = "Scope" }) }
}

try {
    az ad app update `
        --id                    $clientId `
        --required-resource-accesses ($accessList | ConvertTo-Json -Depth 5 -Compress) 2>$null | Out-Null
    Write-OK "Graph permissions set."
} catch {
    Write-Warn "Could not set Graph permissions (non-fatal): $_"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-OK "App registration complete."
Write-Info "  App name       : $appName"
Write-Info "  Client ID      : $clientId"
Write-Info "  Tenant ID      : $tenantId"
Write-Info "  Redirect URI   : $redirectUri"
Write-Info ""
Write-Info "Azure portal link:"
Write-Info "  https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/$clientId"
