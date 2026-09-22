#!/usr/bin/env bash
#
# bootstrap.sh - Bootstrap OpenVox (masterless) and run homelab baseline configuration
#
# 1. Installs OpenVox Agent (`openvox-agent`) via DNF with sudo from Vox Pupuli repositories
# 2. Prompts for required secrets (Cloudflare API Key for ddclient)
# 3. Executes masterless run with sudo (`sudo puppet apply`)
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

# Configure sudo with explicit PATH to resolve system binaries
SYS_PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/opt/puppetlabs/bin"
SUDO=""
if [[ $EUID -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo env PATH=${SYS_PATH}"
    else
        err "Root privileges required, but sudo is not installed."
        exit 1
    fi
else
    SUDO="env PATH=${SYS_PATH}"
fi

echo "============================================================"
echo "      Homelab OpenVox Bootstrap - RHEL 10 Setup             "
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# Step 1: Install OpenVox Agent via DNF with sudo
# ------------------------------------------------------------------
info "Step 1/4: Checking OpenVox installation..."

if $SUDO puppet --version &>/dev/null; then
    ok "OpenVox (puppet) is already installed: $($SUDO puppet --version 2>/dev/null)"
else
    info "OpenVox not found. Installing openvox-agent via DNF with sudo..."

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

    info "Adding OpenVox repository from ${REPO_URL} with sudo..."
    if ! $SUDO dnf install -y "${REPO_URL}"; then
        err "Failed to install OpenVox release RPM from ${REPO_URL}."
        exit 1
    fi

    # Install openvox-agent with sudo
    info "Installing openvox-agent package with sudo..."
    $SUDO dnf install -y openvox-agent

    if $SUDO puppet --version &>/dev/null; then
        ok "OpenVox (puppet) installed successfully: $($SUDO puppet --version 2>/dev/null)"
    else
        err "Failed to verify OpenVox installation."
        exit 1
    fi
fi

echo ""

# ------------------------------------------------------------------
# Step 2: Prompt for Secrets
# ------------------------------------------------------------------
info "Step 2/4: Gathering secrets..."

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
    echo " Domains:        homelab.brookemao.ca, mindustry.brookemao.ca, photos.brookemao.ca"
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
    chmod 660 "${PROJECT_ROOT}/data/secrets.yaml"
    ok "Saved secret to ${PROJECT_ROOT}/data/secrets.yaml (mode 0660)."
fi

echo ""

# ------------------------------------------------------------------
# Step 3: Install required Puppet Forge modules (before apply)
# ------------------------------------------------------------------
info "Step 3/4: Installing required Puppet Forge modules..."

# Install into the project modules dir so `puppet apply --modulepath` resolves them.
# puppet-firewalld pulls in its dependencies (puppetlabs-stdlib, puppetlabs-augeas_core) automatically.
# southalc-podman pulls in its dependencies (puppetlabs-stdlib, puppetlabs-concat,
# puppetlabs-selinux_core, puppetlabs-inifile, puppet-systemd, southalc-hashfile) automatically.
# puppet-nginx pulls in its dependencies (puppetlabs-concat, puppetlabs-stdlib) automatically.
# puppet-fail2ban pulls in its dependency (puppetlabs-stdlib) automatically.
# puppet-letsencrypt pulls in its dependencies (puppetlabs-stdlib, puppetlabs-inifile, puppet-epel) automatically.
for _forge_module in puppet-firewalld southalc-podman puppet-nginx puppet-fail2ban puppet-letsencrypt; do
    if ! $SUDO puppet module install "${_forge_module}" --modulepath "${PROJECT_ROOT}/modules"; then
        warn "Could not install ${_forge_module} (it may already be installed). Continuing..."
    fi
done
ok "Puppet Forge modules ready."

echo ""

# ------------------------------------------------------------------
# Step 4: Run OpenVox with sudo (Masterless Apply)
# ------------------------------------------------------------------
info "Step 4/4: Executing OpenVox masterless run with sudo..."

info "Project Root: ${PROJECT_ROOT}"

cd "${PROJECT_ROOT}"

ENV_VARS=()
if [[ -n "${CF_KEY}" ]]; then
    ENV_VARS+=("FACTER_cloudflare_token=${CF_KEY}")
fi
ENV_VARS+=("FACTER_ddclient_replace_config=true")

# Run apply directly with sudo
$SUDO "${ENV_VARS[@]}" \
    puppet apply \
    --modulepath "${PROJECT_ROOT}/modules" \
    --hiera_config "${PROJECT_ROOT}/hiera.yaml" \
    "$@" \
    "${PROJECT_ROOT}/manifests/site.pp"

ok "OpenVox configuration run completed successfully!"
