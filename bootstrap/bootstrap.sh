#!/usr/bin/env bash
#
# bootstrap.sh - Bootstrap OpenVox (masterless) and run homelab baseline configuration
#
# 1. Installs OpenVox Agent (`openvox-agent`) via DNF with sudo from Vox Pupuli repositories
# 2. Prompts for required secrets (Cloudflare API Key for ddclient, Immich database password,
#    SearXNG secret key, SearXNG MCP bearer token, llama Basic-auth password) and, whenever
#    data/secrets.yaml lacks one, the optional Cloudflare Tunnel token
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
echo "      Homelab OpenVox Bootstrap - Fedora 44 Setup              "
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

    # Fedora release RPMs are versioned (openvox8-release-fedora-<major>).
    # All project packages come from native Fedora repos.
    OS_VER="$(grep -oP '^VERSION_ID="?\K[0-9]+' /etc/os-release 2>/dev/null | head -n1 || echo "")"
    if [[ -z "${OS_VER}" ]]; then
        OS_VER="44"
    fi

    info "Detected Fedora version: ${OS_VER}"

    # Install the OpenVox release repository package from Vox Pupuli (https://voxpupuli.org/openvox/install/)
    REPO_URL="https://yum.voxpupuli.org/openvox8-release-fedora-${OS_VER}.noarch.rpm"

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
    echo " Domains:        homelab.brookemao.ca, mindustry.brookemao.ca, photos.brookemao.ca, cockpit.brookemao.ca, llama.brookemao.ca, websearch.brookemao.ca"
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

    # Immich database password. PostgreSQL only reads it when it initializes
    echo -n "Enter Immich database password (hidden): "
    read -r -s IMMICH_DB_PASSWORD
    echo ""

    while [[ -z "${IMMICH_DB_PASSWORD// }" ]]; do
        warn "Immich database password cannot be empty."
        echo -n "Enter Immich database password (hidden): "
        read -r -s IMMICH_DB_PASSWORD
        echo ""
    done
    ok "Immich database password captured."

    # Write to data/secrets.yaml for subsequent standalone runs
    mkdir -p "${PROJECT_ROOT}/data"
    cat > "${PROJECT_ROOT}/data/secrets.yaml" <<EOF
---
homelab::cloudflare_token: '${CF_KEY}'
immich::db_password: '${IMMICH_DB_PASSWORD}'
EOF
    sudo chmod 660 "${PROJECT_ROOT}/data/secrets.yaml"
    ok "Saved secrets to ${PROJECT_ROOT}/data/secrets.yaml (mode 0660)."
fi

# Ensure data/secrets.yaml carries the SearXNG server secret Puppet needs
# (searxng::secret_key, consumed by the searxng class). Precedence:
# SEARXNG_SECRET_KEY environment override, then the existing
# data/secrets.yaml value, otherwise prompt (empty input auto-generates).
SECRETS_FILE="${PROJECT_ROOT}/data/secrets.yaml"

# upsert_secret_line <key> <value>: create data/secrets.yaml holding the key,
# append the key, or update the stored value when it differs (e.g. explicit
# environment override). Values are written as single-quoted YAML scalars,
# so embedded quotes are doubled and sed metacharacters escaped.
upsert_secret_line() {
    local key="$1"
    local value="$2"
    local value_yaml="${value//\'/\'\'}"
    local value_sed
    value_sed="$(printf '%s' "${value_yaml}" | sed 's/[&|\\]/\\&/g')"
    local line="${key}: '${value_yaml}'"

    mkdir -p "${PROJECT_ROOT}/data"
    if [[ ! -f "${SECRETS_FILE}" ]]; then
        printf '%s\n' '---' "${line}" > "${SECRETS_FILE}"
        ok "Saved ${key} to ${SECRETS_FILE} (mode 0660)."
    elif ! grep -q "^[[:space:]]*${key}:" "${SECRETS_FILE}"; then
        printf '%s\n' "${line}" >> "${SECRETS_FILE}"
        ok "Saved ${key} to ${SECRETS_FILE} (mode 0660)."
    elif ! grep -qF -- "${line}" "${SECRETS_FILE}"; then
        sed -i "s|^[[:space:]]*${key}:.*|${key}: '${value_sed}'|" "${SECRETS_FILE}"
        ok "Updated ${key} in ${SECRETS_FILE}."
    fi
    chmod 660 "${SECRETS_FILE}"
}

