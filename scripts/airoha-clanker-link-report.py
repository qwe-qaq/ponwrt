#!/usr/bin/env python3
"""Read-only physical link timeline and endpoint evidence inventory.
Usage: airoha-clanker-link-report.py ROUTER_DIR NEW_OUTPUT_DIR [--a DIR --b DIR]
Reads detailed network.log and ordinary light trace.log; no rate from
unsupported counters, no root-cause inference from empty TDMA alone.
"""
import argparse,csv,json,re
from pathlib import Path

def fast_samples(text):
    rows=[]
    for block in text.split('sample_begin=')[1:]:
        end=re.search(r'^sample_end=([0-9.]+)',block,re.M)
        if not end:continue
        item={'begin':float(block.splitlines()[0]),'end':float(end[1]),'ports':{}}
        for m in re.finditer(r'^\s*([^\s:]+):\s*((?:\d+\s+){15}\d+)\s*$',block,re.M):
            v=list(map(int,m[2].split()));item['ports'][m[1]]={'rx_bytes':v[0],'tx_bytes':v[8],'rx_drop':v[3],'tx_drop':v[11]}
        rows.append(item)
    return rows

def fast_intervals(samples):
    rows=[]
    for a,b in zip(samples,samples[1:]):
        dt=(b['begin']+b['end']-a['begin']-a['end'])/2
        if not 0<dt<=10:continue
        for port,y in b['ports'].items():
            x=a['ports'].get(port)
            if not x or any(y[k]<x[k] for k in y):continue
            rows.append({'begin':a['begin'],'end':b['end'],'seconds':dt,'port':port,
                         'rx_mbps':(y['rx_bytes']-x['rx_bytes'])*8/dt/1e6,
                         'tx_mbps':(y['tx_bytes']-x['tx_bytes'])*8/dt/1e6,
                         'rx_drop':y['rx_drop']-x['rx_drop'],'tx_drop':y['tx_drop']-x['tx_drop']})
    return rows

def port_queries(text):
    rows=[]
    for m in re.finditer(r'query=ethtool-S port=(\S+) group=(\S+)\n(.*?)(?=query=ethtool-S|\Z)',text,re.S):
        body=m[3];a=re.search(r'^query_begin=([0-9.]+)',body,re.M);b=re.search(r'^query_end=([0-9.]+)',body,re.M)
        rc=re.search(r'^query_status=(\d+)',body,re.M)
        row={'port':m[1],'group':m[2],'status':int(rc[1]) if rc else None,
             'begin':float(a[1]) if a else None,'end':float(b[1]) if b else None,'counters':{}}
        if row['status']==0 and a and b:
            row['counters']={k.strip():int(v) for k,v in re.findall(r'^\s*([^:\n]+):\s*(\d+)\s*$',body,re.M)}
        rows.append(row)
    return rows

def port_intervals(queries):
    rows=[];last={}
    for q in queries:
        key=(q['port'],q['group']);a=last.get(key);last[key]=q
        if not a or q['status']!=0 or a['status']!=0 or not q['counters'] or not a['counters']:continue
        dt=(q['begin']+q['end']-a['begin']-a['end'])/2
        if dt<=0:continue
        for k,y in q['counters'].items():
            x=a['counters'].get(k)
            if x is None or y<x:continue
            rows.append({'port':q['port'],'group':q['group'],'counter':k,'begin':a['begin'],'end':q['end'],
                         'seconds':dt,'delta':y-x,'per_second':(y-x)/dt})
    return rows

def words(line):
    return {k:int(v,0) for k,v in re.findall(r'(\w+)=(-?0x[0-9a-fA-F]+|-?\d+)(?=\s|$)',line)}

