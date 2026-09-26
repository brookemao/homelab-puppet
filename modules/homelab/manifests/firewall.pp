# @summary Manages firewalld and opens HTTPS in the public zone on RHEL 10
#
# Inbound: opens $port/$protocol in $zone. Outbound: optionally confines the
# nginx workers to localhost egress via direct OUTPUT rules, so a compromised
# or misconfigured proxy cannot exfiltrate. (Direct rules are firewalld's
# deprecated path, but rich rules/policies cannot match on UID; a REJECT
# verdict is terminal and unaffected by the known nftables-backend ACCEPT-mark
# quirks. Revisit if firewalld ever drops direct-rule support.)
#
# @param ensure Ensure state for the firewalld package (via puppet-firewalld)
# @param manage_service Whether to enable and start the firewalld service
# @param zone Firewalld zone to manage (default: public)
# @param port Port to allow in the zone (default: 443)
# @param protocol Protocol for the allowed port (default: tcp)
# @param restrict_nginx_egress Whether to REJECT nginx worker egress outside loopback
# @param nginx_egress_user System user the nginx workers run as (socket owner match)
class homelab::firewall (
  String[1] $ensure               = 'installed',
  Boolean   $manage_service       = true,
  String[1] $zone                 = 'public',
  Integer   $port                 = 443,
  String[1] $protocol             = 'tcp',
  Boolean   $restrict_nginx_egress = true,
  String[1] $nginx_egress_user    = 'nginx',
) {
  class { 'firewalld':
    package_ensure => $ensure,
    service_ensure => $manage_service ? {
      true    => 'running',
      default => 'stopped',
    },
    service_enable => $manage_service,
  }

  firewalld_port { "Open port ${port} in the ${zone} zone":
    ensure   => present,
    zone     => $zone,
    port     => $port,
    protocol => $protocol,
  }

  if $restrict_nginx_egress {
    # The nginx master runs as root but never proxies; workers run as
    # $nginx_egress_user, so the owner match catches proxied outbound sockets.
    # Loopback stays open for Cockpit (:9090) and other local backends.
    firewalld_direct_rule { 'Restrict nginx workers to localhost egress (IPv4)':
      ensure        => present,
      inet_protocol => 'ipv4',
      table         => 'filter',
      chain         => 'OUTPUT',
      priority      => 0,
      args          => "-m owner --uid-owner ${nginx_egress_user} ! --destination 127.0.0.0/8 --jump REJECT",
    }

    firewalld_direct_rule { 'Restrict nginx workers to localhost egress (IPv6)':
      ensure        => present,
      inet_protocol => 'ipv6',
      table         => 'filter',
      chain         => 'OUTPUT',
      priority      => 0,
      args          => "-m owner --uid-owner ${nginx_egress_user} ! --destination ::1 --jump REJECT",
    }
  }
}
