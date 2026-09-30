#!/bin/bash
# Resets the onboard NIC when its TX ring hangs. Run from root's crontab every
# minute.
#
# The 82579V (e1000e) wedges under segmentation offload and the driver never
# recovers: the kernel logs "Detected Hardware Unit Hang" every 2s and the host
# is off the network until the link flaps. 81-e1000e-hang.rules turns the
# offload off, which should prevent it; this is the fallback if it does not.
# Taking the port down and up makes e1000e reset the hardware, same as
# replugging the cable. eno1 is a bridge port with no address, so no route is
# lost (bouncing vmbr0 instead is what dropped the default route in the past).
#
# This used to be a gateway-ping watchdog that ran `ifreload -a`. That never
# ended a single outage and was removed on 2026-09-30. If no hang has been
# logged by 2027-01-01, the offload fix is proven: delete this script, its cron
# entry and the NicTxHangReset Loki rule.

set -u

NIC="eno1"
STAMP="/run/net-watchdog.last-reset"

# Only look at hang reports logged after the previous reset, so messages that
# preceded a successful reset do not trigger another one a minute later.
SINCE=$(( $(date +%s) - 120 ))
LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
[ "$LAST" -gt "$SINCE" ] && SINCE=$LAST

journalctl -k -q --no-pager --since "@$SINCE" 2>/dev/null \
    | grep -q "$NIC: Detected Hardware Unit Hang" || exit 0

date +%s > "$STAMP"
# The kernel log, not syslog: cron-spawned logger lines carry no stable unit,
# and this way the line reaches Loki as job="pve/kernel" next to the hang.
echo "net-watchdog: $NIC TX hang detected, resetting the NIC" > /dev/kmsg
ip link set "$NIC" down
sleep 2
ip link set "$NIC" up