def network_samples(text):
    rows=[]
    for block in text.split('network_begin=')[1:]:
        end=re.search(r'^network_end=([0-9.]+)',block,re.M)
        if not end:continue
        row={'begin':float(block.splitlines()[0]),'end':float(end[1]),
             'health':{},'host':{},'last':{},'retry':{},'path':{},'queues':[],'bql':[],'frame':None,'cost_health':{},'cost':{},'switch':[],'credit_health':{},'credit':{},'feed_health':{},'feed':{},
             'load':[],'prof':[],'memory':[],'cpi':[],'pc_pages':[],'pc':[],'ps':[],'queue_copy':[]}
        for line in block.splitlines():
            if line.startswith('feed available='):row['feed_health']=words(line)
            if line.startswith('hart4_load '):row['load'].append(words(line))
            if line.startswith('prof '):row['prof'].append(words(line))
            if line.startswith('memory kind='):
                m=re.match(r'memory kind=(\S+)\s+(.*)',line)
                if m: row['memory'].append({'kind':m[1],**words(m[2])})
            if line.startswith('cpi_band') or line.startswith('cpi'):
                row['cpi'].append(words(line))
            if line.startswith('pc_page='):row['pc_pages'].append(words(line))
            if line.startswith('pc '):
                m=re.match(r'pc\s+((?:0x)?[0-9a-fA-F]+)\s+(\d+)',line)
                if m: row['pc'].append({'address':int(m[1],16),'samples':int(m[2])})
            if line.startswith('r79_ps'):
                row['ps'].append(words(line))
            if line.startswith('queue_copy '):row['queue_copy'].append(words(line))
            m=re.match(r'feed_band([01]) ',line)
            if m:row['feed'][m[1]]=words(line)
            if line.startswith('queue available='):row['credit_health']=words(line)
            m=re.match(r'queue_band([01]) ',line)
            if m:row['credit'][m[1]]=words(line)
            m=re.match(r'cost_band([01]) ',line)
            if m:row['cost_health'][m[1]]=words(line)
            m=re.match(r'cost([01])_(\d+) name=(\w+) ',line)
            if m:row['cost'].setdefault(m[1],{})[m[2]]={'name':m[3],**words(line)}
            if line.startswith(('switch_abi=','port=','phy_port=','global reg=')):
                row['switch'].append(line)  # hex values and per-field errors retained
            if line.startswith('host_abi='):row['health']=words(line)
            if line.startswith('path_abi='):row['path'].update(words(line))
            if re.match(r'^(event_tick|session|epoch|band|wcid|request|generation|key_generation|route_tag|type|protocol|ports|vlan|dsfield|src[0-3]|dst[0-3]|mac[0-2]|candidate_\w+)=',line):row['path'].update(words(line))
            m=re.match(r'host_retry([01]) ',line)
            if m:row['retry'][m[1]]=words(line)
            m=re.match(r'host_band([01]) ',line)
            if m:row['host'][m[1]]=words(line)
            m=re.match(r'host_last([01]) ',line)
            if m:row['last'][m[1]]=words(line)
            if line.startswith('qdma='):row['queues'].append(words(line))
            if line.startswith('bql '):row['bql'].append(line)
            if line.startswith('{'):
                try:row['frame']=json.loads(line)
                except ValueError:pass
        row['host_fresh']=(row['health'].get('available')==1 and
                           row['health'].get('last_error')==0 and
                           row['health'].get('age_ms',100000)<=25000)
        rows.append(row)
    return rows

def light_hart4_load(text):
    """Parse KF1 hart4 load pages from the ordinary light recorder.

    The light recorder deliberately writes trace.log rather than network.log.
    Keep the sample ordinal and uptime when present; these are counters, not
    a timed CPU percentage.
    """
    rows=[]; current=None; sample=0
    for line in text.splitlines():
        if line.strip() == '--- r78 light counters ---':
            sample += 1
            current={'sample':sample,'source':'trace.log'}
            continue
        if current is None:
            continue
        m=re.match(r'^\s*(\d+(?:\.\d+)?)\s+\d+(?:\.\d+)?\s*$',line)
        if m and 'uptime' not in current:
            current['uptime']=float(m[1])
            continue
        if line.startswith('hart4_load '):
            row=dict(current); row.update(words(line)); rows.append(row)
            current=None
    return rows