# read_secret <key>: print the current data/secrets.yaml value for a key
# (without surrounding quotes), or nothing when the key is absent. Never
# fails: with `set -e -o pipefail` a missing file would otherwise abort the
# whole script from inside the $(...) assignment.
read_secret() {
    sed -n "s/^[[:space:]]*$1:[[:space:]]*['\"]\?\([^'\"]*\)['\"]\?[[:space:]]*$/\1/p" "${SECRETS_FILE}" 2>/dev/null | head -n 1 || true
}

SEARXNG_SECRET="${SEARXNG_SECRET_KEY:-}"
if [[ -n "${SEARXNG_SECRET// }" ]]; then
    ok "Using SearXNG secret key from environment variable SEARXNG_SECRET_KEY."
else
    SEARXNG_SECRET="$(read_secret 'searxng::secret_key')"
    if [[ -n "${SEARXNG_SECRET}" ]]; then
        ok "SearXNG secret key already present in data/secrets.yaml. Skipping prompt."
    else
        echo -n "Enter SearXNG secret key (hidden, empty to auto-generate): "
        read -r -s SEARXNG_SECRET || true
        echo ""

        if [[ -z "${SEARXNG_SECRET// }" ]]; then
            if command -v openssl &>/dev/null; then
                SEARXNG_SECRET="$(openssl rand -hex 32)"
            else
                SEARXNG_SECRET="$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')"
            fi
            ok "Generated random SearXNG secret key."
        else
            ok "SearXNG secret key captured."
        fi
    fi
fi

# Persist the SearXNG server secret: create the file, append the key, or
# update the stored value when it differs (e.g. environment override).
upsert_secret_line 'searxng::secret_key' "${SEARXNG_SECRET}"
unset SEARXNG_SECRET

# Bearer token guarding the public SearXNG MCP vhost
# (websearch.brookemao.ca). The same 32 bytes are injected into the MCP
# container as MCP_HTTP_AUTH_TOKEN and pre-registered in llama's
# --ui-config-file. Precedence: SEARXNG_AUTH_TOKEN environment override,
# then the existing data/secrets.yaml value, otherwise generate. Hex keeps
# it safe for HTTP headers and YAML alike.
BEARER_TOKEN="${SEARXNG_AUTH_TOKEN:-}"
if [[ -n "${BEARER_TOKEN// }" ]]; then
    ok "Using SearXNG MCP bearer token from environment variable SEARXNG_AUTH_TOKEN."
else
    BEARER_TOKEN="$(read_secret 'searxng::auth_token')"
    if [[ -n "${BEARER_TOKEN}" ]]; then
        ok "SearXNG MCP bearer token already present in data/secrets.yaml. Skipping generation."
    else
        if command -v openssl &>/dev/null; then
            BEARER_TOKEN="$(openssl rand -hex 32)"
        else
            BEARER_TOKEN="$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')"
        fi
        ok "Generated random SearXNG MCP bearer token (32 bytes)."
    fi
fi

upsert_secret_line 'searxng::auth_token' "${BEARER_TOKEN}"
unset BEARER_TOKEN

# Password for the llama Basic-auth user (agentforce) on
# llama.brookemao.ca. Only the SHA-512 crypt hash is stored, so the plaintext
# never touches disk. Precedence: LLAMA_BASIC_PASSWORD environment override
# (plaintext, hashed below), then the existing data/secrets.yaml hash,
# otherwise prompt (empty input is rejected).
LLAMA_BASIC_HASH="$(read_secret 'llama::basic_auth_password')"
if [[ -n "${LLAMA_BASIC_HASH}" && -z "${LLAMA_BASIC_PASSWORD:-}" ]]; then
    ok "llama Basic-auth password hash already present in data/secrets.yaml. Skipping prompt."
