#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Standalone or installed diagnostic. Passive snapshots and DHCP/ARP capture.
# No station/MCU queries, service/config changes, or offload changes.
export LC_ALL=C
umask 077

seconds=${1:-120}
case "$seconds" in ''|*[!0-9]*) echo 'Usage: sh airoha-clanker-dhcp-diag.sh [30..300 seconds]' >&2; exit 2 ;; esac
[ "$seconds" -ge 30 ] && [ "$seconds" -le 300 ] || exit 2
destination=$(mktemp -d /tmp/clanker-dhcp.XXXXXX) || exit 1
capture_ifaces=
capture_pids=
log_pid=
wait_pid=
reason=complete
# Prefer the matching script when both files were copied to /tmp. Do not
# replace installed files just to collect evidence from an older image.
diag_script=${0%/*}/airoha-clanker-diag.sh
[ -r "$diag_script" ] || diag_script=/usr/sbin/airoha-clanker-diag

section() { printf '\n--- %s ---\n' "$*"; }
add_interface() {
	case "$1" in ''|*[!a-zA-Z0-9_.:-]*) return ;; esac
	[ -d "/sys/class/net/$1" ] || return
	case " $capture_ifaces " in *" $1 "*) return ;; esac
	capture_ifaces="$capture_ifaces $1"
}
add_bridge() {
	local member
	add_interface "$1"
	for member in "/sys/class/net/$1/brif/"*; do
		[ -e "$member" ] || continue
		add_interface "${member##*/}"
	done
}

# Discover both APs and their actual bridge members, including wired controls.
add_bridge br-lan
lan_device=$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
[ -z "$lan_device" ] || add_bridge "$lan_device"
for phy_path in /sys/class/net/*/phy80211; do
	[ -d "$phy_path" ] || continue
	iface=${phy_path%/phy80211}
	iface=${iface##*/}
	add_interface "$iface"
	master=$(readlink "/sys/class/net/$iface/master" 2>/dev/null)
	[ -z "$master" ] || add_bridge "${master##*/}"
done
printf '%s\n' $capture_ifaces > "$destination/interfaces.txt"

snapshot() {
	local iface field config_file
	section 'time and boot'
	date -u
	cat /proc/uptime /proc/sys/kernel/random/boot_id
	section 'NPU transport, security, RX fence and DP counters'
	timeout 15 sh "$diag_script" --status
	section 'AP link state (station/MCU queries deliberately excluded)'
	for iface in $capture_ifaces; do
		[ -d "/sys/class/net/$iface/phy80211" ] || continue
		printf '\ninterface=%s\n' "$iface"
		cat "/sys/class/net/$iface/operstate"
	done
	section 'IP, neighbours and netdev counters'
	ip -4 addr show
	ip -s link show
	ip -4 neigh show
	section 'bridge ports and VLANs'
	bridge link show
	bridge vlan show
	for iface in $capture_ifaces; do
		[ -d "/sys/class/net/$iface/brport" ] || continue
		for field in state isolated locked learning flood bcast_flood multicast_flood; do
			[ -r "/sys/class/net/$iface/brport/$field" ] || continue
			printf '%s %s=' "$iface" "$field"
			cat "/sys/class/net/$iface/brport/$field"
		done
	done
	section 'DHCP leases'
	[ ! -r /tmp/dhcp.leases ] || cat /tmp/dhcp.leases
	section 'DHCP service during capture'
	pidof dnsmasq
	netstat -lnup 2>/dev/null | awk '$1 ~ /^udp/ && $4 ~ /:67$/ {print; n++} END {if (!n) print "udp67_listener=absent"}'
	for config_file in /var/etc/dnsmasq.conf.*; do
		[ -r "$config_file" ] || continue
		printf 'file=%s\n' "$config_file"
		awk '/^(# dhcp-|dhcp-range=|no-dhcp-interface=)/' "$config_file"
	done
}

