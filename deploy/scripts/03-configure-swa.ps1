# =============================================================================
# 03-configure-swa.ps1 — Configure SWA app settings, auth, routes, and CI/CD
# =============================================================================
# This script:
#   1. Sets required app settings on the SWA (client ID, secret, tenant ID)
#   2. Generates staticwebapp.config.json from template → project/static/
#   3. Copies api-src/ → project/api/ (GetRoles function)
#   4. Generates GitHub Actions workflow → project/.github/workflows/
#   5. Optionally registers SWA deployment token as a GitHub Actions secret
# =============================================================================
param(
    [string]$EnvFile = "$PSScriptRoot\..\..env"
)

. "$PSScriptRoot\helpers.ps1"
Import-EnvFile -Path (Resolve-Path $EnvFile)

Write-Banner "Step 3 — SWA Configuration"

# ── Resolve paths ─────────────────────────────────────────────────────────────
$deployDir    = $PSScriptRoot | Split-Path -Parent      # .../deploy/
$projectRoot  = (Resolve-Path "$deployDir\..").Path     # Evidence.dev project root

# Override project root from env if set
$projectRootOverride = Get-EnvOrDefault 'EVIDENCE_PROJECT_ROOT' ''
if ($projectRootOverride -and $projectRootOverride -ne '..') {
    if (Test-Path $projectRootOverride) {
        $projectRoot = (Resolve-Path $projectRootOverride).Path
    }
}

Write-Info "Deploy dir   : $deployDir"
Write-Info "Project root : $projectRoot"

# ── Validate required vars ────────────────────────────────────────────────────
$swaName       = Require-EnvVar 'SWA_NAME'
$resourceGroup = Require-EnvVar 'AZURE_RESOURCE_GROUP'
$tenantId      = Require-EnvVar 'AZURE_TENANT_ID'
$clientId      = Require-EnvVar 'AAD_CLIENT_ID' `
    -Hint "Run 02-register-app.ps1 first."
$clientSecret  = Require-EnvVar 'AAD_CLIENT_SECRET' `
    -Hint "Run 02-register-app.ps1 first."
$swaHostname   = Require-EnvVar 'SWA_DEFAULT_HOSTNAME' `
    -Hint "Run 01-provision-azure.ps1 first."
$deployToken   = Require-EnvVar 'SWA_DEPLOYMENT_TOKEN' `
    -Hint "Run 01-provision-azure.ps1 first."
$githubBranch  = Get-EnvOrDefault 'REPO_BRANCH' 'main'
$githubRepo    = Get-EnvOrDefault 'REPO_URL' ''
$envFilePath   = Resolve-Path $EnvFile

$adminUsers    = Get-EnvOrDefault 'EVIDENCE_ADMIN_USERS' ''
$allowedGroup  = Get-EnvOrDefault 'EVIDENCE_ALLOWED_GROUP_ID' ''

# ── 1. Set SWA Application Settings ──────────────────────────────────────────
Write-Step "Setting SWA application settings"

$appSettings = @(
    "AAD_CLIENT_ID=$clientId",
    "AAD_CLIENT_SECRET=$clientSecret",
    "AAD_TENANT_ID=$tenantId"
)

if ($adminUsers)   { $appSettings += "EVIDENCE_ADMIN_USERS=$adminUsers" }
if ($allowedGroup) { $appSettings += "EVIDENCE_ALLOWED_GROUP_ID=$allowedGroup" }

try {
    Invoke-Az (@(
        'staticwebapp', 'appsettings', 'set',
        '--name',           $swaName,
        '--resource-group', $resourceGroup,
        '--setting-names'
    ) + $appSettings) | Out-Null
    Write-OK "App settings configured ($($appSettings.Count) setting(s))."
} catch {
    Write-Fail "Failed to set app settings: $_"
    exit 1
}

# ── 2. Generate staticwebapp.config.json ──────────────────────────────────────
Write-Step "Generating staticwebapp.config.json"

