# @summary Installs fastfetch from native Fedora repositories
#
# @param ensure Ensure state for the package ('installed', 'latest', etc.)
class homelab::fastfetch (
  String[1] $ensure = 'installed',
) {
  package { 'fastfetch':
    ensure => $ensure,
  }
}
