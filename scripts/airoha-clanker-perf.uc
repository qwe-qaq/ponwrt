#!/usr/bin/ucode
// Read-only counters; never read process arguments, UCI keys or packet payloads.
import { readfile, glob, basename } from 'fs';
let detail = getenv('CLANKER_PERF_DETAIL') != '0';
let snapshot = { abi: 2, detail, recorder_pid: +(getenv('CLANKER_RECORDER_PID') ?? '0'), boot_id: trim(readfile('/proc/sys/kernel/random/boot_id') ?? ''),
	uptime: +(split(readfile('/proc/uptime') ?? '0', ' ')[0]), cpu: {}, memory: {},
	interfaces: {}, tasks: [], thermal: {}, frequency: {}, steering: {}, irq_affinity: {} };
for (let line in split(readfile('/proc/stat') ?? '', '\n')) {
	let row = split(trim(line), /\s+/);
	if (match(row[0], /^cpu[0-9]*$/))
		snapshot.cpu[row[0]] = map(slice(row, 1), (v) => +v);
}
for (let line in split(readfile('/proc/meminfo') ?? '', '\n')) {
	let m = match(line, /^(MemAvailable|MemFree|Slab|SUnreclaim|PageTables|KernelStack|Shmem):\s+(\d+)/);
	if (m) snapshot.memory[m[1]] = +m[2];
}
for (let line in split(readfile('/proc/net/dev') ?? '', '\n')) {
	let m = match(line, /^\s*([^:]+):\s*(.*)$/);
	if (!m) continue;
	let v = map(split(trim(m[2]), /\s+/), (v) => +v);
	snapshot.interfaces[m[1]] = { rx_bytes: v[0], rx_packets: v[1], rx_errors: v[2], rx_drop: v[3],
		tx_bytes: v[8], tx_packets: v[9], tx_errors: v[10], tx_drop: v[11] };
}
snapshot.softirq = {};
for (let line in split(readfile('/proc/softirqs') ?? '', '\n')) {
	let m = match(line, /^\s*(NET_RX|NET_TX|TIMER|RCU):\s*(.*)$/);
	if (m) snapshot.softirq[m[1]] = map(split(trim(m[2]), /\s+/), (v) => +v);
}
snapshot.softnet = map(filter(split(readfile('/proc/net/softnet_stat') ?? '', '\n'), (v) => length(v)),
	(v) => map(slice(split(trim(v), /\s+/), 0, 3), (v) => int(v, 16)));
snapshot.interrupts = [];
for (let line in split(readfile('/proc/interrupts') ?? '', '\n')) {
	if (!match(line, /mt76|mt7915|airoha|qdma|pcie|PCI|arch_timer|IPI/)) continue;
	push(snapshot.interrupts, trim(line));
	let m = match(line, /^\s*(\d+):/);
	if (m) snapshot.irq_affinity[m[1]] = trim(readfile(`/proc/irq/${m[1]}/effective_affinity_list`) ?? '');
}
// Light samples retain the recorder and its direct children, including
// reaped-child CPU on the parent. Full process enumeration is every detail
// sample (~30s); CPU/per-core/softirq counters remain in every sample.
snapshot.tasks_scope = detail ? 'all' : 'recorder_and_direct_children';
let task_paths = detail ? glob('/proc/[0-9]*/stat') : [];
if (!detail && snapshot.recorder_pid > 0) {
 push(task_paths, `/proc/${snapshot.recorder_pid}/stat`);
 let children = readfile(`/proc/${snapshot.recorder_pid}/task/${snapshot.recorder_pid}/children`) ?? '';
 for (let child in split(trim(children), /\s+/))
  if (match(child, /^[0-9]+$/)) push(task_paths, `/proc/${child}/stat`);
}
for (let path in task_paths) {
	let line = readfile(path);
	let m = line && match(line, /^(\d+) \((.*)\) (.*)$/);
	if (!m) continue;
	let v = split(m[3], /\s+/);
	let task = { pid: +m[1], comm: m[2], start: +v[19], user: +v[11], system: +v[12], cpu: +v[36], ppid: +v[1], child_user: +v[13], child_system: +v[14] };
 // Keep reaped-child CPU on its parent: short-lived rpcd/collector children
 // disappear between samples. Inclusive child ticks must not be summed with
 // live child process rows (the report keeps these views separate).
 if (task.user + task.system + task.child_user + task.child_system ||
     task.pid == snapshot.recorder_pid || task.ppid == snapshot.recorder_pid)
  push(snapshot.tasks, task);
}
for (let path in glob('/sys/class/thermal/thermal_zone*/temp'))
	snapshot.thermal[path] = +(readfile(path) ?? '0');
for (let path in glob('/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq'))
	snapshot.frequency[path] = +(readfile(path) ?? '0');
