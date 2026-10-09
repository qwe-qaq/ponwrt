#!/usr/bin/env python3
"""Offline, read-only report for legacy --record logs and --soak directories.
Never treats counter resets, old appended snapshots or different workloads as
TX performance improvements. CPU percentages are deltas of the first 8 fields
(guest time is already in user/nice); task rows disclose process identity reuse.
"""
import argparse, csv, json, re, statistics
from pathlib import Path
from datetime import datetime, timezone, timedelta

def kv(line):
    return {k: int(v, 16 if '0x' in v else 10) for k, v in
            re.findall(r'(\w+)=(-?(?:0x[0-9a-fA-F]+|[0-9]+))(?=\s|$)', line)}

def rotated(path):
    return [p for p in [*(path.with_name(path.name + '.' + str(i)) for i in range(7, 0, -1)), path] if p.exists()]

def read(path):
    return path.read_text(errors='replace')

def status_records(text):
    result=[]
    # The short recorder and the two-hour recorder use different section
    # labels.  Keep all of them in the same parser so a report cannot
    # silently claim ``Samples: 0`` for a valid --record capture.
    for block in re.split(r'--- (?:periodic TX/RX and station sample|TX/RX and PPE sample|soak TX/RX sample|wireless NPU trace sample) ---',text)[1:]:
        # End before appended final identity/dmesg; it must not replace this sample.
        block=block.split('--- identity and uptime ---')[0]
        uptime=re.search(r'^([0-9]+\.[0-9]+) [0-9.]+$',block,re.M)
        if not uptime: continue
        rec={'uptime':float(uptime[1]),'rx':{},'tx':{},'poll':{}}
        rec['wall_utc']=wall_time(block)
        cpu=re.search(r'^cpu +([0-9 ]+)$',block,re.M)
        if cpu:rec['cpu']={'cpu':list(map(int,cpu[1].split()))}
        mem=re.search(r'^MemAvailable:\s+(\d+)',block,re.M)
        if mem:rec['memory']={'MemAvailable':int(mem[1])}
        perf=re.search(r'^clanker_perf=(.+)$',block,re.M)
        if perf:
            try:rec.update(json.loads(perf[1]))
            except json.JSONDecodeError:pass
        # Older collectors flattened this line into kite_dp. Recover the
        # named group from the same raw snapshot without guessing identity.
        host_notify=re.search(r'^notify_host .*$',block,re.M)
        if host_notify and 'kite_dp' in rec:
            rec['kite_dp']['notify_host']=kv(host_notify[0])
        ident=re.search(r'^tx_abi=.*$',block,re.M)
        if ident:rec['tx_identity']=kv(ident[0])
        for key, prefix in [('health','diag_abi='),('control_health','control_abi='),('mailbox','mailbox ')]:
            line=re.search('^'+re.escape(prefix)+'.*$',block,re.M)
            if line:rec[key]=kv(line[0])
        host=re.search(r'^host_dma .*$',block,re.M)
        if host:rec['host_dma']=kv(host[0])
        for band in (0,1):
            for key,signature in [('rx','rx_frames='),('tx','active='),('poll','polls=')]:
                line=re.search(fr'^band{band} {signature}.*$',block,re.M)
                if line:rec[key][str(band)]=kv(line[0])
        result.append(rec)
    return result

def cpu_delta(a,b):
    if len(a)<8 or len(b)<8:return None
    d=[y-x for x,y in zip(a[:8],b[:8])]
    if min(d)<0 or sum(d)<=0:return None
    total=sum(d)
    return {'ticks':total,'busy_pct':100*(total-d[3]-d[4])/total,
            'user_pct':100*(d[0]+d[1])/total,'system_pct':100*d[2]/total,
            'softirq_pct':100*d[6]/total,'iowait_pct':100*d[4]/total}

def delta(a,b,bits=None):
    if b>=a:return b-a
    if bits and a>0.9*(1<<bits) and b<0.1*(1<<bits):return b-a+(1<<bits)
    return None

def byte_delta(a, b, seconds):
    """Same live DP session/epoch is checked by caller. Each WiFi band is
    bounded well below 2.5 Gbit/s; refuse intervals admitting a full u32 turn
    or a reset that would look like an impossible traffic rate."""
    limit = seconds * 2_500_000_000 / 8
    if not 0 < limit < 2**32 or not (0 <= a < 2**32 and 0 <= b < 2**32):
        return None
    value = (b - a) % 2**32
    return value if value <= limit else None

