#!/usr/bin/env bash
#
# bootstrap.sh - Bootstrap Puppet Bolt and run homelab baseline configuration
#
# 1. Installs Puppet Bolt via DNF
# 2. Prompts for required secrets (Cloudflare API Key for ddclient)
# 3. Executes the Puppet Bolt plan
#

set -euo pipefail

# ANSI color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Determine project directory (one level up from this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Helper to run commands as root if needed
run_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        err "Root privileges required, but sudo is not installed."
        exit 1
    fi
}

echo "============================================================"
echo "      Homelab Puppet Bolt Bootstrap - RHEL 10 Setup         "
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# Step 1: Install Puppet Bolt via DNF
# ------------------------------------------------------------------
info "Step 1/3: Checking Puppet Bolt installation..."

if command -v bolt &>/dev/null; then
    ok "Puppet Bolt is already installed: $(bolt --version)"
else
    info "Puppet Bolt not found. Installing via DNF..."

    # Detect Enterprise Linux major version (defaulting to 10)
    EL_VER="$(rpm -E '%{rhel}' 2>/dev/null || true)"
    if [[ -z "${EL_VER}" || "${EL_VER}" == "%{rhel}" ]]; then
        if [[ -f /etc/os-release ]]; then
            EL_VER="$(grep -oP 'VERSION_ID="?\K[0-9]+' /etc/os-release | head -n1 || echo "10")"
        else
            EL_VER="10"
        fi
    fi

    info "Detected Enterprise Linux version: ${EL_VER}"

    # Install the Puppet release repository package
    REPO_URL="https://yum.puppet.com/puppet-tools-release-el-${EL_VER}.noarch.rpm"
    REPO_FALLBACK_URL="https://yum.puppet.com/puppet8-release-el-${EL_VER}.noarch.rpm"

    info "Adding Puppet repository from ${REPO_URL}..."
    if ! run_root dnf install -y "${REPO_URL}"; then
        warn "Could not install primary repo RPM. Trying fallback repo: ${REPO_FALLBACK_URL}"
        run_root dnf install -y "${REPO_FALLBACK_URL}" || true
    fi

    # Install puppet-bolt
    info "Installing puppet-bolt package..."
    run_root dnf install -y puppet-bolt

    if command -v bolt &>/dev/null; then
        ok "Puppet Bolt installed successfully: $(bolt --version)"
    else
        err "Failed to install Puppet Bolt via DNF."
        exit 1
    fi
fi

echo ""

# ------------------------------------------------------------------
# Step 2: Prompt for Secrets
# ------------------------------------------------------------------
info "Step 2/3: Gathering secrets..."

# Check if already supplied via environment variable
if [[ -n "${CLOUDFLARE_API_KEY:-}" ]]; then
    CF_KEY="${CLOUDFLARE_API_KEY}"
    ok "Using Cloudflare API key from environment variable CLOUDFLARE_API_KEY."
elif [[ -n "${CLOUDFLARE_TOKEN:-}" ]]; then
    CF_KEY="${CLOUDFLARE_TOKEN}"
    ok "Using Cloudflare API key from environment variable CLOUDFLARE_TOKEN."
else
    echo ""
    echo "------------------------------------------------------------"
    echo " Cloudflare Dynamic DNS Configuration for ddclient          "
    echo " Target zone:    brookemao.ca                               "
    echo " Domains:        homelab.brookemao.ca, mindustry.brookemao.ca"
    echo "------------------------------------------------------------"
    echo -n "Enter Cloudflare API Key / Token (hidden): "
    read -r -s CF_KEY
    echo ""

    while [[ -z "${CF_KEY// }" ]]; do
        warn "Cloudflare API Key cannot be empty."
        echo -n "Enter Cloudflare API Key / Token (hidden): "
        read -r -s CF_KEY
        echo ""
    done
    ok "Cloudflare API Key captured."
fi

echo ""

# ------------------------------------------------------------------
# Step 3: Run Puppet Bolt
# ------------------------------------------------------------------
info "Step 3/3: Running Puppet Bolt plan..."

# Allow passing custom targets as first argument, defaults to 'localhost'
TARGETS="${1:-localhost}"

info "Project Root: ${PROJECT_ROOT}"
info "Target Host:  ${TARGETS}"

cd "${PROJECT_ROOT}"

# Execute the bolt plan with the gathered secret
run_root bolt plan run homelab \
    targets="${TARGETS}" \
    cloudflare_token="${CF_KEY}" \
    ddclient_replace_config=true

ok "Puppet Bolt run completed successfully!"
