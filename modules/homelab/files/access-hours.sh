#!/bin/bash
set -euo pipefail

# Keep this zone in sync with OnCalendar in homelab-access-hours.timer.
hour=$(TZ=America/Vancouver date +%H)
today=$(TZ=America/Vancouver date +%F)
units=(cockpit.socket cockpit.service sshd.service)
boot_units=(cockpit.socket sshd.service)

# Fedora normally runs sshd.service directly, but an enabled SSH socket
# must not be able to reactivate it during the overnight window either.
if [[ $(systemctl show --property=LoadState --value sshd.socket) != not-found ]]; then
    units+=(sshd.socket)
    boot_units+=(sshd.socket)
fi

# Only the timer starts these units at boot, after checking the local hour.
# Keep their native boot activation disabled even during daytime so a reboot
# overnight cannot briefly expose listeners before the timer has run.
for unit in "${boot_units[@]}"; do
    if systemctl is-enabled --quiet "$unit"; then
        systemctl disable "$unit"
    fi
done

if (( 10#$hour < 9 )); then
    # Do not rearm after a kill, including on Puppet applies or reboots.
    if [[ -f "/var/lib/homelab-claude-history/killed-$today" ]]; then
        systemctl disable --runtime --now homelab-claude-history.timer
    else
        systemctl enable --runtime --now homelab-claude-history.timer
    fi
    # Mask as well as stop: socket activation and manual/dependency starts
    # must not reopen access. Runtime masks disappear on reboot.
    systemctl mask --runtime --now "${units[@]}"
else
    systemctl disable --runtime --now homelab-claude-history.timer
    systemctl unmask --runtime "${units[@]}"
    # Cockpit's service is socket-activated; only its socket needs starting.
    systemctl start cockpit.socket sshd.service
fi
