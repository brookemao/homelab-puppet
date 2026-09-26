# Cockpit behind nginx with mTLS — Plan

Goal: proxy `https://cockpit.brookemao.ca` via nginx to Cockpit on `https://127.0.0.1:9090`, requiring client certs signed by personal PKI root.

References:
- https://garrett.github.io/cockpit-project.github.io/external/wiki/Proxying-Cockpit-over-NGINX
- https://github.com/brookemao/brooke-pki/blob/main/certificates/brookemao-root-ca-1.pem (private repo — copy manually, see §2)

Current state (repo):
- `modules/homelab/manifests/nginx.pp` proxies `cockpit.brookemao.ca` -> `127.0.0.1:9090` (mTLS), catch-all `_` default vhost, wildcard LE cert `brookemao.ca`. (Immich/photos forwarding removed — Immich stays off the internet.)
- `modules/homelab/manifests/letsencrypt.pp` already covers `brookemao.ca` + `*.brookemao.ca` (no LE change needed).
- `modules/homelab/manifests/firewall.pp` opens only `443/tcp` (keep `9090` closed externally).

## 1. Cockpit — new `modules/homelab/manifests/cockpit.pp`

- Install `cockpit` package, enable `cockpit.socket`.
- Manage `/etc/cockpit/cockpit.conf`:
```ini
[WebService]
Origins = https://cockpit.brookemao.ca wss://cockpit.brookemao.ca
ProtocolHeader = X-Forwarded-Proto
```
- Keep `AllowUnencrypted` unset (proxy to `https://127.0.0.1:9090`, nginx does not verify upstream self-signed cert).
- Leave `ClientCertAuthentication` off: mTLS terminates at nginx, Cockpit never sees the client cert; login stays password-based. Enabling it would break proxy auth.

## 2. CA distribution

- Vendor root to `modules/homelab/files/brookemao-root-ca-1.pem` -> `/etc/nginx/brookemao-root-ca-1.pem` (`0644 root:root`).
- brooke-pki is private so Puppet cannot fetch it at apply time: `cp ~/brooke-pki/certificates/brookemao-root-ca-1.pem modules/homelab/files/brookemao-root-ca-1.pem` before applying. The repo currently holds a placeholder describing this.

## 3. nginx vhost — extend `modules/homelab/manifests/nginx.pp`

- New `nginx::resource::server { 'cockpit-reverse-proxy': }` for `cockpit.brookemao.ca`, same LE `fullchain.pem`/`privkey.pem` as existing vhosts.
- Upstream proxy (per wiki). Cockpit serves a self-signed cert on localhost, so upstream verification stays off (`proxy_ssl_verify off` via `location_cfg_append` — puppet-nginx has no native param; off is also the nginx default):
```nginx
proxy_pass https://127.0.0.1:9090;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
proxy_buffering off;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
gzip off;
```
- mTLS (edge-only):
```nginx
ssl_client_certificate /etc/nginx/brookemao-root-ca-1.pem;
ssl_verify_client on;
ssl_verify_depth 1;
proxy_set_header X-SSL-Client-Verify $ssl_client_verify;
proxy_set_header X-SSL-Client-DN $ssl_client_s_dn;
```
- `puppet-nginx` may lack first-class `ssl_verify_client` params — use `server_cfg_append`/`raw_append` fallback.

## 4. SELinux — no boolean, no http_port_t

- Install `policycoreutils-python-utils` (`semanage`/`semodule`), `policycoreutils` (`semodule_package`), `checkpolicy` (`checkmodule`).
- Keep TCP 9090 on its policy-shipped `websm_port_t` label (Cockpit's historical type name; there is no `cockpit_port_t` on RHEL — `semanage port -l | grep 9090` confirms). Drop any stale local customization; only (re)add the label if policy ever stops shipping it.
```bash
semanage port -l | grep -w 9090  # expect websm_port_t; fix local overrides only
```
- Grant nginx (`httpd_t`) least-privilege access via a vendored allow module (`modules/homelab/files/nginx_cockpit.te`, `allow httpd_t websm_port_t:tcp_socket name_connect`), compiled and installed with `checkmodule`/`semodule_package`/`semodule -i`. Do NOT set `httpd_can_network_connect`.
- In Puppet (`homelab::cockpit`): `exec` for the port label plus `file` + refresh-only `exec` for the module build/install. Bump the `policy_module` version in the `.te` file when the rule changes so `semodule -i` picks it up.

## 5. DNS / firewall / LE

- Add `cockpit.brookemao.ca` DNS `A`/`CNAME`; optionally add to `homelab::cloudflare_domains` in `data/common.yaml` if ddclient-managed.
- No firewall change (`443/tcp` already open). No new LE cert (wildcard covers it).

## 6. Client certs

- Issue leaves from `brooke-pki` with `clientAuth` EKU, import p12 into browser/OS store.
- Expect `400/495` without cert, `200` with `curl --cert client.crt --key client.key`.

## 7. Puppet file changes

- NEW `modules/homelab/manifests/cockpit.pp` (package + `cockpit.conf` + `semanage` exec).
- NEW `modules/homelab/files/brookemao-root-ca-1.pem` (copy from private brooke-pki checkout).
- EDIT `modules/homelab/manifests/nginx.pp` (cockpit vhost with mTLS).
- EDIT `modules/homelab/manifests/init.pp` (include `homelab::cockpit` before `homelab::nginx`).
- EDIT `data/common.yaml` (cockpit hostname / `cloudflare_domains`).
- EDIT `bootstrap/bootstrap.sh` only if new Forge dep (`puppet-selinux`) is chosen.
- UPDATE `README.md` (new vhost + mTLS requirement).

## 8. Verify / rollback

- `nginx -t; systemctl restart cockpit nginx` (or `puppet apply --noop` first).
- With cert: Cockpit UI + websocket terminal works. Without cert: handshake fails. `journalctl -u nginx -u cockpit`, `ausearch -m avc -ts recent` clean.
- Rollback: remove cockpit vhost, `semodule -r nginx_cockpit`, restore `cockpit.conf` (leave the `websm_port_t` label — it is the policy default).
