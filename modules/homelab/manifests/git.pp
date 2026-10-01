# @summary Installs git
#
# @param ensure Ensure state for the git package ('installed', 'latest', etc.)
class homelab::git (
  String[1] $ensure = 'installed',
) {
  package { 'git':
    ensure => $ensure,
  }
}
