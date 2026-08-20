#!/bin/bash
# Keeps the management interface's default route alive. Run from root's crontab
# every minute.
#
# The previous version bounced the bridge with `ip link set down/up` whenever the
# gateway stopped answering. That does not go through ifupdown, so the static
# gateway declared in /etc/network/interfaces was dropped and never re-added:
# the host lost internet permanently (no apt, no DNS, tailscaled logged out) and
# the script could then only log "no gateway found" forever, because its very
# first step is to read a route that no longer exists.
#
# Now: a missing route is re-added directly from the declared config, which is
# the cheap and by far the most common case. Only an unreachable gateway falls
# back to `ifreload -a`, which is what the PVE UI itself uses, and that is rate
# limited so a genuinely dead uplink cannot cause a reload every minute.

set -u

# The management address lives on the VLAN 30 subinterface, not on the bridge
# itself: vmbr0 is VLAN-aware and carries VLANs 30/40/50, so it holds no
# address and no route. Watching "vmbr0" here would find neither, and the
# script would exit 1 every minute without ever restoring anything.
IF="vmbr0.30"
COOLDOWN=600
STAMP="/run/net-watchdog.last-reload"

# The gateway is declared in interfaces.d, not in the main interfaces file, so
# both have to be searched.
declared_gateway() {
    awk -v iface="$IF" '
        $1 == "iface" && $2 == iface { in_iface = 1; next }
        $1 == "iface" || $1 == "auto" { in_iface = 0 }
        in_iface && $1 == "gateway" { print $2; exit }
    ' /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null
}

GW=$(ip route show default dev "$IF" | awk '{print $3}' | head -n1)

if [ -z "$GW" ]; then
    DECLARED=$(declared_gateway)
    if [ -z "$DECLARED" ]; then
        logger "net-watchdog: no default route on $IF and none declared in /etc/network/interfaces or interfaces.d"
        exit 1
    fi
    if ip route add default via "$DECLARED" dev "$IF" 2>/dev/null; then
        logger "net-watchdog: restored missing default route via $DECLARED on $IF"
    else
        logger "net-watchdog: failed to restore default route via $DECLARED on $IF"
    fi
    exit 0
fi

if ping -c 1 -W 2 "$GW" >/dev/null 2>&1; then
    exit 0
fi

NOW=$(date +%s)
if [ -f "$STAMP" ] && [ $(( NOW - $(cat "$STAMP" 2>/dev/null || echo 0) )) -lt "$COOLDOWN" ]; then
    logger "net-watchdog: gateway $GW unreachable, reload suppressed by cooldown"
    exit 0
fi

echo "$NOW" > "$STAMP"
logger "net-watchdog: gateway $GW unreachable, running ifreload -a"
ifreload -a