def performance_delta(a,b):
    """Only compare coherent snapshots within one DP/configuration identity.
    Cycles are sampled hart4 service cycles, not ARM CPU utilization or RF ACK.
    """
    if (a.get('boot_id')!=b.get('boot_id') or not a.get('boot_id')):return {}
    old=a.get('kite_dp',{});new=b.get('kite_dp',{})
    if (old.get('session') is None or any(old.get(k)!=new.get(k) for k in ('session','epoch','abi')) or
        any(x.get('fault',0) or x.get('gate',1) or x.get('enabled')!=1 for x in (old,new))):return {}
    ao=old.get('observe',{});bo=new.get('observe',{})
    hz=bo.get('clock_mhz',0)
    if (not hz or ao.get('clock_mhz')!=hz or ao.get('sample_shift')!=bo.get('sample_shift') or
        not ao.get('valid') or not bo.get('valid')):return {}
    def diffs(x,y,skip=()):
        return {k:d for k,v in y.items() if k in x and k not in skip and
                (d:=delta(x[k],v,32)) is not None}
    out={'service':{},'service_load':{},'bands':{},'stages':{},'notify':{},'notify_host':{},'ba_activity':{},'activity':{}}
    if old.get('service',{}).get('valid') and new.get('service',{}).get('valid'):
        d=diffs(old['service'],new['service'],('seq','valid','loop_max_cycles'))
        if d.get('loop_packets') and d.get('loop_samples'):
            d['us_per_ppe_packet']=d.get('loop_cycles',0)/hz/d['loop_packets']
        out['service']=d
        for band,v in new.get('service_bands',{}).items():
            d=diffs(old.get('service_bands',{}).get(band,{}),v,('prepare_max_ticks','wire_dma_max_ticks'))
            for name in ('prepare','wire_dma'):
                if d.get(name+'_samples') and name+'_ticks' in d:
                    d[name+'_mean_us']=d[name+'_ticks']*256/hz/d[name+'_samples']
            out['bands'][band]=d
    for stage,v in new.get('cycles',{}).items():
        d=diffs(old.get('cycles',{}).get(stage,{}),v,('max_cycles',))
        if d.get('units') and 'cycles' in d:d['us_per_unit']=d['cycles']/hz/d['units']
        out['stages'][stage]=d
    al=old.get('service_load',{});bl=new.get('service_load',{})
    if al.get('valid') and bl.get('valid') and al.get('revision')==bl.get('revision') and bl.get('revision') in (1,2,3):
        d=diffs(al,bl,('valid','revision'))
        if d.get('submit_packets'):
            d['submit_loop_us_per_packet']=d.get('submit_cycles',0)/hz/d['submit_packets']
        out['service_load']=d
    if al.get('valid') and bl.get('valid') and al.get('revision')==bl.get('revision')==3:
        x=old.get('r66',{}).get('r66_observe',{});y=new.get('r66',{}).get('r66_observe',{})
        d=diffs(x,y,('pressure_max_cycles','snapshot_max_cycles','detail'))
        for key in ('pressure_cycles','snapshot_cycles'):
            if key in d:d[key.replace('_cycles','_total_us')]=d[key]/hz
        out['r66']={'observation':d,'snapshots':new.get('r66',{})}
    if new.get('r78'):
        out['r78']={'snapshots':new['r78'],'scope':'per-STA current-generation longest negative probe; gauges are not deltas'}
    ar=old.get('r58',{});br=new.get('r58',{})
    if ar.get('valid') and br.get('valid') and ar.get('batch')==br.get('batch'):
        out['r58']=diffs(ar,br,('valid','batch','pending_peak','pressure_pending','dma_wait','wa_wait','ready_wait','done_backlog','oldest_ticks'))
        out['r58']['snapshot']=br
        out['r58']['snapshot_limit']='Sticky last pressure event, not current queue occupancy; use r63 age when available.'
        out['r58']['batch']=br.get('batch')
        out['r58_stages']={}
        for stage,v in new.get('r58_stages',{}).items():
            d=diffs(old.get('r58_stages',{}).get(stage,{}),v,('max_cycles',))
            if d.get('units') and 'cycles' in d:d['us_per_unit']=d['cycles']/hz/d['units']
            out['r58_stages'][stage]=d
        # Disjoint sampled segments across all loops; not submit-loop-only.
        covered=sum(v.get('cycles',0) for v in out['r58_stages'].values())
        total=out['service'].get('loop_cycles',0)
        if total>=covered:out['r58']['residual_sampled_cycles']=total-covered
    for name in ('notify','notify_host','ba_activity','ba_local'):
        out[name]=diffs(old.get(name,{}),new.get(name,{}),('producer','consumer','published','request','ack','wcid','tids','max_ns'))
    a59=old.get('r59',{});b59=new.get('r59',{})
    if a59.get('valid') and b59.get('valid') and a59.get('revision')==b59.get('revision')==59:
        out['r59']={'hot':{},'fallback':{},'age':{},'ps':{},'napi':{}}
        z=out['r59']
        for stage,v in new.get('r59_hot',{}).items():
            d=diffs(old.get('r59_hot',{}).get(stage,{}),v,('max_cycles',))
            if d.get('units') and 'cycles' in d:d['us_per_unit']=d['cycles']/hz/d['units']
            z['hot'][stage]=d
        for band,v in new.get('r59_fallback',{}).items():
            d=diffs(old.get('r59_fallback',{}).get(band,{}),v,('pending','peak','max_ticks'))
            completed=d.get('completed',0)+d.get('failed',0)
            if completed and 'ticks' in d:d['copy_mean_us']=d['ticks']*256/hz/completed
            z['fallback'][band]=d
        for key,v in new.get('r59_age',{}).items():z['age'][key]=diffs(old.get('r59_age',{}).get(key,{}),v)
        for key,v in new.get('r59_ps',{}).items():
            a=old.get('r59_ps',{}).get(key,{})
            if a and all(a.get(k)==v.get(k) for k in ('generation','key_generation')):
                z['ps'][key]=diffs(a,v,('generation','key_generation','revoked','max_blocked_ns','current_ns'))
        z['wa']=diffs(old.get('r59_wa',{}),new.get('r59_wa',{}),('max_ns','publish_max_ns'))
        if z['wa'].get('reports') and 'total_ns' in z['wa']:z['wa']['mean_report_us']=z['wa']['total_ns']/1000/z['wa']['reports']
        z['wa_age']=diffs(old.get('r59_wa_age',{}),new.get('r59_wa_age',{}))
        for key,v in new.get('r59_napi',{}).items():z['napi'][key]=diffs(old.get('r59_napi',{}).get(key,{}),v,('max_ns',))
        # Configuration is a snapshot, never a counter difference or inferred RF cap.
        z['aggregation']=new.get('r59_agg',{});z['aggregation_hw_raw']=new.get('r59_agg_hw',{})
    if new.get('r61_ps'):
        out['r61_ps']={'snapshots':new['r61_ps'],'counters':{}}
        for key,after in new['r61_ps'].items():
            before=old.get('r61_ps',{}).get(key,{})
            if before and all(before.get(k)==after.get(k) for k in ('generation','key_generation')):
                d=diffs(before,after,('generation','key_generation','request','mask','probe_max_ns',
                                    'fence_valid','fence_target','fence_reaped','fence_session','fence_epoch'))
                if d.get('probes') and 'probe_ns' in d:
                    d['mean_probe_us']=d['probe_ns']/1000/d['probes']
                out['r61_ps']['counters'][key]=d
    if new.get('r60'):
        out['r60']={'snapshots':new['r60'],'counters':{}}
        for key,entry in new['r60'].items():
            before=old.get('r60',{}).get(key,{}).get('values',{})
            after=entry.get('values',{})
            if key.startswith('r60_quality') or key=='r60_soft':
                out['r60']['counters'][key]=diffs(before,after)
            elif key.startswith('r60_gap'):
                d=diffs(before,after,('max_ticks','unit_cycles'))
                if d.get('samples') and 'ticks' in d:d['mean_us']=d['ticks']*256/hz/d['samples']
                out['r60']['counters'][key]=d
            elif key.startswith('r60_ps') and same_ps_identity(old,new,key[6:]):
                out['r60']['counters'][key]=diffs(before,after,('request','active','drained','consumed_serial','sleep_current_ns','relearn_valid','relearn_ms'))
    if new.get('r64'):
        out['r64']={'snapshots':new['r64'],'counters':{}}
        for key,v in new['r64'].items():
            a=old.get('r64',{}).get(key,{})
            if key=='r64_host' or (key.startswith('r64_ps') and same_ps_identity(old,new,key[6:])):
                out['r64']['counters'][key]=diffs(a,v)
    if new.get('r63'):
        out['r63']={'snapshots':new['r63'],'counters':{}}
        for key,v in new['r63'].items():
            a=old.get('r63',{}).get(key,{})
            if key.startswith('r63_band') and new['r63'].get('r63',{}).get('valid') and old.get('r63',{}).get('r63',{}).get('valid'):
                out['r63']['counters'][key]=diffs(a,v,('soft_wcid','soft_request','soft_type','soft_protocol','soft_ports','empty_active','empty_age_ticks'))
            elif key.startswith('r63_ps') and same_ps_identity(old,new,key[6:]):
                out['r63']['counters'][key]=diffs(a,v,('queue_delay_max_ns',))
        out['r63']['events']=new.get('r63_events',[])
    # Labels follow KDP_SERVICE_*; stage 1 measures DMA, never ARM host time.
    out['stage_names']={'0':'wa_reap','1':'wfdma_completion','2':'submit','3':'publish'}
    load=out.get('service_load',{})
    if load.get('submit_packets'):
        load['all_loops_us_per_submit_packet']=(load.get('submit_cycles',0)+load.get('other_cycles',0))/hz/load['submit_packets']
        load['all_loops_includes_idle']=True
    if new.get('r70'):
        z=out['r70']={'txstatus':{},'age_valid':new['r70'].get('r70_observe',{}).get('age_valid')}
        for band in ('0','1'):
            key='r70_txstatus'+band;x=old.get('r70',{}).get(key,{});y=new['r70'].get(key,{})
            d={k:y[k]-x[k] for k in ('mpdu','retries','final_failed') if k in x and k in y and y[k]>=x[k]}
            if len(d)==3:
                d['final_failure_fraction']=d['final_failed']/d['mpdu'] if d['mpdu'] else None
                z['txstatus'][band]=d
        z['scope']='MPDU status reported for all native/Kite TX, not payload token completions; absent headers do not prove zero failures'
        if z['age_valid']==0:
            if 'r59' in out:out['r59']['age']={}
            if 'r58' in out:out['r58']['oldest_age_available']=False
    for wi,v in new.get('activity',{}).items():
        before=old.get('activity',{}).get(wi,{})
        if before and all(before.get(k)==v.get(k) for k in ('generation','key_generation','tag')):
            out['activity'][wi]=diffs(before,v,('generation','key_generation','tag'))
    return out

