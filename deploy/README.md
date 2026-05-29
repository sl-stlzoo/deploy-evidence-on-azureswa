# Evidence.dev → Azure Static Web Apps Deployment

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/sl-stlzoo/deploy-evidence-on-azureswa)

Fully scripted, idempotent deployment of an [Evidence.dev](https://evidence.dev) instance
to **Azure Static Web Apps Standard** with **Entra ID (Azure AD) single-tenant authentication**
and custom role-based access control.

> **One-liner** (from your Evidence.dev project root in VS Code PowerShell terminal):
> 
> ```powershell
> .\deploy\deploy.ps1
> ```

-----

## Table of Contents

1. [Architecture Overview](#architecture-overview)
1. [Prerequisites](#prerequisites)
1. [Quick Start](#quick-start)
1. [Directory Structure](#directory-structure)
1. [Environment Variables Reference](#environment-variables-reference)
1. [Authentication & Roles](#authentication--roles)
1. [Script Reference](#script-reference)
1. [Idempotency & Re-running Scripts](#idempotency--re-running-scripts)
1. [GitHub Actions CI/CD](#github-actions-cicd)
1. [Moving from .env to Azure Key Vault](#moving-from-env-to-azure-key-vault)
1. [Group-Based Access (Optional)](#group-based-access-optional)
1. [Custom Domain Setup (Next Step)](#custom-domain-setup-next-step)
1. [Troubleshooting](#troubleshooting)
1. [References](#references)

-----

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  GitHub (private repo)                                              │
│                                                                     │
│  Committed (you place these):                                       │
│  ├── .devcontainer/   ← Codespace config + lifecycle scripts        │
│  └── deploy/          ← All deployment and teardown scripts         │
│                                                                     │
│  Generated after first deploy (then committed for CI/CD):          │
│  ├── static/          ← staticwebapp.config.json (auth + routes)   │
│  ├── api/             ← GetRoles Azure Function                     │
│  └── .github/         ← GitHub Actions workflow                    │
│                                                                     │
│  Pulled by post-create.sh into codespace (not committed):          │
│  ├── pages/           ← Evidence.dev reports (.md)                 │
│  ├── sources/         ← Data source definitions                    │
│  └── package.json     ← Evidence.dev project manifest              │
└──────────────────────┬──────────────────────────────────────────────┘
                       │ pwsh ./deploy/deploy.ps1  /  GitHub Actions
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Azure Static Web Apps (Standard SKU)                               │
│                                                                     │
│  ┌─────────────────────────┐   ┌─────────────────────────────────┐  │
│  │  Static Site (Evidence) │   │  Managed Azure Functions API    │  │
│  │  build/ → CDN           │   │  api/GetRoles  → role logic     │  │
│  └─────────────────────────┘   └─────────────────────────────────┘  │
│                                                                     │
│  Auth: Entra ID (single-tenant) via OIDC — all routes protected    │
│  App Settings: AAD_CLIENT_ID, AAD_CLIENT_SECRET, AAD_TENANT_ID     │
└──────────────────────────────────────────────────────────────────────┘
                       │
                       │ Login required for all routes
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Microsoft Entra ID                                                 │
│  App Registration: evidence-swa-prod                                │
│  Audience: AzureADMyOrg (single-tenant only)                       │
└─────────────────────────────────────────────────────────────────────┘
```

**Authentication flow:**

1. User visits any route → SWA checks for `evidence_user` role
1. Unauthenticated → 401 → `responseOverrides` redirects to `/.auth/login/aad`
1. User authenticates with your Entra tenant
1. SWA calls `/api/GetRoles` with user’s claims
1. `GetRoles` verifies tenant ID, optional group membership, returns roles
1. User receives `evidence_user` (and optionally `evidence_admin`) role
1. Access granted to all routes matching `evidence_user`

-----

## Prerequisites

|Tool             |Min Version|Install                                    |
|-----------------|-----------|-------------------------------------------|
|PowerShell       |7+         |`winget install Microsoft.PowerShell`      |
|Node.js          |18 LTS     |<https://nodejs.org>                       |
|Azure CLI (`az`) |2.55+      |<https://aka.ms/installazurecliwindows>    |
|SWA CLI (`swa`)  |2.x        |`npm install -g @azure/static-web-apps-cli`|
|Git              |any        |<https://git-scm.com>                      |
|**Optional**     |           |                                           |
|GitHub CLI (`gh`)|2.x        |`winget install GitHub.cli`                |

**Azure account requirements:**

- PAYG subscription (Free tier does not support Standard SWA or custom auth)
- `Contributor` role on the subscription (or resource group)
- `Application Administrator` role in Entra ID (to create app registrations)

**Run prerequisites check:**

```powershell
.\deploy\scripts\00-prerequisites.ps1        # check only
.\deploy\scripts\00-prerequisites.ps1 -Fix   # check + auto-install swa CLI
```

-----

## Codespace Quickstart

> **Recommended for workshops and shared environments.** No local installs required —
> not even Node.js. Launch a codespace, set env vars, deploy with one command.

### What happens automatically when the codespace starts

The `post-create.sh` lifecycle script runs **once** on first container build and
handles everything in sequence. You do not need to run any of these manually:

|Step|What runs                                  |What it does                                                                                                                                                    |
|----|-------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
|1   |`npx degit evidence-dev/template`          |Pulls the full Evidence.dev project skeleton into the repo root if `pages/` or `package.json` are absent. Existing `.devcontainer/` and `deploy/` are untouched.|
|2   |`npm install`                              |Installs Evidence.dev dependencies from the pulled `package.json`.                                                                                              |
|3   |`npm install -g @azure/static-web-apps-cli`|Installs the SWA CLI globally.                                                                                                                                  |
|4   |`az extension add staticwebapps`           |Ensures the az SWA extension is present.                                                                                                                        |
|5   |`pwsh init-codespace-env.ps1`              |Reads any Codespace secrets already in the environment and writes them to `deploy/.env`, printing a colour-coded status table of set vs missing values.         |


> **The Evidence.dev template is deliberately not committed to the repository.**
> The repo contains only `.devcontainer/` and `deploy/`. The codespace pulls the
> template on first launch via `degit`. This keeps the repository minimal and lets
> Evidence.dev’s template stay up to date independently.

-----

### Step 1 — Set Codespace secrets

Codespace secrets are injected as environment variables before the container
starts. They map directly to `deploy/.env` and are never stored in the repository.

Navigate to: **GitHub repo** → **Settings** → **Secrets and variables** →
**Codespaces** → **New repository secret**

Add these secrets:

|Secret name            |Where to find the value                  |Example                               |
|-----------------------|-----------------------------------------|--------------------------------------|
|`AZURE_SUBSCRIPTION_ID`|`az account show --query id -o tsv`      |`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`|
|`AZURE_TENANT_ID`      |`az account show --query tenantId -o tsv`|`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`|
|`AZURE_LOCATION`       |Choose a region                          |`eastus2`                             |
|`AZURE_RESOURCE_GROUP` |Your choice — will be created            |`rg-evidence-prod`                    |
|`SWA_NAME`             |Your choice — must be globally unique    |`swa-evidence-prod`                   |
|`AAD_APP_NAME`         |Your choice — display name only          |`evidence-swa-prod`                   |
|`REPO_URL`      |This repository’s HTTPS URL              |`https://github.com/org/repo`         |

**Do NOT add these as Codespace secrets** — they are written automatically by
the deploy scripts: `AAD_CLIENT_ID`, `AAD_CLIENT_SECRET`, `SWA_DEPLOYMENT_TOKEN`,
`SWA_DEFAULT_HOSTNAME`.

> **Workshop note:** An instructor sets these secrets once on a shared fork.
> Every participant launches their own codespace from that fork and inherits
> the secrets automatically — no per-participant configuration needed.

-----

### Step 2 — Launch the codespace

**GitHub repo → Code → Codespaces → Create codespace on main**

First launch takes 2–4 minutes. When the terminal appears, `post-create.sh`
has already finished and the codespace is fully ready:

```
╔══════════════════════════════════════════════════════════╗
║   Evidence.dev → Azure SWA  |  Codespace Setup          ║
╚══════════════════════════════════════════════════════════╝

▶  Step 1 — Evidence.dev template
   ✔  Evidence.dev template pulled successfully.
      Files added: package.json, pages/, sources/, evidence.config.yaml, and more.
      Existing .devcontainer/ and deploy/ were not modified.

▶  Step 2 — Evidence.dev project dependencies (npm install)
   ✔  Project dependencies installed.

▶  Step 3 — Azure Static Web Apps CLI
   ✔  swa CLI installed: 2.x.x

▶  Step 4 — az staticwebapps extension
   ✔  staticwebapps extension already present

▶  Step 5 — Bootstrap deploy/.env from Codespace secrets
   ✔  All required values are set.

══════════════════════════════════════════════════════════
   ✔  Codespace setup complete.

   YOUR THREE-COMMAND WORKFLOW:

   # 1. Authenticate to Azure (browser opens — any browser works):
   az login --use-device-code

   # 2. Confirm deploy/.env has all required values (green = set):
   cat deploy/.env

   # 3. Deploy to Azure Static Web Apps:
   pwsh ./deploy/deploy.ps1
══════════════════════════════════════════════════════════
```

If step 5 shows yellow `MISSING` warnings, any Codespace secrets set
*after* the container was created won’t be present until the container
restarts. Either edit `deploy/.env` directly (`code deploy/.env`) or
add the missing secrets in GitHub and run:

```bash
pwsh ./deploy/scripts/init-codespace-env.ps1
```

-----

### Step 3 — Authenticate and deploy

```powershell
# Authenticate — device code works from any browser, no local redirect needed:
az login --use-device-code

# Deploy:
pwsh ./deploy/deploy.ps1
```

The pipeline runs all five steps (~3–5 minutes) and prints your live URL on completion.

-----

### Re-running after changing Codespace secrets

Secrets are injected only at container start. To pick up a new or changed secret
without rebuilding:

```powershell
pwsh ./deploy/scripts/init-codespace-env.ps1
```

To fully rebuild: Codespaces menu → **Rebuild container**.

-----

## Local Quickstart

### 1. Install Evidence.dev (local)

Follow the [Evidence.dev install guide](https://docs.evidence.dev/install-evidence).
The recommended codespace approach:

```bash
npx degit evidence-dev/template my-evidence-project
cd my-evidence-project
npm install
```

### 2. Add this deploy directory

Clone or copy the `deploy/` directory into your Evidence.dev project root:

```
my-evidence-project/
├── pages/
├── sources/
└── deploy/          ← place this directory here
```

### 3. Configure environment variables

```powershell
Copy-Item deploy\.env.example deploy\.env
# Open deploy\.env and fill in all required values
code deploy\.env
```

**Minimum required values to fill in before first run:**

```env
AZURE_SUBSCRIPTION_ID=  # az account show --query id -o tsv
AZURE_TENANT_ID=        # az account show --query tenantId -o tsv
AZURE_LOCATION=         # e.g. eastus2
AZURE_RESOURCE_GROUP=   # e.g. rg-evidence-prod
SWA_NAME=               # globally unique, e.g. swa-evidence-prod
AAD_APP_NAME=           # e.g. evidence-swa-prod
REPO_URL=        # https://github.com/your-org/your-repo
```

Other values (client ID/secret, deployment token, hostname) are **written back
to `.env` automatically** by the provisioning scripts.

### 4. Login to Azure

```powershell
az login
# In a codespace (no browser):
az login --use-device-code
```

### 5. Deploy (one-liner)

```powershell
.\deploy\deploy.ps1
```

The script runs all five steps (~3–5 minutes total) and outputs your live URL.

-----

## Directory Structure

The tree below shows the **complete repository** in its fully deployed state,
with every file annotated by how it gets there. Use the legend to understand
what to commit, what the codespace creates automatically, and what to never commit.

```
Legend:
  [C] Committed to git — you place this in the repo before launch
  [T] Pulled by post-create.sh from the Evidence.dev template — NOT committed
  [G] Generated at runtime by a deploy script — commit after first deploy
  [X] Gitignored — never committed
```

```
your-evidence-project/                          ← repository root
│
│ ─── CODESPACE CONFIGURATION ───────────────────────────────────────────
│
├── .devcontainer/                         [C] Must be at the repo ROOT.
│   │                                          GitHub looks here for Codespace
│   │                                          config. Not inside deploy/.
│   │
│   ├── devcontainer.json                  [C] Declares the container image
│   │                                          (ubuntu-24.04), dev features
│   │                                          (node:20, powershell, azure-cli,
│   │                                          github-cli), VS Code
│   │                                          extensions, port forwarding,
│   │                                          and the lifecycle hooks below.
│   │
│   ├── post-create.sh                     [C] Runs ONCE on first container
│   │                                          build. Executes five steps:
│   │                                          1. degit evidence-dev/template
│   │                                          2. npm install
│   │                                          3. npm install -g swa
│   │                                          4. az extension add staticwebapps
│   │                                          5. init-codespace-env.ps1
│   │
│   └── motd.sh                            [C] Runs on every container start.
│                                              Prints Azure login status and
│                                              flags any missing .env values.
│
│ ─── EVIDENCE.DEV PROJECT (pulled by post-create.sh, not committed) ────
│
├── package.json                           [T] Evidence.dev project manifest.
├── evidence.config.yaml                   [T] Data source configuration.
├── pages/                                 [T] Your report files (.md).
│   └── index.md                           [T] Default homepage.
├── sources/                               [T] Data source definitions.
└── (remaining template files)            [T] .npmrc, .gitignore, etc.
│
│ ─── GENERATED BY DEPLOY SCRIPTS (commit after first deploy) ───────────
│
├── static/
│   └── staticwebapp.config.json           [G] Written by 03-configure-swa.ps1
│                                              from deploy/templates/
│                                              staticwebapp.config.template.json
│                                              with %%TENANT_ID%% substituted.
│                                              THIS FILE ACTIVATES AUTH — all
│                                              routes are locked until it exists.
│
├── api/                                   [G] Copied from deploy/api-src/
│   ├── host.json                          [G] by 03-configure-swa.ps1.
│   ├── package.json                       [G] Do not edit these directly;
│   └── GetRoles/                          [G] edit deploy/api-src/ and
│       ├── function.json                  [G] re-run step 3.
│       └── index.js                       [G]
│
├── swa-cli.config.json                    [G] Written by 04-build-deploy.ps1
│                                              if not already present. Controls
│                                              app/api/output locations for
│                                              the SWA CLI.
│
└── .github/
    └── workflows/
        └── azure-static-web-apps          [G] Written by 03-configure-swa.ps1
              -deploy.yml                      from the yml.template. Commit
│                                              this to enable CI/CD on push.
│
│ ─── GITIGNORED (never committed) ──────────────────────────────────────
│
├── deploy/.env                            [X] Created by init-codespace-env.ps1
│                                              from Codespace secrets + defaults.
│                                              Contains AAD_CLIENT_SECRET and
│                                              SWA_DEPLOYMENT_TOKEN — never commit.
├── build/                                 [X] Evidence.dev build output.
└── node_modules/                          [X] npm dependencies.
│
│ ─── DEPLOYMENT SCRIPTS (all committed inside deploy/) ─────────────────
│
└── deploy/
    │
    ├── deploy.ps1                         [C] ENTRY POINT — one-liner deploy.
    │                                          Orchestrates steps 0–4 in order.
    │                                          Usage: pwsh ./deploy/deploy.ps1
    │
    ├── teardown.ps1                       [C] ENTRY POINT — one-liner teardown.
    │                                          Orchestrates steps 10–12 in order.
    │                                          Usage: pwsh ./deploy/teardown.ps1
    │
    ├── .env.example                       [C] Canonical list of every variable
    │                                          with comments and example values.
    │                                          Copy to .env and populate.
    │
    ├── .gitignore                         [C] Excludes deploy/.env, build/,
    │                                          node_modules/, .azure/, generated/
    │
    ├── README.md                          [C] This file.
    │
    ├── scripts/
    │   │
    │   ├── helpers.ps1                    [C] Shared utilities dot-sourced by
    │   │                                      all other scripts. Provides
    │   │                                      Import-EnvFile, Set-EnvFileLine,
    │   │                                      Require-EnvVar, Write-Step/OK/Warn,
    │   │                                      Invoke-Az, Confirm-Step.
    │   │
    │   ├── init-codespace-env.ps1         [C] Called by post-create.sh (step 5).
    │   │                                      Reads Codespace secrets from the
    │   │                                      process environment, merges with
    │   │                                      any existing deploy/.env values,
    │   │                                      writes the result to deploy/.env,
    │   │                                      and prints a status table.
    │   │                                      Safe to re-run at any time.
    │   │
    │   ├── 00-prerequisites.ps1           [C] Checks: PowerShell 7+, Node 18+,
    │   │                                      npm, az CLI, swa CLI, gh CLI, git.
    │   │                                      Pass -Fix to auto-install swa CLI.
    │   │
    │   ├── 01-provision-azure.ps1         [C] Idempotent. Creates resource group
    │   │                                      and SWA (Standard SKU). Writes
    │   │                                      SWA_DEFAULT_HOSTNAME and
    │   │                                      SWA_DEPLOYMENT_TOKEN to deploy/.env.
    │   │
    │   ├── 02-register-app.ps1            [C] Idempotent. Creates (or locates)
    │   │                                      the Entra app registration and
    │   │                                      service principal. Writes
    │   │                                      AAD_CLIENT_ID and AAD_CLIENT_SECRET
    │   │                                      to deploy/.env.
    │   │
    │   ├── 03-configure-swa.ps1           [C] Sets SWA app settings (client ID,
    │   │                                      secret, tenant ID). Generates
    │   │                                      static/staticwebapp.config.json,
    │   │                                      copies api-src/ → api/, generates
    │   │                                      .github/workflows/ yml, optionally
    │   │                                      registers GitHub Actions secret.
    │   │
    │   ├── 04-build-deploy.ps1            [C] Runs npm run build (Evidence.dev),
    │   │                                      then swa deploy. Accepts -SkipBuild
    │   │                                      and -SkipDeploy flags.
    │   │
    │   ├── 10-remove-files.ps1            [C] Teardown step. Removes generated
    │   │                                      files from the project root:
    │   │                                      static/staticwebapp.config.json,
    │   │                                      api/, .github/workflows/ yml,
    │   │                                      swa-cli.config.json.
    │   │
    │   ├── 11-remove-entra-app.ps1        [C] Teardown step. Deletes the Entra
    │   │                                      service principal and app
    │   │                                      registration. Optionally removes
    │   │                                      the GitHub Actions secret via gh.
    │   │                                      Blanks AAD_* values in deploy/.env.
    │   │
    │   └── 12-remove-azure-resources.ps1  [C] Teardown step. Deletes the SWA
    │                                          resource and (by default) the
    │                                          entire resource group. Pass
    │                                          -KeepResourceGroup to delete SWA
    │                                          only. Blanks SWA_* values in .env.
    │
    ├── templates/
    │   │
    │   ├── staticwebapp.config            [C] Auth and route configuration
    │   │     .template.json                   template. Contains %%TENANT_ID%%
    │   │                                      and %%SWA_HOSTNAME%% placeholders
    │   │                                      substituted by step 3. Disables all
    │   │                                      auth providers except Entra ID.
    │   │                                      Locks all routes to evidence_user.
    │   │                                      Redirects 401/403 → Entra login.
    │   │
    │   ├── azure-static-web-apps          [C] GitHub Actions workflow template.
    │   │     .yml.template                    Contains %%REPO_BRANCH%%
    │   │                                      placeholder substituted by step 3.
    │   │                                      Builds and deploys on push to main.
    │   │
    │   └── swa-cli.config.json            [C] SWA CLI configuration template
    │                                          copied to the project root by
    │                                          step 4 if not already present.
    │
    └── api-src/                           [C] Source of truth for the Azure
        │                                      Functions API. Step 3 copies this
        │                                      directory to api/ at the project
        │                                      root. Edit here, not in api/.
        │
        ├── host.json                      [C] Functions host configuration.
        │                                      Sets extension bundle v4.
        │
        ├── package.json                   [C] Functions package manifest.
        │
        └── GetRoles/
            ├── function.json              [C] HTTP trigger binding (POST,
            │                                  anonymous auth level — SWA
            │                                  controls access, not Functions).
            │
            └── index.js                   [C] Role assignment logic. Verifies
                                               the tid claim matches AAD_TENANT_ID,
                                               optionally checks group membership,
                                               returns evidence_user and/or
                                               evidence_admin roles.
```

### File counts

|Category                                    |Count       |Notes                                                     |
|--------------------------------------------|------------|----------------------------------------------------------|
|**Committed** (`.devcontainer/` + `deploy/`)|**25 files**|Everything you place in the repo                          |
|**Template** (pulled by `post-create.sh`)   |~12 files   |`package.json`, `pages/`, `sources/`, etc. — not committed|
|**Generated** (created by deploy scripts)   |**6 files** |Commit after first deploy for CI/CD                       |
|**Gitignored**                              |—           |`deploy/.env`, `build/`, `node_modules/`                  |

### Commit sequence after first deploy

Run this after `deploy.ps1` completes successfully. These generated files must
be committed for GitHub Actions CI/CD to function on subsequent pushes:

```bash
git add .devcontainer/
git add deploy/
git add static/staticwebapp.config.json
git add api/
git add swa-cli.config.json
git add .github/workflows/azure-static-web-apps-deploy.yml
git commit -m "Add SWA deployment configuration and Codespace setup"
git push
```

> **Do not** run `git add .` — this risks accidentally staging `deploy/.env`
> if the root `.gitignore` from the Evidence.dev template hasn’t been extended
> to cover it. Stage paths explicitly as shown above.

-----

## Environment Variables Reference

|Variable                   |Required|Auto-set|Description                                      |
|---------------------------|--------|--------|-------------------------------------------------|
|`AZURE_SUBSCRIPTION_ID`    |✅       |        |Azure subscription GUID                          |
|`AZURE_TENANT_ID`          |✅       |        |Entra tenant GUID — restricts auth to this tenant|
|`AZURE_LOCATION`           |✅       |        |Azure region (e.g. `eastus2`)                    |
|`AZURE_RESOURCE_GROUP`     |✅       |        |Resource group name                              |
|`AZURE_RESOURCE_TAGS`      |        |        |`key=value,key=value` tags for resource group    |
|`SWA_NAME`                 |✅       |        |Globally unique SWA resource name                |
|`SWA_SKU`                  |        |        |Always `Standard` (scripts enforce this)         |
|`SWA_DEPLOYMENT_TOKEN`     |        |✅ step 1|SWA API key for deployments                      |
|`SWA_DEFAULT_HOSTNAME`     |        |✅ step 1|`*.azurestaticapps.net` hostname                 |
|`AAD_APP_NAME`             |✅       |        |Display name for the Entra app registration      |
|`AAD_CLIENT_ID`            |        |✅ step 2|App registration client ID                       |
|`AAD_CLIENT_SECRET`        |        |✅ step 2|Client secret (stored in .env only)              |
|`EVIDENCE_ADMIN_USERS`     |        |        |Comma-separated UPNs for `evidence_admin` role   |
|`EVIDENCE_ALLOWED_GROUP_ID`|        |        |Entra group OID — restricts to group members     |
|`REPO_URL`          |✅       |        |`https://github.com/org/repo`                    |
|`REPO_BRANCH`            |        |        |Default: `main`                                  |
|`GH_PAT`               |        |        |PAT for `gh secret set` (optional)               |
|`NODE_VERSION`             |        |        |Default: `20`                                    |
|`EVIDENCE_PROJECT_ROOT`    |        |        |Default: `..` (parent of `deploy/`)              |
|`CUSTOM_DOMAIN_APEX`       |        |        |e.g. `example.com` (future use)                  |
|`CUSTOM_DOMAIN_SUBDOMAIN`  |        |        |e.g. `analytics` (future use)                    |
|`CUSTOM_DOMAIN`            |        |        |e.g. `analytics.example.com` (future use)        |

-----

## Authentication & Roles

### How it works

Azure Static Web Apps Standard supports custom auth via OIDC. This deployment
configures the `aad` provider against **your Entra tenant only** — users from
other organisations cannot log in.

The `staticwebapp.config.json` (generated from the template):

- Disables all other built-in providers (GitHub, Twitter, Facebook, Google, Apple)
- Requires `evidence_user` **or** `evidence_admin` role for all routes (`/*`)
- Overrides 401/403 responses to redirect to `/.auth/login/aad`
- Calls `/api/GetRoles` after every successful Entra login

### Custom roles

|Role            |Assigned to                   |Access    |
|----------------|------------------------------|----------|
|`evidence_user` |All verified tenant members   |All routes|
|`evidence_admin`|UPNs in `EVIDENCE_ADMIN_USERS`|All routes|

### Restricting to a group

Set `EVIDENCE_ALLOWED_GROUP_ID` in `.env` to an Entra security group Object ID.
Only members of that group will receive the `evidence_user` role.

You must also enable group claims in the app registration manifest:

1. Azure portal → **Entra ID** → **App registrations** → your app → **Manifest**
1. Set `"groupMembershipClaims": "SecurityGroup"`
1. Save

### Manual role assignment (alternative)

For small teams, skip `EVIDENCE_ALLOWED_GROUP_ID` and use SWA’s built-in
invitation system:

Azure portal → **Static Web Apps** → your app → **Role management** → **Invite**

Invitees receive a link; once accepted, the SWA assigns the role you specify.
This bypasses the `GetRoles` function for that user.

-----

## Script Reference

Run individual scripts from the project root:

```powershell
# Prerequisites check (and auto-install swa CLI)
.\deploy\scripts\00-prerequisites.ps1 -Fix

# Provision Azure resources only
.\deploy\scripts\01-provision-azure.ps1 -EnvFile .\deploy\.env

# Register / update Entra app only
.\deploy\scripts\02-register-app.ps1 -EnvFile .\deploy\.env

# Update SWA config and auth settings (after changing .env)
.\deploy\scripts\03-configure-swa.ps1 -EnvFile .\deploy\.env

# Rebuild and redeploy
.\deploy\scripts\04-build-deploy.ps1 -EnvFile .\deploy\.env

# Redeploy without rebuilding (fast — uses existing build/)
.\deploy\scripts\04-build-deploy.ps1 -SkipBuild

# Build without deploying (CI validation)
.\deploy\scripts\04-build-deploy.ps1 -SkipDeploy
```

**Partial pipeline runs** (resume after a failure, or skip to specific steps):

```powershell
# Run only steps 3 and 4 (after updating config)
.\deploy\deploy.ps1 -Steps "3,4"

# Run only step 4 (quick redeploy)
.\deploy\deploy.ps1 -Steps "4"
```

-----

## Idempotency & Re-running Scripts

All provisioning scripts are safe to re-run:

|Script                 |Idempotency mechanism                                              |
|-----------------------|-------------------------------------------------------------------|
|`01` — Resource group  |`az group show` before `az group create`                           |
|`01` — SWA             |`az staticwebapp show` before `az staticwebapp create`             |
|`02` — App registration|`az ad app list --display-name` before `az ad app create`          |
|`02` — Client secret   |Only creates a new secret if `AAD_CLIENT_SECRET` is blank in `.env`|
|`03` — App settings    |`az staticwebapp appsettings set` is always idempotent (upsert)    |
|`03` — Config files    |Files are overwritten on each run (safe)                           |

**To rotate the client secret:**

1. Delete `AAD_CLIENT_SECRET=` from `deploy\.env` (leave the key, blank the value)
1. Run `.\deploy\scripts\02-register-app.ps1 -EnvFile .\deploy\.env`
1. Run `.\deploy\scripts\03-configure-swa.ps1 -EnvFile .\deploy\.env` to push the new secret to SWA

-----

## GitHub Actions CI/CD

After running the full pipeline, commit the generated workflow file:

```powershell
git add .github/workflows/azure-static-web-apps-deploy.yml
git add static/staticwebapp.config.json
git add api/
git commit -m "Add Azure SWA deployment configuration"
git push
```

The workflow triggers on every push to `main` and builds + deploys automatically.

### GitHub Actions secret

The workflow needs `AZURE_STATIC_WEB_APPS_API_TOKEN` set as a repository secret.

**Automatic** (if `gh` CLI is installed and `GH_PAT` or `gh auth login` is done):  
Step 3 of the deployment sets it automatically.

**Manual:**

1. Copy `SWA_DEPLOYMENT_TOKEN` from `deploy\.env`
1. GitHub → repo → **Settings** → **Secrets and variables** → **Actions** → **New secret**
1. Name: `AZURE_STATIC_WEB_APPS_API_TOKEN` | Value: paste token

-----

## Moving from .env to Azure Key Vault

The `.env` file stores secrets (client secret, deployment token) in plain text on
disk. For production workloads, migrate these to Azure Key Vault.

### Overview of the migration

```
.env (local)  →  Azure Key Vault  →  SWA App Settings (reference)
```

Azure Static Web Apps can reference Key Vault secrets directly in app settings
using the `@Microsoft.KeyVault(...)` syntax.

### Step 1 — Create a Key Vault

```powershell
# Add to your .env:
# KV_NAME=kv-evidence-prod

az keyvault create `
  --name            $env:KV_NAME `
  --resource-group  $env:AZURE_RESOURCE_GROUP `
  --location        $env:AZURE_LOCATION `
  --sku             standard `
  --enable-rbac-authorization true
```

### Step 2 — Store secrets in Key Vault

```powershell
az keyvault secret set --vault-name $env:KV_NAME --name "AAD-CLIENT-SECRET" --value $env:AAD_CLIENT_SECRET
az keyvault secret set --vault-name $env:KV_NAME --name "SWA-DEPLOYMENT-TOKEN" --value $env:SWA_DEPLOYMENT_TOKEN
```

### Step 3 — Grant SWA managed identity access to Key Vault

```powershell
# Enable system-assigned managed identity on the SWA
$swaIdentity = az staticwebapp show `
  --name $env:SWA_NAME `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query "identity.principalId" -o tsv

# Grant Key Vault Secrets User role
$kvResourceId = az keyvault show --name $env:KV_NAME --query "id" -o tsv

az role assignment create `
  --assignee    $swaIdentity `
  --role        "Key Vault Secrets User" `
  --scope       $kvResourceId
```

> **Note:** Azure Static Web Apps managed identity for Key Vault references is
> supported in the Standard plan. See:
> <https://learn.microsoft.com/en-us/azure/static-web-apps/key-vault-secrets>

### Step 4 — Update SWA app settings to reference Key Vault

```powershell
$kvUri = az keyvault show --name $env:KV_NAME --query "properties.vaultUri" -o tsv
$kvUri = $kvUri.TrimEnd('/')

az staticwebapp appsettings set `
  --name           $env:SWA_NAME `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --setting-names `
    "AAD_CLIENT_SECRET=@Microsoft.KeyVault(SecretUri=${kvUri}/secrets/AAD-CLIENT-SECRET/)" `
    "AAD_CLIENT_ID=$env:AAD_CLIENT_ID" `
    "AAD_TENANT_ID=$env:AZURE_TENANT_ID"
```

### Step 5 — Remove secrets from .env

Once Key Vault is configured and verified, remove the raw secret values from
`deploy\.env` (keep the key names but blank the values):

```env
AAD_CLIENT_SECRET=    # ← now stored in Key Vault
SWA_DEPLOYMENT_TOKEN= # ← now stored in Key Vault
```

Store the `.env` file with only non-secret config values in a secure location
(e.g. an encrypted vault, 1Password, or Azure DevOps variable groups).

### CI/CD with Key Vault

For GitHub Actions, the deployment token should remain as a GitHub Actions
secret (`AZURE_STATIC_WEB_APPS_API_TOKEN`). GitHub Actions does not have access
to your Key Vault unless you add an additional OIDC/service-principal step.

-----

## Group-Based Access (Optional)

To restrict Evidence.dev access to members of a specific Entra security group:

### 1. Create or identify the security group

```powershell
# Create a new group
az ad group create --display-name "Evidence Users" --mail-nickname "evidence-users"
# Get the group Object ID
az ad group show --group "Evidence Users" --query "id" -o tsv
```

### 2. Set the group ID in .env

```env
EVIDENCE_ALLOWED_GROUP_ID=<group-object-id>
```

### 3. Enable group claims in the app manifest

Azure portal → Entra ID → App registrations → `evidence-swa-prod` → Manifest:

```json
"groupMembershipClaims": "SecurityGroup"
```

### 4. Re-run configuration

```powershell
.\deploy\deploy.ps1 -Steps "3"
```

### 5. Add users to the group

```powershell
az ad group member add --group "Evidence Users" --member-id <user-object-id>
```

-----

## Custom Domain Setup (Next Step)

> Custom domain binding is **out of scope** for the initial deployment scripts
> but the environment variables are included for future use.

When you are ready to bind a subdomain (e.g. `analytics.example.com`):

### 1. Populate the domain variables in .env

```env
CUSTOM_DOMAIN_APEX=example.com
CUSTOM_DOMAIN_SUBDOMAIN=analytics
CUSTOM_DOMAIN=analytics.example.com
```

### 2. Add the custom domain to the SWA

```powershell
az staticwebapp hostname set `
  --name           $env:SWA_NAME `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --hostname       $env:CUSTOM_DOMAIN
```

Azure will return a validation token (TXT record or CNAME, depending on your
setup). Add it to your DNS provider.

### 3. Update the Entra redirect URI

After the custom domain is active, add it as an additional redirect URI in
the app registration:

```powershell
$newRedirectUri = "https://$($env:CUSTOM_DOMAIN)/.auth/login/aad/callback"
az ad app update `
  --id                $env:AAD_CLIENT_ID `
  --web-redirect-uris `
    "https://$($env:SWA_DEFAULT_HOSTNAME)/.auth/login/aad/callback" `
    $newRedirectUri
```

### DNS provider guidance

|Provider  |Docs link                                                                            |
|----------|-------------------------------------------------------------------------------------|
|Cloudflare|<https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/>|
|Azure DNS |<https://learn.microsoft.com/en-us/azure/dns/dns-getstarted-portal>                  |
|GoDaddy   |<https://www.godaddy.com/help/add-a-cname-record-19236>                              |

**For an apex/root domain** (`example.com` rather than a subdomain), use Azure
DNS or a DNS provider that supports CNAME flattening (Cloudflare, Route53).
SWA requires a CNAME record; apex CNAMEs are not standard DNS — use ALIAS/ANAME
records or CNAME flattening.

**Reference:**  
<https://learn.microsoft.com/en-us/azure/static-web-apps/custom-domain>

-----

## Troubleshooting

### `az staticwebapp create` fails with “SKU not available in region”

Not all Azure regions support the Standard SWA SKU. Try:

- `eastus`, `eastus2`, `westus2`, `westeurope`, `centralus`, `uksouth`

### Login redirects loop or returns 403 after Entra sign-in

1. Verify the redirect URI in the app registration matches exactly:
   `https://<hostname>/.auth/login/aad/callback`
1. Check that `AAD_CLIENT_ID` and `AAD_CLIENT_SECRET` are set correctly as SWA
   app settings (Azure portal → SWA → Configuration).
1. Check `GetRoles` function logs: Azure portal → SWA → Functions → GetRoles → Monitor.
1. Confirm `AAD_TENANT_ID` matches the tenant the user is logging in from.

### `swa deploy` fails with “Deployment token is not valid”

The `SWA_DEPLOYMENT_TOKEN` in `.env` may be stale. Refresh it:

```powershell
az staticwebapp secrets list `
  --name $env:SWA_NAME `
  --resource-group $env:AZURE_RESOURCE_GROUP `
  --query "properties.apiKey" -o tsv
```

Update `SWA_DEPLOYMENT_TOKEN` in `.env`, then re-run step 4.

### `npm run build` fails in Evidence.dev

- Ensure data source connection strings/credentials are set as environment
  variables or in `evidence.config.yaml`.
- For DuckDB sources, verify `.parquet` or `.csv` files are present.
- Run `npm run dev` locally first to validate the project builds cleanly.

### Client secret expired

Client secrets created with `--years 2` expire after 2 years. To rotate:

1. Delete `AAD_CLIENT_SECRET=<value>` from `.env` (leave blank: `AAD_CLIENT_SECRET=`)
1. `.\deploy\scripts\02-register-app.ps1 -EnvFile .\deploy\.env`
1. `.\deploy\scripts\03-configure-swa.ps1 -EnvFile .\deploy\.env`

-----

## Teardown

To remove all provisioned resources — useful after a workshop, demo, or when decommissioning — run the teardown one-liner from your project root:

```powershell
.\deploy\teardown.ps1
```

This reverses the deployment pipeline in reverse dependency order:

|Step|What is removed                                                                          |
|----|-----------------------------------------------------------------------------------------|
|10  |Generated project files (`static/staticwebapp.config.json`, `api/`, `.github/workflows/`)|
|11  |Entra ID app registration, service principal, and GitHub Actions secret                  |
|12  |Azure Static Web App and the entire resource group (all contents)                        |

Each destructive action prompts for confirmation. Step 12 requires you to **type the resource group name** to confirm deletion of the entire group.

**Common teardown variants:**

```powershell
# Non-interactive / workshop cleanup (no prompts):
.\deploy\teardown.ps1 -Force

# Delete Azure resources only (skip file cleanup and Entra app):
.\deploy\teardown.ps1 -Steps "12"

# Delete the SWA but keep the resource group (other resources inside are preserved):
.\deploy\teardown.ps1 -Steps "12" -KeepResourceGroup

# Remove only the generated project files (no Azure or Entra changes):
.\deploy\teardown.ps1 -Steps "10"

# Remove Entra app + Azure resources (leave project files in place):
.\deploy\teardown.ps1 -Steps "11,12"
```

**What teardown preserves:**

- `deploy/.env` — the file remains, but auto-generated secrets (`AAD_CLIENT_ID`, `AAD_CLIENT_SECRET`, `SWA_DEPLOYMENT_TOKEN`, `SWA_DEFAULT_HOSTNAME`) are blanked so a fresh `deploy.ps1` run starts clean
- All Evidence.dev source files (`pages/`, `sources/`, etc.)
- The `deploy/` directory itself

**Entra soft-delete:** Deleted app registrations sit in Entra’s soft-delete bin for 30 days. If you redeploy with the same `AAD_APP_NAME` within that window, `02-register-app.ps1` will find the existing (soft-deleted) app. To hard-delete immediately: Azure portal → Entra ID → App registrations → Deleted applications → select → Delete permanently.

-----

## References

|Resource                     |URL                                                                                                   |
|-----------------------------|------------------------------------------------------------------------------------------------------|
|Evidence.dev deployment docs |<https://docs.evidence.dev/deployment/self-host/azure-static-apps/>                                   |
|SWA custom authentication    |<https://learn.microsoft.com/en-us/azure/static-web-apps/authentication-custom>                       |
|SWA auth + Entra ID blog post|<https://blog.andreev.it/2024/03/entra-id-azure-ad-sso-and-azure-static-web-apps/>                    |
|SWA route configuration      |<https://learn.microsoft.com/en-us/azure/static-web-apps/configuration>                               |
|SWA custom roles             |<https://learn.microsoft.com/en-us/azure/static-web-apps/authentication-custom?tabs=aad%2Cinvitations>|
|SWA Key Vault integration    |<https://learn.microsoft.com/en-us/azure/static-web-apps/key-vault-secrets>                           |
|SWA custom domain            |<https://learn.microsoft.com/en-us/azure/static-web-apps/custom-domain>                               |
|Entra app registrations      |<https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app>                   |
|Azure CLI static web apps    |<https://learn.microsoft.com/en-us/cli/azure/staticwebapp>                                            |
|SWA CLI reference            |<https://azure.github.io/static-web-apps-cli/>                                                        |
|Evidence.dev install guide   |<https://docs.evidence.dev/install-evidence>                                                          |
