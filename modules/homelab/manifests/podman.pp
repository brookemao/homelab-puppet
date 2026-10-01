# @summary Installs podman and podman-compose from native Fedora repositories
#
# @param ensure Ensure state for the packages ('installed', 'latest', etc.)
# @param manage_podman Whether to install the podman package itself (disable if managed elsewhere)
class homelab::podman (
  String[1] $ensure        = 'installed',
  Boolean   $manage_podman = true,
) {
  if $manage_podman {
    package { 'podman':
      ensure => $ensure,
    }
  }

  package { 'podman-compose':
    ensure => $ensure,
  }
}
