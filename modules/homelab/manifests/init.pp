# @summary Homelab baseline configuration for Fedora 44
#
# Sets up git, fastfetch, firewalld, fail2ban, podman, ddclient, TLS,
# Cockpit, nginx, and Immich from native Fedora repositories
#
# @param manage_services Whether to manage and start background services (fail2ban,
#   ddclient, certificate renewal, nginx, and the immich systemd unit)
# @param ddclient_install_method 'tarball' (from GitHub release tarball) or 'package' (via dnf)
# @param ddclient_release_tag 'latest' (tracks newest tag past 4.0.0) or specific tag like 'v4.0.0'
# @param cloudflare_token API token for Cloudflare DDNS
# @param cloudflare_zone Root zone for Cloudflare DDNS
# @param cloudflare_domains Comma-separated domains to update
# @param ddclient_replace_config Whether to overwrite ddclient.conf if it exists
# @param acme_email Contact email for Let's Encrypt registration (defaults to admin@<cloudflare_zone>)
class homelab (
  Boolean   $manage_services         = true,
  String[1] $ddclient_install_method = 'tarball',
  String[1] $ddclient_release_tag    = 'latest',
  String[1] $cloudflare_token        = '<SECRET TOKEN HERE>',
  String[1] $cloudflare_zone         = 'brookemao.ca',
  String[1] $cloudflare_domains      = 'homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca',
  Boolean   $ddclient_replace_config = false,
  Optional[String[1]] $acme_email    = undef,
) {
  # 1. Install git package
  class { 'homelab::git': }

  # 2. Install fastfetch from native Fedora repos
  class { 'homelab::fastfetch': }

  # 3. Manage firewalld and open HTTPS (443/tcp); pins the default zone so the
  # rule lands on the active zone on Fedora (FedoraServer/FedoraWorkstation)
  class { 'homelab::firewall': }

  # 4. Install and configure fail2ban with firewalld integration
  class { 'homelab::fail2ban':
    manage_service => $manage_services,
    require        => Class['homelab::firewall'],
  }

  # 5. Install podman and podman-compose (both native on Fedora)
  class { 'homelab::podman': }

  # 6. Install and configure ddclient from GitHub release tarball or package
  class { 'homelab::ddclient':
    install_method     => $ddclient_install_method,
    release_tag        => $ddclient_release_tag,
    manage_service     => $manage_services,
    cloudflare_token   => $cloudflare_token,
    cloudflare_zone    => $cloudflare_zone,
    cloudflare_domains => $cloudflare_domains,
    replace_config     => $ddclient_replace_config,
  }

  # 7. Install and configure Cockpit (proxy-aware cockpit.conf, websm_port_t on 9090, nginx allow module)
  class { 'homelab::cockpit':
    manage_service => $manage_services,
  }

  # 8. Obtain wildcard Let's Encrypt certificate via Cloudflare DNS-01 (after ddclient)
  class { 'homelab::letsencrypt':
    cloudflare_token => $cloudflare_token,
    cloudflare_zone  => $cloudflare_zone,
    email            => $acme_email,
    manage_service   => $manage_services,
    require          => Class['homelab::ddclient'],
  }

  # 9. Install nginx as a TLS-terminating reverse proxy (needs the certificate and Cockpit first)
  class { 'homelab::nginx':
    cert_name      => $cloudflare_zone,
    manage_service => $manage_services,
    require        => [Class['homelab::cockpit'], Class['homelab::ddclient'], Class['homelab::letsencrypt']],
  }

  # 10. Mount the parkpack drive Immich reads as an external library
  class { 'homelab::parkpack': }

  # 11. Deploy Immich. Everything else uses the class defaults; override with immich::* Hiera keys.
  class { 'immich':
    manage_service => $manage_services,
  }
  Class['homelab::podman'] -> Class['immich']
  Class['homelab::parkpack'] -> Class['immich']

  # firewalld --reload (triggered by any permanent firewall change) flushes
  # podman netavark/aardvark-dns runtime rules, breaking Immich
  # inter-container DNS (EAI_AGAIN database, ML unhealthy) until the stack
  # restarts. Refresh immich whenever firewall resources change. See
  # docs/firewalld-podman-immich.md. fail2ban runtime bans don't reload,
  # so they are unaffected.
  Class['homelab::firewall'] ~> Class['immich']
}
