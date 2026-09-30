# @summary Installs and configures Cockpit for nginx mTLS reverse proxy
#
# Makes Cockpit proxy-aware (Origins + ProtocolHeader per upstream wiki),
# keeps TCP 9090 on its policy-shipped websm_port_t label, and installs a
# minimal SELinux allow module so nginx (httpd_t) can reverse-proxy to
# Cockpit without the broad httpd_can_network_connect boolean (and without
# mislabeling 9090 as http_port_t, which Cockpit's policy does not expect).
#
# mTLS itself terminates at nginx (homelab::nginx); Cockpit never sees the
# client certificate, so ClientCertAuthentication stays off and Cockpit login
# remains password-based.
#
# @param server_name Public hostname nginx serves Cockpit on
# @param origins Explicit Origins list for cockpit.conf. When undef (default),
#   built from server_name plus hardcoded LAN IP and localhost names.
# @param extra_origins Additional origins appended to the auto-built list
# @param include_local_origins Whether to append hardcoded local origins
# @param lan_ip Static LAN IP homelab always gets (DHCP reservation)
# @param package_ensure Ensure state for the cockpit package
# @param manage_service Whether to enable and start cockpit.socket
# @param port Local TCP port Cockpit listens on
# @param selinux_module_name Name of the custom SELinux allow module
# @param selinux_policy_dir Directory holding the .te source and built module
class homelab::cockpit (
  String[1] $server_name                = 'cockpit.brookemao.ca',
  Optional[Array[String[1]]] $origins   = undef,
  Array[String[1]] $extra_origins       = [],
  Boolean $include_local_origins        = true,
  String[1] $lan_ip                     = '192.168.50.176',
  String[1] $package_ensure             = 'installed',
  Boolean   $manage_service             = true,
  Integer   $port                       = 9090,
  String[1] $selinux_module_name        = 'nginx_cockpit',
  String[1] $selinux_policy_dir         = '/usr/local/share/selinux',
) {
  # Proxy origins never carry a port (nginx terminates 443).
  $proxy_origins = ["https://${server_name}", "wss://${server_name}"]

  # Direct-access origins carry :port. Static LAN IP via DHCP reservation.
  if $include_local_origins {
    $direct_hosts = unique([$lan_ip, 'localhost', '127.0.0.1', 'homelab'])
    $direct_origins = unique(flatten($direct_hosts.map |$h| {
      ["https://${h}:${port}", "wss://${h}:${port}"]
    }))
    $default_origins = unique(flatten([$proxy_origins, $direct_origins, $extra_origins]))
  } else {
    $default_origins = unique(flatten([$proxy_origins, $extra_origins]))
  }

  $effective_origins = $origins ? {
    undef   => $default_origins,
    default => $origins,
  }
  package { 'cockpit':
    ensure => $package_ensure,
  }

  # Provides `semanage`/`semodule` for the SELinux work below.
  package { 'policycoreutils-python-utils':
    ensure => installed,
  }

  package { 'policycoreutils':
    ensure => installed,
  }

  file { '/etc/cockpit/cockpit.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('homelab/cockpit.conf.epp', { 'origins' => $effective_origins }),
    require => Package['cockpit'],
  }

  # TCP 9090 ships in RHEL policy as websm_port_t (Cockpit's historical type
  # name; there is no cockpit_port_t — `semanage port -l | grep 9090`
  # confirms). A mislabeled port (notably http_port_t) makes cockpit.socket
  # fail to bind with "Permission denied" / "Input/output error" and a
  # cockpit_ws_t -> http_port_t name_bind AVC, so the service below orders
  # after this exec.
  # Cleanup removes a stale http_port_t mislabel and drops the duplicate
  # local websm_port_t entry, leaving the policy default. It only re-adds
  # websm_port_t if policy ever stops shipping it. Already-correct state
  # (websm has the port, no local override, no http mislabel) is a no-op.
  # NOTE: `semanage port -d` requires -t; bare `-d -p tcp <port>` fails with
  # "defined in policy, cannot be deleted" and never cleans anything.
  exec { 'selinux-cockpit-port':
    command   => "semanage port -d -t http_port_t -p tcp ${port} || true; semanage port -d -t websm_port_t -p tcp ${port} || true; if ! semanage port -l | grep -qE '^websm_port_t.*\\b${port}\\b'; then semanage port -a -t websm_port_t -p tcp ${port}; fi",
    unless    => "semanage port -l | grep -qE '^websm_port_t.*\\b${port}\\b' && ! semanage port -l -C | grep -qw '${port}' && ! semanage port -l | grep -qE '^http_port_t.*\\b${port}\\b'",
    logoutput => on_failure,
    path      => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    require   => [Package['cockpit'], Package['policycoreutils-python-utils']],
  }

  # Least-privilege nginx -> Cockpit access: allow httpd_t name_connect to
  # websm_port_t. Installed directly from vendored CIL source, which needs
  # no compiler toolchain (semodule consumes .cil natively); reapplied
  # whenever the source changes.
  file { $selinux_policy_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { "${selinux_policy_dir}/${selinux_module_name}.cil":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    source  => "puppet:///modules/homelab/${selinux_module_name}.cil",
    require => [Package['cockpit'], File[$selinux_policy_dir]],
  }

  exec { "install-${selinux_module_name}-selinux-module":
    command     => "semodule -i ${selinux_policy_dir}/${selinux_module_name}.cil",
    subscribe   => File["${selinux_policy_dir}/${selinux_module_name}.cil"],
    refreshonly => true,
    logoutput   => on_failure,
    path        => ['/usr/bin', '/usr/sbin', '/bin', '/sbin'],
    require     => [
      Package['policycoreutils'],
      Package['policycoreutils-python-utils'],
    ],
  }

  if $manage_service {
    service { 'cockpit.socket':
      ensure    => running,
      enable    => true,
      require   => [Package['cockpit'], Exec['selinux-cockpit-port']],
      subscribe => File['/etc/cockpit/cockpit.conf'],
    }
  }
}
