# @summary Exports Claude conversations daily for the mTLS-protected nginx site
#
# Runs as the owner of the rootless container volume. The setgid output
# directory and restrictive umask give nginx read access without making
# transcripts world-readable or granting it access to the source volume.
#
# @param user Existing user who owns the Claude container volume
# @param projects_dir Claude transcript source directory
# @param output_dir HTML document root shared with homelab::nginx
# @param timezone Cron scheduling timezone (Pacific time, including DST)
# @param manage_service Whether to enable and start crond
class homelab::claudelogs (
  String[1]            $user           = 'iapark',
  Stdlib::Absolutepath $projects_dir   = '/home/iapark/.local/share/containers/storage/volumes/claude-home/_data/projects/',
  Stdlib::Absolutepath $output_dir     = '/home/share/claudelogs',
  String[1]            $timezone       = 'America/Los_Angeles',
  Boolean              $manage_service = true,
) {
  stdlib::ensure_packages(['uv', 'cronie', 'tzdata'])

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
  }

  # A separate cron.d file scopes CRON_TZ to this job; it does not change
  # the system timezone or the schedule of any other user's cron jobs.
  file { '/etc/cron.d/claudelogs':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('homelab/claudelogs.cron.epp', {
      'user'         => $user,
      'projects_dir' => $projects_dir,
      'output_dir'   => $output_dir,
      'timezone'     => $timezone,
    }),
    require => [Package['uv'], Package['cronie'], Package['tzdata'], File[$output_dir]],
  }

  if $manage_service {
    service { 'crond':
      ensure  => running,
      enable  => true,
      require => File['/etc/cron.d/claudelogs'],
    }
  }
}
