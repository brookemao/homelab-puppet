# @summary Installs and configures Cockpit for nginx mTLS reverse proxy
#
# Makes Cockpit proxy-aware (Origins + ProtocolHeader per upstream wiki) and
# labels TCP 9090 as http_port_t so nginx (httpd_t) can connect under SELinux
# enforcing without enabling the httpd_can_network_connect boolean.
#
# mTLS itself terminates at nginx (homelab::nginx); Cockpit never sees the
# client certificate, so ClientCertAuthentication stays off and Cockpit login
# remains password-based.
#
# @param server_name Public hostname nginx serves Cockpit on
# @param package_ensure Ensure state for the cockpit package
# @param manage_service Whether to enable and start cockpit.socket
# @param port Local TCP port Cockpit listens on
class homelab::cockpit (
  String[1] $server_name    = 'cockpit.brookemao.ca',
  String[1] $package_ensure = 'installed',
  Boolean   $manage_service = true,
  Integer   $port           = 9090,
) {
  package { 'cockpit':
    ensure => $package_ensure,
  }

  # Provides `semanage` for the SELinux port labeling below.
  package { 'policycoreutils-python-utils':
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

  # Least-privilege SELinux access for nginx to reach Cockpit.
  # Do NOT use `setsebool -P httpd_can_network_connect on`; label only 9090.
  # The `-a || -m` fallback handles re-runs where the port is already defined.
  exec { 'selinux-cockpit-http-port':
    command => "semanage port -a -t http_port_t -p tcp ${port} || semanage port -m -t http_port_t -p tcp ${port}",
    unless  => "semanage port -l | grep -E '^http_port_t.*\\b${port}\\b'",
    path    => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    require => Package['policycoreutils-python-utils'],
  }

  if $manage_service {
    service { 'cockpit.socket':
      ensure    => running,
      enable    => true,
      require   => Package['cockpit'],
      subscribe => File['/etc/cockpit/cockpit.conf'],
    }
  }
}