def snapshot_fresh(sample):
    health=sample.get('health')
    if not health:return None
    control=sample.get('control_health')
    mailbox=sample.get('mailbox')
    return (health.get('last_error')==0 and health.get('samples',0)>0 and
            0<=health.get('age_ms',30001)<=30000 and
            (not control or (control.get('last_error')==0 and
                             control.get('available')==1 and
                             0<=control.get('age_ms',30001)<=30000)) and
            (not mailbox or mailbox.get('pending')==0))

def analyze(samples):
    intervals=[];gaps=0
    for a,b in zip(samples,samples[1:]):
        dt=b['uptime']-a['uptime']
        if dt<=0 or a.get('boot_id')!=b.get('boot_id'):
            gaps+=1;continue
        cp=cpu_delta(a.get('cpu',{}).get('cpu',[]),b.get('cpu',{}).get('cpu',[]))
        if cp is None:gaps+=1;continue
        ai=a.get('tx_identity',{});bi=b.get('tx_identity',{})
        same_instance=ai.get('session')==bi.get('session') and ai.get('requested')==bi.get('requested')
        row={'uptime':b['uptime'],'seconds':dt,**cp,'mode':bi.get('requested'),'session':bi.get('session'),
             'boundary':not same_instance,'memory_kib':b.get('memory',{}).get('MemAvailable'),
             'per_cpu':{},'interfaces':{},'tasks':[],'rx':{},'tx':{},'poll':{},
             'snapshot_fresh':snapshot_fresh(b),'health':b.get('health',{}),
             'mailbox':b.get('mailbox',{})}
        for name in b.get('cpu',{}):
            if name=='cpu':continue
            d=cpu_delta(a.get('cpu',{}).get(name,[]),b['cpu'][name])
            if d:row['per_cpu'][name]=d
        for name,now in b.get('interfaces',{}).items():
            prev=a.get('interfaces',{}).get(name)
            if not prev:continue
            values={k:delta(prev.get(k,0),v) for k,v in now.items()}
            if any(v is None for v in values.values()):continue
            row['interfaces'][name]={'rx_mbps':values['rx_bytes']*8/dt/1e6,'tx_mbps':values['tx_bytes']*8/dt/1e6,'rx_drop':values['rx_drop'],'tx_drop':values['tx_drop']}
        prevtasks={(t['pid'],t['start']):t for t in a.get('tasks',[])}
        for task in b.get('tasks',[]):
            prev=prevtasks.get((task['pid'],task['start']))
            if not prev:continue
            d=delta(prev['user']+prev['system'],task['user']+task['system'])
            child = delta(prev.get('child_user',0)+prev.get('child_system',0),
                          task.get('child_user',0)+task.get('child_system',0))
            if d or child:
                row['tasks'].append({'comm':task['comm'],'pid':task['pid'],
                    'total_cpu_pct':100*(d or 0)/cp['ticks'],
                    'reaped_children_cpu_pct':100*(child or 0)/cp['ticks']})
            if task['pid'] == b.get('recorder_pid') and d is not None and child is not None:
                row['recorder_inclusive_cpu_pct'] = 100*(d+child)/cp['ticks']
        row['tasks'].sort(key=lambda t:t['total_cpu_pct'],reverse=True)
        for kind,fields in [('rx',['rx_frames','host_desc','host_fail','rx_bad']),('tx',['submitted','reaped','WA_freed','invalid','fault']),('poll',['polls','frames','batches','budget','invalid','refill_short','irqs'])]:
            # A failed mailbox leaves old firmware counters cached indefinitely.
            # Their apparent zero delta does not prove no traffic or no errors.
            if kind=='rx' and (snapshot_fresh(a) is False or snapshot_fresh(b) is False):continue
            for band,now in b.get(kind,{}).items():
                prev=a.get(kind,{}).get(band)
                if not prev:continue
                if kind!='rx' and (not same_instance or now.get('epoch')!=prev.get('epoch')):continue
                row[kind][band]={k:delta(prev[k],now[k],32) for k in fields if k in prev and k in now}
        for key in ('softnet',):
            prev=a.get(key,[]);now=b.get(key,[])
            if prev and len(prev)==len(now):
                ds=[[delta(x,y,32) for x,y in zip(p,n)] for p,n in zip(prev,now)]
                if all(v is not None for d in ds for v in d):row[key]=[sum(d[i] for d in ds) for i in range(3)]
        # Presence, resets and counter configuration are part of the evidence.
        # BND/HW_OFFLOAD installation alone does not prove hardware traffic.
        row['offload'] = {'ppe': {}, 'qdma': {}, 'software': {}}
        old=a.get('offload',{});new=b.get('offload',{})
        for key,now in new.get('ppe',{}).items():
            if key in ('abi','npu_attached','flow_stats','kite_ingress','kite_egress','kite_l4_bound','kite_session','kite_gate','kite_fault','kite_full_bucket','last_reason','r63_reauth_last_reason','r64_learn_budget','r64_learn_last_slot','r64_learn_last_reason','r66_scan_rx0','r66_scan_rx1','r66_scan_idle_remaining_jiffies','hash','policy','in_wcid','out_wcid','type') or key.endswith('errno'):continue
            before=old.get('ppe',{}).get(key)
            if before is not None:row['offload']['ppe'][key]=delta(before,now)
        row['offload']['ppe_snapshot']=new.get('ppe',{})
        row['offload']['ppe_flows']=new.get('ppe_flows',[])
        for channel,now in new.get('qdma',{}).items():
            before=old.get('qdma',{}).get(channel)
            if not before:continue
            if any(before.get(k)!=now.get(k) for k in ('cpu_cfg','fwd_cfg')):continue
            row['offload']['qdma'][channel]={k:delta(before[k],now[k],32) for k in ('cpu','fwd')}
        before=old.get('software',[]);now=new.get('software',[])
        if before and len(before)==len(now):
            for key in ('sw_bridge_packets','sw_routed_packets','hw_skipped_sw_path'):
                values=[delta(x[key],y[key],32) for x,y in zip(before,now) if key in x and key in y]
                if len(values)==len(now) and all(v is not None for v in values):
                    row['offload']['software'][key]=sum(values)
        row['kite_dp'] = {}
        previous=a.get('kite_dp',{}); current=b.get('kite_dp',{})
        if (previous.get('session') is not None and
            bool(a.get('boot_id')) and
            all(previous.get(k)==current.get(k) for k in ('session','epoch','abi')) and
            all(v.get('enabled')==1 and v.get('gate')==0 and v.get('fault')==0
                for v in (previous,current))):
            for band,values in current.get('bands',{}).items():
                before=previous.get('bands',{}).get(band,{})
                row['kite_dp'][band]={k:(byte_delta(before[k],v,dt) if k in ('tx_bytes','rx_bytes')
                                           else delta(before[k],v,32))
                                      for k,v in values.items() if k in before and k not in ('telemetry_abi',)}
        row['npu_performance']=performance_delta(a,b)
        intervals.append(row)
    groups={}
    for mode in (0,1,None):
        rows=[x for x in intervals if x['mode']==mode and not x['boundary']]
        if not rows:continue
        ticks=sum(x['ticks'] for x in rows)
        groups[str(mode)]={'intervals':len(rows),'seconds':sum(x['seconds'] for x in rows),
            'mean_pct':sum(x['busy_pct']*x['ticks'] for x in rows)/ticks,
            'p95_pct':sorted(x['busy_pct'] for x in rows)[int(.95*(len(rows)-1))],
            'max_pct':max(x['busy_pct'] for x in rows)}
    memory=[x['memory_kib'] for x in intervals if x['memory_kib'] is not None]
    stale=[x for x in intervals if x['snapshot_fresh'] is False]
    limits=['CPU deltas cover all cores; compare the same direction, band, throughput and client load.',
            'Firmware counters with stale/error snapshots are excluded; host CPU/interface/poll counters remain independent.',
            'RX firmware counters are cached for about 10 seconds; individual rate intervals may lag.',
            'TX bind counters reset by epoch; WA counters reset by driver instance; boundaries excluded.',
            'Rotated logs may omit early samples; missing evidence is not a passing test.',
            'Whole-loop us_per_ppe_packet includes empty polling and completion work; it is not a saturated throughput ceiling.',
            'Submit-loop timing excludes loops with no new TX, including some completion work; compare both groups.',
            'NPU tx_bytes counts Ethernet submissions, not receiver goodput or acknowledged wireless delivery.']
    if not any('boot_id' in s for s in samples):
        limits.append('Legacy recorder lacks per-core/task/IRQ/softnet/temperature samples.')
    evidence={'samples_with_counters':sum(bool(x.get('offload',{}).get('ppe')) for x in samples),
              'software_handoffs':{},'qdma_handoffs':{},'ppe_host_operations':{}}
    for category,dest in [('software','software_handoffs'),('ppe','ppe_host_operations')]:
        for row in intervals:
            for key,v in row['offload'][category].items():
                if v is not None:evidence[dest][key]=evidence[dest].get(key,0)+v
    for row in intervals:
        for channel,values in row['offload']['qdma'].items():
            dest=evidence['qdma_handoffs'].setdefault(channel,{'cpu':0,'fwd':0})
            for key,v in values.items():
                if v is not None:dest[key]+=v
    evidence['wifi_datapath']={'samples':sum('kite_dp' in x for x in samples),
        'bands':{}, 'fault_samples':sum(bool(x.get('kite_dp',{}).get('fault')) for x in samples),
        'limit':'rx_ppe is TDMA submission; tx_sent is PPE-to-WiFi submission; free-only and DMA+WA completion do not prove peer delivery. Correlate endpoint throughput and real FOE tuples.'}
    for row in intervals:
        for band,values in row['kite_dp'].items():
            dest=evidence['wifi_datapath']['bands'].setdefault(band,{})
            for key,value in values.items():
                if value is not None:dest[key]=dest.get(key,0)+value
    evidence['hw_requests_skipped']=evidence['software_handoffs'].pop('hw_skipped_sw_path',None)
    evidence['qdma_limit']='Raw QDMA source counters are not PPE hit counters. run15 OFF stages increment cpu and fwd equally; never infer hardware forwarding from fwd alone.'
    evidence['limit']='Handoffs are not endpoint delivery; correlate a single test path with FOE tuples/timestamps and endpoint traffic. Missing counters are unobserved.'
    return {'samples':len(samples),'intervals':intervals,'counter_discontinuities':gaps,'cpu_by_mode':groups,
        'offload_evidence':evidence,
        'memory_kib':{'first':memory[0],'last':memory[-1],'min':min(memory)} if memory else {},
        'stale_firmware_intervals':len(stale),
        'first_stale_uptime':stale[0]['uptime'] if stale else None,
        'limits':limits+['r55 npu_performance uses sampled whole-loop cycles per sampled PPE packet; includes shared polling/completion/host service, not a pure TX function cost. prepare and wire_dma are observed times, not peer ACK. Empty or reset windows have no cost claim.']}