for (let path in glob('/sys/class/net/*/queues/rx-*/rps_cpus'))
	snapshot.steering[path] = trim(readfile(path) ?? '');
// Cheap read-only evidence: no FOE table scans or mailbox commands here.
snapshot.offload = { ppe: {}, ppe_flows: [], qdma: {}, software: [] };
for (let line in split(readfile('/sys/kernel/debug/ppe/status') ?? '', '\n')) {
 let q = match(line, /^(qdma[0-9]+_channel[0-9]+) cpu=([0-9]+) fwd=([0-9]+) cpu_cfg=([0-9a-f]+) fwd_cfg=([0-9a-f]+)/);
 if (q) { snapshot.offload.qdma[q[1]] = { cpu: +q[2], fwd: +q[3], cpu_cfg: q[4], fwd_cfg: q[5] }; continue; }
 let flow = match(line, /^kite_flow /), reauth = match(line, /^r63_reauth /), learn = match(line, /^r64_learn /), scan = match(line, /^r66_scan /), values = {};
 for (let item in split(line, /\s+/)) {
  let m = match(item, /^([a-z_0-9]+)=(-?[0-9]+)$/);
  if (m) values[m[1]] = +m[2];
 }
 if (flow) { push(snapshot.offload.ppe_flows, values); continue; }
 for (let key, value in values)
  snapshot.offload.ppe[reauth ? 'r63_reauth_' + key : (learn ? 'r64_learn_' + key : (scan ? 'r66_scan_' + key : key))] = value;
}
let rows = split(trim(readfile('/proc/net/stat/nf_flowtable') ?? ''), '\n');
if (length(rows) > 1) {
 let names = split(trim(rows[0]), /\s+/);
 for (let row in slice(rows, 1)) {
  let values = split(trim(row), /\s+/), item = {};
  if (length(values) != length(names)) continue;
  for (let i = 0; i < length(names); i++) item[names[i]] = +values[i];
  push(snapshot.offload.software, item);
 }
}