configuration() {
	local config_file
	section 'running candidate identity'
	uname -a
	ubus call system board
	cat /lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt
	sha256sum /lib/modules/*/mt76.ko /lib/modules/*/mt7915e.ko \
		/lib/firmware/airoha/en7581_MT7916_npu_*.bin
	section 'Wi-Fi network binding, without keys'
	timeout 15 sh "$diag_script" --wifi
	section 'LAN runtime'
	ubus call network.interface.lan status
	ip -4 route show
	section 'DHCP UCI allowlist'
	uci -q show dhcp | awk -F= '
		($1 ~ /^dhcp\.[^.]+$/ && $2 ~ /^(dnsmasq|dhcp)$/) ||
		$1 ~ /^dhcp\.[^.]+\.(interface|instance|networkid|netmask|ignore|start|limit|leasetime|dhcpv4|dynamicdhcp|force|authoritative|nonwildcard|localservice|logdhcp|leasefile|notinterface|maindhcp|disabled)$/ {print}'
	section 'generated dnsmasq DHCP/binding settings only'
	for config_file in /var/etc/dnsmasq.conf.*; do
		[ -r "$config_file" ] || continue
		printf '\nfile=%s\n' "$config_file"
		awk '/^(# dhcp-|interface=|except-interface=|no-dhcp-interface=|dhcp-range=|dhcp-leasefile=|dhcp-ignore|dhcp-authoritative|bind-dynamic|bind-interfaces|port=|conf-dir=|conf-file=|dhcp-relay=)/ {print}' "$config_file"
	done
	section 'DHCP probe cache and enabled servers'
	for config_file in /var/run/dnsmasq.*.dhcp; do
		[ -r "$config_file" ] || continue
		printf '%s=' "$config_file"; cat "$config_file"
	done
	ls /etc/rc.d/*dnsmasq /etc/rc.d/*dhcp* 2>/dev/null
	section 'LAN pool arithmetic'
	(
		. /lib/functions.sh
		. /lib/functions/network.sh
		network_get_subnet dhcp_diag_subnet lan || exit 1
		ipcalc.sh "$dhcp_diag_subnet" "$(uci -q get dhcp.lan.start)" "$(uci -q get dhcp.lan.limit)"
	)
	section 'DHCP process, build support and listening sockets' 
	pidof dnsmasq
	dnsmasq --version
	netstat -lnup
	section 'capture binary'
	command -v tcpdump
	tcpdump --version
	section 'diagnostic script fingerprints'
	sha256sum "$0" "$diag_script"
}

stop_streams() {
	local pid
	[ -z "$wait_pid" ] || kill "$wait_pid" 2>/dev/null
	for pid in $capture_pids; do kill -TERM "$pid" 2>/dev/null; done
	[ -z "$log_pid" ] || kill "$log_pid" 2>/dev/null
	for pid in $capture_pids $log_pid $wait_pid; do wait "$pid" 2>/dev/null; done
	capture_pids=
	log_pid=
	wait_pid=
}
finish() {
	trap '' INT TERM HUP
	stop_streams
	snapshot > "$destination/after.log" 2>&1
	timeout 15 sh "$diag_script" --check Y > "$destination/check-after.log" 2>&1
	nft -a list ruleset > "$destination/nft-after.log" 2>&1
	logread | grep -Ei 'dnsmasq|dhcp|hostapd|Kite|Clanker|mt7915|netifd|bridge|br-' > "$destination/relevant-system.log"
	printf 'reason=%s\n' "$reason" >> "$destination/manifest.txt"
	if tar -czf "$destination.tar.gz" -C /tmp "${destination##*/}"; then
		printf '\nSaved: %s.tar.gz\n' "$destination"
	else
		printf '\nArchive failed; logs remain in: %s\n' "$destination" >&2
	fi
}
trap 'reason=interrupted; finish; exit 130' INT TERM HUP

printf 'schema=3 seconds=%s passive=1 station_mcu_queries=0 capture_filter=DHCPv4+ARP max_packets_per_interface=1000\n' "$seconds" > "$destination/manifest.txt"
printf 'Preparing diagnostic in %s ...\n' "$destination"
configuration > "$destination/configuration.log" 2>&1
snapshot > "$destination/before.log" 2>&1
timeout 15 sh "$diag_script" --check Y > "$destination/check-before.log" 2>&1
nft -a list ruleset > "$destination/nft-before.log" 2>&1

logread -f -F "$destination/system.log" -S 512 > "$destination/logread-errors.log" 2>&1 &
log_pid=$!
if command -v tcpdump >/dev/null 2>&1; then
	for iface in $capture_ifaces; do
		capture_file=$(printf '%s' "$iface" | tr ':' '_')
		tcpdump -p -i "$iface" -nn -e -tttt -l -vvv -s 768 -c 1000 \
			'(arp or (udp and (port 67 or port 68))) or (vlan and (arp or (udp and (port 67 or port 68))))' \
			> "$destination/packets-$capture_file.log" 2>&1 &
		capture_pids="$capture_pids $!"
	done
else
	printf 'tcpdump unavailable; packet-path evidence is incomplete\n' | tee "$destination/capture-unavailable.txt"
fi
printf 'READY: reconnect each affected Wi-Fi client once, leave DHCP automatic, and wait.\n'
printf 'Capturing for %s seconds; Ctrl-C finishes early and saves logs.\n' "$seconds"

read -r started unused < /proc/uptime
started=${started%.*}
while :; do
	read -r now unused < /proc/uptime
	elapsed=$((${now%.*} - started))
	[ "$elapsed" -lt "$seconds" ] || break
	snapshot >> "$destination/samples.log" 2>&1
	# Account for snapshot time so a slow query does not add a full interval.
	read -r now unused < /proc/uptime
	remaining=$((seconds - (${now%.*} - started)))
	[ "$remaining" -gt 0 ] || break
	[ "$remaining" -le 10 ] || remaining=10
	sleep "$remaining" & wait_pid=$!
	wait "$wait_pid"
	wait_pid=
done
finish
exit 0
