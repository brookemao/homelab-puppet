# @summary Installs fastfetch from EPEL 10
#
# @param ensure Ensure state for the package ('installed', 'latest', etc.)
class homelab::fastfetch (
  String[1] $ensure = 'installed',
) {
  require homelab::epel

  package { 'fastfetch':
    ensure  => $ensure,
    require => Class['homelab::epel'],
  }
}
