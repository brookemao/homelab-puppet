# @summary Installs nginx with host-aware routing to backend web servers
#
# Only requests for the proxy host names (e.g. photos.brookemao.ca) are
# forwarded to the backend web server. Requests for any other host fall
# through to the catch-all default server serving the stock nginx page.
#
# TLS is terminated on 443 (ssl_port); the plain-HTTP block on listen_port
# redirects to HTTPS. This matches the puppet-nginx model where ssl => true
# emits a second server block on ssl_port.
#
# @param backend_host Host running the backend web server
# @param backend_port Port the backend web server listens on
# @param proxy_server_names Host names forwarded to the backend web server
# @param listen_port Plain-HTTP port (redirects to HTTPS; 443 serves TLS)
# @param ssl Whether to terminate TLS using the Let's Encrypt certificate
# @param cert_name Certificate lineage name under /etc/letsencrypt/live (defaults to the zone apex)
# @param default_www_root Document root for the catch-all default page
# @param manage_service Whether to manage and start the nginx service
class homelab::nginx (
  String[1]         $backend_host       = '127.0.0.1',
  Integer           $backend_port       = 2283,
  Array[String[1]]  $proxy_server_names = ['photos.brookemao.ca'],
  Integer           $listen_port        = 80,
  Boolean           $ssl                = true,
  String[1]         $cert_name          = 'brookemao.ca',
  String[1]         $default_www_root   = '/usr/share/nginx/html',
  Boolean           $manage_service     = true,
) {
  class { 'nginx':
    service_manage => $manage_service,
  }

  $ssl_cert = "/etc/letsencrypt/live/${cert_name}/fullchain.pem"
  $ssl_key  = "/etc/letsencrypt/live/${cert_name}/privkey.pem"

  nginx::resource::server { 'homelab-reverse-proxy':
    ensure           => present,
    server_name      => $proxy_server_names,
    listen_port      => $listen_port,
    ssl              => $ssl,
    ssl_cert         => $ssl_cert,
    ssl_key          => $ssl_key,
    ssl_redirect     => true,
    proxy            => "http://${backend_host}:${backend_port}",
    proxy_set_header => [
      'Host $host',
      'X-Real-IP $remote_addr',
      'X-Forwarded-For $proxy_add_x_forwarded_for',
      'X-Forwarded-Proto $scheme',
    ],
    # NOTE: do NOT require Class['nginx'] here. The define notifies
    # Class['nginx::service'] internally, and that class is contained in
    # Class['nginx'] -- requiring the outer class closes a dependency cycle.
    # Ordering with the package/config dirs is already handled by the module.
  }

  nginx::resource::server { 'homelab-default':
    ensure         => present,
    server_name    => ['_'],
    listen_port    => $listen_port,
    listen_options => 'default_server',
    ssl            => $ssl,
    ssl_cert       => $ssl_cert,
    ssl_key        => $ssl_key,
    ssl_redirect   => true,
    www_root       => $default_www_root,
    # NOTE: do NOT require Class['nginx'] here (see above -- it creates a
    # dependency cycle via the define's internal notify to nginx::service).
  }
}
