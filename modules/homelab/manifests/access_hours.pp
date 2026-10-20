# @summary Restricts overnight access and stops immich-tools on overnight Claude use
# @param manage_service Whether to activate the schedule and enforce it on apply
class homelab::access_hours (
  Boolean $manage_service = true,
) {
  package { 'openssh-server':
    ensure => installed,
  }

  stdlib::ensure_packages(['python3', 'tzdata'])

  file { '/usr/local/sbin/homelab-claude-history':
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
    source => 'puppet:///modules/homelab/claude-history-guard.py',
  }

  file { '/usr/local/sbin/homelab-access-hours':
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
    source => 'puppet:///modules/homelab/access-hours.sh',
  }

  [
    'homelab-access-hours.service',
    'homelab-access-hours.timer',
    'homelab-claude-history.service',
    'homelab-claude-history.path',
  ].each |$unit| {
    file { "/etc/systemd/system/${unit}":
      ensure => file,
      owner  => 'root',
      group  => 'root',
      mode   => '0644',
      source => "puppet:///modules/homelab/${unit}",
      notify => Exec['systemd-daemon-reload-access-hours'],
    }
  }

  exec { 'systemd-daemon-reload-access-hours':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  if $manage_service {
    # Reconcile on every apply so Puppet never reopens access overnight and
    # installing the schedule takes effect immediately, even between events.
    exec { 'enforce-access-hours':
      command => '/usr/bin/systemctl start homelab-access-hours.service',
      require => [
        Package['openssh-server'],
        Package['python3'],
        Package['tzdata'],
        File['/usr/local/sbin/homelab-access-hours'],
        File['/usr/local/sbin/homelab-claude-history'],
        File['/etc/systemd/system/homelab-access-hours.service'],
        File['/etc/systemd/system/homelab-claude-history.service'],
        File['/etc/systemd/system/homelab-claude-history.path'],
        Exec['systemd-daemon-reload-access-hours'],
      ],
    }

    service { 'homelab-access-hours.timer':
      ensure    => running,
      enable    => true,
      require   => Exec['enforce-access-hours'],
      subscribe => File['/etc/systemd/system/homelab-access-hours.timer'],
    }
  }
}
