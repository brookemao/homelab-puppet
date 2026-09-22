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
# @param immich_enabled Whether to enable the Immich failed-login jail
# @param immich_maxretry Failed Immich logins before banning (default: 10)
# @param immich_bantime Immich ban duration in seconds (default: 86400 = 24 hours)
# @param immich_findtime Time window in seconds to count Immich failures (default: 600 = 10 min)
# @param immich_port Ports guarded by the Immich jail (default: http,https)
# @param immich_logpath Log file for the Immich jail (default: undef = read from systemd journal)
# @param immich_journalmatch Journal match scoping the Immich jail to its container logs
class homelab::fail2ban (
  String[1] $ensure         = 'installed',
  Boolean   $manage_service = true,
  Boolean   $manage_config  = true,
  Integer   $bantime        = 3600,
  Integer   $findtime       = 600,
  Integer   $maxretry       = 5,
  String[1] $banaction      = 'firewallcmd-rich-rules',
  String[1] $backend        = 'systemd',
  Boolean   $immich_enabled      = true,
  Integer   $immich_maxretry     = 10,
  Integer   $immich_bantime      = 86400,
  Integer   $immich_findtime     = 600,
  String[1] $immich_port         = 'http,https',
  Optional[String[1]] $immich_logpath = undef,
  String[1] $immich_journalmatch = 'CONTAINER_NAME=immich-server',
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
        'bantime'            => $bantime,
        'findtime'           => $findtime,
        'maxretry'           => $maxretry,
        'banaction'          => $banaction,
        'backend'            => $backend,
        'immich_enabled'     => $immich_enabled,
        'immich_maxretry'    => $immich_maxretry,
        'immich_bantime'     => $immich_bantime,
        'immich_findtime'    => $immich_findtime,
        'immich_port'        => $immich_port,
        'immich_logpath'     => $immich_logpath,
        'immich_journalmatch' => $immich_journalmatch,
      }),
      require => Package[$packages],
      notify  => Service['fail2ban'],
    }

    file { '/etc/fail2ban/filter.d/immich.conf':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      source  => 'puppet:///modules/homelab/fail2ban-immich-filter.conf',
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