def load(path):
    if path.is_file():return status_records(read(path))
    text=''.join(read(p) for p in rotated(path/'samples.log'))
    statuses=status_records(text);perfs=[]
    if not statuses:
        # --record-wifi stores embedded performance JSON in trace.log,
        # unlike --soak's samples.log + perf.log. Do not silently report 0.
        statuses=status_records(''.join(read(p) for p in rotated(path/'trace.log')))
    for p in rotated(path/'perf.log'):
        for line in read(p).splitlines():
            if line.startswith('clanker_perf='):
                try:perfs.append(json.loads(line.split('=',1)[1]))
                except json.JSONDecodeError:pass
    for record in statuses:
        choices=[p for p in perfs if abs(p['uptime']-record['uptime'])<5]
        if choices:record.update(min(choices,key=lambda p:abs(p['uptime']-record['uptime'])))
    return statuses

def offload_mode(text):
    """Read the observed tables/configuration, never infer mode from a label."""
    modern=re.search(r'^clanker_offload_mode=(.+)$',text,re.M)
    if modern:
        try:return json.loads(modern[1])
        except json.JSONDecodeError:pass
    values=dict(re.findall(r'^(flow_offloading(?:_hw)?)=([^\s]+)$',text,re.M))
    sw=values.get('flow_offloading');hw=values.get('flow_offloading_hw')
    configured=('hardware' if hw=='1' else 'software') if sw=='1' else 'off' if sw in ('0','unset') else 'unknown'
    observed=text.split('--- actual flowtables and forwarding rules ---',1)
    tables={};effective='unknown'
    if len(observed)==2:
        block=observed[1].split('\n--- ',1)[0]
        for name,body in re.findall(r'flowtable (ft|fb) \{(.*?)\n[ \t]*\}',block,re.S):
            tables[name]={'name':name,'hardware':bool(re.search(r'\bflags offload\b',body)),
                          'devices':re.findall(r'"([^"\n]+)"',body)}
        if tables:
            flags=[t['hardware'] for t in tables.values()]
            effective='hardware' if all(flags) else 'mixed' if any(flags) else 'software'
        elif re.search(r'table inet fw4 \{',block):effective='off'
    return {**values,'configured':configured,'effective':effective,'tables':list(tables.values()),
            'consistent':configured==effective and effective!='unknown'}

