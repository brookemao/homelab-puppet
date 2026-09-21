# @summary Enables CodeReady Builder (CRB) and installs the EPEL 10 repository
#
# @param epel_rpm_url URL to the EPEL 10 release RPM package
class homelab::epel (
  String[1] $epel_rpm_url = 'https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm',
) {
  # EPEL 10 depends on packages from CodeReady Builder (CRB).
  # Handles RHEL 10, Rocky Linux 10, AlmaLinux 10, and CentOS Stream 10.
  exec { 'enable_crb_repo':
    command => '/usr/bin/dnf config-manager --set-enabled crb || /usr/bin/crb enable || /usr/bin/subscription-manager repos --enable "codeready-builder-for-rhel-10-$(arch)-rpms" || true',
    unless  => '/usr/bin/dnf repolist --enabled | /usr/bin/grep -iE "(crb|codeready)"',
    path    => ['/usr/bin', '/usr/sbin', '/bin', '/sbin'],
  }

  package { 'epel-release':
    ensure   => installed,
    provider => 'rpm',
    source   => $epel_rpm_url,
    require  => Exec['enable_crb_repo'],
  }

  # Refresh repository metadata after installing EPEL
  exec { 'refresh_epel_metadata':
    command     => '/usr/bin/dnf makecache --refresh',
    path        => ['/usr/bin', '/usr/sbin', '/bin', '/sbin'],
    refreshonly => true,
    subscribe   => Package['epel-release'],
  }
}
