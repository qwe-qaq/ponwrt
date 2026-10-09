#!/usr/bin/env python3
"""Run on each wireless PC, with iperf3 servers on a wired PC.
Alternates RX/TX and TCP/UDP in bounded blocks, retaining each outcome through
planned AP/reset interruptions. This only generates traffic to the given host.
"""
import argparse,datetime,json,os,signal,subprocess,time
from pathlib import Path

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--server',required=True);ap.add_argument('--port',type=int,default=5201)
    ap.add_argument('--hours',type=float,default=24);ap.add_argument('--block',type=int,default=120)
    ap.add_argument('--udp-mbps',type=float,default=20);ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--iperf',default='iperf3');ap.add_argument('--ipv6',action='store_true')
    args=ap.parse_args()
    if not 0<args.hours<=72 or not 1<=args.port<=65535 or not 5<=args.block<=3600 or not 0<args.udp_mbps<=10000:ap.error('invalid duration, port, block or rate')
    args.output.mkdir(parents=True,exist_ok=False)
    stop=False
    def stopping(*_):
        nonlocal stop
        stop=True
    for sig in (signal.SIGINT,signal.SIGTERM):signal.signal(sig,stopping)
    modes=[('tcp-download',['-R','-P','4']),('tcp-upload',['-P','4']),
           ('udp-download',['-R','-u','-b',f'{args.udp_mbps}M','-l','1200']),
           ('udp-upload-small',['-u','-b',f'{args.udp_mbps}M','-l','128'])]
    start=time.monotonic();deadline=start+args.hours*3600;count=failures=0
    with (args.output/'results.jsonl').open('x') as log:
        while not stop and time.monotonic()+5<deadline:
            name,extra=modes[count%len(modes)];duration=min(args.block,int(deadline-time.monotonic()))
            command=[args.iperf,'-c',args.server,'-p',str(args.port),'-J','-i','0','-t',str(duration),*extra]
            if args.ipv6:command+=['-6']
            record={'index':count,'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'mode':name,'command':command}
            begin=time.monotonic();proc=None
            try:
                proc=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                while True:
                    try:
                        stdout,stderr=proc.communicate(timeout=1)
                        break
                    except subprocess.TimeoutExpired:
                        if stop or time.monotonic()-begin>duration+20:
                            proc.terminate()
                            try:stdout,stderr=proc.communicate(timeout=3)
                            except subprocess.TimeoutExpired:
                                proc.kill();stdout,stderr=proc.communicate()
                            record['interrupted']=stop;record['timeout']=not stop
                            break
                record['exit_code']=proc.returncode
                try:record['iperf']=json.loads(stdout)
                except json.JSONDecodeError:record['stdout']=stdout[-4096:]
                if stderr:record['stderr']=stderr[-4096:]
            except OSError as exc:
                record['error']=str(exc);record['exit_code']=-1;stop=True
            record['seconds']=time.monotonic()-begin
            failed=record['exit_code']!=0 or bool(record.get('iperf',{}).get('error'))
            failures+=bool(failed);count+=1
            log.write(json.dumps(record)+'\n');log.flush()
            print(f"{count}: {name}: {'FAIL' if failed else 'OK'} ({record['seconds']:.1f}s)",flush=True)
            # A recovering AP must not create a tight failed-connect loop.
            wait_until=time.monotonic()+(5 if failed else 1)
            while not stop and time.monotonic()<min(wait_until,deadline):time.sleep(.2)
    (args.output/'summary.json').write_text(json.dumps({'blocks':count,'failed_blocks':failures,'elapsed_seconds':time.monotonic()-start,
        'requested_hours':args.hours,'stopped_early':stop,'server':args.server,'port':args.port,
        'note':'Correlate failed blocks with deliberately marked recovery; zero failures alone does not prove CPU reduction or security isolation.'},indent=2)+'\n')
    return 0 if count and failures<count else 1
if __name__=='__main__':raise SystemExit(main())
