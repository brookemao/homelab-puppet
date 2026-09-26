# @summary Installs nginx with host-aware routing to backend web servers
#
# Requests for cockpit.brookemao.ca are forwarded to Cockpit on 9090 and
# require an mTLS client certificate signed by the personal PKI root.
# Requests for any other host fall through to the catch-all default server
# serving the stock nginx page. (The former photos/Immich forwarding was
# removed to keep Immich off the internet.)
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
class homelab::nginx (
  Array[String[1]]  $cockpit_server_names        = ['cockpit.brookemao.ca'],
  String[1]         $cockpit_backend_host        = '127.0.0.1',
  Integer           $cockpit_backend_port        = 9090,
  String[1]         $cockpit_client_ca_path      = '/etc/nginx/brookemao-root-ca-1.pem',
  String[1]         $cockpit_client_ca_source    = 'puppet:///modules/homelab/brookemao-root-ca-1.pem',
  Integer           $cockpit_client_verify_depth = 1,
  Integer           $listen_port                 = 443,
  Boolean           $ssl                         = true,
  String[1]         $cert_name                   = 'brookemao.ca',
  String[1]         $default_www_root            = '/usr/share/nginx/html',
  Boolean           $manage_service              = true,
) {
  class { 'nginx':
    service_manage => $manage_service,
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
  # homelab::cockpit (cockpit_port_t label + nginx_cockpit allow module,
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
}
