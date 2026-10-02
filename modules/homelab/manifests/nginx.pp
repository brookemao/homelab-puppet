# @summary Installs nginx with host-aware routing to backend web servers
#
# Requests for cockpit.brookemao.ca are forwarded to Cockpit on 9090 and
# require an mTLS client certificate signed by the personal PKI root.
# Requests for websearch.brookemao.ca are forwarded to the SearXNG MCP server
# on 8081 gated by a Bearer token, and llama.brookemao.ca to llama-server on
# 8080 gated by HTTP Basic auth. Requests for any other host fall through to
# the catch-all default server serving the stock nginx page. (The former
# photos/Immich forwarding was removed to keep Immich off the internet.)
#
# HTTPS-only server on $listen_port (443 by default). Per puppet-nginx,
# setting listen_port == ssl_port with ssl => true disables the plain-HTTP
# server and emits only the TLS server block.
#
# @param cockpit_server_names Host names forwarded to Cockpit (mTLS required)
# @param cockpit_backend_host Host running Cockpit
# @param cockpit_backend_port Port Cockpit listens on
# @param cockpit_client_ca_path Path to the client-verify CA bundle on the node
# @param cockpit_client_ca_source Puppet source for the CA bundle (copy from private brooke-pki checkout)
# @param cockpit_client_verify_depth Chain depth for client certificate verification
# @param listen_port HTTPS port for TLS termination
# @param ssl Whether to terminate TLS using the Let's Encrypt certificate
# @param cert_name Certificate lineage name under /etc/letsencrypt/live (defaults to the zone apex)
# @param default_www_root Document root for the catch-all default page
# @param manage_service Whether to manage and start the nginx service
# @param websearch_auth_token Bearer token gating the websearch (SearXNG MCP) vhost;
#   the same secret the searxng module injects into the MCP container
# @param websearch_bearer_map_path 0600 file holding the token-checking map (http context)
# @param websearch_bearer_check_path Location-level include rejecting missing bearers
# @param websearch_access_log Dedicated access log for the websearch vhost, so the
#   fail2ban websearch jail can count 401s without matching other vhosts' traffic
# @param llama_basic_user Basic-auth username for the llama vhost
# @param llama_basic_password SHA-512 crypt hash for the llama vhost (bootstrap
#   hashes the prompted password with `openssl passwd -6`; the plaintext never
#   reaches disk, only this hash)
# @param llama_access_log Dedicated access log for the llama vhost, so the
#   fail2ban llama jail can count Basic-auth 401s without matching other
#   vhosts' traffic
class homelab::nginx (
  Array[String[1]]     $cockpit_server_names        = ['cockpit.brookemao.ca'],
  String[1]            $cockpit_backend_host        = '127.0.0.1',
  Integer              $cockpit_backend_port        = 9090,
  String[1]            $cockpit_client_ca_path      = '/etc/nginx/brookemao-root-ca-1.pem',
  String[1]            $cockpit_client_ca_source    = 'puppet:///modules/homelab/brookemao-root-ca-1.pem',
  Integer              $cockpit_client_verify_depth = 1,
  Integer              $listen_port                 = 443,
  Boolean              $ssl                         = true,
  String[1]            $cert_name                   = 'brookemao.ca',
  String[1]            $default_www_root            = '/usr/share/nginx/html',
  Boolean              $manage_service              = true,
  Sensitive[String[1]] $websearch_auth_token,
  String[1]            $websearch_server_name       = 'websearch.brookemao.ca',
  Integer              $websearch_backend_port      = 8081,
  String[1]            $websearch_bearer_map_path   = '/etc/nginx/conf.d/websearch-bearer-map.conf',
  String[1]            $websearch_bearer_check_path = '/etc/nginx/websearch-bearer-check.conf',
  String[1]            $websearch_access_log        = '/var/log/nginx/websearch-access.log',
  String[1]            $llama_server_name           = 'llama.brookemao.ca',
  Integer              $llama_backend_port          = 8080,
  String[1]            $llama_basic_user            = 'agentforce',
  Sensitive[String[1]] $llama_basic_password,
  String[1]            $llama_htpasswd_path         = '/etc/nginx/llama.htpasswd',
  String[1]            $llama_access_log            = '/var/log/nginx/llama-access.log',
  String[1]            $llama_splash_message        = 'llama.cpp',
) {
  # MCP HTTP responses can be SSE streams; the stock 90s upstream timeout
  # would cut long searches short. 10 minutes keeps direct browser streams
  # alive through slow tool calls.
  class { 'nginx':
    service_manage     => $manage_service,
    proxy_read_timeout => '10m',
  }

  $ssl_cert = "/etc/letsencrypt/live/${cert_name}/fullchain.pem"
  $ssl_key  = "/etc/letsencrypt/live/${cert_name}/privkey.pem"

  # Client-verify CA for the Cockpit vhost. brooke-pki is private, so the
  # bundle cannot be fetched at apply time -- copy it into
  # modules/homelab/files/brookemao-root-ca-1.pem from
  # https://github.com/brookemao/brooke-pki/blob/main/certificates/brookemao-root-ca-1.pem
  file { $cockpit_client_ca_path:
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
    source => $cockpit_client_ca_source,
  }

  # Cockpit behind mTLS. Follows
  # https://garrett.github.io/cockpit-project.github.io/external/wiki/Proxying-Cockpit-over-NGINX
  # plus ssl_client_certificate / ssl_verify_client for client certs signed
  # by the personal PKI root. SELinux access to 9090 is granted by
  # homelab::cockpit (websm_port_t label + nginx_cockpit allow module,
  # no httpd_can_network_connect).
  # Cockpit serves its own self-signed cert on localhost, so upstream
  # verification is explicitly off (nginx default; stated for clarity).
  # puppet-nginx has no native proxy_ssl_verify param, hence location_cfg_append.
  nginx::resource::server { 'cockpit-reverse-proxy':
    ensure              => present,
    server_name         => $cockpit_server_names,
    listen_port         => $listen_port,
    ssl_port            => $listen_port,
    ssl                 => $ssl,
    ssl_cert            => $ssl_cert,
    ssl_key             => $ssl_key,
    ssl_client_cert     => $cockpit_client_ca_path,
    ssl_verify_client   => 'on',
    ssl_verify_depth    => $cockpit_client_verify_depth,
    proxy               => "https://${cockpit_backend_host}:${cockpit_backend_port}",
    proxy_http_version  => '1.1',
    proxy_buffering     => 'off',
    proxy_set_header    => [
      'Host $host',
      'X-Real-IP $remote_addr',
      'X-Forwarded-For $proxy_add_x_forwarded_for',
      'X-Forwarded-Proto $scheme',
      'Upgrade $http_upgrade',
      'Connection "upgrade"',
      'X-SSL-Client-Verify $ssl_client_verify',
      'X-SSL-Client-DN $ssl_client_s_dn',
    ],
    server_cfg_append   => {
      'gzip' => 'off',
    },
    location_cfg_append => {
      'proxy_ssl_verify' => 'off',
    },
    require             => File[$cockpit_client_ca_path],
    # NOTE: do NOT require Class['nginx'] here (see above -- it creates a
    # dependency cycle via the define's internal notify to nginx::service).
  }

  nginx::resource::server { 'homelab-default':
    ensure         => present,
    server_name    => ['_'],
    listen_port    => $listen_port,
    ssl_port       => $listen_port,
    listen_options => 'default_server',
    ssl            => $ssl,
    ssl_cert       => $ssl_cert,
    ssl_key        => $ssl_key,
    www_root       => $default_www_root,
    # NOTE: do NOT require Class['nginx'] here (see above -- it creates a
    # dependency cycle via the define's internal notify to nginx::service).
  }

  # ---- SearXNG MCP behind Bearer auth (websearch.brookemao.ca) ----
  # The generated vhost file is world-readable, so the token lives in a map in
  # conf.d (included by nginx.conf inside http {}), guarded at 0600 root:nginx
  # (the master reads config as root). The location only includes the token-free
  # check file: a map block cannot live inside a location. `if` checking a map
  # variable is safe per the nginx wiki (no rewrite module weirdness).
  # The map keys on method + credentials because CORS preflight (OPTIONS)
  # carries no Authorization header: it passes through to the MCP server,
  # whose cors middleware answers it. Origin/Access-Control-Request-* headers
  # ride proxy_pass untouched by default.
  file { $websearch_bearer_map_path:
    ensure  => file,
    owner   => 'root',
    group   => 'nginx',
    mode    => '0600',
    content => Sensitive(epp('homelab/websearch-bearer-map.conf.epp', {
      'bearer_token' => $websearch_auth_token,
    })),
    require => File["${nginx::conf_dir}/conf.d"],
    notify  => Class['nginx::service'],
  }

  file { $websearch_bearer_check_path:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('homelab/websearch-bearer-check.conf.epp', {}),
    require => File[$nginx::conf_dir],
    notify  => Class['nginx::service'],
  }

  nginx::resource::server { 'websearch-reverse-proxy':
    ensure              => present,
    server_name         => [$websearch_server_name],
    listen_port         => $listen_port,
    ssl_port            => $listen_port,
    ssl                 => $ssl,
    ssl_cert            => $ssl_cert,
    ssl_key             => $ssl_key,
    access_log          => $websearch_access_log,
    proxy               => "http://127.0.0.1:${websearch_backend_port}",
    proxy_http_version  => '1.1',
    proxy_buffering     => 'off',
    proxy_set_header    => [
      'Host $host',
      'X-Real-IP $remote_addr',
      'X-Forwarded-For $proxy_add_x_forwarded_for',
      'X-Forwarded-Proto $scheme',
      'Authorization $http_authorization',
    ],
    location_cfg_append => {
      'include' => $websearch_bearer_check_path,
    },
    require             => [
      File[$websearch_bearer_map_path],
      File[$websearch_bearer_check_path],
    ],
    # NOTE: the secret files above require only nginx's own directories, never
    # Class['nginx'] itself -- that would cycle via this define's internal
    # notify to nginx::service (same reason as the cockpit/default vhosts).
  }

  # ---- llama.cpp behind HTTP Basic auth (llama.brookemao.ca) ----
  # htpasswd hash only, never the plaintext. Mode 0600 root:nginx: the master
  # opens it as root before dropping privileges. A password change notifies
  # the service so the new file is picked up.
  file { $llama_htpasswd_path:
    ensure  => file,
    owner   => 'root',
    group   => 'nginx',
    mode    => '0600',
    content => Sensitive(epp('homelab/llama.htpasswd.epp', {
      'username' => $llama_basic_user,
      'password' => $llama_basic_password,
    })),
    require => File[$nginx::conf_dir],
    notify  => Class['nginx::service'],
  }

  nginx::resource::server { 'llama-reverse-proxy':
    ensure                 => present,
    server_name            => [$llama_server_name],
    listen_port            => $listen_port,
    ssl_port               => $listen_port,
    ssl                    => $ssl,
    ssl_cert               => $ssl_cert,
    ssl_key                => $ssl_key,
    access_log             => $llama_access_log,
    proxy                  => "http://127.0.0.1:${llama_backend_port}",
    proxy_http_version     => '1.1',
    proxy_buffering        => 'off',
    auth_basic             => $llama_splash_message,
    auth_basic_user_file   => $llama_htpasswd_path,
    # SSE chat streams idle between tokens; 10m keeps --api-key-less clients
    # alive through long thinking runs.
    proxy_read_timeout     => '10m',
    proxy_set_header       => [
      'Host $host',
      'X-Real-IP $remote_addr',
      'X-Forwarded-For $proxy_add_x_forwarded_for',
      'X-Forwarded-Proto $scheme',
      # auth_basic consumes the client Authorization header, so Basic
      # credentials never reach llama-server (which runs without --api-key).
      # The MCP Bearer travels a different path now: the browser sends it
      # straight to websearch.brookemao.ca, never through this vhost.
      'Authorization ""',
    ],
    require                => File[$llama_htpasswd_path],
  }
}
