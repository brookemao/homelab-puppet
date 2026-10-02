# @summary Manages firewalld and opens HTTPS in the managed zone
#
# Inbound: opens $port/$protocol in $zone. Outbound: optionally confines the
# nginx workers to localhost egress via direct OUTPUT rules, so a compromised
# or misconfigured proxy cannot exfiltrate. (Direct rules are firewalld's
# deprecated path, but rich rules/policies cannot match on UID; a REJECT
# verdict is terminal and unaffected by the known nftables-backend ACCEPT-mark
# quirks. Revisit if firewalld ever drops direct-rule support.)
# The destination matches on the ORIGINAL address (--ctorigdst): connections
# to locally-published container ports are DNAT-rewritten before filter
# OUTPUT runs, so matching the rewritten address would wrongly reject the
# backends nginx exists to serve.
#
# Fedora note: fresh Fedora installs default to the FedoraServer or
# FedoraWorkstation zone, not public. $manage_default_zone pins the system
# default zone to $zone so the port rule lands where the interfaces actually
# are. Set $default_zone to undef to leave the system default alone (then
# make sure $zone matches the active zone yourself).
#
# @param ensure Ensure state for the firewalld package (via puppet-firewalld)
# @param manage_service Whether to enable and start the firewalld service
# @param zone Firewalld zone to manage (default: public)
# @param port Port to allow in the zone (default: 443)
# @param protocol Protocol for the allowed port (default: tcp)
# @param manage_default_zone Whether to set firewalld's default zone to $zone
# @param default_zone Explicit default zone; defaults to $zone when undef
# @param allow_cockpit Whether to allow Cockpit (9090/tcp) in $zone.
#   Stock Fedora zones omit it (Rocky's public zone shipped it by default),
#   so without this direct Cockpit access is blocked and only the nginx
#   mTLS proxy on 443 reaches it. Implemented as a port rule rather than
#   firewalld's cockpit service: puppet-firewalld's firewalld_service
#   provider falsely reports the service as present (it enumerates known
#   service definitions instead of zone membership), so the rule silently
#   never applied. The shipped cockpit service is just 9090/tcp anyway.
# @param cockpit_port Port Cockpit listens on (default: 9090)
# @param cockpit_protocol Protocol for the Cockpit port (default: tcp)
# @param restrict_nginx_egress Whether to REJECT nginx worker egress outside loopback.
#   The worker UID is resolved at apply time via the nginx_uid custom fact
#   (numeric UIDs only: the nftables iptables-restore compat layer rejects
#   usernames in --uid-owner with 'Bad value').
class homelab::firewall (
  String[1] $ensure               = 'installed',
  Boolean   $manage_service       = true,
  String[1] $zone                 = 'public',
  Integer   $port                 = 443,
  String[1] $protocol             = 'tcp',
  Boolean   $manage_default_zone  = true,
  Optional[String[1]] $default_zone = undef,
  Boolean   $allow_cockpit        = true,
  Integer   $cockpit_port         = 9090,
  String[1] $cockpit_protocol     = 'tcp',
  Boolean   $restrict_nginx_egress = true,
) {
  $effective_default_zone = $manage_default_zone ? {
    true    => pick($default_zone, $zone),
    default => undef,
  }

  class { 'firewalld':
    package_ensure => $ensure,
    service_ensure => $manage_service ? {
      true    => 'running',
      default => 'stopped',
    },
    service_enable => $manage_service,
    default_zone   => $effective_default_zone,
  }

  firewalld_port { "Open port ${port} in the ${zone} zone":
    ensure   => present,
    zone     => $zone,
    port     => $port,
    protocol => $protocol,
  }

  if $allow_cockpit {
    firewalld_port { "Open Cockpit port ${cockpit_port} in the ${zone} zone":
      ensure   => present,
      zone     => $zone,
      port     => $cockpit_port,
      protocol => $cockpit_protocol,
    }
  }

  # Facts resolve before the catalog applies, so on a fresh host the nginx
  # account does not exist yet (nginx is installed later in this same run)
  # and the fact is empty. Skipping with a loud warning beats failing the
  # whole catalog: everything else still applies, and the next run enforces
  # the rules once the account exists.
  $nginx_uid = $facts['nginx_uid']
  if $restrict_nginx_egress and $nginx_uid == undef {
    warning('homelab::firewall: nginx user not present while compiling; skipping localhost-egress confinement for this run. Re-apply once nginx is installed to enforce it.')
  }

  if $restrict_nginx_egress and $nginx_uid != undef {
    # The nginx master runs as root but never proxies; workers run as the
    # nginx account, so the owner match catches proxied outbound sockets.
    # The UID comes from the nginx_uid fact and must stay numeric (see the
    # restrict_nginx_egress param docs): usernames are rejected outright.
    # Loopback stays open for Cockpit (:9090) and other local backends.
    # Match only NEW connections: without ctstate, the rule also drops
    # ESTABLISHED reply packets (TLS Server hello, HTTP responses), which
    # hangs every remote client after Client hello.
    #
    # The destination matches on the ORIGINAL address (--ctorigdst), not the
    # current one: connections to locally-published container ports (llama
    # :8080, MCP :8081, ...) are DNAT-rewritten to the container IP in nat
    # OUTPUT, which runs before filter OUTPUT -- matching the rewritten
    # address would defeat the loopback exemption for exactly the backends
    # nginx exists to serve (cockpit :9090 needs no DNAT, which is why only
    # the container backends ever broke).
    firewalld_direct_rule { 'Restrict nginx workers to localhost egress (IPv4)':
      ensure        => present,
      inet_protocol => 'ipv4',
      table         => 'filter',
      chain         => 'OUTPUT',
      priority      => 0,
      args          => "-m owner --uid-owner ${nginx_uid} -m conntrack --ctstate NEW ! --ctorigdst 127.0.0.0/8 --jump REJECT",
    }

    firewalld_direct_rule { 'Restrict nginx workers to localhost egress (IPv6)':
      ensure        => present,
      inet_protocol => 'ipv6',
      table         => 'filter',
      chain         => 'OUTPUT',
      priority      => 0,
      args          => "-m owner --uid-owner ${nginx_uid} -m conntrack --ctstate NEW ! --ctorigdst ::1 --jump REJECT",
    }
  }
}
