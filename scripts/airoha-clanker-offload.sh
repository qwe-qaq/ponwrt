#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Read-only observations. Never enable offload, reset counters or access flash.
export LC_ALL=C
section() { printf '\n--- %s ---\n' "$*"; }
snapshot() {
 section 'offload identity'; date -u; cat /proc/uptime /proc/sys/kernel/random/boot_id
 section 'Clanker firmware build identity'
 if [ -r /lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt ]; then
  grep -E '^(Source:|Commit:|Variant:|Host integration candidate:)' \
   /lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt
 else
  echo 'buildinfo unavailable (old image or firmware package missing)'
 fi
 section 'verified offload mode (table flags are not packet hits)'
 ucode /usr/share/airoha-clanker-mode.uc
 section 'configured firewall offload (configuration is not evidence of hits)'
 for option in flow_offloading flow_offloading_hw; do
  printf '%s=' "$option"; uci -q get "firewall.@defaults[0].$option" || echo unset
 done
 section 'actual flowtables and forwarding rules'
 nft list flowtables 2>&1
 nft list table bridge fw4 2>&1
 nft list chain inet fw4 forward 2>&1
 section 'software flow handoffs (per CPU, unsigned decimal counters wrap at 32 bits)'
 cat /proc/net/stat/nf_flowtable 2>/dev/null || echo unavailable
 section 'PPE setup and raw QDMA source counters (cpu/fwd labels do not prove PPE hits)'
 cat /sys/kernel/debug/ppe/status /sys/kernel/debug/ppe/config 2>/dev/null || echo unavailable
 section 'PPE bound entries (BND is installation; timestamp movement adds activity evidence)'
 cat /sys/kernel/debug/ppe/bind 2>/dev/null || echo unavailable
 section 'Kite routed admission and datapath evidence'
 cat /sys/kernel/debug/ppe/status 2>/dev/null | grep -E '^(kite_|.*rx_ppe|.*rx_bytes|.*tx_sent|.*tx_bytes|.*hw_submitted|.*hw_reaped)' || echo unavailable
 section 'test conntrack (5201/5202 only; OFFLOAD and HW_OFFLOAD are installation flags)'
 if [ -r /proc/net/nf_conntrack ]; then
  awk '/(sport|dport)=520[12]([ ]|$)/' /proc/net/nf_conntrack
 elif command -v conntrack >/dev/null; then
  conntrack -L 2>/dev/null | awk '/(sport|dport)=520[12]([ ]|$)/'
 else
  echo unavailable
 fi
 section 'topology routes and physical links'
 ip -d -s link; ip route; ip -6 route
 bridge link show 2>&1; bridge vlan show 2>&1; bridge fdb show 2>&1
 section 'per-port driver features and hardware statistics'
 for path in /sys/class/net/*; do
  dev=${path##*/}
  [ "$dev" != lo ] || continue
  printf '\ninterface=%s carrier=' "$dev"; cat "$path/carrier" 2>/dev/null || echo unavailable
  ethtool -k "$dev" 2>&1 | grep -E 'offload|hw-tc|generic|Error|supported'
  ethtool -S "$dev" 2>&1
  # Standard MAC statistics include switch port counters when supported.
  ethtool --include-statistics -a "$dev" 2>&1
 done
 section 'PON registration and data mapping (read-only, identity omitted)'
 if command -v ponctl >/dev/null; then
  timeout 10 ponctl status --json
  timeout 10 ponctl data-path show
 else
  echo unavailable
 fi
 section 'PON public sysfs state (credentials excluded)'
 for path in /sys/class/pon/* /sys/class/net/pon*/device; do
  [ -d "$path" ] || continue
  for attr in state link_state pon_mode mode onu_state registration_state; do
   [ -r "$path/$attr" ] || continue
   printf '%s=' "$path/$attr"; cat "$path/$attr"
  done
 done
 section 'NPU descriptor transport'; airoha-clanker-diag --status
 section 'host CPU and interface counters'; airoha-clanker-diag --perf
}
record() {
 destination=$1; minutes=${2:-10}; expected_mode=${3:-}
 if [ -n "$expected_mode" ]; then
  ucode /usr/share/airoha-clanker-mode.uc "$expected_mode" || return 2
 fi
 case "$minutes" in ''|*[!0-9]*) return 2 ;; esac
 [ "$minutes" -ge 1 ] && [ "$minutes" -le 120 ] || return 2
 [ -n "$destination" ] && (umask 077; mkdir "$destination") || return 2
 umask 077
 trap 'reason=interrupted; [ -z "$wait_pid" ] || kill "$wait_pid" 2>/dev/null' INT TERM HUP
 reason=complete; wait_pid=; count=0
 read -r started junk < /proc/uptime; started=${started%.*}
 printf 'schema=3 minutes=%s interval=10s expected_mode=%s\n' "$minutes" "${expected_mode:-unspecified}" > "$destination/manifest.txt"
 snapshot > "$destination/start.log" 2>&1
 logread -f -F "$destination/system.log" -S 4096 &
 log_pid=$!
 printf 'Recording offload evidence for %s minutes in %s. Ctrl-C stops cleanly.\n' "$minutes" "$destination"
 while [ "$reason" = complete ]; do
  read -r now junk < /proc/uptime
  [ "$(( ${now%.*} - started ))" -lt "$(( minutes * 60 ))" ] || break
  airoha-clanker-diag --perf >> "$destination/perf.log" 2>> "$destination/errors.log"
  {
   section 'TX/RX and PPE sample'; date -u; cat /proc/uptime
   airoha-clanker-diag --status
   cat /sys/kernel/debug/ppe/status 2>/dev/null || echo ppe_status_unavailable
  } >> "$destination/samples.log" 2>&1
  # Table scans occur only once per minute; compact counters are sampled above.
  if [ "$((count % 6))" -eq 0 ]; then
   if [ -n "$expected_mode" ]; then
    ucode /usr/share/airoha-clanker-mode.uc "$expected_mode" >> "$destination/mode.log" 2>&1 || { reason=mode-mismatch; break; }
   fi
   { date -u; cat /proc/uptime; cat /sys/kernel/debug/ppe/bind; } >> "$destination/bind.log" 2>&1
  fi
  count=$((count + 1))
  kill -0 "$log_pid" 2>/dev/null || { reason=logread-exited; break; }
  sleep 10 & wait_pid=$!
  [ "$reason" = complete ] || kill "$wait_pid" 2>/dev/null
  wait "$wait_pid" 2>/dev/null; wait_pid=
 done
 kill "$log_pid" 2>/dev/null; wait "$log_pid" 2>/dev/null
 snapshot > "$destination/finish.log" 2>&1
 if [ -n "$expected_mode" ]; then
  ucode /usr/share/airoha-clanker-mode.uc "$expected_mode" >> "$destination/mode.log" 2>&1 || reason=mode-mismatch
 fi
 printf 'reason=%s samples=%s\n' "$reason" "$count" >> "$destination/manifest.txt"
 wifi_verify "$destination" > "$destination/coverage.txt" 2>&1 || :
 trap - INT TERM HUP
 [ "$reason" = complete ]
}
wifi_trace_snapshot() {
 local detail=${1:-1}
 section 'wireless NPU trace sample'; date -u; cat /proc/uptime
 for path in /sys/kernel/debug/ieee80211/phy*/mt76; do
  [ -d "$path" ] || continue
  printf 'debugfs=%s\n' "$path"
  for kind in kite_trace kite_events kite_tx kite_rx; do
   case "$kind:$detail" in kite_trace:0|kite_events:0) continue ;; esac
   [ -r "$path/$kind" ] || continue
   printf '\n[%s]\n' "$kind"; cat "$path/$kind"
  done
  break
 done
 section 'wireless datapath counters'
 : > "$dp_snapshot"
 for path in /sys/kernel/debug/ieee80211/phy*/mt76/kite_datapath; do
  [ -r "$path" ] || continue
  if [ "$detail" -eq 0 ] && [ -r "${path}_light" ]; then path="${path}_light"; fi
  cat "$path" > "$dp_snapshot"; break
 done
 if [ "$detail" -eq 1 ]; then cat "$dp_snapshot"; else
  awk '!/^r63_ps_event / && !/^sta[0-9]+ /' "$dp_snapshot"
 fi
 if [ "$detail" -eq 1 ]; then
 section 'wireless activation'
 airoha-clanker-diag --wifi 2>&1
 for iface in /sys/class/net/*; do
  [ -d "$iface/phy80211" ] || continue
  printf 'interface=%s operstate=' "${iface##*/}"
  cat "$iface/operstate" 2>/dev/null || echo unavailable
 done
 fi
 section 'host CPU and interface counters'
 CLANKER_DP_SNAPSHOT="$dp_snapshot" CLANKER_PERF_DETAIL="$detail" CLANKER_RECORDER_PID="${CLANKER_RECORDER_PID:-$$}" airoha-clanker-diag --perf
}
# Slow readout via native driver interfaces. tx_stats updates the driver's
# cumulative MIB counters under its mutex; never poke hardware registers here.
wifi_radio_snapshot() {
 section 'wireless rate and aggregation'; date -u; cat /proc/uptime
 for name in wed_enable npu_cached_hdr npu_perf npu_amsdu npu_profile npu_publish_batch; do
  printf '%s=' "$name"
  cat "/sys/module/mt7915e/parameters/$name" 2>/dev/null || echo unavailable
 done
 for iface in /sys/class/net/*; do
  [ -d "$iface/phy80211" ] || continue
  printf '\ninterface=%s\n' "${iface##*/}"
  iw dev "${iface##*/}" station dump
  iw dev "${iface##*/}" survey dump
 done
 echo 'aggregation_scope=AMSDU_sum_both_PHY_deltas_AMPDU_per_band'
 for path in /sys/kernel/debug/ieee80211/phy*/mt76/tx_stats /sys/kernel/debug/ieee80211/phy*/mt76/hw-queues /sys/kernel/debug/ieee80211/phy0/mt76/kite_aggregation; do
  [ -r "$path" ] || continue
  printf '\ndebugfs=%s\n' "$path"
  cat "$path"
 done
}
# r71: include internal LAN ports and conduit CPU-port private PAUSE.
wifi_ports_snapshot() {
 section 'r71 physical ports'; date -u; cat /proc/uptime
 for port in lan4 lan2 lan3 eth0 lan1; do
  printf '\nport=%s\n' "$port"
  if [ ! -d "/sys/class/net/$port" ]; then echo 'available=0'; continue; fi
  for group in private eth-ctrl eth-mac; do
   printf 'query=ethtool-S port=%s group=%s\n' "$port" "$group"
   # Fixed argument list; never accept external shell command text.
   set -- -S "$port"
   [ "$group" = private ] || set -- "$@" --groups "$group"
   read -r query_start unused < /proc/uptime
   printf 'query_begin=%s\n' "$query_start"
   timeout -k 1 2 ethtool "$@" 2>&1
   rc=$?
   read -r query_end unused < /proc/uptime
   printf 'query_end=%s\n' "$query_end"
    printf 'query_status=%s (nonzero=unsupported/error/timeout; not zero traffic)\n' "$rc"
  done
 done
 cat /proc/uptime
}
# Low-rate adjacent queue evidence. Cached NPU sysfs; no live mailbox from
# readers, no FOE walk, counter clearing, control writes or raw /dev/mem.
wifi_network_snapshot() {
 section 'r73 network sample'; date -u
 read -r stamp unused < /proc/uptime; echo "network_begin=$stamp"
 for path in /sys/bus/platform/devices/*/clanker_host_status /sys/bus/platform/devices/*/clanker_path_status /sys/bus/platform/devices/*/clanker_cost_status /sys/bus/platform/devices/*/clanker_prof_status /sys/bus/platform/devices/*/clanker_pc_status /sys/bus/platform/devices/*/clanker_queue_status /sys/bus/platform/devices/*/clanker_feed_status /sys/bus/platform/devices/*/switch_status /sys/kernel/debug/ppe/frame_status /sys/kernel/debug/ppe/queue_status; do
  printf '\nnode=%s\n' "$path"
  if [ -r "$path" ]; then cat "$path"; else echo unavailable; fi
 done
 if [ -r /sys/kernel/debug/clk/clk_summary ]; then
  echo 'clock_source=CCF_reported_rate'; awk 'NR<=3 || /gsw|sys_bus|cpu/' /sys/kernel/debug/clk/clk_summary
 else echo clock=unavailable; fi
 section 'BQL bytes (individual gauges, not packet completion counters)'
 for port in eth0 lan1 lan2 lan3 lan4; do
  for queue in /sys/class/net/"$port"/queues/tx-*; do
   [ -d "$queue" ] || continue
   printf 'bql port=%s queue=%s' "$port" "${queue##*/}"
   for field in inflight limit; do
    printf ' %s=' "$field"
    if [ -r "$queue/byte_queue_limits/$field" ]; then
     tr -d '\n' < "$queue/byte_queue_limits/$field"
    else printf unavailable; fi
   done
   printf '\n'
  done
 done
 wifi_forwarding_snapshot
 wifi_queue_snapshot
 section 'softnet'; cat /proc/net/softnet_stat
 section 'IRQ'; cat /proc/interrupts
 section 'software flow handoffs'; cat /proc/net/stat/nf_flowtable 2>/dev/null || echo unavailable
 read -r stamp unused < /proc/uptime; echo "network_end=$stamp"
}
# Queue reads have no hardware writes or counter resets. Loss events are
# metadata only, bounded by the driver; unsupported is never zero losses.
wifi_queue_snapshot() {
 section 'r78 native wireless queues'; cat /proc/uptime
 for phy in /sys/kernel/debug/ieee80211/phy*; do
  [ -d "$phy" ] || continue
  for path in "$phy/aqm" "$phy/queue_loss" "$phy"/netdev:*/stations/*/aqm; do
   printf 'queue_node=%s\n' "$path"
   if [ -r "$path" ]; then
    timeout -k 1 2 cat "$path" || echo queue_read_failed=1
   else echo queue_unavailable=1; fi
  done
 done
}
wifi_light_snapshot() {
 section 'r78 light counters'; date -u
 cat /proc/uptime /proc/stat /proc/net/dev
 echo recorder_proc_stat
 cat "/proc/${CLANKER_RECORDER_PID:-$$}/stat" 2>/dev/null || :
 for path in /sys/bus/platform/devices/*/clanker_status /sys/bus/platform/devices/*/clanker_queue_status; do
  [ ! -r "$path" ] || cat "$path"
 done
 for path in /sys/kernel/debug/ieee80211/phy*/mt76/kite_datapath_light; do
  [ -r "$path" ] || continue
  cat "$path"; break
 done
}
wifi_forwarding_snapshot() {
 section 'r72 forwarding: kernel bridge + driver self FDB, neighbours'
 cat /proc/uptime
 timeout -k 1 2 bridge -s fdb show
 printf 'fdb_query_status=%s\n' "$?"
 timeout -k 1 2 ip neigh show
 printf 'neigh_query_status=%s\n' "$?"
 # The default PF_BRIDGE dump includes both bridge-master and DSA self FDB.
 # Keep "self" vs "master" in raw output; do not infer offload from one row.
}
wifi_flow_snapshot() {
 section 'r72 bound FOE and test conntrack (low frequency)'; date -u; cat /proc/uptime
 # Contains r75 PS empty/parked and policy lifecycle counters. Read at the
 # existing slow cadence: status takes the flow mutex, unlike cached KF1.
 echo 'node=/sys/kernel/debug/ppe/status'
 timeout -k 1 4 cat /sys/kernel/debug/ppe/status
 printf 'ppe_status_query_status=%s\n' "$?"
 timeout -k 1 4 cat /sys/kernel/debug/ppe/bind
 printf 'bind_query_status=%s\n' "$?"
 if [ -r /proc/net/nf_conntrack ]; then
  awk '/(sport|dport)=520[12]([ ]|$)/' /proc/net/nf_conntrack
 elif command -v conntrack >/dev/null; then
  timeout -k 1 3 conntrack -L 2>/dev/null | awk '/(sport|dport)=520[12]([ ]|$)/'
 else echo conntrack_unavailable; fi
 cat /proc/uptime
}
wifi_fdb_events() {
 ulimit -f 4096
 exec timeout -k 2 "$1" bridge -t monitor fdb
}
wifi_topology_snapshot() {
 section 'r72 topology (lan1 role is not changed)'; date -u; cat /proc/uptime
 timeout -k 1 3 ip -d -s link
 timeout -k 1 2 ip -4 route
 for kind in link vlan fdb; do timeout -k 1 2 bridge "$kind" show; done
 for port in lan4 lan2 lan3 eth0 lan1; do
  [ -d "/sys/class/net/$port" ] || continue
  printf '\nport=%s\n' "$port"
  timeout -k 1 2 ethtool "$port"
  timeout -k 1 2 ethtool --show-eee "$port"
  timeout -k 1 2 ethtool -a "$port"
  timeout -k 1 2 ethtool -k "$port"
  timeout -k 1 2 tc -s qdisc show dev "$port"
  timeout -k 1 2 tc -s class show dev "$port"
 done
 timeout -k 1 3 nft list table bridge fw4
 cat /proc/uptime
}
wifi_link_timeline() {
 local duration=$1 begin now unused
 ulimit -f 8192
 read -r begin unused < /proc/uptime; begin=${begin%.*}
 while :; do
  read -r now unused < /proc/uptime
  [ "$(( ${now%.*} - begin ))" -lt "$duration" ] || break
  printf 'sample_begin=%s\n' "$now"
  cat /proc/net/dev /proc/stat
  read -r now unused < /proc/uptime
  printf 'sample_end=%s\n' "$now"
  sleep 1
 done
}
# Control histories are separate from full datapath/PHY snapshots. Keep
# only new events, report overwritten intervals, and never clear kernel rings.
wifi_events() {
 local directory=$1 kind path last rc
 for kind in flow ps; do
  path=/sys/kernel/debug/ppe/kite_history
  if [ "$kind" = ps ]; then
   path=
   for candidate in /sys/kernel/debug/ieee80211/phy*/mt76/kite_ps_history; do
    [ ! -r "$candidate" ] || { path=$candidate; break; }
   done
  fi
  if [ ! -r "$path" ]; then printf 'events_unavailable=%s\n' "$kind"; continue; fi
  last=0; [ ! -r "$directory/.event-$kind" ] || read -r last < "$directory/.event-$kind"
  timeout -k 1 2 cat "$path" > "$directory/.event-current-$kind"
  rc=$?; [ "$rc" -eq 0 ] || { printf 'events_read_failed=%s rc=%s\n' "$kind" "$rc"; continue; }
  awk -v last="$last" -v kind="$kind" -v state="$directory/.event-$kind" '
   /_ring / {print;for(i=1;i<=NF;i++)if($i ~ /^last=/){split($i,a,"=");if(a[2]+0<last){print "events_gap=" kind " serial_reset_after=" last;last=0;print 0 >state}}next}
   /^r76_flow / || /^r63_ps_event / {
    seq=0; for(i=1;i<=NF;i++) if($i ~ /^(seq|serial)=/) {split($i,a,"=");seq=a[2]+0}
    if(seq>last){print;if(!first||seq<first)first=seq;if(seq>max)max=seq}
   }
   END {
    if(last && first>last+1)print "events_gap=" kind " after=" last " next=" first;
    if(max>last)print max >state;
   }' "$directory/.event-current-$kind"
 done
}
# On a new terminal loss counter, retain adjacent snapshots plus the
# already-collected control history. At most eight bundles per recording.
wifi_drop_checkpoint() {
 local directory=$1 current=$2 value previous count=0
 value=$(awk '/^band[01] / {for(i=1;i<=NF;i++)if($i ~ /^(tx_drop|host_fallback_drop)=/){split($i,a,"=");n+=a[2]}}END{print n+0}' "$current")
 if [ -r "$directory/.last-drop" ]; then
  read -r previous count < "$directory/.last-drop"
  if [ "$value" != "$previous" ]; then
   printf 'drop_change previous=%s current=%s bundle=%s uptime=' "$previous" "$value" "$count" >> "$directory/events.log"
   cat /proc/uptime >> "$directory/events.log"
   if [ "$count" -lt 8 ]; then
    [ ! -s "$directory/.previous-datapath" ] || cp "$directory/.previous-datapath" "$directory/drop-$count-before.log"
    cp "$current" "$directory/drop-$count-after.log"
    cp "$directory/events.log" "$directory/drop-$count-events.log"
    count=$((count+1))
   fi
  fi
 fi
 printf '%s %s\n' "$value" "$count" > "$directory/.last-drop"
 cp "$current" "$directory/.previous-datapath"
}
wifi_queue_coverage() {
 local directory=$1 file
 for file in queues-start.log start.log network.log queues-finish.log finish.log; do
  [ ! -r "$directory/$file" ] || cat "$directory/$file"
 done | awk '
  /^queue_node=/ {node=$0}
  /^queue_loss_ring / || /^queue_burst_ring / {
   kind=$1;first=last=0;
   for(i=2;i<=NF;i++){split($i,a,"=");if(a[1]=="first")first=a[2]+0;if(a[1]=="last")last=a[2]+0}
   key=node SUBSEP kind;
   if(key in seen && last>=seen[key] && first>seen[key]+1) gap[kind]++;
   if(!(key in seen)||last>seen[key])seen[key]=last;
   found[kind]++;
  }
  END {
   print "queue_packet_coverage=" (found["queue_loss_ring"]?(gap["queue_loss_ring"]?"PARTIAL":"AVAILABLE"):"MISSING");
   print "queue_burst_coverage=" (found["queue_burst_ring"]?(gap["queue_burst_ring"]?"PARTIAL":"AVAILABLE"):"MISSING");
   print "queue_scope=boundary_or_periodic_snapshots cumulative_counters_retained no_peer_delivery_proof";
  }'
}
# Report evidence availability, never turn missing/failed tests into PASS.
wifi_verify() {
 local directory=$1 bounds started finished reason
 [ -r "$directory/manifest.txt" ] || return 2
 [ -s "$directory/finish.log" ] || { echo 'coverage=FAIL missing_finish'; return 1; }
 [ -s "$directory/markers.log" ] || { echo 'coverage=INCOMPLETE missing_window_markers'; return 1; }
 bounds=$(awk '{for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="started_uptime")s=a[2];if(a[1]=="finished_uptime")f=a[2];if(a[1]=="reason")r=a[2]}}END{print s,f,r}' "$directory/manifest.txt")
 read -r started finished reason <<EOF
$bounds
EOF
 case "$reason" in complete|stopped) ;; *) echo "coverage=FAIL recorder_reason=$reason"; return 1;; esac
 awk -v started="$started" -v finished="$finished" '
  {u=0;l="";for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="uptime")u=a[2];if(a[1]=="label")l=a[2]}}
  l ~ /^begin-/ {k=substr(l,7);if(k in begin || u<started || u>finished)bad++;begin[k]=u;next}
  l ~ /^end-/ {k=substr(l,5);sub(/-rc[0-9]+$/,"",k);if(!(k in begin)||u<begin[k]||u>finished)bad++;else{done[k]=1;print "window=" k " begin=" begin[k] " end=" u " status=" l}if(l !~ /-rc0$/)bad++}
  END {for(k in begin){count++;if(!(k in done)){print "missing_end=" k;bad++}}print "coverage=" (bad||!count?"FAIL":"PASS") " windows=" count " errors=" bad;exit(bad||!count)}' "$directory/markers.log" || return 1
 wifi_queue_coverage "$directory"
 if [ -s "$directory/errors.log" ]; then echo 'coverage=INCOMPLETE collector_errors'; return 1; fi
 if grep -q 'recording_mode=light' "$directory/manifest.txt"; then
  echo 'event_coverage=not_collected light_mode; boundary_counters_only'
  return 0
 fi
 [ -s "$directory/events.log" ] || { echo "coverage=INCOMPLETE missing_events"; return 1; }
 if grep -qE 'events_(gap|unavailable|read_failed)=' "$directory/events.log"; then
  echo 'coverage=INCOMPLETE event_history_gap'; return 1
 fi
}
wifi_bounded() (
 # RLIMIT_FSIZE limits the WHOLE destination file, including an existing
 # append offset. Bound each new sample separately so a healthy trace can
 # grow past 8 MiB on BusyBox while the outer 32 MiB budget remains active.
 sample_file=$(mktemp "${destination:-${TMPDIR:-/tmp}}/.clanker-sample.XXXXXX") || exit 1
 trap 'rm -f "$sample_file"' EXIT
 (
  ulimit -f 16384
  exec timeout -k 2 25 "$0" "$@"
 ) > "$sample_file"
 sample_rc=$?
 # Keep even a failed/truncated sample for diagnosis, preserving its exit
 # status. This parent did not lower its file limit on the append target.
 cat "$sample_file" || exit 1
 exit "$sample_rc"
)
# Same flow parameters, much less collection during traffic. Do not claim
# event coverage from this mode; detailed mode supplies the causal evidence.
record_wifi_light() {
 destination=$1; seconds=${2:-180}
 case "$seconds" in ''|*[!0-9]*) return 2;; esac
 [ "$seconds" -ge 30 ] && [ "$seconds" -le 1200 ] || return 2
 command -v timeout >/dev/null || return 2
 [ -n "$destination" ] && (umask 077; mkdir "$destination") || return 2
 umask 077
 reason=complete; wait_pid=; count=0
 trap 'reason=interrupted; [ -z "$wait_pid" ] || kill "$wait_pid" 2>/dev/null' INT TERM HUP
 export CLANKER_RECORDER_PID=$$
 read -r started junk < /proc/uptime; started=${started%.*}
 printf 'schema=10 collector_fix=79 recording_mode=light seconds=%s sleep_seconds=20 pid=%s started_uptime=%s\nreason=running\n' "$seconds" "$$" "$started" > "$destination/manifest.txt"
 { date -u; cat /proc/sys/kernel/random/boot_id; cat /lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt; } > "$destination/identity.log" 2>&1
 wifi_bounded --wifi-light > "$destination/start.log" 2>&1 || reason=start-failed
 wifi_bounded --wifi-radio > "$destination/radio-start.log" 2>&1 || echo radio_start_failed >> "$destination/errors.log"
 wifi_bounded --wifi-queues > "$destination/queues-start.log" 2>&1 || echo queues_start_failed >> "$destination/errors.log"
 echo "RECORD_READY mode=light directory=$destination"
 while [ "$reason" = complete ]; do
  read -r now junk < /proc/uptime
  [ ! -f "$destination/stop.request" ] || { reason=stopped; break; }
  [ "$(( ${now%.*} - started ))" -lt "$seconds" ] || break
  wifi_bounded --wifi-light >> "$destination/trace.log" 2>> "$destination/errors.log" || { reason=sample-failed; break; }
  count=$((count+1))
  set -- $(du -sk "$destination"); [ "$1" -lt 32768 ] || { reason=size-limit; break; }
  sleep 20 & wait_pid=$!
  [ "$reason" = complete ] || kill "$wait_pid" 2>/dev/null
  wait "$wait_pid" 2>/dev/null; wait_pid=
 done
 wifi_bounded --wifi-light > "$destination/finish.log" 2>&1 || echo finish_failed >> "$destination/errors.log"
 wifi_bounded --wifi-radio > "$destination/radio-finish.log" 2>&1 || echo radio_finish_failed >> "$destination/errors.log"
 wifi_bounded --wifi-queues > "$destination/queues-finish.log" 2>&1 || echo queues_finish_failed >> "$destination/errors.log"
 read -r now junk < /proc/uptime
 printf 'reason=%s samples=%s finished_uptime=%s\n' "$reason" "$count" "$now" >> "$destination/manifest.txt"
 wifi_verify "$destination" > "$destination/coverage.txt" 2>&1 || :
 trap - INT TERM HUP
 [ "$reason" = complete ] || [ "$reason" = stopped ]
}
record_wifi() {
 destination=$1; seconds=${2:-180}
 case "$seconds" in ''|*[!0-9]*) return 2 ;; esac
 [ "$seconds" -ge 30 ] && [ "$seconds" -le 1200 ] || return 2
 command -v timeout >/dev/null || { echo 'timeout is required' >&2; return 2; }
 [ -n "$destination" ] && (umask 077; mkdir "$destination") || return 2
 umask 077
 reason=complete; wait_pid=; log_pid=; link_pid=; fdb_pid=; count=0
 trap 'reason=interrupted; [ -z "$wait_pid" ] || kill "$wait_pid" 2>/dev/null' INT TERM HUP
 dp_snapshot="$destination/.datapath-current"
 export CLANKER_RECORDER_PID=$$
 read -r started junk < /proc/uptime; started=${started%.*}
 printf 'schema=10 collector_fix=79 recording_mode=full sample_limit=per_invocation events_delta=1 feed_FE1=1 ppe_status=1 queue_KF1=1 explicit_stop=1 markers=1 cost_KC1=1 aggregation=1 switch_PHY=1 fdb_events=1 forwarding_every=2_samples network_every=2_samples topology_start_end=1 bind_every=6_samples detail_every=6_samples single_datapath_read=1 seconds=%s sleep_seconds=5 fast_sleep_seconds=1 pid=%s started_uptime=%s max_total_kib=32768; read-only\nreason=running\n' "$seconds" "$$" "$started" > "$destination/manifest.txt"
 {
  section 'record identity'; date -u
  cat /proc/uptime /proc/sys/kernel/random/boot_id
  timeout -k 1 3 ubus call system board
  cat /lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt
  section 'offload mode (read-only)'
  timeout -k 1 5 ucode /usr/share/airoha-clanker-mode.uc
  section 'IPv4 routes'; ip -4 route
 } > "$destination/identity.log" 2>&1
 wifi_bounded --wifi-flows > "$destination/flows.log" 2>&1 || echo flows_start_failed >> "$destination/errors.log"
 wifi_bounded --wifi-topology > "$destination/topology-start.log" 2>&1 || echo topology_start_failed >> "$destination/errors.log"
 wifi_bounded --wifi-network > "$destination/network.log" 2>&1 || echo network_start_failed >> "$destination/errors.log"
 wifi_bounded --wifi-sample "$dp_snapshot" 1 > "$destination/start.log" 2>&1 || reason=start-failed
 wifi_bounded --wifi-events "$destination" > "$destination/events.log" 2>> "$destination/errors.log" || echo events_start_failed >> "$destination/errors.log"
 wifi_drop_checkpoint "$destination" "$dp_snapshot"
 wifi_bounded --wifi-radio > "$destination/radio.log" 2>&1 || echo radio_start_failed >> "$destination/errors.log"
 wifi_bounded --wifi-ports > "$destination/ports.log" 2>&1 || echo ports_start_failed >> "$destination/errors.log"
 if [ "$reason" = complete ] && [ ! -f "$destination/stop.request" ]; then
  logread -f -F "$destination/system.log" -S 4096 &
  log_pid=$!
  timeout -k 2 "$seconds" "$0" --link-timeline "$seconds" > "$destination/link-timeline.log" 2>&1 &
  link_pid=$!
  "$0" --fdb-events "$seconds" > "$destination/fdb-events.log" 2>&1 &
  fdb_pid=$!
 fi
 echo "RECORD_READY mode=full directory=$destination"
 while [ "$reason" = complete ]; do
  read -r now junk < /proc/uptime
  [ ! -f "$destination/stop.request" ] || { reason=stopped; break; }
  [ "$(( ${now%.*} - started ))" -lt "$seconds" ] || break
  printf 'sample=%s begin=%s\n' "$count" "$now" >> "$destination/timing.log"
  wifi_bounded --wifi-events "$destination" >> "$destination/events.log" 2>> "$destination/errors.log" || echo events_sample_failed >> "$destination/errors.log"
  detail=0; [ "$((count % 6))" -eq 0 ] && detail=1
  wifi_bounded --wifi-sample "$dp_snapshot" "$detail" >> "$destination/trace.log" 2>> "$destination/errors.log" || { reason=sample-failed; break; }
  wifi_drop_checkpoint "$destination" "$dp_snapshot"
  [ "$((count % 2))" -ne 0 ] || wifi_bounded --wifi-network >> "$destination/network.log" 2>&1 || echo network_sample_failed >> "$destination/errors.log"
  [ "$((count % 2))" -ne 0 ] || wifi_bounded --wifi-ports >> "$destination/ports.log" 2>&1 || echo ports_sample_failed >> "$destination/errors.log"
  [ "$((count % 6))" -ne 0 ] || wifi_bounded --wifi-flows >> "$destination/flows.log" 2>&1 || echo flows_sample_failed >> "$destination/errors.log"
  [ "$((count % 3))" -ne 0 ] || wifi_bounded --wifi-radio >> "$destination/radio.log" 2>&1 || echo radio_sample_failed >> "$destination/errors.log"
  read -r now junk < /proc/uptime
  printf 'sample=%s end=%s\n' "$count" "$now" >> "$destination/timing.log"
  count=$((count + 1))
  set -- $(du -sk "$destination")
  [ "$1" -lt 28672 ] || printf "budget_warning kib=%s cap=32768\n" "$1" >> "$destination/events.log"
  [ "$1" -lt 32768 ] || { reason=size-limit; break; }
  kill -0 "$log_pid" 2>/dev/null || { reason=logread-exited; break; }
  kill -0 "$link_pid" 2>/dev/null || { reason=timeline-exited; break; }
  sleep 5 & wait_pid=$!
  [ "$reason" = complete ] || kill "$wait_pid" 2>/dev/null
  wait "$wait_pid" 2>/dev/null; wait_pid=
 done
 [ -z "$fdb_pid" ] || kill "$fdb_pid" 2>/dev/null
 [ -z "$log_pid" ] || kill "$log_pid" 2>/dev/null
 [ -z "$link_pid" ] || kill "$link_pid" 2>/dev/null
 [ -z "$fdb_pid" ] || wait "$fdb_pid" 2>/dev/null
 [ -z "$log_pid" ] || wait "$log_pid" 2>/dev/null
 [ -z "$link_pid" ] || wait "$link_pid" 2>/dev/null
 wifi_bounded --wifi-sample "$dp_snapshot" 1 > "$destination/finish.log" 2>&1 || echo finish_failed >> "$destination/errors.log"
 wifi_bounded --wifi-radio >> "$destination/radio.log" 2>&1 || echo radio_finish_failed >> "$destination/errors.log"
 wifi_bounded --wifi-ports >> "$destination/ports.log" 2>&1 || echo ports_finish_failed >> "$destination/errors.log"
 wifi_bounded --wifi-network >> "$destination/network.log" 2>&1 || echo network_finish_failed >> "$destination/errors.log"
 wifi_bounded --wifi-flows >> "$destination/flows.log" 2>&1 || echo flows_finish_failed >> "$destination/errors.log"
 wifi_bounded --wifi-topology > "$destination/topology-finish.log" 2>&1 || echo topology_finish_failed >> "$destination/errors.log"
 wifi_bounded --wifi-events "$destination" >> "$destination/events.log" 2>> "$destination/errors.log" || echo events_finish_failed >> "$destination/errors.log"
 wifi_drop_checkpoint "$destination" "$dp_snapshot"
 rm -f "$dp_snapshot" "$destination/.previous-datapath" "$destination/.event-current-flow" "$destination/.event-current-ps"
 read -r now junk < /proc/uptime
 printf 'reason=%s samples=%s finished_uptime=%s\n' "$reason" "$count" "$now" >> "$destination/manifest.txt"
 wifi_verify "$destination" > "$destination/coverage.txt" 2>&1 || :
 trap - INT TERM HUP
 [ "$reason" = complete ] || [ "$reason" = stopped ]
}
# Physical and switch evidence is collected outside each wired traffic
# window, including light mode. Query failures stay explicit in the log.
wifi_wired_boundary() {
 section 'r78 wired boundary: GSW PHY BQL PAUSE'; date -u; cat /proc/uptime
 for path in /sys/bus/platform/devices/*/switch_status /sys/kernel/debug/ppe/frame_status /sys/kernel/debug/ppe/queue_status; do
  printf 'node=%s\n' "$path"
  if [ -r "$path" ]; then cat "$path"; else echo unavailable; fi
 done
 wifi_ports_snapshot
 wifi_topology_snapshot
 cat /proc/uptime
}
# Markers contain only data. Never evaluate a path, label or recorded PID.
wifi_mark() {
 directory=$1; label=$2
 [ -d "$directory" ] && [ -f "$directory/manifest.txt" ] || return 2
 case "$label" in ''|*[!a-zA-Z0-9_.-]*) return 2;; esac
 [ "${#label}" -le 80 ] || return 2
 case "$label" in begin-wired-*)
  wifi_bounded --wifi-wired-boundary > "$directory/boundary-$label.log" 2>&1 || {
   echo "boundary_failed=$label" >> "$directory/errors.log"; return 1;
  };; esac
 read -r stamp unused < /proc/uptime
 printf 'uptime=%s label=%s\n' "$stamp" "$label" >> "$directory/markers.log"
 case "$label" in end-wired-*)
  wifi_bounded --wifi-wired-boundary > "$directory/boundary-$label.log" 2>&1 || {
   echo "boundary_failed=$label" >> "$directory/errors.log"; return 1;
  };; esac
}
case "${1:-}" in
 '') snapshot ;;
 --check-mode) ucode /usr/share/airoha-clanker-mode.uc "${2:-invalid}" ;;
 --record-mode) record "${3:-}" "${4:-10}" "${2:-invalid}" ;;
 --record) record "${2:-}" "${3:-10}" ;;
 --wifi-events) wifi_events "$2" ;;
 --verify) wifi_verify "$2" ;;
 --wifi-sample) dp_snapshot=$2; wifi_trace_snapshot "$3" ;;
 --wifi-radio) wifi_radio_snapshot ;;
 --wifi-queues) wifi_queue_snapshot ;;
 --wifi-wired-boundary) wifi_wired_boundary ;;
 --wifi-light) wifi_light_snapshot ;;
 --wifi-network) wifi_network_snapshot ;;
 --wifi-topology) wifi_topology_snapshot ;;
 --wifi-flows) wifi_flow_snapshot ;;
 --wifi-ports) wifi_ports_snapshot ;;
 --link-timeline) case "$2" in ''|*[!0-9]*) exit 2;; esac; [ "$2" -le 1200 ] || exit 2; wifi_link_timeline "$2" ;;
 --fdb-events) case "$2" in ''|*[!0-9]*) exit 2;; esac; [ "$2" -ge 30 ] && [ "$2" -le 1200 ] || exit 2; wifi_fdb_events "$2" ;;
 --mark) wifi_mark "${2:-}" "${3:-}" ;;
 --stop) wifi_mark "${2:-}" stop-request && (umask 077; : > "$2/stop.request") ;;
 --record-wifi-light) record_wifi_light "${2:-}" "${3:-180}" ;;
 --record-wifi|--record-lan) record_wifi "${2:-}" "${3:-180}" ;;
 *) echo 'Usage: airoha-clanker-offload [--record NEW_DIR MINUTES | --record-mode MODE NEW_DIR MINUTES | --record-wifi NEW_DIR SECONDS | --record-wifi-light NEW_DIR SECONDS | --record-lan NEW_DIR SECONDS | --mark DIR LABEL | --stop DIR | --check-mode MODE]; MODE=off|software|hardware, MINUTES=1..120, SECONDS=30..1200' >&2; exit 2 ;;
esac
