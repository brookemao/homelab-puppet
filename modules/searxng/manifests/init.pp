# @summary Installs SearXNG + mcp-searxng via podman-compose, running as image defaults.
#
# The compose file and SearXNG settings live in $install_dir. Caches and Valkey
# persistence use named volumes, so there are no host data directories to own
# or label. Only the MCP server publishes a host port (loopback-only $port);
# SearXNG and Valkey are reachable solely inside the container network.
#
# Containers run as their image defaults (root), exactly like the upstream
# compose files: the SearXNG entrypoint repairs volume ownership itself when
# root, while a root-owned named-volume cache is not writable by a remapped
# user. The settings file carries the secret, so it is root-only (0600) and
# Sensitive-wrapped to keep it out of reports.
#
# Requires podman-compose (see homelab::podman).
#
# @param secret_key SearXNG server.secret_key. No default - provide it via the
#   searxng::secret_key Hiera key (bootstrap collects it into data/secrets.yaml).
# @param version SearXNG image tag.
# @param mcp_version mcp-searxng image tag.
# @param port Host port published for the MCP HTTP endpoint (loopback-only).
# @param install_dir Directory holding the generated compose.yml and settings.yml.
# @param compose_command Absolute path to the compose implementation (systemd ExecStart needs a full path)
# @param manage_service Whether to enable and start the searxng systemd unit
# @param service_name Name of the systemd unit that owns the stack
#
class searxng (
  Sensitive[String[1]]  $secret_key,
  String[1]             $version         = 'latest',
  String[1]             $mcp_version     = 'latest',
  Integer[1, 65535]     $port            = 8081,
  Searxng::Absolutepath $install_dir     = '/opt/searxng-app',
  Searxng::Absolutepath $compose_command = '/usr/bin/podman-compose',
  Boolean               $manage_service  = true,
  String[1]             $service_name    = 'searxng',
) {
  # Install directory: root-owned so only root can reach the secret-bearing settings file
  file { $install_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0750',
  }

  $compose_file  = "${install_dir}/compose.yml"
  $settings_file = "${install_dir}/settings.yml"

  file { $compose_file:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('searxng/compose.yml.epp', {
      'version'       => $version,
      'mcp_version'   => $mcp_version,
      'port'          => $port,
      'settings_file' => $settings_file,
    }),
    require => File[$install_dir],
  }

  # Settings file contains the secret, so keep it root-only and hide it from reports
  file { $settings_file:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    content => Sensitive(epp('searxng/settings.yml.epp', {
      'secret_key' => $secret_key.unwrap,
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
    content => epp('searxng/searxng.service.epp', {
      'compose_command' => $compose_command,
      'compose_file'    => $compose_file,
      'install_dir'     => $install_dir,
    }),
    notify  => Exec["${service_name}-daemon-reload"],
  }

  exec { "${service_name}-daemon-reload":
    command     => 'systemctl daemon-reload',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  if $manage_service {
    # Restarting on a compose/settings change runs ExecStop then ExecStart, i.e. down then up
    service { $service_name:
      ensure    => running,
      enable    => true,
      subscribe => [
        File[$compose_file],
        File[$settings_file],
        File["/etc/systemd/system/${service_name}.service"],
      ],
      require   => [
        Exec["${service_name}-daemon-reload"],
      ],
    }
  }
}
