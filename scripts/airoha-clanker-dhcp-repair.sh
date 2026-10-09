#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Re-evaluate the configured LAN DHCP pool. No UCI/firewall/PN/offload changes.
# dnsmasq restart also briefly interrupts DNS service; collect evidence first.
export LC_ALL=C
umask 077
[ "${1:-}" = --lan ] || { echo 'Usage: airoha-clanker-dhcp-repair --lan'; exit 2; }
. /lib/functions.sh
. /lib/functions/network.sh
[ "$(uci -q get dhcp.lan.interface)" = lan ] &&
[ "$(uci -q get dhcp.lan.dhcpv4)" = server ] &&
[ "$(uci -q get dhcp.lan.ignore)" != 1 ] &&
network_get_device dhcp_repair_dev lan &&
network_get_protocol dhcp_repair_proto lan &&
[ "$dhcp_repair_proto" = static ] &&
network_get_subnet dhcp_repair_subnet lan || {
 echo 'LAN is not a ready, static, configured DHCPv4 server; no service change made.' >&2
 exit 2
}
dhcp_repair_dir=$(mktemp -d /tmp/clanker-dhcp-repair.XXXXXX) || exit 1
snapshot() {
 date -u
 printf 'device=%s subnet=%s\n' "$dhcp_repair_dev" "$dhcp_repair_subnet"
 ubus call network.interface.lan status
 for dhcp_repair_file in /var/etc/dnsmasq.conf.*; do
  [ -r "$dhcp_repair_file" ] || continue
  printf '\nfile=%s\n' "$dhcp_repair_file"
  awk '/^(# dhcp-|dhcp-range=|no-dhcp-interface=|interface=|except-interface=)/' "$dhcp_repair_file"
 done
 for dhcp_repair_file in /var/run/dnsmasq.*.dhcp; do
  [ -r "$dhcp_repair_file" ] || continue
  printf '%s=' "$dhcp_repair_file"; cat "$dhcp_repair_file"
 done
 netstat -lnup
 logread | grep -Ei 'dnsmasq|dhcp' | tail -n 120
}
snapshot > "$dhcp_repair_dir/before.log" 2>&1
printf 'Restarting dnsmasq to recheck the LAN pool; DNS pauses briefly. Evidence: %s\n' "$dhcp_repair_dir"
/etc/init.d/dnsmasq restart > "$dhcp_repair_dir/restart.log" 2>&1
dhcp_repair_rc=$?
sleep 3
snapshot > "$dhcp_repair_dir/after.log" 2>&1
printf 'restart_exit=%s\n' "$dhcp_repair_rc" > "$dhcp_repair_dir/result.txt"
printf 'Saved: %s\n' "$dhcp_repair_dir"
awk '/^(# dhcp-|dhcp-range=|no-dhcp-interface=)/' /var/etc/dnsmasq.conf.* 2>/dev/null
netstat -lnup 2>/dev/null | awk '$1 ~ /^udp/ && $4 ~ /:67$/ {print}'
echo 'Now reconnect one client on each band and verify the lease and gateway. A listener alone is not DHCP acceptance.'
exit "$dhcp_repair_rc"
