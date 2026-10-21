# @summary Watches Claude conversations and exports HTML for the mTLS-protected nginx site
#
# Runs as root to access both the container volume and export directory. The setgid output
# directory and restrictive umask give nginx read access without making
# transcripts world-readable or granting it access to the source volume.
#
# @param user Export user (root by default to access both directories)
# @param projects_dir Claude transcript source directory
# @param output_dir HTML document root shared with homelab::nginx
# @param manage_service Whether to enable and start the watcher and daily restart timer
class homelab::claudelogs (
  String[1]            $user           = 'root',
  Stdlib::Absolutepath $projects_dir   = '/home/iapark/.local/share/containers/storage/volumes/claude-home/_data/projects/',
  Stdlib::Absolutepath $output_dir     = '/home/share/claudelogs',
  Boolean              $manage_service = true,
) {
  stdlib::ensure_packages(['uv', 'tzdata'])

  # Do not require the whole nginx class: its service must be able to start
  # after the document root and SELinux labels are ready.
  file { '/home/share':
    ensure => directory,
    # Allow traversal while preserving the shared directory's other rights
    # and ownership (it can already be used by services outside this profile).
    mode   => 'o+x',
  }

  file { $output_dir:
    ensure  => directory,
    owner   => $user,
    group   => 'nginx',
    mode    => '2750',
    require => [File['/home/share'], Package['nginx']],
  }

  if $facts['os']['selinux']['enabled'] {
    # Label just the shared parent and exports, leaving the private container
    # volume untouched. New exports inherit httpd_sys_content_t.
    selinux::fcontext { '/home/share':
      seltype => 'httpd_sys_content_t',
      before  => File['/home/share'],
    }
    selinux::fcontext { "${output_dir}(/.*)?":
      seltype => 'httpd_sys_content_t',
      before  => File[$output_dir],
    }

    exec { 'selinux-claudelogs-content':
      command     => "/usr/sbin/restorecon /home/share && /usr/sbin/restorecon -R '${output_dir}'",
      refreshonly => true,
      subscribe   => [
        Selinux::Fcontext['/home/share'],
        Selinux::Fcontext["${output_dir}(/.*)?"],
      ],
      require     => [File['/home/share'], File[$output_dir]],
      before      => Class['nginx::service'],
      logoutput   => on_failure,
    }

    if $manage_service {
      Exec['selinux-claudelogs-content'] -> Service['claudelogs']
    }
  }

  # Remove the former scheduled exporter before starting the watcher.
  file { '/etc/cron.d/claudelogs':
    ensure => absent,
  }

  file { '/etc/systemd/system/claudelogs.service':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('homelab/claudelogs.service.epp', {
      'user'         => $user,
      'projects_dir' => $projects_dir,
      'output_dir'   => $output_dir,
    }),
    notify  => Exec['claudelogs-daemon-reload'],
  }

  ['claudelogs-restart.service', 'claudelogs-restart.timer'].each |$unit| {
    file { "/etc/systemd/system/${unit}":
      ensure => file,
      owner  => 'root',
      group  => 'root',
      mode   => '0644',
      source => "puppet:///modules/homelab/${unit}",
      notify => Exec['claudelogs-daemon-reload'],
    }
  }

  exec { 'claudelogs-daemon-reload':
    command     => 'systemctl daemon-reload',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  if $manage_service {
    service { 'claudelogs':
      ensure    => running,
      enable    => true,
      subscribe => [Package['uv'], File['/etc/systemd/system/claudelogs.service']],
      require   => [
        File[$output_dir],
        File['/etc/cron.d/claudelogs'],
        Exec['claudelogs-daemon-reload'],
      ],
    }

    service { 'claudelogs-restart.timer':
      ensure    => running,
      enable    => true,
      subscribe => File['/etc/systemd/system/claudelogs-restart.timer'],
      require   => [
        Package['tzdata'],
        Service['claudelogs'],
        File['/etc/systemd/system/claudelogs-restart.service'],
        Exec['claudelogs-daemon-reload'],
      ],
    }
  }
}
