# @summary Standalone masterless OpenVox entrypoint
#
# Can be run directly with:
#   sudo openvox apply --modulepath=modules manifests/site.pp
#
# Supports configuration via Hiera (data/common.yaml, data/secrets.yaml)
# or environment variables (FACTER_cloudflare_token, FACTER_ddclient_replace_config).

node default {
  # 1. Resolve Cloudflare API Token:
  # Check FACTER_cloudflare_token environment variable first, then Hiera, then fallback default
  $cf_token_fact = $facts['cloudflare_token']
  $cf_token = if $cf_token_fact and $cf_token_fact != '' {
    $cf_token_fact
  } else {
    lookup('homelab::cloudflare_token', String, 'first', '<SECRET TOKEN HERE>')
  }

  # 2. Resolve ddclient replace config option:
  $replace_fact = $facts['ddclient_replace_config']
  $replace_config = if $replace_fact =~ Boolean {
    $replace_fact
  } elsif $replace_fact == 'true' {
    true
  } else {
    lookup('homelab::ddclient_replace_config', Boolean, 'first', false)
  }

  # 3. Apply baseline homelab configuration
  class { 'homelab':
    cloudflare_token        => $cf_token,
    ddclient_replace_config => $replace_config,
  }
}
