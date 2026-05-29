#!/usr/bin/env bash
# =============================================================================
# .devcontainer/post-create.sh
# Runs ONCE after the devcontainer is first built (postCreateCommand).
# =============================================================================
# STEP 1  Pull Evidence.dev template (if this is a bare repo without it)
# STEP 2  Install Evidence.dev project dependencies  (npm install)
# STEP 3  Install Azure Static Web Apps CLI globally (npm install -g swa)
# STEP 4  Verify az staticwebapps extension
# STEP 5  Bootstrap deploy/.env from Codespace secrets
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
RESET='\033[0m'

step()  { echo -e "\n${CYAN}▶  $*${RESET}"; }
ok()    { echo -e "   ${GREEN}✔  $*${RESET}"; }
warn()  { echo -e "   ${YELLOW}⚠  $*${RESET}"; }
info()  { echo -e "   ${GRAY}ℹ  $*${RESET}"; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║   Evidence.dev → Azure SWA  |  Codespace Setup          ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Working directory: repository root ───────────────────────────────────────
# All paths below are relative to the repo root, not .devcontainer/.
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
info "Repo root: $REPO_ROOT"

# =============================================================================
# STEP 1 — Pull Evidence.dev template
# =============================================================================
# Detection: a repo that already has the Evidence.dev template will have
# BOTH a package.json at root AND a pages/ directory.  If either is missing
# this is a bare repo (only .devcontainer/ and deploy/ were committed) and
# the template must be pulled before anything else can proceed.
#
# We use `npx degit` — the same tool Evidence.dev's own install docs recommend.
# degit does a shallow copy of the template: no .git history, no extra files,
# just the working project skeleton.  It will NOT overwrite .devcontainer/ or
# deploy/ because those directories are not part of the Evidence.dev template.
# =============================================================================
step "Step 1 — Evidence.dev template"

NEEDS_TEMPLATE=false
if [[ ! -f "$REPO_ROOT/package.json" ]]; then
  NEEDS_TEMPLATE=true
  info "package.json not found — bare repo detected."
elif [[ ! -d "$REPO_ROOT/pages" ]]; then
  NEEDS_TEMPLATE=true
  info "pages/ directory not found — Evidence.dev template not present."
fi

if [[ "$NEEDS_TEMPLATE" == "true" ]]; then
  echo ""
  echo -e "   ${YELLOW}Evidence.dev template is not present in this repository.${RESET}"
  echo -e "   ${YELLOW}Pulling it now via degit...${RESET}"
  echo ""
  info "Source: github:evidence-dev/template"
  info "Target: $REPO_ROOT  (existing files — .devcontainer/, deploy/ — are preserved)"
  echo ""

  # npx degit copies only files that don't already exist when run against a
  # directory that has content.  .devcontainer/ and deploy/ are untouched.
  npx --yes degit evidence-dev/template "$REPO_ROOT" --force 2>&1 | \
    sed "s/^/   /"

  # Verify the pull produced what we need
  if [[ ! -f "$REPO_ROOT/package.json" ]]; then
    echo ""
    echo -e "   ${YELLOW}⚠  degit completed but package.json is still missing.${RESET}"
    echo -e "   ${YELLOW}   This may be a network issue or a change in the template repo.${RESET}"
    echo -e "   ${YELLOW}   Run manually:  npx degit evidence-dev/template . --force${RESET}"
    echo ""
    # Non-fatal: continue so the rest of setup still runs cleanly.
  else
    echo ""
    ok "Evidence.dev template pulled successfully."
    info "Files added: package.json, pages/, sources/, evidence.config.yaml, and more."
    info "Existing .devcontainer/ and deploy/ were not modified."
  fi
else
  ok "Evidence.dev template already present (package.json + pages/ found)."
fi

# =============================================================================
# STEP 2 — Install Evidence.dev project dependencies
# =============================================================================
# Must run AFTER step 1 so package.json exists.
# =============================================================================
step "Step 2 — Evidence.dev project dependencies (npm install)"

if [[ -f "$REPO_ROOT/package.json" ]]; then
  npm install
  ok "Project dependencies installed."
else
  warn "package.json still not found — skipping npm install."
  warn "Resolve the template pull above, then run:  npm install"
fi

# =============================================================================
# STEP 3 — Azure Static Web Apps CLI
# =============================================================================
step "Step 3 — Azure Static Web Apps CLI (@azure/static-web-apps-cli)"

if command -v swa &>/dev/null; then
  ok "swa CLI already installed: $(swa --version 2>/dev/null || echo 'version unknown')"
else
  npm install -g @azure/static-web-apps-cli
  ok "swa CLI installed: $(swa --version 2>/dev/null)"
fi

# =============================================================================
# STEP 4 — Azure CLI staticwebapps extension
# =============================================================================
step "Step 4 — az staticwebapps extension"

if az extension show --name staticwebapps &>/dev/null; then
  ok "staticwebapps extension already present"
else
  az extension add --name staticwebapps --only-show-errors
  ok "staticwebapps extension installed"
fi

# =============================================================================
# STEP 5 — Bootstrap deploy/.env from Codespace secrets
# =============================================================================
# Reads any Codespace secrets already injected as environment variables and
# writes them into deploy/.env so that deploy.ps1 can find them.
# Re-running this step at any time is safe — it merges, never blindly overwrites.
# =============================================================================
step "Step 5 — Bootstrap deploy/.env from Codespace secrets"

DEPLOY_DIR="$REPO_ROOT/deploy"

if [[ ! -d "$DEPLOY_DIR" ]]; then
  warn "deploy/ directory not found — skipping .env bootstrap."
  warn "Ensure deploy/ was committed to the repository."
elif ! command -v pwsh &>/dev/null; then
  warn "pwsh not found — cannot run init-codespace-env.ps1."
  warn "The PowerShell feature should have installed it.  Try rebuilding the container."
else
  pwsh -NonInteractive -File "$DEPLOY_DIR/scripts/init-codespace-env.ps1"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════${RESET}"
ok "Codespace setup complete."
echo ""
info "YOUR THREE-COMMAND WORKFLOW:"
echo ""
echo -e "   ${CYAN}# 1. Authenticate to Azure (browser opens — any browser works):${RESET}"
echo -e "   ${GREEN}az login --use-device-code${RESET}"
echo ""
echo -e "   ${CYAN}# 2. Confirm deploy/.env has all required values (green = set):${RESET}"
echo -e "   ${GREEN}cat deploy/.env${RESET}"
echo ""
echo -e "   ${CYAN}# 3. Deploy to Azure Static Web Apps:${RESET}"
echo -e "   ${GREEN}pwsh ./deploy/deploy.ps1${RESET}"
echo ""
info "Teardown when done:  pwsh ./deploy/teardown.ps1"
info "Full docs:           deploy/README.md"
echo -e "${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo ""
