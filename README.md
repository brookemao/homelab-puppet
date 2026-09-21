# Homelab Puppet Bolt Configuration for RHEL 10

Agentless Puppet Bolt automation to configure a baseline RHEL 10 (or Rocky Linux 10 / AlmaLinux 10 / CentOS Stream 10) system with:

- **EPEL 10 Repository**: Enables CodeReady Builder (CRB) and installs the EPEL 10 release package with automated metadata cache refresh.
- **fastfetch**: Modern, lightweight CLI system information display tool.
- **fail2ban**: Intrusion prevention service configured for systemd journal logging and Firewalld rich rules integration.
- **ddclient**: Dynamic DNS client built and installed directly from upstream [GitHub repository](https://github.com/ddclient/ddclient) (with GNU autotools, SSL & JSON dependencies, and systemd service integration) or via native DNF package.

---

## Project Structure

```text
.
├── bolt-project.yaml           # Bolt project declaration
├── inventory.yaml              # Target hosts, SSH credentials, and connection options
├── manifests/
│   └── site.pp                 # Standalone manifest entrypoint for `bolt apply`
├── plans/
│   └── init.pp                 # Bolt plan entrypoint (`bolt plan run homelab`)
├── modules/
│   └── homelab/
│       ├── manifests/
│       │   ├── init.pp         # Main class orchestrating baseline setup
│       │   ├── epel.pp         # CRB repository enablement & EPEL 10 package
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

### 1. Configure Target Inventory

Edit `inventory.yaml` to specify your target host's IP address or hostname and SSH credentials:

```yaml
version: 2
groups:
  - name: rhel10
    targets:
      - uri: 192.168.1.50           # Target IP address or hostname
        name: rhel10-node1
    config:
      transport: ssh
      ssh:
        user: root                   # Or non-root user (see sudo notes below)
        private-key: ~/.ssh/id_ed25519
        host-key-check: false
```

> **Note for Non-Root Users:** If connecting as a regular user with `sudo`, add:
> ```yaml
> user: admin
> run-as: root
> sudo-password: 'your_sudo_password'
> ```

---

### 2. Run the Automated Bootstrap Script

A bootstrap script is included in `bootstrap/bootstrap.sh` that installs Puppet Bolt via DNF, prompts you securely for your Cloudflare API key, and launches the Bolt run:

```bash
chmod +x bootstrap/bootstrap.sh
./bootstrap/bootstrap.sh
```

You can optionally pass a specific target group or host (default is `rhel10`):

```bash
./bootstrap/bootstrap.sh rhel10-node1
```

Or provide your Cloudflare token via environment variable to skip the prompt:

```bash
CLOUDFLARE_API_KEY='your_api_token' ./bootstrap/bootstrap.sh
```

---

### 3. Alternative: Running Bolt Directly

If Puppet Bolt is already installed, you can execute the plan directly:

```bash
bolt plan run homelab targets=rhel10
```

Or using standalone `bolt apply`:

```bash
bolt apply manifests/site.pp --targets rhel10
```

---

## Plan Parameters

You can override default plan settings directly on the command line:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `targets` | `TargetSpec` | `'rhel10'` | Group or list of hosts from `inventory.yaml` |
| `manage_services` | `Boolean` | `true` | Whether to manage and enable background services |
| `ddclient_install_method` | `String` | `'tarball'` | `'tarball'` (official GitHub release tarball) or `'package'` (dnf) |
| `ddclient_release_tag` | `String` | `'latest'` | `'latest'` (auto-queries newest GitHub release tag) or specific tag (e.g. `'v4.0.0'`) |
| `cloudflare_token` | `String` | `'<SECRET TOKEN HERE>'` | Cloudflare API Token for dynamic DNS updates |
| `cloudflare_zone` | `String` | `'brookemao.ca'` | Cloudflare root domain zone |
| `cloudflare_domains` | `String` | `'homelab.brookemao.ca,mindustry.brookemao.ca'` | Subdomains to update |
| `ddclient_replace_config` | `Boolean` | `false` | Whether to overwrite existing `/etc/ddclient/ddclient.conf` |

### Example: Running with Cloudflare Token

You can either provide your Cloudflare token directly via Bolt:

```bash
bolt plan run homelab \
  targets=rhel10 \
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
