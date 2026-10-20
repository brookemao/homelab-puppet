# @summary Restricts Cockpit and SSH access to 09:00-24:00 Pacific time
# @param manage_service Whether to activate the schedule and enforce it on apply
class homelab::access_hours (
  Boolean $manage_service = true,
) {
  package { 'openssh-server':
    ensure => installed,
  }

  file { '/usr/local/sbin/homelab-access-hours':
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
    source => 'puppet:///modules/homelab/access-hours.sh',
  }

  ['service', 'timer'].each |$extension| {
    file { "/etc/systemd/system/homelab-access-hours.${extension}":
      ensure => file,
      owner  => 'root',
      group  => 'root',
      mode   => '0644',
      source => "puppet:///modules/homelab/homelab-access-hours.${extension}",
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
  }
}
