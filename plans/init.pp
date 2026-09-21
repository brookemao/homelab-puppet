# @summary Bolt plan to install EPEL 10, fastfetch, fail2ban, and ddclient
#
# Dynamically resolves the latest release tag from GitHub before running puppet apply,
# ensuring updates past 4.0.0 are automatically discovered and installed.
#
# @param targets Target hosts or group to configure (defaults to 'rhel10' from inventory.yaml)
# @param manage_services Whether to ensure services like fail2ban are enabled and started
# @param ddclient_install_method 'tarball' (build/install from GitHub release tar) or 'package' (dnf)
# @param ddclient_release_tag Specific tag like 'v4.0.0' or 'latest' to automatically query GitHub
# @param cloudflare_token Cloudflare API token
# @param cloudflare_zone Cloudflare root zone
# @param cloudflare_domains Cloudflare subdomains to update
# @param ddclient_replace_config Whether to overwrite /etc/ddclient/ddclient.conf if it exists
plan homelab (
  TargetSpec $targets                 = 'rhel10',
  Boolean    $manage_services         = true,
  String[1]  $ddclient_install_method = 'tarball',
  String[1]  $ddclient_release_tag    = 'latest',
  String[1]  $cloudflare_token        = '<SECRET TOKEN HERE>',
  String[1]  $cloudflare_zone         = 'brookemao.ca',
  String[1]  $cloudflare_domains      = 'homelab.brookemao.ca,mindustry.brookemao.ca',
  Boolean    $ddclient_replace_config = false,
) {
  # 1. Prepare targets for puppet execution (installs puppet-agent package on targets if absent)
  apply_prep($targets)

  # 2. Resolve the latest ddclient tag from GitHub on target before puppet apply
  $resolved_ddclient_tag = if $ddclient_install_method == 'tarball' and $ddclient_release_tag == 'latest' {
    $target_list = get_targets($targets)
    $resolve_target = $target_list[0]
    out::message("Querying GitHub for the latest ddclient release tag on ${resolve_target.name}...")

    # Query GitHub releases redirect for the latest tag
    $cmd = 'curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/ddclient/ddclient/releases/latest | sed -e "s#.*/tag/##"'
    $res = run_command($cmd, $resolve_target, 'Resolving latest ddclient release tag')
    $raw_tag = $res[0]['stdout'].strip()

    if $raw_tag =~ /^v?[0-9]/ {
      out::message("Resolved latest ddclient tag: ${raw_tag}")
      $raw_tag
    } else {
      out::message("Could not dynamically resolve tag (${raw_tag}); falling back to v4.0.0")
      'v4.0.0'
    }
  } else {
    $ddclient_release_tag
  }

  # 3. Apply manifest declarations to all targets with the resolved tag
  return apply($targets, '_catch_errors' => true) {
    class { 'homelab':
      manage_services         => $manage_services,
      ddclient_install_method => $ddclient_install_method,
      ddclient_release_tag    => $resolved_ddclient_tag,
      cloudflare_token        => $cloudflare_token,
      cloudflare_zone         => $cloudflare_zone,
      cloudflare_domains      => $cloudflare_domains,
      ddclient_replace_config => $ddclient_replace_config,
    }
  }
}