def host_intervals(samples):
    rows=[]
    for a,b in zip(samples,samples[1:]):
        # Cached 10s page can repeat at the edges. Stale/unsupported pages
        # break the chain, never hide unavailable evidence behind a zero.
        if not a['host_fresh'] or not b['host_fresh']:continue
        if a['health'].get('seq')==b['health'].get('seq'):continue
        dt=(b['begin']+b['end']-a['begin']-a['end'])/2
        if not 0<dt<=60:continue
        reset=False
        for band,y in b['host'].items():
            x=a['host'].get(band,{})
            if any(k in x and v<x[k] and not (x[k]>=0xf0000000 and v<=0x0fffffff) for k,v in y.items()):reset=True
        if reset:continue
        for band,y in b['host'].items():
            x=a['host'].get(band)
            if not x or x.keys()!=y.keys():continue
            delta={}
            for k,v in y.items():
                if v>=x[k]:delta[k]=v-x[k]
                elif x[k]>=0xf0000000 and v<=0x0fffffff:delta[k]=(v-x[k])&0xffffffff
                else:break
            else:
                rows.append({'band':band,'begin':a['begin'],'end':b['end'],
                             'seconds':dt,**delta})
    return rows

def cost_intervals(samples):
    rows=[]
    for a,b in zip(samples,samples[1:]):
        for band,y in b['cost_health'].items():
            x=a['cost_health'].get(band,{})
            def usable(h):
                return (h.get('revision',0)>=74 and
                        h.get('producer_age_ms',999999)<=25000 and
                        h.get('available')==1 and h.get('valid')==1 and
                        h.get('last_error')==0 and h.get('age_ms',999999)<=25000 and
                        6<=h.get('shift',0)<=12 and h.get('mhz',0)>0)
            if not usable(x) or not usable(y):continue
            if x.get('seq')==y.get('seq'):continue
            if any(x.get(k)!=y.get(k) for k in ('session','epoch','shift','mhz','revision')):continue
            if not 0<b['begin']-a['begin']<=60:continue
            for stage,v in b['cost'].get(band,{}).items():
                u=a['cost'].get(band,{}).get(stage)
                if not u or u['name']!=v['name']:continue
                if not all(k in u and k in v for k in ('samples','cycles','units')):continue
                d={k:(v[k]-u[k])&0xffffffff for k in ('samples','cycles','units')}
                if not d['samples']:continue
                # Identity guards reset; modulo32 handles a single cumulative
                # wrap. These are sampled calls, never scale them to all packets.
                rows.append({'band':band,'stage':stage,'name':v['name'],
                    'begin':a['begin'],'end':b['end'],'sample_shift':y['shift'],**d,
                    'us_per_call':d['cycles']/y['mhz']/d['samples'],
                    'us_per_unit':d['cycles']/y['mhz']/d['units'] if d['units'] else None,
                    'lifetime_max_us':v.get('max_cycles',0)/y['mhz']})
    return rows

def feed_intervals(samples):
    """FE1 deltas: descriptor doorbells are not air aggregation measurements."""
    rows=[]
    counters=['batches','packets','batch1','batch2_4','batch5_8','batch9_15','batch16',
              'end_other','end_empty','end_token','end_credit','end_ps','end_gate',
              'end_ring','end_budget','sampled_mixed','gap_samples','gap_cycles',
              'ready_gap_samples','ready_gap_cycles']
    def valid(h):
        return (h.get('revision') in (76,77) and (h.get('revision')==76 or h.get('enabled')==1) and h.get('available')==1 and h.get('valid')==1
                and h.get('last_error')==0 and h.get('age_ms',999999)<=25000
                and h.get('producer_age_ms',999999)<=25000 and h.get('mhz',0)>0)
    for a,b in zip(samples,samples[1:]):
        x=a.get('feed_health',{});y=b.get('feed_health',{})
        if not valid(x) or not valid(y) or x.get('seq')==y.get('seq'):continue
        if any(x.get(k)!=y.get(k) for k in ('session','epoch','mhz','revision')):continue
        if not 0<b['begin']-a['begin']<=60:continue
        for band,v in b.get('feed',{}).items():
            u=a.get('feed',{}).get(band,{})
            if not all(k in u and k in v for k in counters):continue
            d={k:(v[k]-u[k])&0xffffffff for k in counters}
            rows.append({'band':band,'begin':a['begin'],'end':b['end'],**d,
                         'packets_per_doorbell':d['packets']/d['batches'] if d['batches'] else None,
                         'sampled_gap_us':d['gap_cycles']/y['mhz']/d['gap_samples'] if d['gap_samples'] else None,
                         'last_wcid':v.get('last_wcid'),'last_tid':v.get('last_tid')})
    return rows

