# @summary Homelab baseline configuration for Fedora 44
#
# Sets up git, fastfetch, firewalld, fail2ban, podman, ddclient, TLS,
# Cockpit, nginx, Immich, SearXNG, and a Cloudflare Tunnel to Immich, from native Fedora
# repositories (cloudflared from Cloudflare's)
#
# @param manage_services Whether to manage and start background services (fail2ban,
#   ddclient, certificate renewal, nginx, the immich systemd unit, and cloudflared)
# @param ddclient_install_method 'package' (via dnf, default) or 'tarball' (from GitHub release tarball)
# @param ddclient_release_tag 'latest' (tracks newest tag past 4.0.0) or specific tag like 'v4.0.0' (tarball installs only)
# @param cloudflare_token API token for Cloudflare DDNS
# @param cloudflare_zone Root zone for Cloudflare DDNS
# @param cloudflare_domains Comma-separated domains to update
# @param ddclient_replace_config Whether to overwrite ddclient.conf if it exists
# @param acme_email Contact email for Let's Encrypt registration (defaults to admin@<cloudflare_zone>)
class homelab (
  Boolean   $manage_services         = true,
  String[1] $ddclient_install_method = 'package',
  String[1] $ddclient_release_tag    = 'latest',
  String[1] $cloudflare_token        = '<SECRET TOKEN HERE>',
  String[1] $cloudflare_zone         = 'brookemao.ca',
  String[1] $cloudflare_domains      = 'homelab.brookemao.ca,mindustry.brookemao.ca,photos.brookemao.ca,cockpit.brookemao.ca,llama.brookemao.ca,websearch.brookemao.ca',
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

  # 5. Install podman and podman-compose (both native on Fedora) with custom
  # storage (overlay driver, graphroot under /home/containers)
  class { 'homelab::podman': }

  # 6. Install and configure ddclient from the native DNF package or a GitHub release tarball
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
  # The websearch/llama vhosts share secrets with the searxng and llama
  # modules (searxng::auth_token for bearer, llama::basic_auth_password for
  # the htpasswd file). Those keys live in other modules' namespaces, so
  # homelab::nginx cannot pick them up by automatic parameter lookup;
  # resolve them explicitly here. Module-level lookup_options convert both
  # to Sensitive.
  $searxng_auth_token = lookup('searxng::auth_token', Sensitive[String[1]], 'first')
  $llama_basic_password = lookup('llama::basic_auth_password', Sensitive[String[1]], 'first')
  class { 'homelab::nginx':
    cert_name             => $cloudflare_zone,
    manage_service        => $manage_services,
    websearch_auth_token  => $searxng_auth_token,
    llama_basic_password  => $llama_basic_password,
    require               => [Class['homelab::cockpit'], Class['homelab::ddclient'], Class['homelab::letsencrypt']],
  }

  # The llama/websearch fail2ban jails tail the vhosts' dedicated access logs,
  # which only exist once nginx has started. Without this a fresh host's first
  # apply starts fail2ban before the logs exist and those jails fail to load.
  Class['homelab::nginx'] -> Class['homelab::fail2ban']

  # 10. Mount the parkpack drive Immich reads as an external library
  class { 'homelab::parkpack': }

  # 11. Deploy Immich. Everything else uses the class defaults; override with immich::* Hiera keys.
  class { 'immich':
    manage_service => $manage_services,
  }
  Class['homelab::podman'] -> Class['immich']
  Class['homelab::parkpack'] -> Class['immich']

  # 12. Deploy SearXNG + mcp-searxng. The MCP endpoint listens on loopback port
  # 8081; SearXNG itself stays on the container network. Override with
  # searxng::* Hiera keys (the secret comes from searxng::secret_key).
  class { 'searxng':
    manage_service => $manage_services,
  }
  Class['homelab::podman'] -> Class['searxng']

  # 13. Run llama.cpp llama-server with SearXNG MCP web search. Needs the
  # prebuilt localhost/llama-rocm (or llama-vulkan) image, GPU devices and a
  # model file (see homelab-llama). Search reaches the MCP server over HTTPS at
  # websearch.brookemao.ca (pre-registered in --ui-config-file), so the
  # container has no dependency on the searxng stack. The Bearer token is the
  # same searxng::auth_token secret the websearch vhost checks.
  # Override with llama::* Hiera keys.
  class { 'llama':
    manage_service       => $manage_services,
    searxng_bearer_token => $searxng_auth_token,
  }
  Class['homelab::podman'] -> Class['llama']

  # firewalld --reload (triggered by any permanent firewall change) flushes
  # podman netavark/aardvark-dns runtime rules, breaking inter-container DNS
  # (Immich: EAI_AGAIN database, ML unhealthy; SearXNG: mcp-searxng cannot
  # resolve searxng) and published-port forwarding until the stacks restart.
  # Refresh all of them whenever firewall resources change.
  # See docs/firewalld-podman-immich.md. fail2ban runtime bans don't reload,
  # so they are unaffected.
  Class['homelab::firewall'] ~> Class['immich']
  Class['homelab::firewall'] ~> Class['searxng']
  Class['homelab::firewall'] ~> Class['llama']

  # 14. Publish Immich through a Cloudflare Tunnel. The token comes from the
  # homelab::cloudflared::tunnel_token Hiera key.
  class { 'homelab::cloudflared':
    manage_service => $manage_services,
  }
}
