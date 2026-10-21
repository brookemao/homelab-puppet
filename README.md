# Homelab OpenVox (Masterless) Configuration for Fedora 44

Standalone masterless [OpenVox](https://voxpupuli.org/openvox/) automation (`puppet apply`) to configure a baseline Fedora 44 system.

[OpenVox](https://voxpupuli.org/openvox/) is the fully open source, community-governed configuration management platform maintained by [Vox Pupuli](https://voxpupuli.org/). This project exclusively uses **OpenVox 8** via [Vox Pupuli's YUM repository](https://voxpupuli.org/openvox/install/) (`openvox8-release-fedora-44`). (OpenVox packages provide the drop-in CLI executable as `puppet`).

OpenVox maintains complete compatibility with declarative manifests and Hiera data while removing proprietary dependencies and commercial repository restrictions.

### Managed Components:
- **git**: Standard distributed version control system package.
- **fastfetch**: Modern, lightweight CLI system information display tool.
- **fail2ban**: Intrusion prevention service configured for systemd journal logging and Firewalld rich rules integration, including an Immich failed-login jail (10 failures in 10 min → 24 h ban), a Cockpit failed-login jail (5 failures in 10 min → 1 h ban, doubling per repeat offense up to 48 h), and `llama` / `websearch` jails counting HTTP 401s in each nginx vhost's dedicated access log (5 failures in 10 min → 1 h ban). Check them with `sudo fail2ban-client status llama` / `status websearch`; if a jail reports no log file after a fresh apply, confirm nginx created `/var/log/nginx/llama-access.log` and `/var/log/nginx/websearch-access.log`, and check `sudo ausearch -m avc -ts recent` in case SELinux blocks fail2ban from reading them.
- **firewalld**: Firewall service managed via `puppet-firewalld` with ports `443/tcp` and `9090/tcp` (Cockpit) allowed in the managed zone (`public` by default, pinned as the system default zone so the rules land on Fedora's active `FedoraServer`/`FedoraWorkstation` zone), plus direct `OUTPUT` rules confining the `nginx` workers to localhost egress (`NEW` connections only, so `ESTABLISHED` replies still flow; matched on the pre-DNAT original destination so locally-published container ports stay reachable). Any permanent firewall change triggers a `firewalld --reload`, which flushes podman DNS — so `homelab::firewall` notifies `immich`, `searxng` and `llama` to restart (see `docs/firewalld-podman-immich.md`).
- **podman**: Container runtime with `podman-compose` for compose workloads. Container storage uses the `overlay` driver with `graphroot` relocated to `/home/containers/storage` (SELinux-labeled) instead of the `/var/lib` default.
- **nginx**: TLS reverse proxy (via `puppet-nginx`) — `cockpit.brookemao.ca` forwards to Cockpit on port `9090` requiring an mTLS client certificate signed by the personal PKI root (upstream `proxy_ssl_verify off` — Cockpit uses a self-signed cert on localhost); `websearch.brookemao.ca` forwards to the SearXNG MCP server on loopback `8081` gated by a Bearer token; `llama.brookemao.ca` forwards to llama-server on loopback `8080` gated by HTTP Basic auth (`agentforce`); `llama-api.brookemao.ca` forwards to the same llama-server on loopback `8080` gated by per-client API keys (`brooke`, `izzy`, `general`); all other hosts hit the catch-all default page. (Immich is not proxied by nginx — it is published through the Cloudflare Tunnel instead.) SELinux least privilege, same pattern as Cockpit: a minimal `nginx_backends` allow module lets the workers reach both loopback backends (TCP `8081` is relabeled to the policy-shipped `http_cache_port_t` to match `8080`), no `httpd_can_network_connect`.
- **cockpit**: Proxy-aware Cockpit (`Origins` + `X-Forwarded-Proto` in `cockpit.conf`, `cockpit.socket` enabled) with extra UIs for Podman containers, virtual machines, and files (`cockpit-podman`, `cockpit-machines`, `cockpit-files`) and SELinux least privilege — TCP `9090` stays on its policy-shipped `websm_port_t` label and a minimal `nginx_cockpit` allow module lets nginx connect, no `httpd_can_network_connect`.
- **Claude conversation exports**: A systemd watcher runs as root and keeps individual session HTML current from `iapark`'s Claude container volume into `/home/share/claudelogs`, served at `https://claudechats.brookemao.ca` with the same required client certificate as Cockpit.
- **letsencrypt**: Wildcard certificate for the zone apex + `*` via Cloudflare DNS-01 (via `puppet-letsencrypt`), with a twice-daily `certbot-renew` systemd timer and nginx reload on renewal.
- **ddclient**: Dynamic DNS client installed via the native DNF package (or built from the upstream [GitHub release tarball](https://github.com/ddclient/ddclient#installation) with automatic discovery of the latest tag past 4.0.0 and systemd service integration).
- **cloudflared**: [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) from Cloudflare's RPM repository, publishing `immich.iapark.dev` → Immich on `127.0.0.1:2283` with no inbound port. Remotely managed: the tunnel, its public hostname and the Zero Trust Access policy in front of it live in the Cloudflare dashboard; Puppet only runs the connector with the token from `data/secrets.yaml`. See [Cloudflare Tunnel](#cloudflare-tunnel).
- **Immich**: Self-hosted [photo and video server](https://immich.app) deployed as a `podman-compose` stack (server, machine learning, Valkey, PostgreSQL) running under a dedicated `immich` system account, supervised by a systemd unit so the stack returns after a reboot.
- **SearXNG**: Self-hosted metasearch ([SearXNG](https://docs.searxng.org)) plus the [mcp-searxng](https://github.com/ihor-sokoliuk/mcp-searxng) MCP server, deployed as a `podman-compose` stack (SearXNG, Valkey, MCP server) supervised by a systemd unit so the stack returns after a reboot. Only the MCP HTTP endpoint is published, on loopback port `8081`; SearXNG itself stays on the container network.
- **llama**: [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` on the ROCm (`localhost/llama-rocm`) or Vulkan (`localhost/llama-vulkan`) image (Qwen3.8 thinking-mode preset, 131072-token context, 8 GiB host-RAM prompt cache), supervised by a systemd unit so it returns after a reboot. Only the HTTP endpoint is published, on loopback port `8080`. Web search comes from the SearXNG MCP server over public HTTPS and page fetching from Crawl4AI Cloud: a `--ui-config-file` pre-registers `https://websearch.brookemao.ca/mcp` (with the Bearer token) as a `searxng_*` tool set and `https://api.crawl4ai.com/mcp` (with its own Bearer token) as a `crawl4ai_*` tool set for first-time Web UI visitors. SearXNG is called directly from the browser (its CORS allowlist permits the llama origin); Crawl4AI goes through llama-server's `--ui-mcp-proxy` (`useProxy:true`) because its third-party CORS headers do not permit the llama origin.

### Known issues

- **`puppet-firewalld` `firewalld_service` silently never applies (workaround in place).**
  The provider prefetches a canned `ensure => :present` for every service definition
  firewalld knows about (`firewall-cmd --get-services` lists *definitions*, not zone
  membership — `cockpit.xml` ships with firewalld, so it is always "known"). The
  resource therefore evaluates as in-sync without ever running the real zone-membership
  check, and every apply is a silent no-op. Reproducer:
  ```bash
  sudo puppet resource --modulepath=modules firewalld_service "Allow cockpit in the public zone" \
    ensure=present zone=public service=cockpit   # reports present, changes nothing
  sudo firewall-cmd --permanent --zone=public --list-services   # cockpit absent
  ```
  Workaround: `homelab::firewall` allows Cockpit via `firewalld_port` (`9090/tcp`)
  instead — behaviorally identical, since the shipped `cockpit` service is just
  `9090/tcp`, and the port provider checks actual zone membership. An upstream fix
  (prefetch only services actually enabled in the resource's zone, or always run
  `exists?`) is planned.
- **Direct-rule `--uid-owner` must be numeric.** firewalld applies direct rules
  through the nftables `iptables-restore` compat layer, which rejects usernames
  (`Bad value for "--uid-owner" option`), failing the whole restore and leaving
  the rules unenforced. `homelab::firewall` therefore resolves the worker UID at
  apply time via the `nginx_uid` custom fact. On a fresh host the nginx account
  does not exist yet when facts resolve, so the first apply skips the egress
  rules with a warning and the second apply enforces them.

---

## Overnight access restrictions

`homelab::access_hours` installs `homelab-access-hours.timer` to stop and
runtime-mask `cockpit.socket`, `cockpit.service`, and `sshd.service` from
**midnight to 9 AM Pacific**, then unmask and start Cockpit's socket and SSH
at 9 AM. An installed `sshd.socket` is also blocked overnight. The timer and
hour check both use **`America/Vancouver`**, independently of the host timezone.
The calendar syntax follows [systemd's timer documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html).

`homelab-claude-history.timer` runs a Bash oneshot service every five minutes
from 00:00 through 08:55 Pacific. The access-hours timer enables and starts it
at midnight, then disables and stops it at 9 AM. Its enablement is runtime-only;
the access-hours service checks the schedule again after reboot and on every
Puppet apply. The old `history.jsonl` path watcher is removed during migration.

The script recursively greps
`/home/iapark/.local/share/containers/storage/volumes/claude-home/_data/projects`
for `"origin":{"kind":"human"}`, then uses `jq` to sort matching JSON records
by timestamp, latest first. If the latest ISO 8601 timestamp is strictly after
today's midnight in `America/Vancouver`, it kills `iapark`'s running
**immich-tools devcontainer**. No matches or a missing projects directory do
nothing; read errors, malformed JSON and invalid timestamps fail the check and
are retried on the next tick. Fractional seconds are included in the comparison.

The service runs as root to control its system timer, invoking Podman as
`iapark` using that user's local rootless storage.
It identifies the external devcontainer by the exact name `immich-tools`, a
generated `vsc-immich-tools-...` name, or a `devcontainer.local_folder` /
`vsch.local.folder` label whose folder is named `immich-tools`. Matching running
containers are killed with `podman kill`. Checks continue every five minutes
throughout the nighttime window, including after a successful kill. Once human
activity after midnight is detected, any matching container restarted that
night is killed again on the next check. At 9 AM the access-hours service
disables and stops the timer. This repository does not
create, reconfigure, or automatically restart the devcontainer at 9 AM.

The schedule is enforced immediately on every Puppet apply and checked again
at boot and after missed timer events. Native boot activation of these
listeners stays disabled; the timer starts them during daytime. This prevents
an overnight reboot from starting them before the schedule is checked.
The baseline delegates Cockpit's service state to this class so Puppet cannot
restart it overnight. `homelab::manage_services: false` installs the files
without activating or enforcing the schedule.

Apply using the usual bootstrap/Puppet workflow, then inspect it on the host:

```bash
sudo systemctl list-timers homelab-access-hours.timer
sudo journalctl -u homelab-access-hours.service
sudo systemctl list-timers homelab-claude-history.timer
sudo journalctl -u homelab-claude-history.service
```

SSH and Cockpit access will be unavailable during the overnight window;
keep local console access for maintenance then. Stopping SSH blocks new
connections; existing SSH sessions may survive according to sshd's unit policy.

Run `python -B -m unittest discover -s tests` to check history parsing, Pacific
date/time boundaries, and devcontainer selection without touching live containers.

## Project Structure

```text
.
├── bootstrap/bootstrap.sh   # Installs OpenVox, prompts for secrets, runs apply
├── data/                    # Hiera data: common.yaml, secrets.yaml.example
├── hiera.yaml               # Hiera 5 hierarchy
├── environment.conf         # modulepath
├── manifests/site.pp        # Masterless entrypoint for `puppet apply`
└── modules/
    ├── homelab/             # Site profile: git, fastfetch, fail2ban, firewall, podman,
    │                        #   ddclient, Let's Encrypt, cockpit, nginx (mTLS proxy); declares immich, searxng, llama
    ├── immich/              # Immich stack: compose.yml + systemd unit
    ├── searxng/             # SearXNG + MCP stack: compose.yml, settings.yml + systemd unit
    └── llama/               # llama.cpp server: ui-config.json + systemd unit
```

---

## Quick Start

### 1. Automated Bootstrap Script (Recommended)

The easiest way to bootstrap and configure a fresh Fedora 44 machine is using `bootstrap/bootstrap.sh`. It automatically:
1. Installs the official Vox Pupuli OpenVox repository (`openvox8-release-fedora-44.noarch.rpm`) and `openvox-agent` via DNF with sudo.
2. Securely prompts for secrets (Cloudflare API key/token, Immich database
   password, SearXNG secret key, Crawl4AI MCP bearer token, llama Basic-auth
   password) — or reads Cloudflare from `CLOUDFLARE_API_KEY`, SearXNG from
   `SEARXNG_SECRET_KEY`, Crawl4AI from `CRAWL4AI_AUTH_TOKEN` and the llama
   password from `LLAMA_BASIC_PASSWORD`. Empty SearXNG input auto-generates
   a random key, and the SearXNG MCP bearer token (`searxng::auth_token`,
   32 bytes) is always auto-generated unless `SEARXNG_AUTH_TOKEN` is set.
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
  homelab::ddclient_install_method: 'package'
  homelab::ddclient_release_tag: 'latest'
  homelab::cloudflare_zone: 'brookemao.ca'
  homelab::cloudflare_domains: 'homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca,llama.brookemao.ca,llama-api.brookemao.ca,websearch.brookemao.ca,claudechats.brookemao.ca'
  homelab::ddclient_replace_config: false
  ```

- **`data/secrets.yaml`** *(gitignored)*: Holds private tokens and keys:
  ```yaml
  homelab::cloudflare_token: 'your_real_token_here'

  # Optional. Defaults to 'immich' if omitted. See "Managing Immich" below
  # before changing this on a host that has already run once.
  immich::db_password: 'your_immich_db_password_here'

  # SearXNG server secret_key. Generate one with `openssl rand -hex 32`.
  # The bootstrap script prompts for this (empty input auto-generates).
  searxng::secret_key: 'your_searxng_secret_key_here'

  # Bearer token for the public SearXNG MCP vhost (websearch.brookemao.ca),
  # also injected into the MCP container and pre-registered in llama's
  # --ui-config-file. 32 bytes, hex-encoded (`openssl rand -hex 32`).
  # The bootstrap script generates this automatically.
  searxng::auth_token: 'your_searxng_mcp_bearer_token_here'

  # Bearer token for the Crawl4AI Cloud MCP server
  # (https://api.crawl4ai.com/mcp), pre-registered in llama's
  # --ui-config-file. The bootstrap script prompts for this (or reads
  # CRAWL4AI_AUTH_TOKEN).
  llama::crawl4ai_bearer_token: 'your_crawl4ai_mcp_bearer_token_here'

  # SHA-512 crypt hash of the llama Basic-auth password (user `agentforce`).
  # The bootstrap script prompts for the password and stores only the hash.
  llama::basic_auth_password: 'your_llama_basic_auth_password_hash_here'

  # Per-client API keys for the llama API vhost (llama-api.brookemao.ca),
  # sent as `Authorization: Bearer <key>`. 32 bytes each, base64-encoded
  # (`openssl rand -base64 32`). The bootstrap script generates any missing
  # key automatically.
  homelab::nginx::llama_api_keys:
    brooke: 'your_llama_api_key_brooke_here'
    izzy: 'your_llama_api_key_izzy_here'
    general: 'your_llama_api_key_general_here'

  # Optional. See "Cloudflare Tunnel" below.
  homelab::cloudflared::tunnel_token: 'your_tunnel_token_here'
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
| `ddclient_install_method` | `String` | `'package'` | `'package'` (dnf) or `'tarball'` (official GitHub release tarball) |
| `ddclient_release_tag` | `String` | `'latest'` | `'latest'` (auto-queries newest GitHub release tag past 4.0.0) or specific tag (e.g. `'v4.0.0'`) |
| `cloudflare_token` | `String` | `'<SECRET TOKEN HERE>'` | Cloudflare API Token for dynamic DNS updates |
| `cloudflare_zone` | `String` | `'brookemao.ca'` | Cloudflare root domain zone |
| `cloudflare_domains` | `String` | `'homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca,llama.brookemao.ca,llama-api.brookemao.ca,websearch.brookemao.ca,claudechats.brookemao.ca'` | Subdomains to update |
| `ddclient_replace_config` | `Boolean` | `false` | Whether to overwrite existing `/etc/ddclient/ddclient.conf` |

### `immich`

Set these with `immich::<name>` Hiera keys. All are optional - the class defaults apply
when no key is present, which is why `data/common.yaml` carries none of them.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `db_password` | `Sensitive[String]` | `Sensitive('immich')` | PostgreSQL password. Only read at database initialisation - see below |
| `db_readonly_password` | `Optional[Sensitive[String]]` | `undef` | Password for the read-only role `db_readonly_user`. When set, PostgreSQL is published on `127.0.0.1:db_port` and the role is created; bootstrap generates it. See [Read-only database access](#read-only-database-access) |
| `db_readonly_user` | `String` | `'immich_ro'` | Name of the read-only role. Renaming it drops the old one; `postgres`, `public`, `none` and `pg_*` are rejected |
| `db_port` | `Integer[1, 65535]` | `5432` | Host loopback port PostgreSQL is published on when `db_readonly_password` is set |
| `version` | `String` | `'v3.2.2'` | Immich image tag |
| `timezone` | `String` | `'America/Los_Angeles'` | `TZ` passed to the containers |
| `port` | `Integer[1, 65535]` | `2283` | Host port published for the web UI |
| `cpu_limit` | `Numeric` | `4` | Cores the whole stack may use |
| `memory_limit` | `String` | `'12g'` | Memory the whole stack may use |
| `ml_acceleration` | `Enum['cpu', 'rocm']` | `'rocm'` | `'rocm'` runs machine learning on the AMD GPU (`-rocm` image, `/dev/kfd` + `/dev/dri`); `'cpu'` uses the plain image |
| `base_dir` | `Immich::Absolutepath` | `'/home/immich'` | Directory the deployment lives under; created if missing, never restyled. Its own parent must already exist |
| `install_dir` | `Immich::Absolutepath` | `'/opt/immich-app'` | Holds the generated `compose.yml` |

### `searxng`

Set these with `searxng::<name>` Hiera keys. `secret_key` and `auth_token` are
required — bootstrap collects both into `data/secrets.yaml`; the rest default
sensibly.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `secret_key` | `Sensitive[String]` | *(required)* | SearXNG `server.secret_key`. Re-applying after a change restarts the stack via the settings subscription |
| `auth_token` | `Sensitive[String]` | *(required)* | Bearer token for the public MCP vhost; also injected into the MCP container as `MCP_HTTP_AUTH_TOKEN`. Re-applying after a change restarts the stack and reloads nginx |
| `version` | `String` | `'latest'` | SearXNG image tag |
| `mcp_version` | `String` | `'latest'` | mcp-searxng image tag |
| `memory_limit` | `String` | `'4g'` | Memory the whole stack may use (collective pod cap) |
| `port` | `Integer[1, 65535]` | `8081` | Host loopback port published for the MCP HTTP endpoint |
| `mcp_allowed_origins` | `String` | `'https://llama.brookemao.ca'` | CORS origins the MCP server accepts — this is what lets the browser call it directly from the llama Web UI |
| `mcp_allowed_hosts` | `String` | `"websearch.brookemao.ca,localhost,127.0.0.1,localhost:${port},127.0.0.1:${port}"` | Host values the MCP server accepts (matched exactly, port included, so the loopback port forms are needed for direct `curl` checks) |
| `install_dir` | `Searxng::Absolutepath` | `'/opt/searxng-app'` | Holds the generated `compose.yml` and `settings.yml` |

### `llama`

Set these with `llama::<name>` Hiera keys. `searxng_bearer_token` and
`crawl4ai_bearer_token` are required — bootstrap collects the former into
`data/secrets.yaml` (as `searxng::auth_token`, shared with the searxng module)
and the latter as `llama::crawl4ai_bearer_token`; the rest default
sensibly. The Basic-auth password for the public vhost lives under the
`llama::basic_auth_password` Hiera key (SHA-512 crypt hash, collected by
bootstrap) and is consumed by `homelab::nginx`, not this class.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `backend` | `Enum['rocm', 'vulkan']` | `'rocm'` | GPU backend: `rocm` passes `/dev/kfd` + `/dev/dri` with the ROCm library path; `vulkan` passes only the single dGPU (see `vulkan_pci_id`). Also selects the default `image` when `image` is unset |
| `model` | `String` | `'Qwen3.8-27B-UD-Q6_K.gguf'` | GGUF basename under `models_dir`, or an absolute container path |
| `mmproj` | `Optional[String]` | `undef` | Vision encoder GGUF basename under `models_dir`, or an absolute container path; passed as `--mmproj` when set |
| `models_dir` | `Llama::Absolutepath` | `'/home/llama/models'` | Host model directory, mounted read-only at the same path. Only the directory itself is ensured; its parent must already exist |
| `port` | `Integer[1, 65535]` | `8080` | Host loopback port published for the HTTP endpoint |
| `image` | `Optional[String]` | `undef` (`'localhost/llama-rocm:latest'` when `backend` is `rocm`, `'localhost/llama-vulkan:latest'` when `vulkan`) | Container image; must already exist in rootful podman storage (build it with `sudo` via [homelab-llama](https://github.com/brookemao/homelab-llama)). Set explicitly to pin a tag or use a custom build |
| `reasoning_effort` | `String` | `'xhigh'` | Thinking effort passed to the chat template |
| `memory_limit` | `String` | `'12g'` | RAM the container may use; over-allocation fails inside the container instead of OOMing the host |
| `vulkan_pci_id` | `Optional[String]` | `undef` | Explicit dGPU PCI slot override (e.g. `'0000:03:00.0'`); defaults to the `llama_dgpu_pci` fact (Navi 48 lookup), else `'0000:03:00.0'`. The unit resolves that slot's stable `/dev/dri/by-path` symlinks at each start into `/dev/llama-dgpu-render` and `/dev/llama-dgpu-card` (mapped to `renderD128`/`card0`) |
| `searxng_mcp_url` | `String` | `'https://websearch.brookemao.ca/mcp'` | Public MCP endpoint pre-registered in `--ui-config-file`; the browser calls it directly |
| `searxng_bearer_token` | `Sensitive[String]` | *(required)* | Bearer token for that endpoint; same secret as `searxng::auth_token` |
| `crawl4ai_mcp_url` | `String` | `'https://api.crawl4ai.com/mcp'` | Crawl4AI Cloud MCP endpoint pre-registered in `--ui-config-file` with `useProxy:true` (via llama-server `--ui-mcp-proxy`; direct browser calls fail its third-party CORS check) |
| `crawl4ai_bearer_token` | `Sensitive[String]` | *(required)* | Bearer token for that endpoint (`Authorization: Bearer` header) |
| `install_dir` | `Llama::Absolutepath` | `'/opt/llama-app'` | Holds `ui-config.json` and the bundled Sharp chat template, bind-mounted read-only into the container |

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
homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca,llama.brookemao.ca,llama-api.brookemao.ca,websearch.brookemao.ca,claudechats.brookemao.ca
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
`replace => false` preserves existing API credentials and options. Puppet still updates
the hostname-only line for the managed Cloudflare zone from `homelab::cloudflare_domains`,
so adding `claudechats.brookemao.ca` takes effect on existing installations. Keep custom
hostnames in that Hiera list. This profile manages one Cloudflare zone/config stanza.

---

## Claude conversation exports

`homelab::claudelogs` installs Fedora's `uv` package and manages
`claudelogs.service`. The service runs the following command continuously as
`root` to access both directories, with `UMask=0027`:

```bash
/usr/bin/uvx claude-code-log@latest watch --all-projects --combined no --projects-dir /home/iapark/.local/share/containers/storage/volumes/claude-home/_data/projects/ --output /home/share/claudelogs
```

The watcher converts once at startup, then updates HTML when transcripts change.
Only individual session pages are generated (`--combined no`); combined pages left
from earlier exports are retained but no longer refreshed. Reload a session page
to see new messages. nginx continues to serve static HTML; full-archive search
requires the separate `serve` mode and is not enabled here.

systemd starts the watcher at boot, restarts it on failure, and captures its output
in the journal. The service must be able to download the latest tool from PyPI at
startup. Puppet removes the former `/etc/cron.d/claudelogs` job and reloads systemd
when the unit changes; other cron jobs and the shared cron daemon are left alone.
Override `homelab::claudelogs::{user,projects_dir,output_dir}` through Hiera if needed;
nginx uses the same `output_dir`. The baseline `manage_services` flag also controls
management of `claudelogs.service`.

nginx serves the generated `index.html` and project/session pages at
`https://claudechats.brookemao.ca`, using the existing wildcard Let's Encrypt certificate
and Cockpit's client CA and verification depth. A valid client certificate is required
for every page. Directory listings are disabled. The output directory is owned by
`root:nginx` with mode `2750`, so new exports inherit the nginx group and remain
unreadable to other local users. SELinux labels `/home/share` and the export tree as
`httpd_sys_content_t`; the source container volume keeps its existing labels and permissions.

Apply the manifests using the normal command from [Standalone Execution](#2-standalone-execution).
In Cloudflare, ensure `claudechats.brookemao.ca` has a **DNS-only** A record, as with
Cockpit, so TLS terminates at this nginx instance and it receives the client certificate.
ddclient maintains the record's public IP using the existing Cloudflare token.

The first export starts when the service starts. After applying, check it with:

```bash
sudo systemctl status claudelogs
sudo journalctl -u claudelogs -f
sudo nginx -t
curl -I https://claudechats.brookemao.ca/  # must reject a request without a client certificate
curl --cert client.pem --key client.key -I https://claudechats.brookemao.ca/
```

The authenticated request should return `200` once conversion has generated `index.html`.

---

## Cloudflare Tunnel

`homelab::cloudflared` installs `cloudflared` from `pkg.cloudflare.com` and runs the connector as
`cloudflared.service` (a systemd `DynamicUser`, so it has no account or privileges of its own).
Nothing is opened in firewalld; the tunnel only dials out.

The tunnel is **remotely managed**: Puppet holds only the token. The tunnel, its public hostname
and the Access application that guards it are all set up in the
[Zero Trust dashboard](https://one.dash.cloudflare.com/):

1. **Create the tunnel.** Networks > Tunnels > Create a tunnel > Cloudflared, named `homelab`.
   The install step shows a command ending in `--token <token>`: copy the token and skip the
   install itself - Puppet does that.
2. **Add the public hostname** `immich.iapark.dev` → service `HTTP`, URL `127.0.0.1:2283`. Use
   `127.0.0.1`, not `localhost`: Immich is published on IPv4 loopback only, and `localhost` may
   resolve to `::1`. Delete any existing `immich.iapark.dev` DNS record first; the dashboard
   creates the CNAME to the tunnel.
3. **Put Access in front of it.** Access > Applications > Add > Self-hosted, domain
   `immich.iapark.dev`, with an Allow policy for the people who should get in (e.g. their email
   addresses). Then, on the tunnel's public hostname, turn on Access JWT validation
   ("Enforce Access JSON Web Token validation") so the connector rejects anything that did not
   pass through Access.
4. **Let the mobile app through.** The Immich app cannot complete the Access browser login.
   Create a service token (Access > Service Auth), add a policy with action *Service Auth* that
   includes it, and enter its `CF-Access-Client-Id` and `CF-Access-Client-Secret` as custom proxy
   headers in the app (Settings > Advanced).

Then re-run `bootstrap/bootstrap.sh`: whenever `data/secrets.yaml` has no tunnel token it asks for
one (or takes `CLOUDFLARE_TUNNEL_TOKEN`) and saves it as `homelab::cloudflared::tunnel_token`.
Leaving it blank skips it. The service starts once the token is present; the dashboard shows the
tunnel as Healthy once it connects.

```bash
sudo systemctl status cloudflared
sudo journalctl -u cloudflared
```

Caveats:

- **Uploads over 100 MB fail.** Cloudflare's Free and Pro plans cap a proxied request body at
  100 MB, so large videos cannot be uploaded through `immich.iapark.dev`. Upload them on the LAN
  instead.
- **fail2ban does not cover tunnel traffic.** The `[immich]` jail bans client IPs in firewalld,
  but tunnel requests reach the host over cloudflared's outbound connection, so those bans never
  apply. Access (and Cloudflare's WAF) is the protection here.

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

### Encoded-video storage

`immich::encoded_video_location` is set to `/mnt/immich/encoded-video` in
`data/common.yaml`. Puppet writes `ENCODED_VIDEO_LOCATION` to `/opt/immich-app/.env`
and uses it for the server's `/data/encoded-video` bind mount, following Immich's
[custom-location guide](https://docs.immich.app/guides/custom-locations/).
The systemd unit waits for this storage mount, and changes to `.env` restart the stack.
Omitting the Hiera key leaves encoded videos under `/home/immich/data/library/encoded-video`.

For an existing deployment, copy the files **before the first apply of this change**
on the Fedora host (adjust the source if `immich::base_dir` was overridden):

```bash
sudo systemctl stop immich
sudo mkdir -p /mnt/immich/encoded-video
sudo rsync -a /home/immich/data/library/encoded-video/ /mnt/immich/encoded-video/
```

Copy the entire directory, including its hidden `.immich` marker. Then run the normal
Puppet apply to set directory ownership and the `container_file_t` label,
then run `sudo restorecon -R /mnt/immich/encoded-video` to label the copied files
and `sudo systemctl restart immich` to restart with those labels in place.
Ensure `/mnt/immich` exists and its storage is mounted before applying.
If the previous parkpack location was already deployed, use
`/mnt/parkpack/encoded-video/` as the rsync source instead, and stop other processes
using parkpack so Puppet can remount it with its original read-only SELinux label.
The external photos library is still mounted `:ro` inside the server container.
Keep the original encoded-video files until playback and transcoding work at the new
location. Puppet does not copy or delete existing media files.

### Read-only database access

Setting `immich::db_readonly_password` (bootstrap generates it) publishes PostgreSQL on
`127.0.0.1:5432` and creates the `immich_ro` role, for tooling such as the
[immich-tools](https://github.com/IAPark/immich-tools) devcontainer. The role gets `USAGE`
and `SELECT` on every table, view and sequence in every non-system schema, plus default
privileges so objects Immich's migrations create later are covered too. It deliberately
does not get `pg_read_all_data`, which would also let it read `pg_authid` and so the
superuser's password hash. It defaults to read-only transactions and has no create or
temp-table rights: the SQL also revokes Postgres 14's default `CREATE` on `public` and
`TEMPORARY` on the database from `PUBLIC`, which does not affect Immich (it connects as the
`postgres` superuser).

Puppet writes the SQL to `/opt/immich-app/readonly-role.sql` (mode `0600`) and runs it through
`podman exec immich_postgres psql`, retrying for up to 5 minutes while Postgres starts. It
records a hash of the applied SQL in `readonly-role.sql.applied` and runs again on any apply
where that hash is stale or the role is missing, so a failed first run, a password rotation
or a recreated database fix themselves. With `manage_service => false` it is skipped while
`immich_postgres` isn't running, and since Puppet then doesn't restart the stack, turning the
feature on or off only logs a warning that `systemctl restart immich` is needed before the
port appears or goes away.

Roles it creates carry a comment marking them as Puppet's. Renaming `db_readonly_user`
drops the old role, and removing `immich::db_readonly_password` drops the role, deletes
the SQL file and unpublishes the port (the `PUBLIC` revokes stay). Check it with:

```bash
PGPASSWORD="$(sudo awk -F"'" '/^immich::db_readonly_password:/ {print $2}' data/secrets.yaml)" \
  psql -h 127.0.0.1 -U immich_ro -d immich -c '\dt'
```

Like the web UI port, `5432` is bound to loopback only, so it is reachable from the host
(including `--network=host` containers) but not from the LAN. The `postgres` superuser
can also log in over that port with `immich::db_password`, so the class refuses to compile
while that is still the `'immich'` default. Postgres only reads it at initdb, so on an
existing database run `ALTER USER postgres PASSWORD '...'` inside `immich_postgres` before
changing `immich::db_password`.

### Resource limits

`cpu_limit` and `memory_limit` cap the stack **collectively**, not per container. All four
services together get 4 cores and 12 GB.

podman-compose puts every service of a project into a pod (`pod_immich` here), and a pod
is a cgroup. Limiting the pod limits everything inside it, so the compose file sets the
limits on `podman pod create` rather than on each service:

```yaml
x-podman:
  pod_args:
    - --infra=false
    - --share=
    - --cpus=4
    - --memory=12g
```

`pod_args` **replaces** podman-compose's defaults rather than extending them, which is why
`--infra=false` and `--share=` are repeated - dropping them would change how the stack is
networked.

Check it took with `podman pod inspect pod_immich`, or read the cgroup directly:

```bash
cat /sys/fs/cgroup/machine.slice/*libpod_pod*/memory.max
cat /sys/fs/cgroup/machine.slice/*libpod_pod*/cpu.max
```

Pod-level limits need cgroups v2, which Fedora 44 uses by default.

---

## Managing SearXNG

Puppet writes `/opt/searxng-app/compose.yml` and `/opt/searxng-app/settings.yml`
(the latter carries `searxng::secret_key`, mode `0600`) plus a systemd unit at
`/etc/systemd/system/searxng.service`, then enables it. The unit wraps
`podman-compose up -d` / `down` and is what brings the stack back after a reboot -
podman is daemonless, so `restart: always` alone would not survive one.

```bash
sudo systemctl status searxng      # is the stack up?
sudo systemctl restart searxng     # down, then up
sudo journalctl -u searxng         # compose output
sudo podman ps                     # the three containers
sudo podman logs searxng-mcp       # logs from the MCP server
```

The MCP endpoint listens on loopback port `8081` (`/health` for reachability,
`/mcp` for clients). `homelab::firewall` opens no port for it, so it is
reachable from the host but not through firewalld from the LAN. SearXNG itself
publishes no host port — verify it through the MCP tool: discovery and
`/health` succeeding do not prove the JSON search path works, so make a real
`searxng_web_search` call after (re)deploying.

The same MCP server is public at `https://websearch.brookemao.ca/mcp` behind
nginx Bearer auth (`searxng::auth_token`, checked against
`MCP_HTTP_AUTH_TOKEN` in hardened static mode). That is the endpoint llama's
Web UI is pre-configured to call directly. CORS preflight (`OPTIONS`, which
carries no credentials by design) passes through nginx to the MCP server's own
cors middleware; every data method still needs the Bearer at both layers.

Caveats:

- **Set `searxng::secret_key` before the first run.** The class has no default;
  without the Hiera key the catalog fails to compile. Bootstrap collects it.
- **Re-applying after a secret change restarts the stack**, since the service
  subscribes to the generated files.

---

## Managing Llama

Puppet writes a systemd unit at `/etc/systemd/system/llama.service` plus the
Web UI defaults at `/opt/llama-app/ui-config.json` (mode `0600`, carries both
MCP Bearer tokens), then enables the unit. The unit runs `podman run` in the
foreground (no compose file — a single container), so logs flow straight to
the journal.

```bash
sudo systemctl status llama       # is the server up?
sudo systemctl restart llama      # recreate the container with new settings
sudo journalctl -u llama          # server output
sudo podman logs llama            # same logs via podman
```

The HTTP endpoint (Web UI, OpenAI-compatible API) listens on loopback port
`8080` and is public at `https://llama.brookemao.ca` behind HTTP Basic auth
(user `agentforce`; bootstrap prompts for the password and stores only its
SHA-512 crypt hash as `llama::basic_auth_password`). The same endpoint is
also public at `https://llama-api.brookemao.ca` behind per-client API-key
auth (`Authorization: Bearer <key>`, one key per label under
`homelab::nginx::llama_api_keys`; bootstrap generates each missing key with
`openssl rand -base64 32`), for programmatic OpenAI-compatible API use
without the browser UI. The client key is stripped before proxying since the
backend runs without `--api-key`. The SearXNG tools show up
as `searxng_*` and the Crawl4AI tools as `crawl4ai_*` in the Web UI and
`GET /tools`: first-time visitors get the `https://websearch.brookemao.ca/mcp`
server pre-registered from `--ui-config-file` (url + Bearer header, direct
browser calls), and the MCP
server's CORS allowlist (`MCP_HTTP_ALLOWED_ORIGINS`, set to the llama origin
by the searxng module) is what permits those calls — llama-server itself needs
no CORS configuration since the UI is same-origin with it. The
`https://api.crawl4ai.com/mcp` server is pre-registered with `useProxy:true`
(url + Bearer header from `llama::crawl4ai_bearer_token`, reached through
llama-server's `--ui-mcp-proxy`): direct browser calls fail because
api.crawl4ai.com is third-party and its CORS response does not allow the
llama origin, and the Bearer `Authorization` header triggers a preflight
the browser blocks. No nginx change fixes that — CORS is enforced by the
upstream response, so the request must avoid cross-origin browser fetch
via the server-side proxy instead.
Verify search end
to end with a chat prompt that needs fresh information — discovery and
`/health` alone don't prove the tool path works.

Prerequisites Puppet does not provide (first apply fails loudly without them):

- The container image in rootful podman storage — `localhost/llama-rocm:latest`
  by default, or `localhost/llama-vulkan:latest` with `llama::backend: 'vulkan'`
  — build it with `sudo` via [homelab-llama](https://github.com/brookemao/homelab-llama)
  so it lands in rootful (system) storage where the root systemd unit can see
  it (a user-storage build is invisible to the unit).
- GPU devices `/dev/kfd` and `/dev/dri` (ROCm) or `/dev/dri` (Vulkan) on the host.
- The model file, e.g. `/home/llama/models/Qwen3.8-27B-UD-Q6_K.gguf`.
- The vision encoder file, e.g. `/home/llama/models/Qwen3.8-27B-mmproj-BF16.gguf`
  (required when `llama::mmproj` is set).

Caveats:

- **The [Qwen Sharp chat template](https://huggingface.co/peculiar-ragdoll/Qwen-Sharp-Chat-Templates) is managed by Puppet.**
  The bundled v22.5.0 template replaces the model's embedded template through
  `--jinja --chat-template-file`, with `--reasoning-format deepseek` and the
  existing `reasoning_effort` setting. Its source revision and checksum are
  recorded in `modules/llama/files/README.md`. Template changes restart the service.
- **`--spec-type draft-mtp,ngram-mod` enables both speculative decoders.**
  The existing `--spec-draft-n-max 3` setting is retained. The container image
  must support both decoder types and comma-separated `--spec-type` values.
- **`--ctx-size 131072` is passed.** This sets the context length to 131072
  tokens (1/2 of the 262144-token Qwen3 maximum, kept this low to avoid OOM);
  the KV cache uses the configured q8_0 cache types.
- **`--cache-ram 8192` is passed.** The host-RAM prompt cache stays at the
  8 GiB llama.cpp default, keeping prompt/KV state in system RAM bounded
  under the container's memory cap.
- **No `--parallel` is passed.** llama.cpp manages concurrent requests using
  its defaults.
- **`-kvu` is passed.** This forces the shared (unified) KV cache across
  sequences instead of per-slot buffers.
- **`--sleep-idle-seconds 600` is passed.** The model unloads after 10
  minutes idle and reloads on the next request.
- **The Bearer tokens are baked into the browser-side defaults.** Anyone who can
  log in to the Web UI can read them from their own browser storage — acceptable
  for a private, Basic-auth-gated instance, and it matches how the upstream UI
  stores per-server headers. Rotating the SearXNG token means updating
  `searxng::auth_token`
  (restarts the searxng stack, reloads nginx) and re-applying so llama picks
  up the new `--ui-config-file` (restarts llama-server); rotating the Crawl4AI
  token means updating `llama::crawl4ai_bearer_token` and re-applying.
- **llama has no dependency on the searxng stack.** The browser reaches the
  MCP server over public HTTPS at chat time, so either side can restart
  independently and the container needs no special egress. Puppet still
  restarts llama on firewall changes because the published-port forwarding
  depends on podman network rules.
- **Vulkan dGPU selection is automatic.** The host has two AMD GPUs
  (Navi 48 dGPU at `03:00.0`, Raphael iGPU at `12:00.0`), and `card*`/`renderD*`
  numbers drift across reboots, so the unit selects the dGPU by PCI-anchored
  `/dev/dri/by-path` symlinks: the `llama_dgpu_pci` fact finds the Navi 48 slot
  via `lspci` (override with `llama::vulkan_pci_id`, fallback `'0000:03:00.0'`),
  and `ExecStartPre` resolves them into colon-free `/dev/llama-dgpu-render`
  and `/dev/llama-dgpu-card` links (podman would split the `by-path` colons as
  `src:dst` separators) on every start. Re-run puppet if a PCIe device is
  added or moved: slot numbers can change, and the unit bakes in whatever the
  fact saw at apply time.
