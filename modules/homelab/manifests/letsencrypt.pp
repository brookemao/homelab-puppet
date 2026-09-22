# @summary Obtains a wildcard Let's Encrypt certificate via Cloudflare DNS-01
#
# Installs certbot (via puppet-letsencrypt) with the Cloudflare DNS plugin and
# requests a certificate covering the zone apex and wildcard (e.g.
# `brookemao.ca` and `*.brookemao.ca`). DNS-01 needs no inbound HTTP, so no
# firewall changes are required. Renewal is handled by the certbot-renew
# systemd timer (twice daily); nginx is reloaded after each renewal via a
# deploy hook.
#
# @param cloudflare_token Cloudflare API token (DNS:Edit on the zone)
# @param cloudflare_zone DNS zone for the certificate (cert covers apex + wildcard)
# @param email Contact email for Let's Encrypt registration (defaults to admin@<zone>)
# @param propagation_seconds Seconds to wait for DNS propagation before asking Let's Encrypt to verify
# @param manage_service Whether to enable and start the certbot-renew timer
class homelab::letsencrypt (
  String[1]            $cloudflare_token,
  String[1]            $cloudflare_zone      = 'brookemao.ca',
  Optional[String[1]]  $email                = undef,
  Integer              $propagation_seconds  = 30,
  Boolean              $manage_service       = true,
) {
  require homelab::epel

  $acme_email = $email ? {
    undef   => "admin@${cloudflare_zone}",
    default => $email,
  }

  $cert_domains = [$cloudflare_zone, "*.${cloudflare_zone}"]

  class { 'letsencrypt':
    email          => $acme_email,
    configure_epel => false,
    require        => Class['homelab::epel'],
  }

  class { 'letsencrypt::plugin::dns_cloudflare':
    api_token           => $cloudflare_token,
    propagation_seconds => $propagation_seconds,
    require             => Class['homelab::epel'],
  }

  letsencrypt::certonly { $cloudflare_zone:
    domains              => $cert_domains,
    plugin               => 'dns-cloudflare',
    manage_cron          => false,
    deploy_hook_commands => ['/usr/bin/systemctl reload nginx'],
    require              => Class['letsencrypt::plugin::dns_cloudflare'],
  }

  # Twice-daily renewal check. A unit of the same name in /etc overrides the
  # one shipped by the distro certbot package, so exactly one effective timer
  # exists whether or not the package provides its own.
  file { '/etc/systemd/system/certbot-renew.service':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    source  => 'puppet:///modules/homelab/certbot-renew.service',
    notify  => Exec['systemd-daemon-reload-certbot'],
  }

  file { '/etc/systemd/system/certbot-renew.timer':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    source  => 'puppet:///modules/homelab/certbot-renew.timer',
    notify  => Exec['systemd-daemon-reload-certbot'],
  }

  exec { 'systemd-daemon-reload-certbot':
    command     => '/usr/bin/systemctl daemon-reload',
    path        => ['/usr/bin', '/usr/sbin', '/bin', '/sbin'],
    refreshonly => true,
  }

  if $manage_service {
    service { 'certbot-renew.timer':
      ensure    => running,
      enable    => true,
      require   => [
        File['/etc/systemd/system/certbot-renew.service'],
        File['/etc/systemd/system/certbot-renew.timer'],
        Exec['systemd-daemon-reload-certbot'],
      ],
      subscribe => [
        File['/etc/systemd/system/certbot-renew.service'],
        File['/etc/systemd/system/certbot-renew.timer'],
      ],
    }
  }
}
