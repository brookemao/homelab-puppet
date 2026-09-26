# @summary Installs Immich via podman-compose, running as a dedicated user.
#
# The compose file lives in $install_dir. Everything else lives under $base_dir, with all
# persistent data in $base_dir/data in a fixed layout (library, postgres, ml-model-cache,
# redis) so one ownership scheme and one SELinux rule cover it.
#
# Requires puppet-selinux (for the file context rule) and podman-compose (see
# homelab::podman).
#
# @param db_password Postgres password. Override via the immich::db_password Hiera key.
#   Postgres isn't exposed, but overriding this will help security
#   Postgres only reads this at initdb time, so changing it after the first boot will
#   NOT re-key an existing database - the server container will then fail to authenticate.
# @param base_dir Directory the whole deployment lives under; created if missing. 
# Its own parent must already exist (/home by default). Persistent data goes
#   in $base_dir/data, and the SELinux rule is recursive over that - so anything placed
#   beside it stays unreachable by the containers.
# @param external_libraries Host directories bind-mounted read-only into the server
#   container at the same path, for use as Immich external libraries (add each path under
#   Administration > External Libraries). Relabelled container_ro_file_t when SELinux is
#   managed, so they must be on a filesystem that supports labels (not NFS/CIFS), and their
#   files must be readable by the immich uid.
# @param cpu_limit Cores the whole stack may use. Applied to the pod podman-compose puts
#   the containers in, so it is a collective cap, not a per-container one.
# @param memory_limit Memory the whole stack may use, e.g. '16g'. Collective, as above.
# @param manage_selinux Whether to label the data directories for container access
# @param selinux_type SELinux type the containers need on their bind mounts
# @param compose_command Absolute path to the compose implementation (systemd ExecStart needs a full path)
# @param manage_service Whether to enable and start the immich systemd unit
# @param service_name Name of the systemd unit that owns the stack
#
class immich (
  Sensitive[String[1]] $db_password     = Sensitive('immich'),
  String[1]            $version         = 'v3.2.2',
  String[1]            $timezone        = 'America/Los_Angeles',
  Integer[1, 65535]    $port            = 2283,
  Immich::Absolutepath $install_dir     = '/opt/immich-app',
  Immich::Absolutepath $base_dir        = '/home/immich',
  Array[Immich::Absolutepath] $external_libraries = [],
  String[1]            $user            = 'immich',
  String[1]            $group           = 'immich',
  Numeric              $cpu_limit       = 4,
  Pattern[/\A\d+(\.\d+)?([bkmgBKMG]|[kKmMgG][bB])?\z/] $memory_limit = '16g',
  Integer[1]           $uid             = 2283,
  Integer[1]           $gid             = 2283,
  Boolean              $manage_selinux        = true,
  String[1]            $selinux_type          = 'container_file_t',
  Immich::Absolutepath $compose_command = '/usr/bin/podman-compose',
  Boolean              $manage_service  = true,
  String[1]            $service_name    = 'immich',
) {
  # Fixed layout, deliberately not parameterised. Everything the containers persist sits
  # under $data_dir, so one SELinux rule and one ownership scheme cover all of it, and
  # anything placed beside $data_dir stays outside the container label.
  $data_dir        = "${base_dir}/data"
  $upload_location = "${data_dir}/library"
  $db_location     = "${data_dir}/postgres"
  $ml_cache        = "${data_dir}/ml-model-cache"
  $redis_location  = "${data_dir}/redis"

  # Dedicated system account the containers run as
  group { $group:
    ensure => present,
    gid    => $gid,
    system => true,
  }

  user { $user:
    ensure     => present,
    uid        => $uid,
    gid        => $gid,
    system     => true,
    home       => $base_dir,
    managehome => false,
    shell      => '/usr/sbin/nologin',
    comment    => 'Immich service account',
    require    => Group[$group],
  }

  # Install directory: root-owned so the service account can't rewrite the compose file
  file { $install_dir:
    ensure  => directory,
    owner   => 'root',
    group   => $group,
    mode    => '0750',
    require => Group[$group],
  }

  $selinux_enabled = $manage_selinux and $facts['os']['selinux']['enabled']
  $dir_seltype     = $selinux_enabled ? { true => $selinux_type, default => undef }

  # seltype applies the label; this rule is what keeps it. Without something more specific
  # than the /home/<name> default, a restorecon -R /home or a full filesystem relabel puts
  # user_home_t back. One recursive pattern covers the whole tree.
  if $selinux_enabled {
    selinux::fcontext { "${data_dir}(/.*)?":
      seltype => $selinux_type,
      before  => File[$data_dir],
    }
  }

  # External libraries are the user's own files, so only relabel them, read-only, and leave
  # ownership and modes alone. restorecon only runs when the rule is first added; new files
  # inherit the label from their directory.
  if $selinux_enabled {
    $external_libraries.each |$library| {
      selinux::fcontext { "${library}(/.*)?":
        seltype => 'container_ro_file_t',
      }
      ~> selinux::exec_restorecon { $library:
        before => File[$compose_file],
      }
    }
  }

  file { $base_dir:
    ensure => directory,
  }

  # Storage root and the bind-mounted volumes, all writable by the container uid. Puppet
  # autorequires parent directories, so $data_dir is created before the rest.
  $data_dirs = [$data_dir, $upload_location, $ml_cache, $redis_location]

  file { $data_dirs:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0750',
    seltype => $dir_seltype,
    require => User[$user],
  }

  # Postgres insists its data directory is 0700 and owned by the running uid
  file { $db_location:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0700',
    seltype => $dir_seltype,
    require => File[$data_dir],
  }

  # Compose file contains the DB password, so keep it private and hide it from reports
  $compose_file = "${install_dir}/compose.yml"

  file { $compose_file:
    ensure  => file,
    owner   => 'root',
    group   => $group,
    mode    => '0640',
    content => Sensitive(epp('immich/compose.yml.epp', {
      'version'            => $version,
      'timezone'           => $timezone,
      'db_password'        => $db_password.unwrap,
      'port'               => $port,
      'upload_location'    => $upload_location,
      'external_libraries' => $external_libraries,
      'db_location'        => $db_location,
      'ml_cache'           => $ml_cache,
      'redis_location'     => $redis_location,
      'uid'                => $uid,
      'gid'                => $gid,
      'cpu_limit'          => $cpu_limit,
      'memory_limit'       => $memory_limit,
    })),
    require => File[$install_dir],
  }

  # systemd owns the stack so it comes back after a reboot. podman is daemonless and
  # podman-compose writes no units, so without this nothing restarts on boot.
  file { "/etc/systemd/system/${service_name}.service":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('immich/immich.service.epp', {
      'compose_command'    => $compose_command,
      'compose_file'       => $compose_file,
      'install_dir'        => $install_dir,
      'data_dir'           => $data_dir,
      'external_libraries' => $external_libraries,
    }),
    notify  => Exec["${service_name}-daemon-reload"],
  }

  exec { "${service_name}-daemon-reload":
    command     => 'systemctl daemon-reload',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  if $manage_service {
    # Restarting on a compose-file change runs ExecStop then ExecStart, i.e. down then up
    service { $service_name:
      ensure    => running,
      enable    => true,
      subscribe => [
        File[$compose_file],
        File["/etc/systemd/system/${service_name}.service"],
      ],
      require   => [
        Exec["${service_name}-daemon-reload"],
        File[$data_dirs],
        File[$db_location],
      ],
    }
  }
}
