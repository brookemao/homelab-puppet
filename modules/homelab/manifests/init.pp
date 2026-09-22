# @summary Homelab baseline configuration for RHEL 10
#
# Sets up the EPEL repository, git, fastfetch, firewalld, fail2ban, podman, ddclient, and Immich
#
# @param manage_services Whether to manage and start background services
# @param ddclient_install_method 'tarball' (from GitHub release tarball) or 'package' (via dnf)
# @param ddclient_release_tag 'latest' (tracks newest tag past 4.0.0) or specific tag like 'v4.0.0'
# @param cloudflare_token API token for Cloudflare DDNS
# @param cloudflare_zone Root zone for Cloudflare DDNS
# @param cloudflare_domains Comma-separated domains to update
# @param ddclient_replace_config Whether to overwrite ddclient.conf if it exists
class homelab (
  Boolean   $manage_services         = true,
  String[1] $ddclient_install_method = 'tarball',
  String[1] $ddclient_release_tag    = 'latest',
  String[1] $cloudflare_token        = '<SECRET TOKEN HERE>',
  String[1] $cloudflare_zone         = 'brookemao.ca',
  String[1] $cloudflare_domains      = 'homelab.brookemao.ca,mindustry.brookemao.ca',
  Boolean   $ddclient_replace_config = false,
) {
  # 1. Enable CRB & Install EPEL 10 repository
  class { 'homelab::epel': }

  # 2. Install git package
  class { 'homelab::git': }

  # 3. Install fastfetch from EPEL
  class { 'homelab::fastfetch':
    require => Class['homelab::epel'],
  }

  # 4. Manage firewalld and open HTTPS (443/tcp) in the public zone
  class { 'homelab::firewall': }

  # 5. Install and configure fail2ban with firewalld integration
  class { 'homelab::fail2ban':
    manage_service => $manage_services,
    require        => [Class['homelab::epel'], Class['homelab::firewall']],
  }

  # 6. Install podman and podman-compose (compose from EPEL)
  class { 'homelab::podman':
    require => Class['homelab::epel'],
  }

  # 7. Install and configure ddclient from GitHub release tarball or package
  class { 'homelab::ddclient':
    install_method     => $ddclient_install_method,
    release_tag        => $ddclient_release_tag,
    manage_service     => $manage_services,
    cloudflare_token   => $cloudflare_token,
    cloudflare_zone    => $cloudflare_zone,
    cloudflare_domains => $cloudflare_domains,
    replace_config     => $ddclient_replace_config,
    require            => Class['homelab::epel'],
  }

  # 8. Deploy Immich. Everything else uses the class defaults; override with immich::* Hiera keys.
  class { 'immich':
    manage_service => $manage_services,
  }
  Class['homelab::podman'] -> Class['immich']
}
