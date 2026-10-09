#!/bin/sh
# Read-only collector for both ponwrt and upstream OpenWrt. No Kite dependency.
umask 077
query() {
 printf '\nquery='; printf '%s ' "$@"; printf '\n'
 timeout -k 1 2 "$@" 2>&1
 printf 'query_status=%s\n' "$?"
}
snapshot() {
 echo 'lan_schema=1 role_lan1=WAN no_configuration_changes=1'
 date -u; cat /proc/uptime
 for path in /sys/bus/platform/devices/*/switch_status; do
  echo "node=$path"
  if [ -r "$path" ]; then cat "$path"; else echo 'switch_registers=unavailable requires_readonly_driver_interface'; fi
 done
 echo 'clock_source=CCF_reported_rate_not_external_frequency_measurement'
 if [ -r /sys/kernel/debug/clk/clk_summary ]; then
  awk 'NR<=3 || /gsw|en7581|sys_bus|cpu/' /sys/kernel/debug/clk/clk_summary
 else echo clock=unavailable; fi
 for port in lan1 lan2 lan3 lan4 eth0; do
  [ -d "/sys/class/net/$port" ] || continue
  echo "port=$port"
  for field in speed duplex carrier operstate mtu; do
   printf '%s=' "$field"; cat "/sys/class/net/$port/$field" 2>/dev/null || echo unavailable
  done
  query ethtool "$port"
  query ethtool -a "$port"
  query ethtool --show-eee "$port"
  query ethtool -S "$port"
 done
 query bridge -d link show
 query bridge -s fdb show
 query bridge vlan show
 query tc -s qdisc show
 query ip -s link show
 echo 'cpu'; cat /proc/stat
 echo 'softnet'; cat /proc/net/softnet_stat
 echo 'interrupts'; cat /proc/interrupts
 cat /proc/uptime
}
case "$1" in
 --snapshot) snapshot ;;
 --record)
  seconds=$2; destination=$3
  case "$seconds" in ''|*[!0-9]*) echo 'duration must be 60..900 seconds' >&2; exit 2;; esac
  [ "$seconds" -ge 60 ] && [ "$seconds" -le 900 ] && [ -n "$destination" ] && [ ! -e "$destination" ] || exit 2
  mkdir -m 700 "$destination" || exit 2
  echo "lan_schema=1 seconds=$seconds interval=10 max_kib=8192" > "$destination/manifest.txt"
  ubus call system board > "$destination/board.json" 2>&1
  uname -a > "$destination/version.txt"
  cat /etc/openwrt_release >> "$destination/version.txt"
  read -r start unused < /proc/uptime; start=${start%.*}
  trap 'echo interrupted >> "$destination/manifest.txt"; exit 1' INT TERM
  while :; do
   read -r now unused < /proc/uptime; now=${now%.*}
   [ "$((now-start))" -lt "$seconds" ] || break
   timeout -k 2 30 "$0" --snapshot >> "$destination/lan.log" 2>&1
   echo "snapshot_status=$?" >> "$destination/lan.log"
   size=$(du -sk "$destination" | awk '{print $1}')
   [ "$size" -lt 8192 ] || { echo size_limit >> "$destination/manifest.txt"; exit 1; }
   sleep 10
  done
  echo complete >> "$destination/manifest.txt"
  ;;
 *) echo "Usage: $0 --snapshot | --record SECONDS NEW_DIRECTORY" >&2; exit 2;;
esac
