#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Installed as /usr/sbin/airoha-clanker-diag. Default/status use cached state.
# --full also queries driver/MCU statistics; it is not a passive snapshot.
export LC_ALL=C
section() { printf '\n--- %s ---\n' "$*"; }
status() {
	local found=0 node kind param
	printf '%s\n' 'Clanker build identity'
	if [ -r /lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt ]; then
		grep -E '^(Source:|Commit:|Variant:|Host integration candidate:)' \
			/lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt
	else
		printf '%s\n' 'buildinfo unavailable (old image or firmware package missing)'
	fi
	printf 'module'
	for param in npu_enable npu_control npu_tx; do
		printf ' %s=' "$param"
		if [ -r "/sys/module/mt7915e/parameters/$param" ]; then
			tr -d '\n' < "/sys/module/mt7915e/parameters/$param"
		else
			printf 'unavailable'
		fi
	done
	printf '\n'
	for node in /sys/bus/platform/devices/*/clanker_status /sys/bus/platform/devices/*/clanker_rx_status /sys/bus/platform/devices/*/clanker_host_status /sys/bus/platform/devices/*/clanker_path_status; do
		[ -r "$node" ] || continue
		found=1
		printf '%s\n' "$node"
		cat "$node"
	done
	for kind in kite_tx kite_rx kite_datapath kite_trace kite_events; do
		for node in /sys/kernel/debug/ieee80211/phy*/mt76/"$kind"; do
			[ -r "$node" ] || continue
			printf '%s\n' "$node"
			cat "$node"
			break # Both PHY files expose the same two physical rings.
		done
	done
	[ "$found" = 1 ] || printf '%s\n' 'NPU snapshot unavailable (driver, firmware ABI, or hardware absent)'
}
check_status() {
	local expected="$1"
	case "$expected" in Y|y|1) expected=1 ;; N|n|0) expected=0 ;; *)
		printf '%s\n' 'Usage: airoha-clanker-diag --check Y|N' >&2; return 2 ;;
	esac
	status | awk -v expected="$expected" '
	function value(name, i, pair) {
		for (i = 1; i <= NF; i++) {
			split($i, pair, "=")
			if (pair[1] == name) return pair[2]
		}
		return ""
	}
	function fail(where, field, actual, wanted) {
		printf "CHECK FAIL: %s.%s actual=%s expected=%s\n", where, field,
		       (actual == "" ? "missing" : actual), wanted
		bad++
	}
	function require(where, name, wanted, actual) {
		actual=value(name)
		if (actual == "" || actual != wanted) fail(where, name, actual, wanted)
	}
	function fresh(where, age) {
		age=value("age_ms")
		if (age == "" || age !~ /^[0-9]+$/ || age + 0 > 30000)
			fail(where, "age_ms", age, "0..30000")
	}
	function once(where, count) {
		if (count != 1) fail(where, "records", count "", 1)
	}
	/^module / {
		module++
		actual=value("npu_tx")
		want=(expected ? "Y" : "N")
		if (toupper(actual) != want) fail("module", "npu_tx", actual, want)
	}
	/^control_abi=/ {
		control++
		require("control", "available", 1)
		require("control", "last_error", 0)
		fresh("control")
	}
	/^control mode=/ { require("control", "state", "running"); running++ }
	/^diag_abi=/ {
		diag++
		require("diag", "last_error", 0)
		if (value("samples") + 0 < 1) fail("diag", "samples", value("samples"), ">=1")
		fresh("diag")
	}
	/^mailbox / { mailbox++; require("mailbox", "pending", 0) }
	/^tx_abi=/ {
		tx++
		printf "CHECK STATE: tx requested=%s enabled=%s bound=%s recovery_pending=%s control_failed=%s\n",
		       value("requested"), value("enabled"), value("bound"),
		       value("recovery_pending"), value("control_failed")
		require("tx", "requested", expected)
		require("tx", "enabled", expected)
		require("tx", "bound", expected)
		require("tx", "recovery_pending", 0)
		require("tx", "control_active", 1)
		require("tx", "control_failed", 0)
	}
	/^abi=[0-9]+ negotiated=/ {
		dp++
		require("datapath", "abi", 12)
		require("datapath", "negotiated", expected)
		require("datapath", "bound", expected)
		require("datapath", "attached", expected)
		require("datapath", "changing", 0)
	}
	/^magic=/ {
		dp_state++
		if (expected) {
			require("datapath", "magic", "4b44000c")
			require("datapath", "enabled", 1)
			require("datapath", "gate", 0)
			require("datapath", "fault", 0)
			require("datapath", "stopped", 0)
		}
	}
	/^stations=/ {
		dp_counters++
		if (expected) {
			require("datapath", "tx_bad_done", 0)
			require("datapath", "tokens_quarantine", 0)
		}
	}
	/^rx_fence_stage=/ {
		fence++
		require("rx_fence", "held", 0)
		require("rx_fence", "key_pending", 0)
		printf "CHECK STATE: rx_fence stage=%s failures=%s held=%s key_pending=%s\n",
		       value("rx_fence_stage"), value("failures"), value("held"), value("key_pending")
	}
	/^band[01] active=/ {
		bands++
		if (expected) {
			require($1, "active", 1)
			require($1, "gate", 0)
			require($1, "fault", 0)
		}
	}
	END {
		once("module", module); once("control", control); once("control_state", running)
		once("diag", diag); once("mailbox", mailbox); once("tx", tx); once("datapath", dp)
		if (expected) {
			once("datapath_state", dp_state); once("datapath_counters", dp_counters)
			once("rx_fence", fence)
			if (bands != 2) fail("tx_bands", "records", bands "", 2)
		}
		if (bad) {
			printf "CHECK RESULT: FAIL (%d conditions); no settings changed. This does not identify the DHCP packet-loss stage.\n", bad
			exit 1
		}
		print "CHECK PASS: npu_tx=" (expected ? "Y" : "N") "; control/datapath snapshot healthy. DHCP and endpoint delivery are not tested."
	}'
}
wifi_status() {
	ucode /usr/share/airoha-clanker-wifi-status.uc
}
perf_status() {
	ucode /usr/share/airoha-clanker-perf.uc
}
station_status() {
	local iface
	for iface in /sys/class/net/*; do
		[ -d "$iface/phy80211" ] || continue
		printf '%s operstate=' "${iface##*/}"
		cat "$iface/operstate"
	done
}
basic_snapshot() {
	section 'passive diagnostic schema=3 (no station-rate, ethtool, PPE-table or PON queries)'
	date -u
	uname -a
	cat /proc/uptime /proc/sys/kernel/random/boot_id
	ubus call system board
	section 'cached NPU and driver state'
	status
	section 'Wi-Fi config and hostapd activation (credentials omitted)'
	wifi_status
	section 'DHCP listener and leases'
	netstat -lnup
	[ ! -r /tmp/dhcp.leases ] || cat /tmp/dhcp.leases
	section 'IPv4 addresses and routes'
	ip -4 addr show
	ip -4 route show
	section 'kernel log'
	dmesg
	section 'relevant system log'
	logread | grep -Ei 'netifd|hostapd|dnsmasq|dhcp|Kite|Clanker|mt7915' | tail -n 250
}
# Long runs keep compact performance counters separately from verbose snapshots.
# Rotation is performed by the only writer, between complete samples.
rotate_samples() {
	local file="$1" index
	[ -f "$file" ] && [ "$(wc -c < "$file")" -ge 4194304 ] || return 0
	index=6
	while [ "$index" -ge 1 ]; do
		[ ! -f "$file.$index" ] || mv "$file.$index" "$file.$((index + 1))"
		index=$((index - 1))
	done
	mv "$file" "$file.1"
}
soak() {
	local destination="$1" hours="${2:-2}" log_pid wait_pid= reason=complete
	local start_tick now_tick remaining samples=0
	case "$hours" in ''|*[!0-9]*) return 2 ;; esac
	[ "$hours" -ge 1 ] && [ "$hours" -le 2 ] || return 2
	[ -n "$destination" ] && mkdir -m 700 "$destination" || return 2
	umask 077
	printf 'schema=1 hours=%s interval=30s rotation=8x4MiB-per-stream\n' "$hours" > "$destination/manifest.txt"
	printf '%s\n' "$$" > "$destination/recorder.pid"
	trap 'reason=interrupted; [ -z "$wait_pid" ] || kill "$wait_pid" 2>/dev/null' INT TERM HUP
	"$0" > "$destination/start.log" 2>&1
	# Native ubox logread -S is KiB (despite its help text), with one .old file.
	logread -f -F "$destination/system.log" -S 4096 &
	log_pid=$!
	read -r start_tick remaining < /proc/uptime
	start_tick=${start_tick%.*}
	printf 'Recording %s hours in %s (PID %s). Ctrl-C or TERM stops cleanly.\n' "$hours" "$destination" "$$"
	while [ "$reason" = complete ]; do
		read -r now_tick remaining < /proc/uptime
		[ "$(( ${now_tick%.*} - start_tick ))" -lt "$((hours * 3600))" ] || break
		rotate_samples "$destination/perf.log"
		perf_status >> "$destination/perf.log" 2>> "$destination/recorder-errors.log"
		rotate_samples "$destination/samples.log"
		{
			section 'soak TX/RX sample'
			date -u
			cat /proc/uptime
			status
			[ "$((samples % 2))" -ne 0 ] || station_status
		} >> "$destination/samples.log" 2>&1
		samples=$((samples + 1))
		if ! kill -0 "$log_pid" 2>/dev/null; then
			reason=logread-exited
			break
		fi
		sleep 30 &
		wait_pid=$!
		# TERM can arrive while the snapshot is written, before wait_pid exists.
		[ "$reason" = complete ] || kill "$wait_pid" 2>/dev/null
		wait "$wait_pid" 2>/dev/null
		wait_pid=
	done
	kill "$log_pid" 2>/dev/null
	wait "$log_pid" 2>/dev/null
	"$0" > "$destination/finish.log" 2>&1
	printf 'reason=%s samples=%s\n' "$reason" "$samples" >> "$destination/manifest.txt"
	rm -f "$destination/recorder.pid"
	trap - INT TERM HUP
	[ "$reason" != logread-exited ]
}
record() {
	local destination="$1" log_pid sample_pid
	[ -n "$destination" ] && [ ! -e "$destination" ] || {
		printf '%s\n' 'Choose a new output filename; existing logs are preserved.' >&2
		return 2
	}
	"$0" > "$destination" 2>&1 || return
	logread -f >> "$destination" 2>&1 &
	log_pid=$!
	(
		while :; do
			section 'periodic TX/RX and station sample'
			date -u
			cat /proc/uptime
			head -n 1 /proc/stat
			perf_status
			grep -E '^(MemFree|MemAvailable|Slab):' /proc/meminfo
			status
			station_status
			sleep 10
		done
	) >> "$destination" 2>&1 &
	sample_pid=$!
	trap 'kill "$log_pid" "$sample_pid" 2>/dev/null; wait "$log_pid" "$sample_pid" 2>/dev/null; "$0" >> "$destination" 2>&1; exit 0' INT TERM HUP
	printf 'Recording to %s; press Ctrl-C after the complete test batch.\n' "$destination"
	wait "$sample_pid"
}
case "${1:-}" in
	--soak) soak "${2:-}" "${3:-2}"; exit $? ;;
	--check) check_status "${2:-}"; exit $? ;;
	--perf) perf_status; exit $? ;;
	--record) record "${2:-}"; exit $? ;;
	--status) status; exit 0 ;;
	--offload) exec /usr/sbin/airoha-clanker-offload ;;
	--wifi) wifi_status; exit $? ;;
	--boot-wifi)
		sleep 30
		wifi_status > /tmp/airoha-clanker-wifi-boot.log 2>&1
		while IFS= read -r line; do
			printf '<6>Clanker Wi-Fi: %s\n' "$line" > /dev/kmsg
		done < /tmp/airoha-clanker-wifi-boot.log
		exit 0
		;;
	''|--basic) basic_snapshot; exit $? ;;
	--full) ;;
	*) printf 'Usage: %s [--basic|--full|--offload|--status|--check Y|N|--wifi|--perf|--record NEW_FILE|--soak NEW_DIR [HOURS, default 2]]\n' "$0" >&2; exit 2 ;;
