# @summary Installs and configures fail2ban with firewalld integration on RHEL 10
#
# @param ensure Ensure state for the packages ('installed', 'latest', etc.)
# @param manage_service Whether to enable and start the fail2ban service
# @param manage_config Whether to generate /etc/fail2ban/jail.local
# @param bantime Default ban duration in seconds (default: 3600 = 1 hour)
# @param findtime Time window in seconds to count failed attempts (default: 600 = 10 min)
# @param maxretry Number of failed attempts before banning (default: 5)
# @param banaction Firewall ban action (default: firewallcmd-rich-rules)
# @param backend Log backend (default: systemd)
class homelab::fail2ban (
  String[1] $ensure         = 'installed',
  Boolean   $manage_service = true,
  Boolean   $manage_config  = true,
  Integer   $bantime        = 3600,
  Integer   $findtime       = 600,
  Integer   $maxretry       = 5,
  String[1] $banaction      = 'firewallcmd-rich-rules',
  String[1] $backend        = 'systemd',
) {
  require homelab::epel

  $packages = [
    'fail2ban',
    'fail2ban-firewalld',
    'fail2ban-selinux',
    'fail2ban-server',
  ]

  package { $packages:
    ensure  => $ensure,
    require => Class['homelab::epel'],
  }

  if $manage_config {
    file { '/etc/fail2ban/jail.local':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('homelab/jail.local.epp', {
        'bantime'   => $bantime,
        'findtime'  => $findtime,
        'maxretry'  => $maxretry,
        'banaction' => $banaction,
        'backend'   => $backend,
      }),
      require => Package[$packages],
      notify  => Service['fail2ban'],
    }
  }

  if $manage_service {
    service { 'fail2ban':
      ensure  => running,
      enable  => true,
      require => Package[$packages],
    }
  }
}