def queue_intervals(samples):
    """KF1 gauges and wide wait times. Admission attempts are not drops."""
    rows=[]
    for a,b in zip(samples,samples[1:]):
        x=a.get('credit_health',{});y=b.get('credit_health',{})
        def valid(h):
                return (h.get('revision') in (75,76,77,79) and h.get('available')==1 and h.get('valid')==1
                    and h.get('last_error')==0 and h.get('age_ms',999999)<=25000
                    and h.get('producer_age_ms',999999)<=25000 and h.get('mhz',0)>0)
        if not valid(x) or not valid(y) or x.get('seq')==y.get('seq'):continue
        if any(x.get(k)!=y.get(k) for k in ('session','epoch','mhz','revision')):continue
        if not 0<b['begin']-a['begin']<=60:continue
        for band,v in b.get('credit',{}).items():
            u=a.get('credit',{}).get(band)
            if not u:continue
            row={'band':band,'begin':a['begin'],'end':b['end'],
                 'free':y.get('free'),'pending':v.get('pending'),
                 'owner_wcid':v.get('owner_wcid'),'owner_pending':v.get('owner_pending'),
                 'producer_backlog':(y.get('producer',0)-y.get('consumer',0))&0xffffffff,
                 'pressure_tick':y.get('pressure_tick'),'dma_wait':v.get('dma_wait'),
                 'wa_wait':v.get('wa_wait'),'ready_wait':v.get('ready_wait')}
            for k in ('credit_hold','no_buffer','released'):
                if k in u and k in v:row[k]=(v[k]-u[k])&0xffffffff
            for k in ('no_buffer_cycles','credit_cycles'):
                if all(t in u and t in v for t in (k,k+'_hi')):
                    old=(u[k+'_hi']<<32)|u[k];new=(v[k+'_hi']<<32)|v[k]
                    if new>=old:row[k.replace('_cycles','_ms')]=(new-old)/y['mhz']/1000
            rows.append(row)
    return rows

def endpoint(path):
    if not path or not path.is_dir():return {'available':False}
    files=list(path.rglob('*'));texts=[p for p in files if p.suffix=='.txt'];caps=[p for p in files if p.suffix=='.pcapng']
    # Keep the original capture summary: absent loss counters are unknown.
    summaries={str(p.relative_to(path)):p.read_text(errors='replace') for p in texts if p.name=='capture.txt'}
    return {'available':True,'server_logs':[str(p.relative_to(path)) for p in texts if 'server' in p.name],
            'text_files':len(texts),'captures':{str(p.relative_to(path)):p.stat().st_size for p in caps},
            'capture_summaries':summaries,'time_coverage':'verify iperf start/end against endpoint clocks and pcap timestamps; file presence alone is insufficient',
            'capture_loss':'see original summaries; missing statistics mean unknown; also inspect pcapng interface statistics',
            'scope':'TSO/RSC can alter endpoint segment presentation; header snaplen may include a few data bytes'}

