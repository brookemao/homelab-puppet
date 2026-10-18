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
#   Postgres is only published (on loopback) when db_readonly_password is set, and the
#   postgres superuser can then log in over that port with this password, so override it.
#   Postgres only reads this at initdb time, so changing it after the first boot will
#   NOT re-key an existing database - the server container will then fail to authenticate.
# @param db_readonly_password Password for a read-only Postgres role ($db_readonly_user).
#   When set, Postgres is published on 127.0.0.1:$db_port and the role is created, or its
#   password and grants updated, whenever the SQL changes or the role is missing. undef
#   leaves Postgres unpublished and drops any role an earlier apply created. Override via
#   immich::db_readonly_password.
# @param db_readonly_user Name of the read-only role. Renaming it drops the old role.
# @param db_port Host loopback port Postgres is published on when the read-only role is enabled
# @param base_dir Directory the whole deployment lives under; created if missing. 
# Its own parent must already exist (/home by default). Persistent data goes
#   in $base_dir/data, and the SELinux rule is recursive over that - so anything placed
#   beside it stays unreachable by the containers.
# @param external_libraries Host directories bind-mounted read-only into the server
#   container at the same path, for use as Immich external libraries (add each path under
#   Administration > External Libraries). They must already be readable by the immich
#   uid under a container-readable SELinux label (see homelab::parkpack).
# @param cpu_limit Cores the whole stack may use. Applied to the pod podman-compose puts
#   the containers in, so it is a collective cap, not a per-container one.
# @param memory_limit Memory the whole stack may use, e.g. '8g'. Collective, as above.
# @param ml_acceleration 'rocm' runs machine learning on an AMD GPU (the -rocm image, with
#   /dev/kfd and /dev/dri passed through); 'cpu' uses the plain image. The ROCm image is
#   several GB larger, so the first start after switching takes a while to pull.
# @param manage_selinux Whether to label the data directories for container access
# @param selinux_type SELinux type the containers need on their bind mounts
# @param compose_command Absolute path to the compose implementation (systemd ExecStart needs a full path)
# @param manage_service Whether to enable and start the immich systemd unit
# @param service_name Name of the systemd unit that owns the stack
#
class immich (
  Sensitive[String[1]] $db_password     = Sensitive('immich'),
  Optional[Sensitive[String[1]]] $db_readonly_password = undef,
  Pattern[/\A(?!pg_|postgres\z|public\z|none\z)[a-z_][a-z0-9_]{0,62}\z/] $db_readonly_user = 'immich_ro',
  Integer[1, 65535]    $db_port         = 5432,
  String[1]            $version         = 'v3.2.2',
  String[1]            $timezone        = 'America/Los_Angeles',
  Integer[1, 65535]    $port            = 2283,
  Immich::Absolutepath $install_dir     = '/opt/immich-app',
  Immich::Absolutepath $base_dir        = '/home/immich',
  Array[Immich::Absolutepath] $external_libraries = [],
  String[1]            $user            = 'immich',
  String[1]            $group           = 'immich',
  Numeric              $cpu_limit       = 8,
  Pattern[/\A\d+(\.\d+)?([bkmgBKMG]|[kKmMgG][bB])?\z/] $memory_limit = '12g',
  Enum['cpu', 'rocm']  $ml_acceleration = 'rocm',
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

  # Postgres only gets a host port when there is a read-only role to use it with
  $readonly_enabled  = $db_readonly_password != undef

  # The postgres superuser can log in over that port too, so not with the well-known default
  if $readonly_enabled and $db_password.unwrap == 'immich' {
    fail(@("MSG"/L))
      immich: db_readonly_password publishes Postgres on 127.0.0.1:${db_port}, where the \
      postgres superuser can log in with db_password, so db_password must not be the 'immich' \
      default. Set immich::db_password; on an existing database also run \
      ALTER USER postgres PASSWORD '...' first, since Postgres only reads it at initdb.
      | MSG
  }
  $published_db_port = $readonly_enabled ? { true => $db_port, default => undef }

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
      'db_port'            => $published_db_port,
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
      'ml_acceleration'    => $ml_acceleration,
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

  if !$manage_service {
    # Nothing applies a compose-file change (e.g. the Postgres port appearing or going away)
    # until the stack is recreated, so say so in the run output rather than look finished
    exec { "${service_name}-restart-required":
      command     => "echo '${compose_file} changed; run systemctl restart ${service_name} to apply it'",
      path        => ['/usr/bin', '/bin'],
      refreshonly => true,
      logoutput   => true,
      loglevel    => 'warning',
      subscribe   => File[$compose_file],
    }
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

  $readonly_sql   = "${install_dir}/readonly-role.sql"
  $readonly_stamp = "${install_dir}/readonly-role.sql.applied"
  # Role comment that identifies roles this class created, for renames and removal
  $readonly_marker = 'puppet:immich::db_readonly_user'
  $psql            = 'podman exec -i immich_postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d immich'
  $postgres_running = 'podman container inspect -f "{{.State.Running}}" immich_postgres 2>/dev/null | grep -qx true'

  # With manage_service the stack is started just before; otherwise nothing guarantees it is
  # up, so skip (and retry on a later apply) rather than wait out the retries
  $readonly_onlyif = $manage_service ? { true => undef, default => $postgres_running }
  $stack           = $manage_service ? { true => [Service[$service_name]], default => [] }

  if $readonly_enabled {
    # The SQL carries the password, so it stays root-only and out of reports
    file { $readonly_sql:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
      content => Sensitive(epp('immich/readonly-role.sql.epp', {
        'user'     => $db_readonly_user,
        'password' => $db_readonly_password.unwrap,
        'marker'   => $readonly_marker,
      })),
      require => File[$install_dir],
    }

    # Runs over the container's local socket (trust auth) as the postgres superuser. Not
    # refreshonly: it runs until the stamp matches the current SQL and the role exists, so a
    # failed first run, a rotated password or a wiped database all heal on the next apply.
    # The retries cover `podman-compose up -d` returning before Postgres accepts connections.
    exec { "${service_name}-readonly-role":
      command   => "${psql} < ${readonly_sql} && sha256sum ${readonly_sql} > ${readonly_stamp}",
      unless    => "sha256sum -c --status ${readonly_stamp} && ${psql} -tAc \"SELECT 1 FROM pg_roles WHERE rolname = '${db_readonly_user}'\" | grep -qx 1",
      onlyif    => $readonly_onlyif,
      provider  => 'shell',
      path      => ['/usr/bin', '/bin'],
      tries     => 30,
      try_sleep => 10,
      require   => [File[$readonly_sql]] + $stack,
    }
  } else {
    file { [$readonly_sql, $readonly_stamp]:
      ensure => absent,
    }

    # Drop any role an earlier apply created. Only when Postgres is running: on a later apply
    # otherwise, rather than failing every apply while the stack is down.
    $drop_roles = epp('immich/readonly-drop.sql.epp', { 'marker' => $readonly_marker })

    exec { "${service_name}-readonly-role-absent":
      command   => "${psql} <<'SQL'\n${drop_roles}SQL",
      unless    => "${psql} -tAc \"SELECT count(*) FROM pg_roles WHERE shobj_description(oid, 'pg_authid') = '${readonly_marker}'\" | grep -qx 0",
      onlyif    => $postgres_running,
      provider  => 'shell',
      path      => ['/usr/bin', '/bin'],
      tries     => 30,
      try_sleep => 10,
      require   => $stack,
    }
  }
}
