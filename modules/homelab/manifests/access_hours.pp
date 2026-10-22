# @summary Restricts overnight access and stops immich-tools on overnight Claude use
# @param manage_service Whether to activate the schedule and enforce it on apply
class homelab::access_hours (
  Boolean $manage_service = true,
) {
  package { 'openssh-server':
    ensure => installed,
  }

  stdlib::ensure_packages(['bash', 'jq', 'tzdata'])

  file { '/usr/local/sbin/homelab-claude-history':
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
    source => 'puppet:///modules/homelab/claude-history-guard.sh',
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
    'homelab-claude-history.timer',
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

  # Retire the old history.jsonl watcher before installing its replacement.
  file { '/etc/systemd/system/homelab-claude-history.path':
    ensure => absent,
    notify => Exec['systemd-daemon-reload-access-hours'],
  }

  if $manage_service {
    exec { 'retire-claude-history-path':
      command => '/usr/bin/systemctl disable --now homelab-claude-history.path',
      onlyif  => '/usr/bin/test -f /etc/systemd/system/homelab-claude-history.path',
      before  => File['/etc/systemd/system/homelab-claude-history.path'],
    }
    # Reconcile on every apply so Puppet never reopens access overnight and
    # installing the schedule takes effect immediately, even between events.
    exec { 'enforce-access-hours':
      command => '/usr/bin/systemctl start homelab-access-hours.service',
      require => [
        Package['openssh-server'],
        Package['bash'],
        Package['tzdata'],
        File['/usr/local/sbin/homelab-access-hours'],
        File['/etc/systemd/system/homelab-access-hours.service'],
        Exec['systemd-daemon-reload-access-hours'],
      ],
    }

    service { 'homelab-access-hours.timer':
      ensure    => running,
      enable    => true,
      require   => Exec['enforce-access-hours'],
      subscribe => File['/etc/systemd/system/homelab-access-hours.timer'],
    }

    # Keep the timer enabled at boot; its own calendar limits checks to 22:00–18:00.
    service { 'homelab-claude-history.timer':
      ensure    => running,
      enable    => true,
      require   => [
        Package['bash'],
        Package['jq'],
        Package['tzdata'],
        File['/usr/local/sbin/homelab-claude-history'],
        File['/etc/systemd/system/homelab-claude-history.service'],
        Exec['systemd-daemon-reload-access-hours'],
      ],
      subscribe => File['/etc/systemd/system/homelab-claude-history.timer'],
    }
  }
}