def audit_stage(path,expected=None):
    observations=[]
    if path.is_file():observations=[offload_mode(read(path))]
    else:
        names=('start.log','finish.log')
        # Short Wi-Fi recordings put their sole mode snapshot in identity.
        # Start/finish here contain radio/DP state, not nft rules.
        if (path/'trace.log').exists() and (path/'identity.log').exists():
            if re.search(r'^clanker_offload_mode=',read(path/'identity.log'),re.M):
                names=('identity.log',)
        for name in names:
            if (path/name).exists():observations.append({'source':name,**offload_mode(read(path/name))})
        for p in rotated(path/'mode.log'):
            for line in read(p).splitlines():
                if line.startswith('clanker_offload_mode='):
                    observations.append({'source':p.name,**offload_mode(line)})
        if expected is None and (path/'manifest.txt').exists():
            match=re.search(r'expected_mode=(off|software|hardware)\b',read(path/'manifest.txt'))
            if match:expected=match[1]
    warnings=[]
    if not observations:warnings.append('No observed flowtable/configuration evidence.')
    for o in observations:
        if o.get('flow_offloading')=='0' and o.get('flow_offloading_hw')=='1':
            warnings.append('UCI 0/1 disables flow offload; software mode requires 1/0.')
        if not o.get('consistent'):warnings.append('Configured and observed flowtable mode differ or are unobserved.')
        if expected is not None and o.get('effective')!=expected:
            warnings.append('Expected '+expected+' but observed '+o.get('effective','unknown')+'.')
    if len(set(o.get('effective') for o in observations))>1:warnings.append('Mode changed across observed snapshots.')
    return {'expected':expected,'observations':observations,'warnings':list(dict.fromkeys(warnings)),
            'valid':bool(observations) and not warnings,
            'limit':'Mode verification is not proof of packet hits. Snapshot sampling cannot exclude changes between observations.'}


