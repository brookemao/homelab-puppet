# firewalld reloads break Immich podman DNS — behavior and fix

## Symptom

After a `puppet apply` that touches `homelab::firewall`, Immich logs fill with:

```
[Nest] LOG [Api:MachineLearningRepository] Machine learning server became unhealthy (http://immich-machine-learning:3003).
[Nest] ERROR [Api:ErrorInterceptor] Unknown error: Error: getaddrinfo EAI_AGAIN database
```

`EAI_AGAIN database` = the `immich_server` container cannot resolve the
`database` (postgres) service name. The `ML unhealthy` line is the same
root cause for `immich-machine-learning:3003`. Cockpit/nginx are unaffected.

## Root cause

`puppet-firewalld` (`firewalld_port`, `firewalld_direct_rule`) manages
`--permanent` config. Activating permanent config requires
`firewall-cmd --reload`, which rebuilds firewall state from permanent config
and flushes podman `netavark`/`aardvark-dns` runtime rules (container DNS on
the podman network, inter-container connectivity). Until the compose stack
restarts, containers fail DNS.

Verify correlation:

```bash
sudo journalctl -u firewalld --no-pager | grep -i reload
sudo journalctl -u immich --since "60 min ago" --no-pager | tail -n 30
podman logs --tail 30 immich_server | grep -i "EAI_AGAIN\|unhealthy"
```

A `firewalld --reload` timestamp immediately before the first `EAI_AGAIN`
confirms it.

## Why fail2ban is safe

`fail2ban` (firewalld rich-rules integration) adds runtime-only bans
(`firewall-cmd --add-rich-rule ... --timeout ...`, ipsets). No `--reload`,
podman chains stay intact. Only permanent-change applies reload.

## Fix in this repo

`modules/homelab/manifests/init.pp`:

```puppet
Class['homelab::firewall'] ~> Class['immich']
```

Any refresh (change) in `homelab::firewall` refreshes `Class['immich']`,
which propagates to `Service['immich']` (restart = compose down/up via the
systemd unit). No firewall change = no restart. This intentionally does not
live in `firewalld.service` as an `ExecReload` — that would restart Immich
(DB + ML + imports) on *every* system reload.

`manage_service => false` is safe: the class always exists, so the
class-to-class edge never dangles (unlike an edge to `Service['immich']`,
which only exists when the service is managed).

## Manual recovery

```bash
sudo systemctl restart immich
podman ps; podman logs --tail 20 immich_server
```

## Operator notes

- Batch firewall edits; each permanent-change apply restarts Immich once.
- `puppet apply --noop` first to see whether firewall resources will change.
- Do not add `ExecReload=systemctl restart immich` to `firewalld.service`:
  fail2ban-adjacent and system reloads would bounce the DB unnecessarily.
