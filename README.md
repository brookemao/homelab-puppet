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
- **nginx**: TLS reverse proxy (via `puppet-nginx`) — `cockpit.brookemao.ca` forwards to Cockpit on port `9090` requiring an mTLS client certificate signed by the personal PKI root (upstream `proxy_ssl_verify off` — Cockpit uses a self-signed cert on localhost); `websearch.brookemao.ca` forwards to the SearXNG MCP server on loopback `8081` gated by a Bearer token; `llama.brookemao.ca` forwards to llama-server on loopback `8080` gated by HTTP Basic auth (`agentforce`); all other hosts hit the catch-all default page. (Immich is not proxied by nginx — it is published through the Cloudflare Tunnel instead.) SELinux least privilege, same pattern as Cockpit: a minimal `nginx_backends` allow module lets the workers reach both loopback backends (TCP `8081` is relabeled to the policy-shipped `http_cache_port_t` to match `8080`), no `httpd_can_network_connect`.
- **cockpit**: Proxy-aware Cockpit (`Origins` + `X-Forwarded-Proto` in `cockpit.conf`, `cockpit.socket` enabled) with extra UIs for Podman containers, virtual machines, and files (`cockpit-podman`, `cockpit-machines`, `cockpit-files`) and SELinux least privilege — TCP `9090` stays on its policy-shipped `websm_port_t` label and a minimal `nginx_cockpit` allow module lets nginx connect, no `httpd_can_network_connect`.
- **letsencrypt**: Wildcard certificate for the zone apex + `*` via Cloudflare DNS-01 (via `puppet-letsencrypt`), with a twice-daily `certbot-renew` systemd timer and nginx reload on renewal.
- **ddclient**: Dynamic DNS client installed via the native DNF package (or built from the upstream [GitHub release tarball](https://github.com/ddclient/ddclient#installation) with automatic discovery of the latest tag past 4.0.0 and systemd service integration).
- **cloudflared**: [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) from Cloudflare's RPM repository, publishing `immich.iapark.dev` → Immich on `127.0.0.1:2283` with no inbound port. Remotely managed: the tunnel, its public hostname and the Zero Trust Access policy in front of it live in the Cloudflare dashboard; Puppet only runs the connector with the token from `data/secrets.yaml`. See [Cloudflare Tunnel](#cloudflare-tunnel).
- **Immich**: Self-hosted [photo and video server](https://immich.app) deployed as a `podman-compose` stack (server, machine learning, Valkey, PostgreSQL) running under a dedicated `immich` system account, supervised by a systemd unit so the stack returns after a reboot.
- **SearXNG**: Self-hosted metasearch ([SearXNG](https://docs.searxng.org)) plus the [mcp-searxng](https://github.com/ihor-sokoliuk/mcp-searxng) MCP server, deployed as a `podman-compose` stack (SearXNG, Valkey, MCP server) supervised by a systemd unit so the stack returns after a reboot. Only the MCP HTTP endpoint is published, on loopback port `8081`; SearXNG itself stays on the container network.
- **llama**: [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` on the ROCm (`localhost/llama-rocm`) or Vulkan (`localhost/llama-vulkan`) image (Qwen3.8 thinking-mode preset, 131072-token context, 8 GiB host-RAM prompt cache), supervised by a systemd unit so it returns after a reboot. Only the HTTP endpoint is published, on loopback port `8080`. Web search comes from the SearXNG MCP server over public HTTPS: a `--ui-config-file` pre-registers `https://websearch.brookemao.ca/mcp` (with the Bearer token) as a `searxng_*` tool set for first-time Web UI visitors, and the browser calls it directly — no CORS proxy.

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
   password, SearXNG secret key, llama Basic-auth password) — or reads Cloudflare
   from `CLOUDFLARE_API_KEY`, SearXNG from `SEARXNG_SECRET_KEY` and the llama
   password from `LLAMA_BASIC_PASSWORD`. Empty SearXNG input auto-generates
   a random key, and the MCP bearer token (`searxng::auth_token`, 32 bytes) is
   always auto-generated unless `SEARXNG_AUTH_TOKEN` is set.
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
  homelab::cloudflare_domains: 'homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca,llama.brookemao.ca,websearch.brookemao.ca'
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

  # SHA-512 crypt hash of the llama Basic-auth password (user `agentforce`).
  # The bootstrap script prompts for the password and stores only the hash.
  llama::basic_auth_password: 'your_llama_basic_auth_password_hash_here'

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
| `cloudflare_domains` | `String` | `'homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca,llama.brookemao.ca,websearch.brookemao.ca'` | Subdomains to update |
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

Set these with `llama::<name>` Hiera keys. Only `searxng_bearer_token` is
required — bootstrap collects it into `data/secrets.yaml` (as
`searxng::auth_token`, shared with the searxng module); the rest default
sensibly. The Basic-auth password for the public vhost lives under the
`llama::basic_auth_password` Hiera key (SHA-512 crypt hash, collected by
bootstrap) and is consumed by `homelab::nginx`, not this class.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `backend` | `Enum['rocm', 'vulkan']` | `'rocm'` | GPU backend: `rocm` passes `/dev/kfd` + `/dev/dri` with the ROCm library path; `vulkan` passes only the single dGPU (see `vulkan_pci_id`). Also selects the default `image` when `image` is unset |
| `model` | `String` | `'Qwen3.8-27B-UD-Q6_K.gguf'` | GGUF basename under `models_dir`, or an absolute container path |
| `models_dir` | `Llama::Absolutepath` | `'/home/llama/models'` | Host model directory, mounted read-only at the same path. Only the directory itself is ensured; its parent must already exist |
| `port` | `Integer[1, 65535]` | `8080` | Host loopback port published for the HTTP endpoint |
| `image` | `Optional[String]` | `undef` (`'localhost/llama-rocm:latest'` when `backend` is `rocm`, `'localhost/llama-vulkan:latest'` when `vulkan`) | Container image; must already exist in rootful podman storage (build it with `sudo` via [homelab-llama](https://github.com/brookemao/homelab-llama)). Set explicitly to pin a tag or use a custom build |
| `reasoning_effort` | `String` | `'xhigh'` | Thinking effort passed to the chat template |
| `memory_limit` | `String` | `'12g'` | RAM the container may use; over-allocation fails inside the container instead of OOMing the host |
| `vulkan_pci_id` | `Optional[String]` | `undef` | Explicit dGPU PCI slot override (e.g. `'0000:03:00.0'`); defaults to the `llama_dgpu_pci` fact (Navi 48 lookup), else `'0000:03:00.0'`. The unit resolves that slot's stable `/dev/dri/by-path` symlinks at each start into `/dev/llama-dgpu-render` and `/dev/llama-dgpu-card` (mapped to `renderD128`/`card0`) |
| `searxng_mcp_url` | `String` | `'https://websearch.brookemao.ca/mcp'` | Public MCP endpoint pre-registered in `--ui-config-file`; the browser calls it directly |
| `searxng_bearer_token` | `Sensitive[String]` | *(required)* | Bearer token for that endpoint; same secret as `searxng::auth_token` |
| `install_dir` | `Llama::Absolutepath` | `'/opt/llama-app'` | Holds the generated `ui-config.json`, bind-mounted read-only into the container |

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
homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca,llama.brookemao.ca,websearch.brookemao.ca
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
Web UI defaults at `/opt/llama-app/ui-config.json` (mode `0600`, carries the
MCP Bearer token), then enables the unit. The unit runs `podman run` in the
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
SHA-512 crypt hash as `llama::basic_auth_password`). The SearXNG tools show up
as `searxng_*` in the Web UI and `GET /tools`: first-time visitors get the
`https://websearch.brookemao.ca/mcp` server pre-registered from
`--ui-config-file` (url + Bearer header, direct browser calls), and the MCP
server's CORS allowlist (`MCP_HTTP_ALLOWED_ORIGINS`, set to the llama origin
by the searxng module) is what permits those calls — llama-server itself needs
no CORS configuration since the UI is same-origin with it. Verify search end
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

Caveats:

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
- **The Bearer token is baked into the browser-side defaults.** Anyone who can
  log in to the Web UI can read it from their own browser storage — acceptable
  for a private, Basic-auth-gated instance, and it matches how the upstream UI
  stores per-server headers. Rotating it means updating `searxng::auth_token`
  (restarts the searxng stack, reloads nginx) and re-applying so llama picks
  up the new `--ui-config-file` (restarts llama-server).
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