def wall_time(text):
    m=re.search(r'^\w{3} \w{3}\s+\d+ \d\d:\d\d:\d\d UTC \d{4}$',text,re.M)
    if not m:return None
    return datetime.strptime(m[0],'%a %b %d %H:%M:%S UTC %Y').replace(tzinfo=timezone.utc).timestamp()

def same_ps_identity(old,new,wi):
    a=old.get('r59_ps',{}).get(wi,{});b=new.get('r59_ps',{}).get(wi,{})
    return bool(a and b and all(a.get(k)==b.get(k) for k in ('generation','key_generation')))

def endpoint_logs(path,offset):
    results={};units={'bits/sec':1e-6,'Kbits/sec':1e-3,'Mbits/sec':1,'Gbits/sec':1000}
    pattern=re.compile(r'^\[\s*(SUM|\d+)\]\s+(\d+\.\d+)-(\d+\.\d+)\s+sec\s+([\d.]+)\s+\w+\s+([\d.]+)\s+([KMG]?bits/sec)(.*)$')
    for p in sorted(path.rglob('*.txt')):
        text=p.read_bytes().decode('gb18030',errors='replace')
        local=text.split('Server output:')[0]
        if ' receiver' not in local:continue
        multi=bool(re.search(r'^\[SUM\].*receiver',local,re.M));rows=[];summary=[];retr=None
        for line in local.splitlines():
            m=pattern.match(line)
            if not m:continue
            chan,start,end,amount,rate,unit,tail=m.groups()
            if (chan=='SUM')!=multi:continue
            z={'start':float(start),'end':float(end),'mbps':float(rate)*units[unit]}
            if 'receiver' in tail:summary.append(z)
            if not tail.strip() and .5<=z['end']-z['start']<=1.5:rows.append(z)
            # Sender Retr column must be present and numeric; absence != zero.
            if 'Retr' in local and 'sender' in tail:
                number=re.match(r'\s+(\d+)\s+sender',tail)
                if number:retr=int(number[1])
        if len(summary)!=1:continue
        phase='diagnostic' if 'diagnostic' in str(p.relative_to(path)).lower() else ('content-check' if '-file-' in p.name else 'performance')
        z={'phase':phase,'receiver_mbps':summary[0]['mbps'],'duration':summary[0]['end']-summary[0]['start'],
           'retransmits':retr,'tcp_detail':'Retr/cwnd/RTT unavailable unless explicitly emitted by iperf or endpoint capture',
           'intervals':rows,'start_utc':None,'omit':5 if '(omitted)' in local else 0}
        stamp=re.search(r'(\d{4})[/\-](\d{1,2})[/\-](\d{1,2}).*?(\d{1,2}):(\d\d):(\d\d)(?:\.(\d+))?',local)
        if stamp:
            y,mo,d,h,mi,se=map(int,stamp.groups()[:6]);fraction=float('0.'+(stamp[7] or '0'))
            z['start_utc']=datetime(y,mo,d,h,mi,se,tzinfo=timezone(timedelta(hours=offset))).timestamp()+fraction
        values=sorted(x['mbps'] for x in rows)
        z['p10_mbps']=values[max(0,int(len(values)*.1)-1)] if values else None
        z['clock_limit']='Windows local timestamp + configured UTC offset; NTP offset not independently proved.'
        results[str(p.relative_to(path))]=z
    return results

