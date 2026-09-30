#!/bin/bash
# Resets eno1 when e1000e reports a TX hang; see AGENTS.md "Host NIC".

set -u

NIC="eno1"
STAMP="/run/net-watchdog.last-reset"

# Ignore hang messages from before the last reset.
SINCE=$(( $(date +%s) - 120 ))
LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
[ "$LAST" -gt "$SINCE" ] && SINCE=$LAST

journalctl -k -q --no-pager --since "@$SINCE" 2>/dev/null \
    | grep -q "$NIC: Detected Hardware Unit Hang" || exit 0

date +%s > "$STAMP"
# Kernel log so it reaches Loki as job="pve/kernel" (NicTxHangReset).
echo "net-watchdog: $NIC TX hang detected, resetting the NIC" > /dev/kmsg
ip link set "$NIC" down
sleep 2
ip link set "$NIC" up
