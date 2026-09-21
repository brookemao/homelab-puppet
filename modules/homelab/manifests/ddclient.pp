# @summary Installs and configures ddclient for Dynamic DNS management on RHEL 10
#
# Installs ddclient from upstream GitHub release tarball (https://github.com/ddclient/ddclient#installation)
# using the tag resolved by the Bolt plan, ensuring perl and make are installed beforehand as packages.
#
# @param install_method 'tarball' (builds from GitHub release tarball) or 'package' (dnf)
# @param release_tag GitHub release tag to install (resolved by Bolt plan, e.g. 'v4.0.0')
# @param manage_service Whether to manage the ddclient systemd service
# @param service_ensure Service target state ('running' or 'stopped')
# @param service_enable Whether to enable ddclient at boot
# @param cloudflare_token API token for Cloudflare DDNS
# @param cloudflare_zone Root zone for Cloudflare DDNS
# @param cloudflare_domains Comma-separated domains to update
# @param replace_config Whether to overwrite /etc/ddclient/ddclient.conf if it already exists
class homelab::ddclient (
  Enum['tarball', 'package'] $install_method    = 'tarball',
  String[1]                  $release_tag       = 'latest',
  Boolean                    $manage_service    = true,
  String[1]                  $service_ensure    = 'running',
  Boolean                    $service_enable    = true,
  String[1]                  $cloudflare_token   = '<SECRET TOKEN HERE>',
  String[1]                  $cloudflare_zone    = 'brookemao.ca',
  String[1]                  $cloudflare_domains = 'homelab.brookemao.ca,mindustry.brookemao.ca',
  Boolean                    $replace_config    = false,
) {
  require homelab::epel

  # Common directories
  file { '/etc/ddclient':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  file { '/var/cache/ddclient':
    ensure => directory,
    owner  => 'ddclient',
    group  => 'ddclient',
    mode   => '0755',
  }

  file { '/usr/local/src':
    ensure => directory,
  }

  # Configuration file with Cloudflare credentials/snippet
  # replace => false ensures that user modifications / API credentials are preserved across runs unless replace_config is true
  file { '/etc/ddclient/ddclient.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    content => epp('homelab/ddclient.conf.epp', {
      'cloudflare_token'   => $cloudflare_token,
      'cloudflare_zone'    => $cloudflare_zone,
      'cloudflare_domains' => $cloudflare_domains,
    }),
    replace => $replace_config,
    require => File['/etc/ddclient'],
  }

  if $install_method == 'tarball' {
    # 1. Packages required beforehand (perl and make explicitly required, plus tar, curl and perl runtime libs)
    $prereq_packages = [
      'perl',
      'make',
      'tar',
      'curl',
      'perl-JSON-PP',
      'perl-IO-Socket-SSL',
      'perl-Digest-SHA1',
      'perl-Data-Validate-IP',
      'perl-NetAddr-IP',
    ]

    package { $prereq_packages:
      ensure  => installed,
      require => Class['homelab::epel'],
    }

    # Explicit ordering guarantees that perl and make are installed beforehand
    Package['perl'] -> Exec['install_ddclient_release_tar']
    Package['make'] -> Exec['install_ddclient_release_tar']
    Package['tar']  -> Exec['install_ddclient_release_tar']

    # 2. Download release tarball for the tag, build, and install
    exec { 'install_ddclient_release_tar':
      command  => @("CMD"/$),
        set -euo pipefail

        target_tag="${release_tag}"
        if [ "\$target_tag" = "latest" ]; then
          echo "Resolving latest release tag from GitHub..."
          resolved=\$(curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/ddclient/ddclient/releases/latest 2>/dev/null | sed -e 's#.*/tag/##' || true)
          if echo "\$resolved" | grep -qE '^v?[0-9]'; then
            target_tag="\$resolved"
            echo "Resolved latest tag: \$target_tag"
          else
            echo "Could not dynamically resolve latest tag; falling back to v4.0.0"
            target_tag="v4.0.0"
          fi
        fi

        version=\$(echo "\$target_tag" | sed -e 's/^v//')
        tarball="ddclient-\$version.tar.gz"
        release_url="https://github.com/ddclient/ddclient/releases/download/\$target_tag/\$tarball"
        fallback_url="https://github.com/ddclient/ddclient/archive/refs/tags/\$target_tag.tar.gz"

        echo "Fetching ddclient release tarball for \$target_tag..."
        cd /usr/local/src
        if ! curl -fsSL -o "\$tarball" "\$release_url"; then
          echo "Direct release asset not found, downloading source archive..."
          curl -fsSL -o "\$tarball" "\$fallback_url"
        fi

        # Clean previous extraction if present
        rm -rf "ddclient-\$version" "ddclient-\$target_tag"
        tar -xf "\$tarball"

        extract_dir=\$(find . -maxdepth 1 -type d -name "ddclient-*" | head -n 1)
        cd "\$extract_dir"

        # Configure, make, and install
        if [ ! -f ./configure ] && [ -f ./autogen ]; then
          ./autogen
        fi
        ./configure --prefix=/usr --sysconfdir=/etc/ddclient --localstatedir=/var
        make
        make install

        # Install systemd service from release archive
        if [ -f sample-etc_systemd.service ]; then
          cp -f sample-etc_systemd.service /etc/systemd/system/ddclient.service
          systemctl daemon-reload
        fi

        # Record installed tag to ensure idempotency and detect future updates
        echo "\$target_tag" > /etc/ddclient/.installed_tag
        echo "ddclient \$target_tag successfully installed."
        | CMD
      unless   => @("UNLESS"/$),
        set -euo pipefail
        test -x /usr/bin/ddclient || exit 1
        test -f /etc/ddclient/.installed_tag || exit 1

        installed_tag=\$(cat /etc/ddclient/.installed_tag 2>/dev/null || true)
        test -n "\$installed_tag" || exit 1

        target_tag="${release_tag}"
        if [ "\$target_tag" = "latest" ]; then
          resolved=\$(curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/ddclient/ddclient/releases/latest 2>/dev/null | sed -e 's#.*/tag/##' || true)
          if echo "\$resolved" | grep -qE '^v?[0-9]'; then
            target_tag="\$resolved"
          else
            target_tag="\$installed_tag"
          fi
        fi

        [ "\$installed_tag" = "\$target_tag" ]
        | UNLESS
      provider => 'shell',
      path     => ['/usr/bin', '/usr/sbin', '/bin', '/sbin'],
      require  => [
        Package[$prereq_packages],
        File['/usr/local/src'],
        File['/etc/ddclient'],
      ],
      notify   => Service['ddclient'],
    }

    $service_dependency = [
      Exec['install_ddclient_release_tar'],
      File['/etc/ddclient/ddclient.conf'],
      File['/var/cache/ddclient'],
    ]
  } else {
    # Native package installation via DNF
    package { 'ddclient':
      ensure  => installed,
      require => Class['homelab::epel'],
    }

    $service_dependency = [
      Package['ddclient'],
      File['/etc/ddclient/ddclient.conf'],
    ]
  }

  if $manage_service {
    service { 'ddclient':
      ensure  => $service_ensure,
      enable  => $service_enable,
      require => $service_dependency,
    }
  }
}
