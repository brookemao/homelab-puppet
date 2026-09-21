# Standalone entrypoint manifest for `bolt apply manifests/site.pp`
node default {
  class { 'homelab': }
}
