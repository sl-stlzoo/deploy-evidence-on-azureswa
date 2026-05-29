#!/usr/bin/env bash
# =============================================================================
# .devcontainer/motd.sh — Message of the day (postStartCommand)
# Shown in the terminal on every codespace start/resume.
# =============================================================================
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
RESET='\033[0m'

info() { echo -e "   ${GRAY}$*${RESET}"; }
cmd()  { echo -e "   ${GREEN}$*${RESET}"; }
warn() { echo -e "   ${YELLOW}⚠  $*${RESET}"; }

echo ""
echo -e "${CYAN}  Evidence.dev → Azure Static Web Apps  |  Codespace${RESET}"
echo -e "${CYAN}  ─────────────────────────────────────────────────────${RESET}"

# ── Check az login status ─────────────────────────────────────────────────────
AZ_USER=$(az account show --query "user.name" -o tsv 2>/dev/null || true)
if [[ -n "$AZ_USER" ]]; then
  echo -e "   ${GREEN}✔  Azure: signed in as $AZ_USER${RESET}"
else
  warn "Azure: not signed in"
  info "  Run:  az login --use-device-code"
fi

# ── Check .env ────────────────────────────────────────────────────────────────
if [[ -f "deploy/.env" ]]; then
  MISSING=$(grep -E '^[A-Z_]+=\s*$' deploy/.env | grep -v '^SWA_DEPLOYMENT_TOKEN\|^SWA_DEFAULT_HOSTNAME\|^AAD_CLIENT_ID\|^AAD_CLIENT_SECRET' | cut -d= -f1 | tr '\n' ' ' || true)
  if [[ -n "$MISSING" ]]; then
    warn "deploy/.env is missing values for: $MISSING"
    info "  Edit:  code deploy/.env"
  else
    echo -e "   ${GREEN}✔  deploy/.env ready${RESET}"
  fi
else
  warn "deploy/.env not found"
  info "  Run:  pwsh ./deploy/scripts/init-codespace-env.ps1"
fi

echo ""
info "Deploy:    pwsh ./deploy/deploy.ps1"
info "Teardown:  pwsh ./deploy/teardown.ps1"
info "Docs:      deploy/README.md"
echo ""