def write_csv(path,rows):
    with path.open('w',newline='') as f:
        if rows:
            fields=[]
            for row in rows:
                for key in row:
                    if key not in fields:fields.append(key)
            w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(rows)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('router',type=Path);p.add_argument('output',type=Path)
    p.add_argument('--a',type=Path);p.add_argument('--b',type=Path);args=p.parse_args();args.output.mkdir(parents=True,exist_ok=False)
    def read(name):
        path=args.router/name
        return path.read_text(errors='replace') if path.exists() else ''
    samples=fast_samples(read('link-timeline.log'));queries=port_queries(read('ports.log'))
    write_csv(args.output/'link-intervals.csv',fast_intervals(samples));write_csv(args.output/'physical-counters.csv',port_intervals(queries))
    network=network_samples(read('network.log'))
    write_csv(args.output/'host-returns.csv',host_intervals(network))
    write_csv(args.output/'wifi-costs.csv',cost_intervals(network))
    write_csv(args.output/'wifi-queues.csv',queue_intervals(network))
    write_csv(args.output/'wifi-feed.csv',feed_intervals(network))
    def diagnostic_rows(key):
        rows=[]
        for sample in network:
            for item in sample.get(key,[]):
                rows.append({'begin':sample['begin'],'end':sample['end'],**item})
        return rows
    light_load=light_hart4_load(read('trace.log'))
    for key,name in (('load','hart4-load.csv'),('prof','prof.csv'),('memory','prof-memory.csv'),
                     ('cpi','prof-cpi.csv'),('pc_pages','prof-pc-pages.csv'),
                     ('pc','prof-pc.csv'),('ps','ps-watchdog.csv'),
                     ('queue_copy','queue-copy.csv')):
        rows=diagnostic_rows(key)
        if key == 'load':
            rows += light_load
        if key == 'ps':
            # watchdog_runs includes 1-jiffy retry runs.  The 100 ms value is
            # only the no-event fallback ceiling, so expose the unambiguous
            # name without discarding the raw kernel field.
            for row in rows:
                if 'watchdog_runs' in row:
                    row['non_event_runs']=row['watchdog_runs']
                    row['watchdog_ceiling_ms']=row.get('watchdog_ms',100)
        write_csv(args.output/name,rows)
    result={'network':network,'manifest':read('manifest.txt'),'coverage':read('coverage.txt'),'markers':read('markers.log'),'events':read('events.log'),'fast_samples':len(samples),'queries':queries,
            'endpoint_A':endpoint(args.a),'endpoint_B':endpoint(args.b),
            'limits':['Physical counters have their own query windows; align using recorded times.',
                      'Do not sum eth0 and DSA slave byte counters as independent traffic.',
                      'Unsupported eth-ctrl is unknown PAUSE activity, not zero.',
                      'Only synchronized endpoint SEQ/ACK/window evidence can localize a TCP slowdown.',
                      'PSE occupancy is a snapshot, not a history of backpressure.',
                      'Host causes overlap with dispositions: do not sum them as packet losses.',
                      'KH2 guard_full/rx_busy/tx_busy/chain_busy count attempts, not lost packets; expired counts terminal timeout.',
                      'KP1 is only the last PS miss; candidate_hw_slot is not a measurement of the actual ingress FOE slot.',
                      'HOLD retains ownership; negative rejection counts need direction/caller context.',
                      'KC1 stages have different call populations; do not sum means or extrapolate sampled loop counts to packets.',
                      'GSW/PHY snapshots are sequential; error fields mean unavailable, not a zero register.',
                      'QDMA/BQL are independent gauges, not atomic queue accounting; host page is cached 10s.']}
    result['limits'].append('hart4_load from trace.log is a busy/idle service-round counter; it is not CPU time or a percentage.')
    result['limits'].append('r79_ps watchdog_runs/non_event_runs includes 1-jiffy retries; watchdog_ceiling_ms is only the no-event fallback ceiling.')
    (args.output/'evidence.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(f"{len(samples)} link samples, {len(queries)} queries; written to {args.output}")
if __name__=='__main__':main()
