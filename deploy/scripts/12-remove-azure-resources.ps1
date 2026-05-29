# =============================================================================
# 12-remove-azure-resources.ps1 — Delete SWA and (optionally) resource group
# =============================================================================
# Removes (in order):
#   1. Azure Static Web App (SWA_NAME)
#   2. Resource group (AZURE_RESOURCE_GROUP) — with confirmation
#      Deleting the RG is irreversible and removes ALL resources inside it.
#      Pass -KeepResourceGroup to delete only the SWA and leave the RG.
#
# After deletion, blanks SWA_DEPLOYMENT_TOKEN and SWA_DEFAULT_HOSTNAME in .env.
# Idempotency: checks resource existence before attempting deletion.
# =============================================================================
param(
    [string]$EnvFile           = "$PSScriptRoot\..\..env",
    [switch]$Force,             # Skip all confirmation prompts
    [switch]$KeepResourceGroup  # Delete SWA only, leave the resource group
)

. "$PSScriptRoot\helpers.ps1"
Import-EnvFile -Path (Resolve-Path $EnvFile)

Write-Banner "Teardown Step 12 — Remove Azure Resources"

$envFilePath    = Resolve-Path $EnvFile
$subscriptionId = Require-EnvVar 'AZURE_SUBSCRIPTION_ID'
$resourceGroup  = Require-EnvVar 'AZURE_RESOURCE_GROUP'
$swaName        = Require-EnvVar 'SWA_NAME'

# ── Set active subscription ───────────────────────────────────────────────────
Write-Step "Setting active subscription: $subscriptionId"
try {
    Invoke-Az @('account', 'set', '--subscription', $subscriptionId)
    Write-OK "Subscription set."
} catch {
    Write-Fail $_; exit 1
}

# ── Check resource group exists ───────────────────────────────────────────────
Write-Step "Checking resource group: $resourceGroup"
$rgId = az group show --name $resourceGroup --query "id" -o tsv 2>$null
if (-not $rgId) {
    Write-OK "Resource group '$resourceGroup' not found — already deleted."
    Set-EnvFileLine -Path $envFilePath -Key 'SWA_DEPLOYMENT_TOKEN'  -Value ''
    Set-EnvFileLine -Path $envFilePath -Key 'SWA_DEFAULT_HOSTNAME'  -Value ''
    exit 0
}
Write-Info "Resource group found: $resourceGroup"

# ── Check SWA exists ──────────────────────────────────────────────────────────
Write-Step "Checking SWA: $swaName"
$swaId = az staticwebapp show `
    --name           $swaName `
    --resource-group $resourceGroup `
    --query          "id" `
    -o tsv 2>$null

if ($swaId) {
    $swaHostname = az staticwebapp show `
        --name           $swaName `
        --resource-group $resourceGroup `
        --query          "defaultHostname" `
        -o tsv 2>$null
    Write-Info "SWA found: https://$swaHostname"
} else {
    Write-Info "SWA '$swaName' not found in resource group — may already be deleted."
}

# ── List all resources in the group (for operator awareness) ──────────────────
Write-Step "All resources in '$resourceGroup'"
$allResources = az resource list `
    --resource-group $resourceGroup `
    --query          "[].{Name:name, Type:type}" `
    -o table 2>$null
if ($allResources) {
    Write-Host ($allResources | Out-String) -ForegroundColor Gray
} else {
    Write-Info "(Resource group is empty or could not be queried)"
}

# ══════════════════════════════════════════════════════════════════════════════
# PATH A — Delete the entire resource group
# ══════════════════════════════════════════════════════════════════════════════
if (-not $KeepResourceGroup) {

    Write-Host ""
    Write-Host "   ╔════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "   ║  DESTRUCTIVE — Resource Group Deletion                ║" -ForegroundColor Red
    Write-Host "   ║                                                        ║" -ForegroundColor Red
    Write-Host "   ║  Resource group : $($resourceGroup.PadRight(36))║" -ForegroundColor Red
    Write-Host "   ║  This deletes ALL resources inside the group.         ║" -ForegroundColor Red
    Write-Host "   ║  This action cannot be undone.                        ║" -ForegroundColor Red
    Write-Host "   ╚════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""

    if (-not $Force) {
        # Require explicit typing of the resource group name to proceed
        $typed = Read-Host "  Type the resource group name to confirm deletion"
        if ($typed -ne $resourceGroup) {
            Write-Warn "Input did not match '$resourceGroup' — deletion cancelled."
            Write-Info  "To delete only the SWA (keep the resource group), re-run with -KeepResourceGroup."
            exit 0
        }
    }

    Write-Step "Deleting resource group '$resourceGroup' (async — this takes 1–3 minutes)"
    Write-Info  "Azure is deleting the group and all contained resources..."

    try {
        # --no-wait returns immediately; the deletion continues in Azure.
        # For a workshop teardown the operator can verify in the portal.
        Invoke-Az @(
            'group', 'delete',
            '--name',    $resourceGroup,
            '--yes',
            '--no-wait'
        )
        Write-OK "Deletion initiated. The resource group is being removed asynchronously."
        Write-Info "Verify in the Azure portal or run:"
        Write-Info "  az group exists --name $resourceGroup"
    } catch {
        Write-Fail "Resource group deletion failed: $_"
        exit 1
    }

} else {

    # ══════════════════════════════════════════════════════════════════════════
    # PATH B — Delete SWA only, keep resource group
    # ══════════════════════════════════════════════════════════════════════════
    Write-Host ""
    Write-Host "   [-KeepResourceGroup] Deleting SWA only — resource group will remain." -ForegroundColor Yellow
    Write-Host ""

    if (-not $swaId) {
        Write-OK "SWA '$swaName' not found — nothing to delete."
    } else {
        if (-not $Force) {
            $ok = Confirm-Step "Delete SWA '$swaName' (resource group will remain)?"
            if (-not $ok) { Write-Warn "Skipped by user."; exit 0 }
        }

        Write-Step "Deleting SWA '$swaName'"
        try {
            Invoke-Az @(
                'staticwebapp', 'delete',
                '--name',           $swaName,
                '--resource-group', $resourceGroup,
                '--yes'
            )
            Write-OK "SWA '$swaName' deleted."
        } catch {
            Write-Fail "SWA deletion failed: $_"
            exit 1
        }
    }
}

# ── Clear SWA values from .env ────────────────────────────────────────────────
Write-Step "Clearing SWA values from .env"
Set-EnvFileLine -Path $envFilePath -Key 'SWA_DEPLOYMENT_TOKEN' -Value ''
Set-EnvFileLine -Path $envFilePath -Key 'SWA_DEFAULT_HOSTNAME' -Value ''
Write-OK ".env updated — SWA_DEPLOYMENT_TOKEN and SWA_DEFAULT_HOSTNAME cleared."
