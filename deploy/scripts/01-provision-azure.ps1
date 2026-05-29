# =============================================================================
# 01-provision-azure.ps1 — Idempotent Azure resource group + SWA provisioning
# =============================================================================
# Idempotency: all resources are checked for existence before creation.
# Re-running this script on an existing deployment is safe.
#
# Creates:
#   • Resource group
#   • Azure Static Web App (Standard SKU — required for custom auth)
#
# Outputs (written back to .env):
#   • SWA_DEFAULT_HOSTNAME
#   • SWA_DEPLOYMENT_TOKEN
# =============================================================================
param(
    [string]$EnvFile = "$PSScriptRoot\..\.env"
)

. "$PSScriptRoot\helpers.ps1"
Import-EnvFile -Path (Resolve-Path $EnvFile)

Write-Banner "Step 1 — Azure Resource Provisioning"

# ── Validate required vars ────────────────────────────────────────────────────
$subscriptionId = Require-EnvVar 'AZURE_SUBSCRIPTION_ID' `
    -Hint "Get it with: az account list --query '[].{id:id,name:name}' -o table"
$tenantId       = Require-EnvVar 'AZURE_TENANT_ID'
$location       = Require-EnvVar 'AZURE_LOCATION'
$resourceGroup  = Require-EnvVar 'AZURE_RESOURCE_GROUP'
$swaName        = Require-EnvVar 'SWA_NAME'
$swaSku         = Get-EnvOrDefault 'SWA_SKU' 'Standard'
$githubRepoUrl  = Require-EnvVar 'REPO_URL'
$githubBranch   = Get-EnvOrDefault 'REPO_BRANCH' 'main'
$envFilePath    = Resolve-Path $EnvFile

# ── Set active subscription ───────────────────────────────────────────────────
Write-Step "Setting active subscription: $subscriptionId"
try {
    Invoke-Az @('account', 'set', '--subscription', $subscriptionId)
    Write-OK "Subscription set."
} catch {
    Write-Fail $_
    exit 1
}

# ── Resource Group ────────────────────────────────────────────────────────────
Write-Step "Resource group: $resourceGroup"
$rgExists = az group show --name $resourceGroup --query "id" -o tsv 2>$null
if ($rgExists) {
    Write-OK "Resource group already exists — skipping creation."
} else {
    Write-Info "Creating resource group in $location..."

    $tags = Get-EnvOrDefault 'AZURE_RESOURCE_TAGS' ''
    $tagArgs = if ($tags) { @('--tags') + ($tags -split ',') } else { @() }

    try {
        Invoke-Az (@('group', 'create',
            '--name',     $resourceGroup,
            '--location', $location) + $tagArgs) | Out-Null
        Write-OK "Resource group created."
    } catch {
        Write-Fail $_
        exit 1
    }
}

# ── Azure Static Web App ──────────────────────────────────────────────────────
Write-Step "Azure Static Web App: $swaName (SKU: $swaSku)"

if ($swaSku -ne 'Standard') {
    Write-Warn "SWA_SKU is '$swaSku'. Custom authentication requires 'Standard'."
    Write-Warn "Overriding to Standard."
    $swaSku = 'Standard'
}

$swaId = az staticwebapp show `
    --name           $swaName `
    --resource-group $resourceGroup `
    --query          "id" `
    -o tsv 2>$null

if ($swaId) {
    Write-OK "SWA '$swaName' already exists — skipping creation."
} else {
    Write-Info "Creating SWA '$swaName' in $resourceGroup ($location)..."
    Write-Info "This may take 1–2 minutes..."

    try {
        # Create SWA without source link — we deploy via SWA CLI in step 4.
        # GitHub Actions integration is configured separately in step 3.
        $swaJson = Invoke-Az @(
            'staticwebapp', 'create',
            '--name',           $swaName,
            '--resource-group', $resourceGroup,
            '--location',       $location,
            '--sku',            $swaSku
        )
        Write-OK "SWA created."
    } catch {
        Write-Fail $_
        exit 1
    }
}

# ── Read SWA hostname ─────────────────────────────────────────────────────────
Write-Step "Reading SWA hostname"
$hostname = az staticwebapp show `
    --name           $swaName `
    --resource-group $resourceGroup `
    --query          "defaultHostname" `
    -o tsv 2>$null

if (-not $hostname) {
    Write-Fail "Could not retrieve SWA hostname. Check the Azure portal."
    exit 1
}

Write-OK "Hostname: $hostname"
Set-EnvFileLine -Path $envFilePath -Key 'SWA_DEFAULT_HOSTNAME' -Value $hostname

# ── Read Deployment Token ─────────────────────────────────────────────────────
Write-Step "Retrieving SWA deployment token"
try {
    $deployToken = Invoke-Az @(
        'staticwebapp', 'secrets', 'list',
        '--name',           $swaName,
        '--resource-group', $resourceGroup,
        '--query',          'properties.apiKey',
        '-o',               'tsv'
    )
    $deployToken = $deployToken.Trim()

    if (-not $deployToken) { throw "Empty deployment token returned." }

    Set-EnvFileLine -Path $envFilePath -Key 'SWA_DEPLOYMENT_TOKEN' -Value $deployToken
    Write-OK "Deployment token saved to .env."
} catch {
    Write-Fail "Could not retrieve deployment token: $_"
    exit 1
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-OK "Provisioning complete."
Write-Info "  Resource group : $resourceGroup"
Write-Info "  SWA name       : $swaName"
Write-Info "  Default URL    : https://$hostname"
Write-Info "  SKU            : $swaSku"
