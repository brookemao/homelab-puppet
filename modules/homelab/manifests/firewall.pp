# @summary Manages firewalld and opens HTTPS in the public zone on RHEL 10
#
# @param ensure Ensure state for the firewalld package (via puppet-firewalld)
# @param manage_service Whether to enable and start the firewalld service
# @param zone Firewalld zone to manage (default: public)
# @param port Port to allow in the zone (default: 443)
# @param protocol Protocol for the allowed port (default: tcp)
class homelab::firewall (
  String[1] $ensure         = 'installed',
  Boolean   $manage_service = true,
  String[1] $zone           = 'public',
  Integer   $port           = 443,
  String[1] $protocol       = 'tcp',
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
}