else
    LLAMA_BASIC_PLAINTEXT="${LLAMA_BASIC_PASSWORD:-}"
    if [[ -n "${LLAMA_BASIC_PLAINTEXT// }" ]]; then
        ok "Using llama Basic-auth password from environment variable LLAMA_BASIC_PASSWORD."
    else
        echo -n "Enter llama Basic-auth password for user 'agentforce' (hidden): "
        read -r -s LLAMA_BASIC_PLAINTEXT || true
        echo ""

        while [[ -z "${LLAMA_BASIC_PLAINTEXT// }" ]]; do
            warn "llama Basic-auth password cannot be empty."
            echo -n "Enter llama Basic-auth password for user 'agentforce' (hidden): "
            read -r -s LLAMA_BASIC_PLAINTEXT || true
            echo ""
        done
        ok "llama Basic-auth password captured."
    fi

    if ! command -v openssl &>/dev/null; then
        err "openssl is required to hash the llama Basic-auth password."
        exit 1
    fi
    LLAMA_BASIC_HASH="$(printf '%s' "${LLAMA_BASIC_PLAINTEXT}" | openssl passwd -6 -stdin)"
    unset LLAMA_BASIC_PLAINTEXT LLAMA_BASIC_PASSWORD
    ok "Hashed llama Basic-auth password (SHA-512 crypt)."
fi

upsert_secret_line 'llama::basic_auth_password' "${LLAMA_BASIC_HASH}"
unset LLAMA_BASIC_HASH

# Cloudflare Tunnel token for immich.iapark.dev (homelab::cloudflared), copied from
# the Zero Trust dashboard (see "Cloudflare Tunnel" in the README). Optional, and
# often added after the first run, so ask whenever it is missing rather than only
# when secrets.yaml is first created. Precedence: CLOUDFLARE_TUNNEL_TOKEN
# environment override, then the existing data/secrets.yaml value, otherwise
# prompt (empty input skips; the tunnel then stays stopped).
TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
if [[ -n "${TUNNEL_TOKEN// }" ]]; then
    ok "Using Cloudflare Tunnel token from environment variable CLOUDFLARE_TUNNEL_TOKEN."
    upsert_secret_line 'homelab::cloudflared::tunnel_token' "${TUNNEL_TOKEN}"
elif [[ -n "$(read_secret 'homelab::cloudflared::tunnel_token')" ]]; then
    ok "Cloudflare Tunnel token already present in data/secrets.yaml. Skipping prompt."
else
    echo -n "Enter Cloudflare Tunnel token for immich.iapark.dev (hidden, empty to skip): "
    read -r -s TUNNEL_TOKEN || true
    echo ""

    if [[ -n "${TUNNEL_TOKEN// }" ]]; then
        upsert_secret_line 'homelab::cloudflared::tunnel_token' "${TUNNEL_TOKEN}"
    else
        warn "No Cloudflare Tunnel token; cloudflared will be installed but the tunnel left stopped."
    fi
fi
unset TUNNEL_TOKEN

echo ""

# ------------------------------------------------------------------
# Step 3: Install required Puppet Forge modules (before apply)
# ------------------------------------------------------------------
info "Step 3/4: Installing required Puppet Forge modules..."

# Install into the project modules dir so `puppet apply --modulepath` resolves them.
# (Several Forge modules omit Fedora in their metadata but branch on the
# RedHat osfamily with identical package/service names, which puppet apply
# does not enforce, so they apply cleanly.)
# puppet-firewalld pulls in its dependencies (puppetlabs-stdlib, puppetlabs-augeas_core) automatically.
# southalc-podman pulls in its dependencies (puppetlabs-stdlib, puppetlabs-concat,
# puppetlabs-selinux_core, puppetlabs-inifile, puppet-systemd, southalc-hashfile) automatically.
# puppet-selinux (used by the immich module for its file context rule) needs only puppetlabs-stdlib.
# puppet-nginx pulls in its dependencies (puppetlabs-concat, puppetlabs-stdlib) automatically.
# puppet-fail2ban pulls in its dependency (puppetlabs-stdlib) automatically.
# puppet-letsencrypt pulls in its dependencies (puppetlabs-stdlib, puppetlabs-inifile, puppet-epel) automatically.
for _forge_module in puppet-firewalld southalc-podman puppet-selinux puppet-nginx puppet-fail2ban puppet-letsencrypt; do
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
