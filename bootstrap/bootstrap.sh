#!/usr/bin/env bash
#
# bootstrap.sh - Bootstrap OpenVox (masterless) and run homelab baseline configuration
#
# 1. Installs OpenVox Agent (`openvox-agent`) via DNF from Vox Pupuli repositories
# 2. Prompts for required secrets (Cloudflare API Key for ddclient)
# 3. Executes masterless run (`puppet apply`)
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

# Ensure puppet/openvox binary directories are in PATH
export PATH="/opt/puppetlabs/bin:/opt/openvox/bin:${PATH}"

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
echo "      Homelab OpenVox Bootstrap - RHEL 10 Setup             "
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# Step 1: Install OpenVox Agent via DNF
# ------------------------------------------------------------------
info "Step 1/3: Checking OpenVox installation..."

PUPPET_BIN="$(command -v puppet || command -v openvox || echo "/opt/puppetlabs/bin/puppet")"

if command -v "$PUPPET_BIN" &>/dev/null || [[ -x "$PUPPET_BIN" ]]; then
    ok "OpenVox / Puppet is already installed: $($PUPPET_BIN --version)"
else
    info "OpenVox not found. Installing openvox-agent via DNF..."

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

    # Install the OpenVox release repository package from Vox Pupuli (https://voxpupuli.org/openvox/install/)
    REPO_URL="https://yum.voxpupuli.org/openvox8-release-el-${EL_VER}.noarch.rpm"

    info "Adding OpenVox repository from ${REPO_URL}..."
    if ! run_root dnf install -y "${REPO_URL}"; then
        err "Failed to install OpenVox release RPM from ${REPO_URL}."
        exit 1
    fi

    # Install openvox-agent
    info "Installing openvox-agent package..."
    run_root dnf install -y openvox-agent

    # Ensure /opt/puppetlabs/bin and /opt/openvox/bin are accessible
    export PATH="/opt/puppetlabs/bin:/opt/openvox/bin:${PATH}"

    # Create convenient symlink in /usr/local/bin if not present
    if [[ -x /opt/puppetlabs/bin/puppet ]] && [[ ! -e /usr/local/bin/puppet ]]; then
        run_root ln -sf /opt/puppetlabs/bin/puppet /usr/local/bin/puppet || true
    fi

    PUPPET_BIN="$(command -v puppet || command -v openvox || echo "/opt/puppetlabs/bin/puppet")"
    if [[ -x "$PUPPET_BIN" ]] || command -v "$PUPPET_BIN" &>/dev/null; then
        ok "OpenVox installed successfully: $($PUPPET_BIN --version)"
    else
        err "Failed to verify OpenVox installation via DNF."
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
elif [[ -f "${PROJECT_ROOT}/data/secrets.yaml" ]]; then
    ok "Found existing ${PROJECT_ROOT}/data/secrets.yaml. Skipping prompt."
    CF_KEY=""
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

    # Write to data/secrets.yaml for subsequent standalone runs
    mkdir -p "${PROJECT_ROOT}/data"
    cat > "${PROJECT_ROOT}/data/secrets.yaml" <<EOF
---
homelab::cloudflare_token: '${CF_KEY}'
EOF
    chmod 600 "${PROJECT_ROOT}/data/secrets.yaml"
    ok "Saved secret to ${PROJECT_ROOT}/data/secrets.yaml (mode 0600)."
fi

echo ""

# ------------------------------------------------------------------
# Step 3: Run OpenVox (Masterless Apply)
# ------------------------------------------------------------------
info "Step 3/3: Executing OpenVox masterless run..."

info "Project Root: ${PROJECT_ROOT}"

cd "${PROJECT_ROOT}"

PUPPET_BIN="$(command -v puppet || command -v openvox || echo "/opt/puppetlabs/bin/puppet")"

ENV_VARS=()
if [[ -n "${CF_KEY}" ]]; then
    ENV_VARS+=("FACTER_cloudflare_token=${CF_KEY}")
fi
ENV_VARS+=(
    "FACTER_ddclient_replace_config=true"
    "PATH=/opt/puppetlabs/bin:/opt/openvox/bin:${PATH}"
)

# Run puppet apply with any additional arguments passed to bootstrap.sh (e.g. --noop)
run_root env "${ENV_VARS[@]}" \
    "${PUPPET_BIN}" apply \
    --modulepath="${PROJECT_ROOT}/modules" \
    --hiera_config="${PROJECT_ROOT}/hiera.yaml" \
    "$@" \
    "${PROJECT_ROOT}/manifests/site.pp"

ok "OpenVox configuration run completed successfully!"

