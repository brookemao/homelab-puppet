# Homelab Puppet Bolt Configuration for RHEL 10

Agentless Puppet Bolt automation to configure a baseline RHEL 10 (or Rocky Linux 10 / AlmaLinux 10 / CentOS Stream 10) system with:

- **EPEL 10 Repository**: Enables CodeReady Builder (CRB) and installs the EPEL 10 release package with automated metadata cache refresh.
- **git**: Standard distributed version control system package.
- **fastfetch**: Modern, lightweight CLI system information display tool.
- **fail2ban**: Intrusion prevention service configured for systemd journal logging and Firewalld rich rules integration.
- **ddclient**: Dynamic DNS client built and installed directly from upstream [GitHub repository](https://github.com/ddclient/ddclient) (with GNU autotools, SSL & JSON dependencies, and systemd service integration) or via native DNF package.

---

## Project Structure

```text
.
├── bolt-project.yaml           # Bolt project declaration
├── inventory.yaml              # Target hosts and local transport configuration
├── manifests/
│   └── site.pp                 # Standalone manifest entrypoint for `bolt apply`
├── plans/
│   └── init.pp                 # Bolt plan entrypoint (`bolt plan run homelab`)
├── modules/
│   └── homelab/
│       ├── manifests/
│       │   ├── init.pp         # Main class orchestrating baseline setup
│       │   ├── epel.pp         # CRB repository enablement & EPEL 10 package
│       │   ├── git.pp          # Git package installation
│       │   ├── fastfetch.pp    # Fastfetch installation
│       │   ├── fail2ban.pp     # Fail2ban + firewalld packages & service
│       │   └── ddclient.pp     # GitHub source build or package install & systemd service
│       └── templates/
│           ├── ddclient.conf.epp   # ddclient configuration template (Cloudflare, DuckDNS, etc.)
│           └── jail.local.epp      # fail2ban jail configuration template
└── README.md
```

---

## Quick Start

This project is configured for **local execution** directly on the RHEL 10 machine you want to modify. It uses Puppet Bolt's native `transport: local`, so no SSH keys, SSH daemon, or network credentials are required.

### 1. Run the Automated Bootstrap Script

The easiest way to set up the system is using `bootstrap/bootstrap.sh`. It automatically installs Puppet Bolt via DNF, prompts you securely for your Cloudflare API key, and executes the Bolt plan with root privileges:

```bash
chmod +x bootstrap/bootstrap.sh
./bootstrap/bootstrap.sh
```

You can also pass your Cloudflare token via environment variable to skip the interactive prompt:

```bash
CLOUDFLARE_API_KEY='your_api_token' ./bootstrap/bootstrap.sh
```

---

### 2. Alternative: Running Bolt Directly

If Puppet Bolt is already installed, you can execute the plan directly on the local machine (requires root or sudo for package and service management):

```bash
sudo bolt plan run homelab
```

Or pass parameters directly on the CLI:

```bash
sudo bolt plan run homelab \
  cloudflare_token='your_real_api_token_here' \
  ddclient_replace_config=true
```

Or using standalone `bolt apply`:

```bash
sudo bolt apply manifests/site.pp --targets localhost
```

---

### 3. Target Inventory

The default `inventory.yaml` targets `localhost` using `transport: local`:

```yaml
version: 2

targets:
  - uri: localhost
    name: localhost
    config:
      transport: local
```

*(Note: If you ever wish to target a remote machine over SSH instead, you can change `transport: ssh` and configure SSH credentials in `inventory.yaml`).*

---

## Plan Parameters

You can override default plan settings directly on the command line:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `targets` | `TargetSpec` | `'localhost'` | Target hosts or group (defaults to local machine) |
| `manage_services` | `Boolean` | `true` | Whether to manage and enable background services |
| `ddclient_install_method` | `String` | `'tarball'` | `'tarball'` (official GitHub release tarball) or `'package'` (dnf) |
| `ddclient_release_tag` | `String` | `'latest'` | `'latest'` (auto-queries newest GitHub release tag) or specific tag (e.g. `'v4.0.0'`) |
| `cloudflare_token` | `String` | `'<SECRET TOKEN HERE>'` | Cloudflare API Token for dynamic DNS updates |
| `cloudflare_zone` | `String` | `'brookemao.ca'` | Cloudflare root domain zone |
| `cloudflare_domains` | `String` | `'homelab.brookemao.ca,mindustry.brookemao.ca'` | Subdomains to update |
| `ddclient_replace_config` | `Boolean` | `false` | Whether to overwrite existing `/etc/ddclient/ddclient.conf` |

### Example: Running with Cloudflare Token

```bash
sudo bolt plan run homelab \
  targets=localhost \
  cloudflare_token='your_real_api_token_here' \
  ddclient_replace_config=true
```

Or run with defaults, and manually update `/etc/ddclient/ddclient.conf` on the target host.

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

1. If you did not pass `cloudflare_token` during `bolt plan run`, update the token in `/etc/ddclient/ddclient.conf`:
   ```bash
   sudo nano /etc/ddclient/ddclient.conf
   ```
2. Start and verify the service:
   ```bash
   sudo systemctl start ddclient
   sudo systemctl status ddclient
   ```
*(Note: `replace => false` by default ensures your API credentials will never be overwritten on subsequent Bolt runs unless `ddclient_replace_config=true` is explicitly provided).*
