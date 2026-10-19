#!/bin/bash
# Exports local-lvm thin pool fill for the node_exporter textfile collector;
# see AGENTS.md "Thin pool".

set -eu
export LC_ALL=C

DIR=/var/lib/node_exporter/textfile_collector
POOL="pve/data"

read -r DATA META < <(lvs --noheadings -o data_percent,metadata_percent "$POOL")

cat > "$DIR/.thinpool.tmp" <<EOF
# TYPE pve_thinpool_data_percent gauge
pve_thinpool_data_percent{pool="$POOL"} $DATA
# TYPE pve_thinpool_metadata_percent gauge
pve_thinpool_metadata_percent{pool="$POOL"} $META
EOF
mv "$DIR/.thinpool.tmp" "$DIR/thinpool.prom"