$templatePath = "$deployDir\templates\staticwebapp.config.template.json"
$outputDir    = "$projectRoot\static"
$outputPath   = "$outputDir\staticwebapp.config.json"

if (-not (Test-Path $templatePath)) {
    Write-Fail "Template not found: $templatePath"
    exit 1
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$configContent = Get-Content $templatePath -Raw
$configContent = $configContent -replace '%%TENANT_ID%%',    $tenantId
$configContent = $configContent -replace '%%SWA_HOSTNAME%%', $swaHostname

$configContent | Set-Content -Path $outputPath -Encoding UTF8
Write-OK "Written to: $outputPath"

# ── 3. Copy api-src → project/api ────────────────────────────────────────────
Write-Step "Copying GetRoles function to project api/ directory"

$apiSrcPath  = "$deployDir\api-src"
$apiDestPath = "$projectRoot\api"

if (-not (Test-Path $apiSrcPath)) {
    Write-Fail "api-src not found at: $apiSrcPath"
    exit 1
}

# Copy (overwrite) to project root api/
Copy-Item -Path $apiSrcPath -Destination $apiDestPath -Recurse -Force
Write-OK "api/ directory ready at: $apiDestPath"

# Restore npm deps for the functions
Write-Step "Installing API dependencies"
Push-Location $apiDestPath
try {
    npm install --silent
    Write-OK "API npm install complete."
} catch {
    Write-Warn "npm install in api/ failed (non-fatal for deployment): $_"
} finally {
    Pop-Location
}

# ── 4. Generate GitHub Actions workflow ───────────────────────────────────────
Write-Step "Generating GitHub Actions workflow"

$workflowTemplatePath = "$deployDir\templates\azure-static-web-apps.yml.template"
$workflowDir          = "$projectRoot\.github\workflows"
$workflowPath         = "$workflowDir\azure-static-web-apps-deploy.yml"

if (Test-Path $workflowTemplatePath) {
    New-Item -ItemType Directory -Path $workflowDir -Force | Out-Null

    $wfContent = Get-Content $workflowTemplatePath -Raw
    $wfContent  = $wfContent -replace '%%REPO_BRANCH%%', $githubBranch

    $wfContent | Set-Content -Path $workflowPath -Encoding UTF8
    Write-OK "Workflow written to: $workflowPath"
    Write-Info "Commit this file to trigger automated deployments."
} else {
    Write-Warn "Workflow template not found — skipping GitHub Actions setup."
}

# ── 5. Register SWA Token as GitHub Actions Secret (optional) ─────────────────
Write-Step "GitHub Actions secret (optional)"
if (-not (Test-CommandExists 'gh')) {
    Write-Warn "gh CLI not found — skipping automated secret registration."
    Write-Info  "Manual step: In your GitHub repo settings, add secret:"
    Write-Info  "  Name:  AZURE_STATIC_WEB_APPS_API_TOKEN"
    Write-Info  "  Value: (the SWA_DEPLOYMENT_TOKEN from your .env file)"
} elseif (-not $githubRepo) {
    Write-Warn "REPO_URL not set — skipping secret registration."
} else {
    # Extract owner/repo from URL
    $repoRef = $githubRepo -replace 'https://github.com/', '' -replace '\.git$', ''
    Write-Info "Registering secret in: $repoRef"
    try {
        $deployToken | gh secret set AZURE_STATIC_WEB_APPS_API_TOKEN --repo $repoRef
        Write-OK "GitHub Actions secret registered."
    } catch {
        Write-Warn "Could not set GitHub secret (non-fatal): $_"
        Write-Info  "Set it manually in GitHub → Settings → Secrets → Actions."
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-OK "SWA configuration complete."
Write-Info "  Auth provider  : Entra ID (single-tenant: $tenantId)"
Write-Info "  Roles function : /api/GetRoles"
Write-Info "  Config file    : $outputPath"
Write-Info "  Workflow file  : $workflowPath"
