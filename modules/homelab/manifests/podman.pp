# @summary Installs podman and podman-compose from native Fedora repositories
#
# Optionally relocates container storage via /etc/containers/storage.conf.
# Moving storage orphans existing containers on the old paths: after the
# first apply with new paths, restart dependent stacks (e.g.
# `systemctl restart immich`) so containers are recreated — images re-pull
# into the new graphroot. The abandoned old storage is left behind for you
# to delete once the move is verified.
#
# Requires puppetlabs-inifile (ini_setting) and puppet-selinux
# (selinux::fcontext); both are installed as Forge dependencies by
# bootstrap/bootstrap.sh.
#
# @param ensure Ensure state for the packages ('installed', 'latest', etc.)
# @param manage_podman Whether to install the podman package itself (disable if managed elsewhere)
# @param driver Storage driver (default: overlay). Stated explicitly because a
#   custom storage layout needs the driver key present alongside the paths.
# @param graphroot Persistent image/layer storage dir (undef leaves the distro default)
# @param manage_selinux Whether to label the custom storage dir for container access
class homelab::podman (
  String[1] $ensure        = 'installed',
  Boolean   $manage_podman = true,
  String[1] $driver        = 'overlay',
  Optional[Stdlib::Absolutepath] $graphroot = '/home/containers/storage',
  Boolean   $manage_selinux = true,
) {
  if $manage_podman {
    package { 'podman':
      ensure => $ensure,
    }
  }

  package { 'podman-compose':
    ensure => $ensure,
  }

  # storage.conf ships with the containers stack; order the settings after
  # the podman package when we manage it (otherwise the file is assumed to
  # already exist from externally-managed podman).
  $pkg_require = $manage_podman ? {
    true    => Package['podman'],
    default => [],
  }

  ini_setting { 'podman storage driver':
    ensure  => present,
    path    => '/etc/containers/storage.conf',
    section => 'storage',
    setting => 'driver',
    value   => "\"${driver}\"",
    require => $pkg_require,
  }

  $selinux_enabled = $manage_selinux and $facts['os']['selinux']['enabled']

  if $graphroot != undef {
    if $selinux_enabled {
      # Same type as the default /var/lib/containers. The store entry
      # defaults to seluser system_u, matching
      # system_u:object_r:container_var_lib_t:s0 after restorecon.
      selinux::fcontext { "${graphroot}(/.*)?":
        seltype => 'container_var_lib_t',
        before  => File[$graphroot],
      }

      # Fix any content that already carries the wrong label (e.g. written
      # before the rule existed). Runs only when the fcontext rule changes;
      # afterwards the rule keeps new files labeled automatically.
      exec { "restorecon ${graphroot}":
        command     => "restorecon -R ${graphroot}",
        path        => ['/usr/sbin', '/sbin', '/usr/bin', '/bin'],
        refreshonly => true,
        subscribe   => Selinux::Fcontext["${graphroot}(/.*)?"],
        require     => File[$graphroot],
      }
    }

    file { $graphroot:
      ensure   => directory,
      owner    => 'root',
      group    => 'root',
      mode     => '0755',
      seluser  => $selinux_enabled ? { true => 'system_u', default => undef },
      seltype  => $selinux_enabled ? { true => 'container_var_lib_t', default => undef },
      selrange => $selinux_enabled ? { true => 's0', default => undef },
      require  => $pkg_require,
    }

    ini_setting { 'podman graphroot':
      ensure  => present,
      path    => '/etc/containers/storage.conf',
      section => 'storage',
      setting => 'graphroot',
      value   => "\"${graphroot}\"",
      require => $pkg_require,
    }
  }
}
