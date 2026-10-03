# @summary Runs a Cloudflare Tunnel connector (cloudflared) from Cloudflare's RPM repository
#
# theurw101-cloudflared is Debian-only (it hardcodes a .deb and the dpkg provider), so
# this installs from pkg.cloudflare.com instead and writes its own unit.
#
# The tunnel is remotely managed: it is created in the Cloudflare Zero Trust dashboard,
# which also holds its public hostnames and the Access application in front of them
# (see "Cloudflare Tunnel" in the README). This host only runs the connector, which
# needs nothing but the tunnel token.
#
# The token goes in an EnvironmentFile (TUNNEL_TOKEN) so it never appears on the command
# line or in the unit. Until it is set the package and unit are installed but the
# service is left stopped.
#
# @param tunnel_token Token for the dashboard-created tunnel. Set the
#   homelab::cloudflared::tunnel_token Hiera key in data/secrets.yaml.
# @param manage_service Whether to enable and start the cloudflared unit
# @param repo_baseurl Cloudflare's cloudflared RPM repository
# @param repo_gpgkey Signing key for that repository
class homelab::cloudflared (
  Optional[Sensitive[String[1]]] $tunnel_token   = undef,
  Boolean                        $manage_service = true,
  String[1]                      $repo_baseurl   = 'https://pkg.cloudflare.com/cloudflared/rpm',
  String[1]                      $repo_gpgkey    = 'https://pkg.cloudflare.com/cloudflare-ascii-pubkey.gpg',
) {
  yumrepo { 'cloudflared-stable':
    descr    => 'cloudflared-stable',
    baseurl  => $repo_baseurl,
    enabled  => '1',
    gpgcheck => '1',
    gpgkey   => $repo_gpgkey,
  }

  package { 'cloudflared':
    ensure  => installed,
    require => Yumrepo['cloudflared-stable'],
  }

  file { '/etc/cloudflared':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  # Read by systemd (as root) before it drops to the dynamic user, so root-only is enough
  if $tunnel_token {
    file { '/etc/cloudflared/tunnel.env':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
      content => Sensitive("TUNNEL_TOKEN=${tunnel_token.unwrap}\n"),
    }
  } else {
    warning('homelab::cloudflared::tunnel_token is not set; cloudflared is installed but the tunnel will not start')
  }

  file { '/etc/systemd/system/cloudflared.service':
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
    source => 'puppet:///modules/homelab/cloudflared.service',
    notify => Exec['cloudflared-daemon-reload'],
  }

  exec { 'cloudflared-daemon-reload':
    command     => 'systemctl daemon-reload',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  if $manage_service {
    $running = $tunnel_token =~ NotUndef

    service { 'cloudflared':
      ensure    => $running,
      enable    => $running,
      subscribe => [
        Package['cloudflared'],
        File['/etc/systemd/system/cloudflared.service'],
      ],
      require   => Exec['cloudflared-daemon-reload'],
    }

    if $tunnel_token {
      File['/etc/cloudflared/tunnel.env'] ~> Service['cloudflared']
    }
  }
}
