# =============================================================================
# 04-build-deploy.ps1 — Build Evidence.dev and deploy to Azure SWA via SWA CLI
# =============================================================================
# Runs from the Evidence.dev project root (not from deploy/).
# Evidence.dev builds to ./build — the SWA CLI uploads that directory.
# =============================================================================
param(
    [string]$EnvFile      = "$PSScriptRoot\..\..env",
    [switch]$SkipBuild,         # Pass -SkipBuild to redeploy without rebuilding
    [switch]$SkipDeploy,        # Pass -SkipDeploy to build only
    [string]$Environment  = 'production'
)

. "$PSScriptRoot\helpers.ps1"
Import-EnvFile -Path (Resolve-Path $EnvFile)

Write-Banner "Step 4 — Build & Deploy"

# ── Resolve paths ─────────────────────────────────────────────────────────────
$deployDir   = $PSScriptRoot | Split-Path -Parent
$projectRoot = (Resolve-Path "$deployDir\..").Path

$projectRootOverride = Get-EnvOrDefault 'EVIDENCE_PROJECT_ROOT' ''
if ($projectRootOverride -and $projectRootOverride -ne '..') {
    if (Test-Path $projectRootOverride) { $projectRoot = (Resolve-Path $projectRootOverride).Path }
}

Write-Info "Project root : $projectRoot"

# ── Validate required vars ────────────────────────────────────────────────────
$deployToken = Require-EnvVar 'SWA_DEPLOYMENT_TOKEN' `
    -Hint "Run 01-provision-azure.ps1 first."
$swaHostname = Require-EnvVar 'SWA_DEFAULT_HOSTNAME'

# ── Move to project root ───────────────────────────────────────────────────────
Push-Location $projectRoot
try {

    # ── Validate project structure ────────────────────────────────────────────
    Write-Step "Validating Evidence.dev project structure"
    if (-not (Test-Path 'package.json')) {
        Write-Fail "package.json not found at project root: $projectRoot"
        Write-Info  "Ensure EVIDENCE_PROJECT_ROOT points to your Evidence.dev project."
        exit 1
    }

    $pkgJson = Get-Content 'package.json' -Raw | ConvertFrom-Json
    Write-OK "Project: $($pkgJson.name ?? 'unnamed')"

    # ── npm install ───────────────────────────────────────────────────────────
    Write-Step "Installing project dependencies (npm install)"
    npm install
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "npm install failed."
        exit 1
    }
    Write-OK "Dependencies installed."

    # ── Generate swa-cli config if not present ────────────────────────────────
    $swaConfigPath = 'swa-cli.config.json'
    if (-not (Test-Path $swaConfigPath)) {
        Write-Step "Generating swa-cli.config.json"
        $swaConfig = @{
            '$schema' = 'https://aka.ms/azure/static-web-apps-cli/schema'
            configurations = @{
                evidence = @{
                    appLocation    = '.'
                    apiLocation    = 'api'
                    outputLocation = 'build'
                    appBuildCommand = 'npm run build'
                }
            }
        }
        $swaConfig | ConvertTo-Json -Depth 5 | Set-Content $swaConfigPath -Encoding UTF8
        Write-OK "swa-cli.config.json created."
    } else {
        Write-OK "swa-cli.config.json already present."
    }

    # ── Evidence.dev build ────────────────────────────────────────────────────
    if (-not $SkipBuild) {
        Write-Step "Building Evidence.dev (npm run build)"
        Write-Info  "This compiles all .md reports and data sources — may take a minute."

        npm run build
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "npm run build failed."
            Write-Info  "Check that all data sources are accessible and queries are valid."
            exit 1
        }

        if (-not (Test-Path 'build')) {
            Write-Fail "Build output directory 'build' not found after npm run build."
            exit 1
        }
        Write-OK "Build complete → ./build"
    } else {
        Write-Warn "-SkipBuild specified — using existing ./build directory."
        if (-not (Test-Path 'build')) {
            Write-Fail "'build' directory does not exist. Run without -SkipBuild first."
            exit 1
        }
    }

    # ── SWA Deploy ────────────────────────────────────────────────────────────
    if (-not $SkipDeploy) {
        Write-Step "Deploying to Azure Static Web Apps"
        Write-Info  "Target: https://$swaHostname"

        swa deploy `
            --app-location     '.' `
            --api-location     'api' `
            --output-location  'build' `
            --deployment-token $deployToken `
            --env              $Environment

        if ($LASTEXITCODE -ne 0) {
            Write-Fail "swa deploy failed (exit code $LASTEXITCODE)."
            Write-Info  "Check: deployment token is valid, SWA is provisioned, api/ exists."
            exit 1
        }

        Write-OK "Deployment successful!"
        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor Green
        Write-Host "  │  Evidence.dev is live at:                            │" -ForegroundColor Green
        Write-Host "  │  https://$swaHostname" -ForegroundColor Green
        Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor Green
        Write-Host ""
        Write-Info "Login is required for all routes (Entra ID — your tenant only)."
        Write-Info "First sign-in assigns the evidence_user role via GetRoles function."
    } else {
        Write-Warn "-SkipDeploy specified — build complete but not deployed."
    }

} finally {
    Pop-Location
}
