# Qwen Sharp chat template

`qwen-sharp-chat-template.jinja` is an unmodified copy of `chat_template.jinja`
from [peculiar-ragdoll/Qwen-Sharp-Chat-Templates](https://huggingface.co/peculiar-ragdoll/Qwen-Sharp-Chat-Templates),
based on [froggeric/Qwen-Fixed-Chat-Templates](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates).

- Version: v22.5.0
- License: Apache-2.0 (as declared by the upstream repository)
- Pinned revision: `6a78b888557f8c9987f51bca98d02d8f69682044`
- [Original file](https://huggingface.co/peculiar-ragdoll/Qwen-Sharp-Chat-Templates/blob/6a78b888557f8c9987f51bca98d02d8f69682044/chat_template.jinja)
- SHA-256: `cdff39fb26b60dc90faa292e726655c6b21f62db497846e02e4c4bbab942a84a`

Puppet copies this file into `llama::install_dir`, mounts it read-only into
the container, and restarts llama-server when it changes. Update the bundled
file and this provenance together when adopting a newer upstream revision.
