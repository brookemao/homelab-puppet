# Homelab OpenVox (Masterless) Configuration for RHEL 10

Standalone masterless [OpenVox](https://voxpupuli.org/openvox/) automation (`puppet apply`) to configure a baseline RHEL 10 (or Rocky Linux 10 / AlmaLinux 10 / CentOS Stream 10) system.

[OpenVox](https://voxpupuli.org/openvox/) is the fully open source, community-governed alternative and direct drop-in replacement for Puppet maintained by [Vox Pupuli](https://voxpupuli.org/). Because legacy Puppet packages are no longer distributed in standard RHEL 10 repositories, this project exclusively uses **OpenVox 8** via [Vox Pupuli's YUM repository](https://voxpupuli.org/openvox/install/).

OpenVox maintains complete compatibility with declarative manifests and Hiera data while removing proprietary dependencies and commercial repository restrictions.

### Managed Components:
- **EPEL 10 Repository**: Enables CodeReady Builder (CRB) and installs the EPEL 10 release package with automated metadata cache refresh.
- **git**: Standard distributed version control system package.
- **fastfetch**: Modern, lightweight CLI system information display tool.
- **fail2ban**: Intrusion prevention service configured for systemd journal logging and Firewalld rich rules integration.
- **ddclient**: Dynamic DNS client built and installed directly from upstream [GitHub release tarball](https://github.com/ddclient/ddclient#installation) (with `perl` and `make` installed beforehand, automatic discovery of the latest tag past 4.0.0, and systemd service integration) or via native DNF package.

---

## Project Structure

```text
.
├── bootstrap/
│   └── bootstrap.sh            # Automated bootstrap script (installs OpenVox, prompts secrets, runs apply)
├── data/
│   ├── common.yaml             # Hiera common configuration parameters
│   └── secrets.yaml.example    # Template for private credentials (copied to secrets.yaml)
├── environment.conf            # Environment modulepath definition
├── hiera.yaml                  # Hiera 5 hierarchy configuration
├── manifests/
│   └── site.pp                 # Masterless manifest entrypoint for `puppet apply`
├── modules/
│   └── homelab/
│       ├── manifests/
│       │   ├── init.pp         # Main class orchestrating baseline setup
│       │   ├── epel.pp         # CRB repository enablement & EPEL 10 package
│       │   ├── git.pp          # Git package installation
│       │   ├── fastfetch.pp    # Fastfetch installation
│       │   ├── fail2ban.pp     # Fail2ban + firewalld packages & service
│       │   └── ddclient.pp     # GitHub release tarball build & systemd service
│       └── templates/
│           ├── ddclient.conf.epp   # ddclient configuration template (Cloudflare snippet)
│           └── jail.local.epp      # fail2ban jail configuration template
└── README.md
```

---

## Quick Start

### 1. Automated Bootstrap Script (Recommended)

The easiest way to bootstrap and configure a fresh RHEL 10 machine is using `bootstrap/bootstrap.sh`. It automatically:
1. Installs the official Vox Pupuli OpenVox repository (`openvox8-release-el-10.noarch.rpm`) and `openvox-agent` (`puppet apply`) via DNF.
2. Securely prompts for your Cloudflare API key / token (or reads from `CLOUDFLARE_API_KEY`).
3. Saves the token to `data/secrets.yaml` (mode `0600`, gitignored).
4. Executes masterless `puppet apply` with root privileges.

```bash
chmod +x bootstrap/bootstrap.sh
./bootstrap/bootstrap.sh
```

You can pass standard flags (such as `--noop` for a dry run):

```bash
./bootstrap/bootstrap.sh --noop
```

Or provide your Cloudflare token via environment variable to run non-interactively:

```bash
CLOUDFLARE_API_KEY='your_api_token' ./bootstrap/bootstrap.sh
```

---

### 2. Standalone Execution

If OpenVox (`openvox-agent`) is already installed on the system, you can run `puppet apply` directly:

```bash
sudo puppet apply --modulepath=modules --hiera_config=hiera.yaml manifests/site.pp
```

You can supply or override the Cloudflare token and settings using environment variables:

```bash
sudo env FACTER_cloudflare_token='your_real_api_token_here' \
         FACTER_ddclient_replace_config=true \
         puppet apply --modulepath=modules --hiera_config=hiera.yaml manifests/site.pp
```

---

## Configuration via Hiera

This project uses standard Hiera 5 data lookups.

- **`data/common.yaml`**: Contains default parameters for the system:
  ```yaml
  homelab::manage_services: true
  homelab::ddclient_install_method: 'tarball'
  homelab::ddclient_release_tag: 'latest'
  homelab::cloudflare_zone: 'brookemao.ca'
  homelab::cloudflare_domains: 'homelab.brookemao.ca,mindustry.brookemao.ca'
  homelab::ddclient_replace_config: false
  ```

- **`data/secrets.yaml`** *(gitignored)*: Holds private tokens and keys:
  ```yaml
  homelab::cloudflare_token: 'your_real_token_here'
  ```
  Create it from the example:
  ```bash
  cp data/secrets.yaml.example data/secrets.yaml
  chmod 600 data/secrets.yaml
  ```

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `manage_services` | `Boolean` | `true` | Whether to manage and enable background services (`fail2ban`, `ddclient`) |
| `ddclient_install_method` | `String` | `'tarball'` | `'tarball'` (official GitHub release tarball) or `'package'` (dnf) |
| `ddclient_release_tag` | `String` | `'latest'` | `'latest'` (auto-queries newest GitHub release tag past 4.0.0) or specific tag (e.g. `'v4.0.0'`) |
| `cloudflare_token` | `String` | `'<SECRET TOKEN HERE>'` | Cloudflare API Token for dynamic DNS updates |
| `cloudflare_zone` | `String` | `'brookemao.ca'` | Cloudflare root domain zone |
| `cloudflare_domains` | `String` | `'homelab.brookemao.ca,mindustry.brookemao.ca'` | Subdomains to update |
| `ddclient_replace_config` | `Boolean` | `false` | Whether to overwrite existing `/etc/ddclient/ddclient.conf` |

---

## Configuring ddclient

The configuration file `/etc/ddclient/ddclient.conf` is deployed with your Cloudflare snippet:

```ini
## Cloudflare
protocol=cloudflare,        \
zone=brookemao.ca,            \
ttl=1,                      \
login=token,    \
password=<SECRET TOKEN HERE> \
homelab.brookemao.ca,mindustry.brookemao.ca
```

1. If you ran without supplying a token, update the secret in `/etc/ddclient/ddclient.conf`:
   ```bash
   sudo nano /etc/ddclient/ddclient.conf
   ```
2. Start and verify the service:
   ```bash
   sudo systemctl start ddclient
   sudo systemctl status ddclient
   ```
*(Note: `replace => false` by default ensures your API credentials will never be overwritten on subsequent runs unless `ddclient_replace_config=true` is explicitly provided).*
