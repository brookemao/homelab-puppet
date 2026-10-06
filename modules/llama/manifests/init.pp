# @summary Runs llama.cpp llama-server via podman, with SearXNG MCP search tools.
#
# Mirrors the homelab-llama test settings (Qwen3.8 thinking-mode
# sampling, GPU passthrough, q8_0 KV cache, draft-mtp speculation) with a
# 131072-token context (1/2 of Qwen3 256k max, reduced to avoid OOM) and a 8 GiB host-RAM prompt cache (--cache-ram) so
# concurrent users can reuse cached prompts. --parallel is left to llama.cpp to
# manage concurrent requests automatically, -kvu forces the shared (unified)
# KV cache. --sleep-idle-seconds unloads the
# model after 10 minutes idle.
#
# The SearXNG MCP server is attached through the Web UI: --ui-config-file
# pre-registers it for first-time visitors (url + Bearer header, direct
# browser calls, no proxy). The MCP server is publicly routable at
# websearch.brookemao.ca, so its own CORS allowlist
# (MCP_HTTP_ALLOWED_ORIGINS, set by the searxng module to the llama origin)
# is what lets the browser call it; llama-server needs no CORS configuration
# since the UI is same-origin with it. The token is baked into the
# browser-side default config, which is acceptable for a private,
# Basic-auth-gated instance and matches how the upstream UI stores per-server
# headers.
#
# Prerequisites Puppet does NOT provide: the container image built into rootful
# podman storage (build with sudo in homelab-llama so root sees it), the GPU
# devices (/dev/kfd + /dev/dri for rocm, /dev/dri for vulkan), and the model
# file under $models_dir.
#
# @param backend GPU backend: 'rocm' passes /dev/kfd + /dev/dri with the
#   ROCm library path; 'vulkan' passes only the single dGPU (see
#   $vulkan_pci_id). Selects the default $image when $image is undef.
# @param model GGUF basename under $models_dir, or an absolute container path.
# @param models_dir Host directory holding GGUFs, mounted read-only at the same path.
# @param port Host loopback port published for the HTTP endpoint.
# @param image Container image (must already exist in rootful podman storage,
#   e.g. via `sudo podman build` in homelab-llama).
#   Defaults to "localhost/llama-${backend}:latest" when undef; set explicitly
#   to pin a tag or use a custom build.
# @param reasoning_effort Thinking effort passed to the chat template.
# @param memory_limit RAM the container may use, e.g. '12g'. Caps llama-server
#   so a runaway allocation fails inside the container instead of OOMing the host.
# @param vulkan_pci_id Explicit dGPU PCI slot override (e.g. '0000:03:00.0').
#   Defaults to the llama_dgpu_pci fact (Navi 48 lookup), else '0000:03:00.0'.
#   The unit resolves that slot's stable /dev/dri/by-path symlinks at each
#   start (via ExecStartPre) into /dev/llama-dgpu-render and
#   /dev/llama-dgpu-card (mapped to renderD128/card0 in the container), so
#   selection survives card-number changes across reboots.
# @param searxng_mcp_url Public MCP endpoint the Web UI connects to (through the proxy).
# @param searxng_bearer_token Bearer token for the public MCP endpoint; same
#   secret as searxng::auth_token (homelab passes the shared lookup through).
#   No default - without it nothing can authenticate to websearch.brookemao.ca.
# @param install_dir Directory holding the generated ui-config.json (bind-mounted read-only).
# @param podman_command Absolute path to podman (systemd ExecStart needs a full path)
# @param manage_service Whether to enable and start the systemd unit
# @param service_name Name of the systemd unit and of the container
#
class llama (
  Enum['rocm', 'vulkan'] $backend            = 'rocm',
  String[1]            $model                 = 'Qwen3.8-27B-UD-Q6_K.gguf',
  Llama::Absolutepath  $models_dir            = '/home/llama/models',
  Integer[1, 65535]    $port                  = 8080,
  Optional[String[1]]  $image                 = undef,
  String[1]            $reasoning_effort      = 'xhigh',
  Pattern[/\A\d+(\.\d+)?([bkmgBKMG]|[kKmMgG][bB])?\z/] $memory_limit = '12g',
  Optional[Pattern[/\A[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]\z/]] $vulkan_pci_id = undef,
  String[1]            $searxng_mcp_url       = 'https://websearch.brookemao.ca/mcp',
  Sensitive[String[1]] $searxng_bearer_token,
  Llama::Absolutepath  $install_dir           = '/opt/llama-app',
  Llama::Absolutepath  $podman_command        = '/usr/bin/podman',
  Boolean              $manage_service        = true,
  String[1]            $service_name          = 'llama',
) {
  $ui_config = "${install_dir}/ui-config.json"
  $real_image = $image ? {
    undef   => "localhost/llama-${backend}:latest",
    default => $image,
  }
  # Explicit override wins; otherwise the Navi 48 lookup; otherwise the
  # known-good slot. pick skips undef/empty values left to right.
  $dgpu_pci_id = pick($vulkan_pci_id, $facts['llama_dgpu_pci'], '0000:03:00.0')
  $model_path = $model =~ /^\// ? {
    true    => $model,
    default => "${models_dir}/${model}",
  }

  file { $install_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0750',
  }

  # Models directory must exist for the bind mount; the model files
  # themselves are the operator's and are never touched here.
  file { $models_dir:
    ensure => directory,
  }

  # ui-config carries the Bearer token, so keep it root-only and hide it from
  # reports. It lands read-only in the container; llama-server serves it as
  # first-visit defaults.
  file { $ui_config:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    content => Sensitive(epp('llama/ui-config.json.epp', {
      'searxng_mcp_url'      => $searxng_mcp_url,
      'searxng_bearer_token' => $searxng_bearer_token,
    })),
    require => File[$install_dir],
  }

  file { "/etc/systemd/system/${service_name}.service":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('llama/llama.service.epp', {
      'podman_command'   => $podman_command,
      'container_name'   => $service_name,
      'port'             => $port,
      'models_dir'       => $models_dir,
      'model_path'       => $model_path,
      'ui_config'        => $ui_config,
      'image'            => $real_image,
      'backend'          => $backend,
      'reasoning_effort' => $reasoning_effort,
      'memory_limit'     => $memory_limit,
      'vulkan_pci_id'    => $dgpu_pci_id,
    }),
    notify  => Exec["${service_name}-daemon-reload"],
  }

  exec { "${service_name}-daemon-reload":
    command     => 'systemctl daemon-reload',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  if $manage_service {
    # Restarting on a file change stops then starts the unit, i.e. the
    # container is recreated with the new settings.
    service { $service_name:
      ensure    => running,
      enable    => true,
      subscribe => [
        File[$ui_config],
        File["/etc/systemd/system/${service_name}.service"],
      ],
      require   => [
        Exec["${service_name}-daemon-reload"],
      ],
    }
  }
}