def radio_records(path):
    if not path.exists():return []
    out=[]
    for block in read(path).split('--- wireless rate and aggregation ---')[1:]:
        u=re.search(r'^([\d.]+) [\d.]+$',block,re.M)
        if not u:continue
        x={'wall_utc':wall_time(block),'uptime':float(u[1]),'amsdu':[0]*8,'mpdu':{},'ampdu':{},'rates':[]}
        for size,num in re.findall(r'AMSDU pack count of (\d) MSDU in TXD:\s+(\d+)',block):x['amsdu'][int(size)-1]+=int(num)
        for at,su,band in re.findall(r'Tx MPDU attempts: (\d+) successful: (\d+) \(band (\d)\)',block):x['mpdu'][band]=[int(at),int(su)]
        for band,counts in re.findall(r'Phy \d, Phy band (\d)\nLength:.*\nCount:([^\n]+)',block):x['ampdu'][band]=list(map(int,re.findall(r'\d+',counts)))
        x['rates']=re.findall(r'tx bitrate:\s*([^\n]+)',block)
        out.append(x)
    return out

def radio_summary(ss):
    if len(ss)<2:return {'available':False,'reason':'fewer than two radio snapshots within endpoint window'}
    a,b=ss[0],ss[-1];counts=[delta(x,y,32) for x,y in zip(a['amsdu'],b['amsdu'])]
    if None in counts:return {'available':False,'reason':'radio counter discontinuity'}
    total=sum(counts)
    result={'available':True,'uptime':[a['uptime'],b['uptime']],'samples':len(ss),'amsdu_counts':counts,
            'amsdu_mean':sum((i+1)*v for i,v in enumerate(counts))/total if total else None,
            'rates':sorted({v for x in ss for v in x['rates']}),'mpdu':{},'ampdu':{},
            'limit':'AMSDU sums native per-PHY deltas; AMPDU/MPDU per band. RF attempt failures are not TCP retransmits.'}
    for kind in ('mpdu','ampdu'):
        for band,v in b[kind].items():
            old=a[kind].get(band)
            if old and len(old)==len(v):result[kind][band]=[delta(x,y,32) for x,y in zip(old,v)]
    return result

