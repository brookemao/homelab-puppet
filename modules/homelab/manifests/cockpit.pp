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
# @param package_ensure Ensure state for the cockpit package
# @param manage_service Whether to enable and start cockpit.socket
# @param port Local TCP port Cockpit listens on
# @param selinux_module_name Name of the custom SELinux allow module
# @param selinux_policy_dir Directory holding the .te source and built module
class homelab::cockpit (
  String[1] $server_name         = 'cockpit.brookemao.ca',
  String[1] $package_ensure      = 'installed',
  Boolean   $manage_service      = true,
  Integer   $port                = 9090,
  String[1] $selinux_module_name = 'nginx_cockpit',
  String[1] $selinux_policy_dir  = '/usr/local/share/selinux',
) {
  package { 'cockpit':
    ensure => $package_ensure,
  }

  # Provides `semanage`/`semodule`/`semodule_package` for the SELinux work below.
  package { 'policycoreutils-python-utils':
    ensure => installed,
  }

  package { 'policycoreutils':
    ensure => installed,
  }

  # Provides `checkmodule` to compile the .te policy source.
  package { 'checkpolicy':
    ensure => installed,
  }

  file { '/etc/cockpit/cockpit.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('homelab/cockpit.conf.epp', { 'server_name' => $server_name }),
    require => Package['cockpit'],
  }

  # TCP 9090 ships in RHEL policy as websm_port_t (Cockpit's historical type
  # name; there is no cockpit_port_t — `semanage port -l | grep 9090`
  # confirms). A mislabeled port makes cockpit.socket fail to bind with
  # "Input/output error", so the service below orders after this exec.
  # The exec drops any stale local customization; if policy ever stops
  # shipping the label, it (re)adds it. Already-correct state is a no-op.
  exec { 'selinux-cockpit-port':
    command   => "semanage port -d -p tcp ${port} || true; if ! semanage port -l | grep -qE '^websm_port_t.*\\b${port}\\b'; then semanage port -a -t websm_port_t -p tcp ${port} || semanage port -m -t websm_port_t -p tcp ${port}; fi",
    unless    => "semanage port -l | grep -E '^websm_port_t.*\\b${port}\\b'",
    logoutput => on_failure,
    path      => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    require   => [Package['cockpit'], Package['policycoreutils-python-utils']],
  }

  # Least-privilege nginx -> Cockpit access: allow httpd_t name_connect to
  # websm_port_t. Compiled and installed from the vendored .te source;
  # bump the policy_module version in that file when the rule changes.
  file { $selinux_policy_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { "${selinux_policy_dir}/${selinux_module_name}.te":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    source  => "puppet:///modules/homelab/${selinux_module_name}.te",
    require => [Package['cockpit'], File[$selinux_policy_dir]],
  }

  exec { "install-${selinux_module_name}-selinux-module":
    command     => "checkmodule -M -m -o ${selinux_policy_dir}/${selinux_module_name}.mod ${selinux_policy_dir}/${selinux_module_name}.te && semodule_package -o ${selinux_policy_dir}/${selinux_module_name}.pp -m ${selinux_policy_dir}/${selinux_module_name}.mod && semodule -i ${selinux_policy_dir}/${selinux_module_name}.pp",
    subscribe   => File["${selinux_policy_dir}/${selinux_module_name}.te"],
    refreshonly => true,
    path        => ['/usr/bin', '/usr/sbin', '/bin', '/sbin'],
    require     => [
      Package['checkpolicy'],
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
