# Homelab OpenVox (Masterless) Configuration for RHEL 10

Standalone masterless [OpenVox](https://voxpupuli.org/openvox/) automation (`puppet apply`) to configure a baseline RHEL 10 (or Rocky Linux 10 / AlmaLinux 10 / CentOS Stream 10) system.

[OpenVox](https://voxpupuli.org/openvox/) is the fully open source, community-governed configuration management platform maintained by [Vox Pupuli](https://voxpupuli.org/). Because legacy configuration management packages are not distributed in standard RHEL 10 repositories, this project exclusively uses **OpenVox 8** via [Vox Pupuli's YUM repository](https://voxpupuli.org/openvox/install/). (OpenVox packages provide the drop-in CLI executable as `puppet`).

OpenVox maintains complete compatibility with declarative manifests and Hiera data while removing proprietary dependencies and commercial repository restrictions.

### Managed Components:
- **EPEL 10 Repository**: Enables CodeReady Builder (CRB) and installs the EPEL 10 release package with automated metadata cache refresh.
- **git**: Standard distributed version control system package.
- **fastfetch**: Modern, lightweight CLI system information display tool.
- **fail2ban**: Intrusion prevention service configured for systemd journal logging and Firewalld rich rules integration, including an Immich failed-login jail (10 failures in 10 min → 24 h ban).
- **firewalld**: Firewall service managed via `puppet-firewalld` with port `443/tcp` allowed in the default `public` zone.
- **podman**: Container runtime with `podman-compose` (from EPEL) for compose workloads.
- **nginx**: TLS reverse proxy (via `puppet-nginx`) — `cockpit.brookemao.ca` forwards to Cockpit on port `9090` requiring an mTLS client certificate signed by the personal PKI root (upstream `proxy_ssl_verify off` — Cockpit uses a self-signed cert on localhost); all other hosts hit the catch-all default page. (No public Immich forwarding — Immich stays off the internet.)
- **cockpit**: Proxy-aware Cockpit (`Origins` + `X-Forwarded-Proto` in `cockpit.conf`, `cockpit.socket` enabled) with SELinux least privilege — TCP `9090` labeled `http_port_t` so nginx can connect without `httpd_can_network_connect`.
- **letsencrypt**: Wildcard certificate for the zone apex + `*` via Cloudflare DNS-01 (via `puppet-letsencrypt`), with a twice-daily `certbot-renew` systemd timer and nginx reload on renewal.
- **ddclient**: Dynamic DNS client built and installed directly from upstream [GitHub release tarball](https://github.com/ddclient/ddclient#installation) (with `perl` and `make` installed beforehand, automatic discovery of the latest tag past 4.0.0, and systemd service integration) or via native DNF package.
- **Immich**: Self-hosted [photo and video server](https://immich.app) deployed as a `podman-compose` stack (server, machine learning, Valkey, PostgreSQL) running under a dedicated `immich` system account, supervised by a systemd unit so the stack returns after a reboot.

---

## Project Structure

```text
.
├── bootstrap/bootstrap.sh   # Installs OpenVox, prompts for secrets, runs apply
├── data/                    # Hiera data: common.yaml, secrets.yaml.example
├── hiera.yaml               # Hiera 5 hierarchy
├── environment.conf         # modulepath
├── manifests/site.pp        # Masterless entrypoint for `puppet apply`
└── modules/
    ├── homelab/             # Site profile: epel, git, fastfetch, fail2ban, firewall, podman,
    │                        #   ddclient, Let's Encrypt, cockpit, nginx (mTLS proxy); declares immich
    └── immich/              # Immich stack: compose.yml + systemd unit
```

---

## Quick Start

### 1. Automated Bootstrap Script (Recommended)

The easiest way to bootstrap and configure a fresh RHEL 10 machine is using `bootstrap/bootstrap.sh`. It automatically:
1. Installs the official Vox Pupuli OpenVox repository (`openvox8-release-el-10.noarch.rpm`) and `openvox-agent` via DNF with sudo.
2. Securely prompts for your Cloudflare API key / token (or reads from `CLOUDFLARE_API_KEY`).
3. Saves the token to `data/secrets.yaml` (mode `0660`, gitignored).
4. Executes masterless apply with sudo (`sudo puppet apply`).

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
sudo env PATH='/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/opt/puppetlabs/bin' \
         puppet apply --modulepath=modules --hiera_config=hiera.yaml manifests/site.pp
```

You can supply or override the Cloudflare token and settings using environment variables:

```bash
sudo env PATH='/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/opt/puppetlabs/bin' \
         FACTER_cloudflare_token='your_real_api_token_here' \
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
  homelab::cloudflare_domains: 'homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca'
  homelab::ddclient_replace_config: false
  ```

- **`data/secrets.yaml`** *(gitignored)*: Holds private tokens and keys:
  ```yaml
  homelab::cloudflare_token: 'your_real_token_here'

  # Optional. Defaults to 'immich' if omitted. See "Managing Immich" below
  # before changing this on a host that has already run once.
  immich::db_password: 'your_immich_db_password_here'
  ```
  Create it from the example:
  ```bash
  cp data/secrets.yaml.example data/secrets.yaml
  chmod 660 data/secrets.yaml
  ```

---

## Parameters

### `homelab` (baseline)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `manage_services` | `Boolean` | `true` | Whether to manage and enable background services (`fail2ban`, `ddclient`) |
| `ddclient_install_method` | `String` | `'tarball'` | `'tarball'` (official GitHub release tarball) or `'package'` (dnf) |
| `ddclient_release_tag` | `String` | `'latest'` | `'latest'` (auto-queries newest GitHub release tag past 4.0.0) or specific tag (e.g. `'v4.0.0'`) |
| `cloudflare_token` | `String` | `'<SECRET TOKEN HERE>'` | Cloudflare API Token for dynamic DNS updates |
| `cloudflare_zone` | `String` | `'brookemao.ca'` | Cloudflare root domain zone |
| `cloudflare_domains` | `String` | `'homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca'` | Subdomains to update |
| `ddclient_replace_config` | `Boolean` | `false` | Whether to overwrite existing `/etc/ddclient/ddclient.conf` |

### `immich`

Set these with `immich::<name>` Hiera keys. All are optional - the class defaults apply
when no key is present, which is why `data/common.yaml` carries none of them.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `db_password` | `Sensitive[String]` | `Sensitive('immich')` | PostgreSQL password. Only read at database initialisation - see below |
| `version` | `String` | `'v3.2.2'` | Immich image tag |
| `timezone` | `String` | `'America/Los_Angeles'` | `TZ` passed to the containers |
| `port` | `Integer[1, 65535]` | `2283` | Host port published for the web UI |
| `cpu_limit` | `Numeric` | `4` | Cores the whole stack may use |
| `memory_limit` | `String` | `'16g'` | Memory the whole stack may use |
| `base_dir` | `Immich::Absolutepath` | `'/home/immich'` | Directory the deployment lives under; created if missing, never restyled. Its own parent must already exist |
| `install_dir` | `Immich::Absolutepath` | `'/opt/immich-app'` | Holds the generated `compose.yml` |

Everything the containers persist lives under `base_dir/data` in a fixed layout, which is what
lets a single SELinux rule and a single ownership scheme cover all of it:

```text
/home/immich/                      root:root 0755, not container-accessible
└── data/                          immich:immich 0750, container_file_t
    ├── library/                   photo and video library
    ├── postgres/                  database (mode 0700)
    ├── ml-model-cache/            machine learning models
    └── redis/                     Valkey persistence
```

Move the lot by setting `base_dir`; the paths underneath are not separately configurable.
Only `base_dir` itself is created, so its parent (`/home` by default) must already exist.

The `data/` level is structural, not a convention. The SELinux rule is recursive over
`base_dir/data`, so anything placed beside it - backups, exports - stays outside the
container label and is unreachable by the containers.

The `immich` service account (`user`, `group`, `uid`, `gid`), SELinux (`manage_selinux`,
`selinux_type`) and the unit itself (`compose_command`, `manage_service`, `service_name`)
are also parameters - see the class header in `modules/immich/manifests/init.pp`.

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
homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca
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

---

## Managing Immich

Puppet writes `/opt/immich-app/compose.yml` and a systemd unit at
`/etc/systemd/system/immich.service`, then enables it. The unit wraps
`podman-compose up -d` / `down` and is what brings the stack back after a reboot - podman
is daemonless, so `restart: always` in the compose file alone would not survive one.

```bash
sudo systemctl status immich      # is the stack up?
sudo systemctl restart immich     # down, then up
sudo journalctl -u immich         # compose output
sudo podman ps                    # the four containers
sudo podman logs immich_server    # logs from one container
```

The web UI listens on `2283`. `homelab::firewall` only opens `443/tcp`, so that port is
reachable from the host but not through firewalld from the LAN.

### Caveats

- **Set `immich::db_password` before the first run.** PostgreSQL reads it only when
  initialising its data directory; changing it later does not re-key an existing database,
  and the server container starts failing to authenticate.
- **SELinux is handled, but verify it took.** Run `ls -Z /home/immich/data` after the
  first apply; you want `container_file_t`. If it still reads `user_home_t` the containers
  will be denied access despite correct Unix ownership, and because `podman-compose up -d`
  exits `0` regardless, the run looks clean while PostgreSQL fails behind it. Check
  `sudo podman logs immich_postgres` and `sudo ausearch -m avc -ts recent`.

The first start pulls several GB of images; the unit allows 15 minutes for it.

### Resource limits

`cpu_limit` and `memory_limit` cap the stack **collectively**, not per container. All four
services together get 4 cores and 16 GB.

podman-compose puts every service of a project into a pod (`pod_immich` here), and a pod
is a cgroup. Limiting the pod limits everything inside it, so the compose file sets the
limits on `podman pod create` rather than on each service:

```yaml
x-podman:
  pod_args:
    - --infra=false
    - --share=
    - --cpus=4
    - --memory=16g
```

`pod_args` **replaces** podman-compose's defaults rather than extending them, which is why
`--infra=false` and `--share=` are repeated - dropping them would change how the stack is
networked.

Check it took with `podman pod inspect pod_immich`, or read the cgroup directly:

```bash
cat /sys/fs/cgroup/machine.slice/*libpod_pod*/memory.max
cat /sys/fs/cgroup/machine.slice/*libpod_pod*/cpu.max
```

Pod-level limits need cgroups v2, which RHEL 10 uses by default.
