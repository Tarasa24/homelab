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
METRICS_FILE="/var/lib/node_exporter/textfile_collector/net_watchdog.prom"
METRICS_TMP="${METRICS_FILE}.$$"

# 2026-09-07: an incident on 2026-09-05 ran ifreload -a 74 times over ~12h
# (every ~10min, rate-limited) without the gateway ever becoming reachable
# afterward -- ifreload plainly wasn't the fix for whatever was actually
# wrong, and nothing else noticed or escalated, because this script only
# wrote to syslog, which nobody was watching in real time. Two changes:
#   - ping 3 times, not 1: a single dropped packet (this host generated a lot
#     of network noise the same night) was enough to trigger the whole
#     ifreload path; ping's own exit code already treats any reply out of
#     the 3 as success, so this alone cuts down false positives.
#   - write a Prometheus textfile metric on every run, so Alertmanager can
#     actually page on "still unreachable N minutes after the last ifreload"
#     instead of that only being discoverable by grepping syslog after the
#     fact.
write_metric() {
    # in_progress writes truncate the read a scrape could be mid-way through;
    # write elsewhere and rename, which is atomic on the same filesystem.
    cat > "$METRICS_TMP" <<-EOF
	# HELP net_watchdog_gateway_reachable Whether the last watchdog ping of the declared gateway succeeded (1) or not (0).
	# TYPE net_watchdog_gateway_reachable gauge
	net_watchdog_gateway_reachable{interface="$IF"} $1
	# HELP net_watchdog_last_run_timestamp_seconds Unix time of the watchdog's last run.
	# TYPE net_watchdog_last_run_timestamp_seconds gauge
	net_watchdog_last_run_timestamp_seconds $(date +%s)
	EOF
    mv -f "$METRICS_TMP" "$METRICS_FILE"
}

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
    write_metric 0
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

if ping -c 3 -W 2 "$GW" >/dev/null 2>&1; then
    write_metric 1
    exit 0
fi

write_metric 0

NOW=$(date +%s)
if [ -f "$STAMP" ] && [ $(( NOW - $(cat "$STAMP" 2>/dev/null || echo 0) )) -lt "$COOLDOWN" ]; then
    logger "net-watchdog: gateway $GW unreachable, reload suppressed by cooldown"
    exit 0
fi

echo "$NOW" > "$STAMP"
logger "net-watchdog: gateway $GW unreachable, running ifreload -a"
if ifreload -a; then
    sleep 3
    if ping -c 3 -W 2 "$GW" >/dev/null 2>&1; then
        write_metric 1
        logger "net-watchdog: ifreload -a completed, gateway $GW now reachable"
    else
        logger "net-watchdog: ifreload -a completed but gateway $GW is still unreachable -- likely not a local interface problem"
    fi
else
    logger "net-watchdog: ifreload -a itself exited non-zero"
fi