esac
section 'full diagnostic: includes active driver/MCU and hardware-statistics queries'
section 'identity and uptime'
date -u
uname -a
uptime
ubus call system board
section 'Clanker build identity'
cat /lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt
sha256sum /lib/firmware/airoha/en7581_MT7916_npu_*.bin
section 'RAM root and memory'
[ ! -e /etc/hg5585f-ramboot ] || cat /etc/hg5585f-ramboot
cat /proc/meminfo /proc/mounts
section 'NPU platform binding and WiFi ownership'
ls -l /sys/bus/platform/drivers/airoha-npu/
cat /sys/module/mt7915e/parameters/npu_enable
for param in wed_enable npu_cached_hdr npu_control npu_reorder npu_tx; do
	[ -r "/sys/module/mt7915e/parameters/$param" ] || continue
	printf '%s=' "$param"
	cat "/sys/module/mt7915e/parameters/$param"
done
section 'NPU cached health (10s sample; counters are not throughput measurements)'
status
section 'Wi-Fi config and netifd/hostapd activation (credentials omitted)'
wifi_status
section 'Wi-Fi boot snapshot'
[ ! -r /tmp/airoha-clanker-wifi-boot.log ] || cat /tmp/airoha-clanker-wifi-boot.log
section 'host performance counters'
perf_status
section 'offload setup and topology'
/usr/sbin/airoha-clanker-offload
section 'module fingerprints'
sha256sum /lib/modules/*/mt76.ko /lib/modules/*/mt7915e.ko
section 'interfaces and counters'
ip -s link
ip route
ip -6 route
iw dev
for iface in /sys/class/net/*; do
	[ -d "$iface/phy80211" ] || continue
	iw dev "${iface##*/}" station dump
 done
for phy in /sys/class/ieee80211/phy*; do
	[ -e "$phy" ] || continue
	iw phy "${phy##*/}" info
done
section 'kernel log'
dmesg
section 'wireless userspace log (last 200 matching lines)'
logread | grep -Ei 'netifd|hostapd|wpa_supplicant|wifi|ucode' | tail -n 200
