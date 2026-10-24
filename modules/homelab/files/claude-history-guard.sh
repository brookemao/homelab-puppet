#!/bin/bash
set -euo pipefail

export TZ=America/Vancouver
projects=/home/iapark/.local/share/containers/storage/volumes/claude-home/_data/projects
state=${STATE_DIRECTORY:-/var/lib/homelab-claude-history}
today=$(date +%F)
hour=$(date +%H)
weekday=$(date --date="$today" +%u)
end_hour=18
if (( weekday >= 6 )); then
    end_hour=9
fi

# Also enforce the window on manual starts and delayed timer activations.
if (( 10#$hour >= end_hour && 10#$hour < 22 )); then
    exit 0
fi
[[ -d "$projects" ]] || exit 0
cd "$projects"

# grep returns 1 for no matches, which is a normal idle night. Other errors
# and incomplete JSON fail the check so the next timer tick can retry safely.
records=$(grep -h -R -F '"origin":{"kind":"human"}' .) || {
    status=$?
    if (( status == 1 )); then
        exit 0
    fi
    exit "$status"
}
latest=$(jq -rs 'sort_by(.timestamp) | reverse | .[0].timestamp // empty' <<< "$records")
[[ -n "$latest" ]] || exit 0

# GNU date accepts ISO 8601 timestamps including UTC Z and fractional seconds.
# Use nanoseconds so a message just after 22:00 still exceeds the limit.
latest_ns=$(date --date="$latest" +%s%N)
# Before the morning/daytime cutoff, the window began the previous evening.
limit="$today 22:00:00"
if (( 10#$hour < 22 )); then
    limit="$limit yesterday"
fi
limit_ns=$(date --date="$limit" +%s%N)
if (( latest_ns <= limit_ns )); then
    exit 0
fi

# Persist the message timestamp, rather than the wall-clock time of the kill,
# so a restarted container is left alone until another human prompt appears.
mkdir -p "$state"
if [[ -f "$state/last-killed-message" ]]; then
    last_killed=$(cat "$state/last-killed-message")
    if [[ "$last_killed" == "$latest" ]]; then
        exit 0
    fi
fi

# Only access iapark's local rootless Podman storage, never root's or a remote.
uid=$(id -u iapark)
podman() {
    runuser -u iapark -- env HOME=/home/iapark XDG_RUNTIME_DIR="/run/user/$uid" \
        /usr/bin/podman --remote=false "$@"
}
containers=$(podman ps --format json)
targets=$(jq -r '
    .[] | with_entries(.key |= ascii_downcase) |
    select(
        ((.names // [] | if type == "string" then [.] else . end) |
            any(. == "immich-tools" or startswith("vsc-immich-tools-"))) or
        ((.labels // {}) | [."devcontainer.local_folder", ."vsch.local.folder"] |
            any(. // "" | gsub("\\\\"; "/") | rtrimstr("/") |
                split("/") | last == "immich-tools"))
    ) | .id
' <<< "$containers")
if [[ -z "$targets" ]]; then
    echo 'Overnight Claude activity: no running immich-tools container found; will retry.'
    exit 0
fi
mapfile -t ids <<< "$targets"
echo "Overnight Claude activity ($latest): killing ${#ids[@]} immich-tools container(s)."
podman kill "${ids[@]}"

# Only deduplicate successful kills. Missing containers and failures retry.
# Rename atomically so an interrupted write cannot leave a partial timestamp.
printf '%s\n' "$latest" > "$state/last-killed-message.tmp"
mv -f "$state/last-killed-message.tmp" "$state/last-killed-message"
