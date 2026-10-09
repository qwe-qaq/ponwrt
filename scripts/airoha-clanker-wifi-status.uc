#!/usr/bin/ucode
// Read-only snapshot. Allowlist fields: never dump UCI/ubus config with keys.
import { glob, basename, readfile } from 'fs';
import * as uci from 'uci';
import * as ubus from 'ubus';

let phys = map(glob('/sys/class/ieee80211/*'), basename);
printf('wiphys=%d names=%s\n', length(phys), join(' ', phys));
let config = uci.cursor().get_all('wireless') ?? {};
let radios = 0;
for (let name, c in config) {
	if (c['.type'] == 'wifi-device') {
		radios++;
		printf('config %s: disabled=%s path=%s phy=%s band=%s channel=%s htmode=%s\n',
			name, c.disabled ?? '0', c.path ?? '-', c.phy ?? '-',
			c.band ?? '-', c.channel ?? '-', c.htmode ?? '-');
	} else if (c['.type'] == 'wifi-iface') {
		printf('config %s: device=%s mode=%s disabled=%s network=%s encryption=%s\n',
			name, c.device ?? '-', c.mode ?? '-', c.disabled ?? '0',
			c.network ?? '-', c.encryption ?? '-');
	}
}
printf('configured_radios=%d\n', radios);
if (length(phys) && !radios)
	print('PROBLEM: wiphys exist but wireless has no radio configuration\n');

let bus = ubus.connect();
if (!bus) {
	print('PROBLEM: ubus connection unavailable\n');
	exit(1);
}
let status = bus.call('network.wireless', 'status', {});
if (status == null) {
	print('PROBLEM: netifd wireless status unavailable\n');
	exit(1);
}
for (let name, r in status) {
	printf('netifd %s: up=%J pending=%J disabled=%J retry_setup_failed=%J\n',
		name, r.up, r.pending, r.disabled, r.retry_setup_failed);
	for (let e in r.errors)
		printf('netifd %s: error=%s\n', name, e.code ?? 'unspecified');
	for (let v in r.interfaces) {
		let ifname = v.ifname;
		printf('interface %s: section=%s\n', ifname ?? '-', v.section ?? '-');
		if (!ifname || match(ifname, /[^a-zA-Z0-9_.-]/))
			continue;
		printf('link %s: operstate=%s\n', ifname,
			trim(readfile(`/sys/class/net/${ifname}/operstate`) ?? 'absent'));
		let ap = bus.call(`hostapd.${ifname}`, 'get_status', {});
		if (ap)
			printf('hostapd %s: status=%s freq=%J channel=%J\n',
				ifname, ap.status ?? ap.state ?? '-', ap.freq, ap.channel);
	}
}
