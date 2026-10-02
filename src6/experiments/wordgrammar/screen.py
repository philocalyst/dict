#!/usr/bin/env python3
"""Paid-frame development screen; fresh decoder process verifies every candidate."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile,time
P=pathlib.Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('inputs',nargs='+');ap.add_argument('--rules',type=int,default=8192);ap.add_argument('--classes',type=int,default=16);ap.add_argument('--block',type=int,default=65536);ap.add_argument('--rounds',type=int,default=2);ap.add_argument('--prune',type=float,default=24);ap.add_argument('--reparse',action='store_true');ap.add_argument('--copy',action='store_true');a=ap.parse_args()
for f in a.inputs:
 raw=pathlib.Path(f).read_bytes()
 with tempfile.TemporaryDirectory(prefix='wgr-screen-') as d:
  d=pathlib.Path(d);frame=d/'frame';out=d/'out';env=os.environ.copy()
  if a.reparse:env['WGR_REPARSE']='1'
  if a.copy:env['WGR_COPY']='1'
  enc=time.perf_counter_ns();p=subprocess.run([str(P/'wordgrammar'),'encode',f,str(frame),str(a.block),str(a.rules),str(a.classes),str(a.rounds),str(a.prune),'8','128'],capture_output=True,env=env);enc=time.perf_counter_ns()-enc
  if p.returncode:raise RuntimeError(p.stderr.decode())
  dec=time.perf_counter_ns();q=subprocess.run([str(P/'wordgrammar'),'decode',str(frame),str(out)],capture_output=True);dec=time.perf_counter_ns()-dec
  if q.returncode or out.read_bytes()!=raw:raise RuntimeError(q.stderr.decode())
  info=json.loads(p.stderr);info.update(input=f,sha256=hashlib.sha256(raw).hexdigest(),frame_sha256=hashlib.sha256(frame.read_bytes()).hexdigest(),encode_ns=enc,decode_ns=dec,decode_mbps=len(raw)*1000/dec,reparse=a.reparse,copy=a.copy,source_sha256=hashlib.sha256((P/'codec.cpp').read_bytes()).hexdigest(),executable_sha256=hashlib.sha256((P/'wordgrammar').read_bytes()).hexdigest(),effective_wgr_environment={k:v for k,v in env.items() if k.startswith('WGR_')})
  print(json.dumps(info),flush=True)