def endpoint_windows(root,samples,clients,offset):
    radio=radio_records(root/'radio.log') if root.is_dir() else []
    result={}
    for name,z in endpoint_logs(clients,offset).items():
        start=z['start_utc'];ss=[];rr=[]
        if start is not None:
            lo=start+z['omit']+2;hi=start+z['omit']+z['duration']-2
            ss=[x for x in samples if x.get('wall_utc') is not None and lo<=x['wall_utc']<=hi]
            rr=[x for x in radio if x.get('wall_utc') is not None and lo<=x['wall_utc']<=hi]
        z['router_samples']=len(ss);z['radio']=radio_summary(rr)
        z['router']=analyze(ss) if len(ss)>=2 else None
        z['window_limit']='Whole router intervals strictly within endpoint +/-2s margin; router/radio windows may be shorter.'
        result[name]=z
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('input',type=Path);parser.add_argument('output',type=Path)
    parser.add_argument('--clients',type=Path,help='Windows client text logs; endpoint window matching')
    parser.add_argument('--client-utc-offset',type=float,default=8,help='Client clock UTC offset, hours (default 8)')
    parser.add_argument('--expect-mode',choices=['off','software','hardware'])
    args=parser.parse_args();args.output.mkdir(exist_ok=False,parents=True)
    samples=load(args.input);result=analyze(samples);result['stage_evidence']=audit_stage(args.input,args.expect_mode);result['endpoint_windows']=endpoint_windows(args.input,samples,args.clients,args.client_utc_offset) if args.clients else {};(args.output/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    with (args.output/'cpu.csv').open('w') as f:
        keys=['uptime','seconds','mode','session','boundary','busy_pct','user_pct','system_pct','softirq_pct','iowait_pct','memory_kib']
        writer=csv.DictWriter(f,fieldnames=keys,extrasaction='ignore');writer.writeheader();writer.writerows(result['intervals'])
    lines=['# Clanker CPU / datapath report','',f"Samples: {result['samples']}; discontinuities skipped: {result['counter_discontinuities']}.",'',
           '| npu_tx | intervals | mean CPU % | p95 % | peak % |','|---|---:|---:|---:|---:|']
    for mode,g in result['cpu_by_mode'].items():lines.append(f"| {mode} | {g['intervals']} | {g['mean_pct']:.2f} | {g['p95_pct']:.2f} | {g['max_pct']:.2f} |")
    lines+=['','Memory (KiB): '+json.dumps(result['memory_kib']),
            'Observed stage: '+json.dumps(result['stage_evidence']),
            'Offload evidence: '+json.dumps(result['offload_evidence']),
            f"Stale/error firmware intervals: {result['stale_firmware_intervals']}; first uptime: {result['first_stale_uptime']}.", '',*result['limits']]
    if args.clients:
        lines += ['', '| Endpoint | phase | receiver Mbps | Retr observed | router samples |', '|---|---|---:|---|---:|']
        for name,z in result['endpoint_windows'].items():lines.append(f"| {name} | {z['phase']} | {z.get('receiver_mbps','missing')} | {z['retransmits'] if z.get('retransmits') is not None else 'unavailable'} | {z['router_samples']} |")
    (args.output/'report.md').write_text('\n'.join(lines)+'\n');print('\n'.join(lines))
    if args.expect_mode and not result['stage_evidence']['valid']:raise SystemExit(2)

if __name__=='__main__':main()
