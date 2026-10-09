#!/usr/bin/ucode
// Read-only mode verification. Flowtable creation is not a packet-hit verdict.
import { popen } from 'fs';
function command(cmd) {
 let fp = popen(cmd, 'r');
 if (!fp) return null;
 let value = fp.read('all');
 return fp.close() == 0 ? value : null;
}
function option(name) {
 let value = command(`uci -q get firewall.@defaults[0].${name}`);
 return value == null ? 'unset' : trim(value);
}
let sw = option('flow_offloading'), hw = option('flow_offloading_hw');
let result = { abi: 1, flow_offloading: sw, flow_offloading_hw: hw,
 configured: sw == '1' ? (hw == '1' ? 'hardware' : 'software') : 'off',
 effective: 'unknown', tables: [], consistent: false };
let raw = command('nft -j list flowtables 2>/dev/null'), text_raw = command('nft list flowtables 2>/dev/null'), data;
let text_flags = {};
let text_table = null;
for (let line in split(text_raw ?? '', '\n')) {
 if (match(line, /flowtable ft \{/)) text_table = 'ft';
 else if (match(line, /flowtable fb \{/)) text_table = 'fb';
 if (text_table && match(line, /flags offload/)) text_flags[text_table] = true;
 if (text_table && match(line, /^\s*}/)) text_table = null;
}
try { data = raw == null ? null : json(raw); } catch (e) { data = null; }
if (type(data?.nftables) == 'array') {
 for (let entry in data.nftables) {
  let f = entry.flowtable;
  if (!f || f.table != 'fw4') continue;
  if ((f.family == 'inet' && f.name == 'ft') || (f.family == 'bridge' && f.name == 'fb')) {
   /* nft JSON has emitted both an array (libnftables 1.0.x) and the
    * scalar string "offload" (older OpenWrt nft builds). Treat only the
    * explicit flag as hardware offload; a missing/unknown value remains
    * unobserved instead of being silently certified. */
   let flags = f.flags ?? [];
   let hardware = type(flags) == 'array' ? index(flags, 'offload') >= 0 :
    type(flags) == 'string' ? flags == 'offload' : false;
   /* BusyBox/nft combinations have emitted a valid textual flag while
    * omitting it from JSON. Keep the table evidence visible without
    * claiming a packet hit. */
   if (!hardware && text_flags[f.name]) hardware = true;
   push(result.tables, { family: f.family, name: f.name, devices: f.dev ?? [],
   hardware: hardware, flags: flags, flag_source: hardware &&
    (type(flags) == 'array' || type(flags) == 'string') ? 'json' : 'text' });
  }
 }
 if (!length(result.tables)) result.effective = 'off';
 else {
  let enabled = length(filter(result.tables, (f) => f.hardware));
  result.effective = enabled == length(result.tables) ? 'hardware' : enabled ? 'mixed' : 'software';
 }
 result.consistent = result.configured == result.effective;
}
let expected = ARGV[0];
if (expected != null) {
 result.expected = expected;
 result.valid = index(['off', 'software', 'hardware'], expected) >= 0 && result.consistent && result.effective == expected;
 // Reject 0/1 too: it is disabled, and almost always a reversed test pair.
 if (expected == 'off' && hw != '0' && hw != 'unset') result.valid = false;
}
printf('clanker_offload_mode=%J\n', result);
if (expected != null && !result.valid) exit(1);
