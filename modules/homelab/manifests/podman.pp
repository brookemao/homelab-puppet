# @summary Installs podman and podman-compose on RHEL 10
#
# podman ships natively with RHEL 10 (AppStream); podman-compose comes from EPEL.
#
# @param ensure Ensure state for the packages ('installed', 'latest', etc.)
# @param manage_podman Whether to install the podman package itself (disable if managed elsewhere)
class homelab::podman (
  String[1] $ensure        = 'installed',
  Boolean   $manage_podman = true,
) {
  require homelab::epel

  if $manage_podman {
    package { 'podman':
      ensure => $ensure,
    }
  }

  package { 'podman-compose':
    ensure  => $ensure,
    require => Class['homelab::epel'],
  }
}