// One shared datapath is exposed through both PHY directories; read it once.
let cached_dp = getenv('CLANKER_DP_SNAPSHOT');
for (let path in cached_dp ? [cached_dp] : glob('/sys/kernel/debug/ieee80211/phy*/mt76/kite_datapath')) {
 let text = readfile(path);
 if (!text) continue;
 snapshot.kite_dp = { bands: {}, quality: {}, rx_observe: {}, performance: {}, perf: {}, observe: {}, observe_bands: {}, cycles: {}, gate_reasons: {}, contexts: {}, service: {}, service_load: {}, service_bands: {}, notify: {}, notify_host: {}, ba_activity: {}, activity: {}, r58: {}, r58_stages: {}, ba_local: {}, r59: {}, r59_hot: {}, r59_fallback: {}, r59_age: {}, r59_wa: {}, r59_wa_age: {}, r59_napi: {}, r59_ps: {}, r59_agg: {}, r59_agg_hw: {}, r60: {}, r61_ps: {}, r64: {}, r66: {}, r69: {}, r70: {}, r75: {}, r78: {}, r63: {}, r63_events: [] };
 for (let line in split(text, '\n')) {
  if (match(line, /^sta[0-9]+ /) || (!detail && match(line, /^r63_ps_event /))) continue;
  let band = match(line, /^band([01]) /), quality = match(line, /^quality_band([01]) /),
      rx = match(line, /^rx_observe_band([01]) /), perf = match(line, /^perf_band([01]) /), obs = match(line, /^observe_band([01]) /),
      cyc = match(line, /^cycles_band([01])_stage([0-3]) /), gate = match(line, /^gate_reason([0-9]+) /),
      context = match(line, /^context_reason([0-9]+) /), values = {};
  for (let item in split(line, /\s+/)) {
   let m = match(item, /^([a-z_0-9]+)=(-?[0-9]+)$/);
   if (m) values[m[1]] = +m[2];
  }
  let service = match(line, /^service_band([01]) /), activity = match(line, /^activity_sta([0-9]+) /);
  let tune_stage = match(line, /^r58_stage([0-3]) /);
  let hot = match(line, /^r59_hot([0-5]) /), fallback = match(line, /^r59_fallback([01]) /),
      age = match(line, /^r59_age([01])_([0-3]) /), napi = match(line, /^r59_napi([0-9]+) /),
      ps = match(line, /^r59_ps([0-9]+) /), agg = match(line, /^r59_agg([0-9]+) /), hw = match(line, /^r59_agg_hw([01]) /);
  if (match(line, /^r63_ps_event /)) { push(snapshot.kite_dp.r63_events, values); continue; }
  let r78 = match(line, /^(r78_[a-z]+[0-9_]*)( |$)/);
  if (r78) { snapshot.kite_dp.r78[r78[1]] = values; continue; }
  let r75 = match(line, /^(r75_[a-z]+[0-9_]*)( |$)/);
  if (r75) { snapshot.kite_dp.r75[r75[1]] = values; continue; }
  let r70 = match(line, /^(r70_[a-z]+[0-9_]*)( |$)/);
  if (r70) { snapshot.kite_dp.r70[r70[1]] = values; continue; }
  let r69 = match(line, /^(r69_[a-z]+[0-9_]*)( |$)/);
  if (r69) { snapshot.kite_dp.r69[r69[1]] = values; continue; }
  let r66 = match(line, /^(r66_[a-z]+[0-9_]*)( |$)/);
  if (r66) { snapshot.kite_dp.r66[r66[1]] = values; continue; }
  let r64 = match(line, /^(r64_[a-z]+[0-9]*)( |$)/);
  if (r64) { snapshot.kite_dp.r64[r64[1]] = values; continue; }
  let r63 = match(line, /^(r63|r63_[a-z]+[0-9]*)( |$)/);
  if (r63) { snapshot.kite_dp.r63[r63[1]] = values; continue; }
  let r61 = match(line, /^r61_ps([0-9]+) /);
  if (r61) { snapshot.kite_dp.r61_ps[r61[1]] = values; continue; }
  let r60 = match(line, /^(r60_[a-z]+[0-9_]*)( |$)/);
  if (r60) {
   /* Readback register words stay raw; do not decode undocumented bits. */
   let numeric = {};
   for (let key, value in values) {
    if (match(key, /^(dw[0-9]+|base|count|glb_before|glb_after|unbind|p7)$/)) continue;
    numeric[key] = value;
   }
   snapshot.kite_dp.r60[r60[1]] = { values: numeric, raw: line };
   continue;
  }
  if (hot) snapshot.kite_dp.r59_hot[hot[1]] = values;
  else if (fallback) snapshot.kite_dp.r59_fallback[fallback[1]] = values;
  else if (age) snapshot.kite_dp.r59_age[age[1] + '_' + age[2]] = values;
  else if (napi) snapshot.kite_dp.r59_napi[napi[1]] = values;
  else if (ps) snapshot.kite_dp.r59_ps[ps[1]] = values;
  else if (agg) snapshot.kite_dp.r59_agg[agg[1]] = values;
  else if (hw) snapshot.kite_dp.r59_agg_hw[hw[1]] = values;
  else if (match(line, /^r59_wa_age /)) snapshot.kite_dp.r59_wa_age = values;
  else if (match(line, /^r59_wa /)) snapshot.kite_dp.r59_wa = values;
  else if (match(line, /^r59 /)) snapshot.kite_dp.r59 = values;
  else if (tune_stage) snapshot.kite_dp.r58_stages[tune_stage[1]] = values;
  else if (match(line, /^r58 /)) snapshot.kite_dp.r58 = values;
  else if (match(line, /^ba_local /)) snapshot.kite_dp.ba_local = values;
  else if (service) snapshot.kite_dp.service_bands[service[1]] = values;
  else if (activity) snapshot.kite_dp.activity[activity[1]] = values;
  else if (match(line, /^service /)) snapshot.kite_dp.service = values;
  else if (match(line, /^service_load /)) snapshot.kite_dp.service_load = values;
  else if (match(line, /^notify_host /)) snapshot.kite_dp.notify_host = values;
  else if (match(line, /^notify /)) snapshot.kite_dp.notify = values;
  else if (match(line, /^ba_activity /)) snapshot.kite_dp.ba_activity = values;
  else if (band) snapshot.kite_dp.bands[band[1]] = values;
  else if (quality) snapshot.kite_dp.quality[quality[1]] = values;
  else if (rx) snapshot.kite_dp.rx_observe[rx[1]] = values;
  else if (perf) snapshot.kite_dp.performance[perf[1]] = values;
  else if (match(line, /^perf_abi=/)) snapshot.kite_dp.perf = values;
  else if (obs) snapshot.kite_dp.observe_bands[obs[1]] = values;
  else if (cyc) snapshot.kite_dp.cycles[cyc[1] + '_' + cyc[2]] = values;
  else if (gate) snapshot.kite_dp.gate_reasons[gate[1]] = values;
  else if (context) snapshot.kite_dp.contexts[context[1]] = values;
  else if (match(line, /^observe_abi=|^observe_config /))
   for (let key, value in values) snapshot.kite_dp.observe[key] = value;
  else if (match(line, /^gate_state /)) snapshot.kite_dp.gate_state = values;
  else for (let key, value in values) snapshot.kite_dp[key] = value;
 }
 break;
}
printf('clanker_perf=%J\n', snapshot);
