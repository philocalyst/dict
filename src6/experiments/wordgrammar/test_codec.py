#!/usr/bin/env python3
"""Fresh-process tests for exact surfaces, finite decode, and paid wire ledgers."""
import json,os,pathlib,random,subprocess,tempfile,unittest
HERE=pathlib.Path(__file__).resolve().parent
EXE=pathlib.Path(os.environ.get('WGR_TEST_EXE',HERE/'wordgrammar')).resolve()
class Codec(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='wordgrammar-test-');self.p=pathlib.Path(self.temp.name)
 def tearDown(self):self.temp.cleanup()
 def runcli(self,mode,src,dst,*options,env=None,ok=True):
  p=subprocess.run([str(EXE),mode,str(src),str(dst),*map(str,options)],capture_output=True,env=env,timeout=30)
  if ok:self.assertEqual(p.returncode,0,p.stderr.decode(errors='replace'))
  else:self.assertNotEqual(p.returncode,0,p.stderr.decode(errors='replace'))
  self.assertGreaterEqual(p.returncode,0,'signal/crash')
  return p
 def encode(self,raw,mode='encode-fast',block=8192,*args,env=None):
  inp=self.p/'raw';frame=self.p/'frame';inp.write_bytes(raw)
  p=self.runcli(mode,inp,frame,block,*args,env=env)
  return frame,json.loads(p.stderr)
 def test_roundtrips_restarts_determinism_and_ledger(self):
  rng=random.Random(20261001)
  cases=[b'',b'X',b'a'*17000,bytes(range(256))*80,rng.randbytes(23000),('العربية \u0623\u064e\u0643\u062a\u0628 فنلندية\n汉字かな日本語 Привет Türkçe e\u0301 café\n'*650).encode()]
  for raw in cases:
   with self.subTest(bytes=len(raw)):
    frame,stats=self.encode(raw);out=self.p/'decoded'
    p=self.runcli('decode',frame,out);self.assertEqual(out.read_bytes(),raw)
    self.assertGreaterEqual(json.loads(p.stderr)['codec_ns'],0)
    self.assertEqual(stats['frame'],frame.stat().st_size)
    self.assertEqual(stats['frame'],sum(stats[k] for k in ['model','directory_bytes','root_payload_bytes','copy_parameter_bytes']))
    saved=frame.read_bytes();info=self.p/'inspect';self.runcli('inspect',frame,info);j=json.loads(info.read_text())
    self.assertEqual(j['frame_bytes'],sum(j[k] for k in ['model_bytes','directory_bytes','payload_bytes']))
    for i,b in enumerate(j['records']):
     self.runcli('decode',frame,out,i);self.assertEqual(out.read_bytes(),raw[b['raw_offset']:b['raw_offset']+b['raw_size']])
    self.runcli('decode',frame,out,len(j['records']),ok=False)
    self.runcli('decode',frame,out,-2,ok=False)
    frame2,_=self.encode(raw);self.assertEqual(frame2.read_bytes(),saved)
 def test_every_truncation_and_frame_tail(self):
  # Complete strict-prefix sweep of a representative small delivered frame.
  frame,_=self.encode(('词語 كلمة café\n'*30).encode());wire=frame.read_bytes();bad=self.p/'bad';out=self.p/'out'
  for n in range(len(wire)):
   bad.write_bytes(wire[:n]);self.runcli('decode',bad,out,ok=False)
  for suffix in [b'\0',b'garbage',wire]:
   bad.write_bytes(wire+suffix);self.runcli('decode',bad,out,ok=False)
 def test_mutations_never_accept_wrong_output(self):
  raw=(('Lemma: dictionary\nSense: dictionary-related words and Wörter.\n'*160).encode()+bytes(range(256))*5)
  frame,_=self.encode(raw);wire=frame.read_bytes();bad=self.p/'bad';out=self.p/'out';rng=random.Random(913)
  for _ in range(1200):
   b=bytearray(wire);i=rng.randrange(len(b));b[i]^=1<<rng.randrange(8);bad.write_bytes(b)
   p=subprocess.run([str(EXE),'decode',str(bad),str(out)],capture_output=True,timeout=10)
   self.assertIn(p.returncode,[0,1],p.stderr.decode(errors='replace'))
   if not p.returncode:self.assertEqual(out.read_bytes(),raw)
 def test_direct_header_bounds_and_topological_grammar(self):
  env=os.environ.copy()
  for k in list(env):
   if k.startswith('WGR_'):env.pop(k)
  raw=b'abcdefghij '*200;frame,_=self.encode(raw,'encode',8192,64,4,2,24,2,128,env=env);wire=frame.read_bytes()
  def put(v):
   out=[]
   while True:
    out.append((v&127)|(128 if v>>7 else 0));v>>=7
    if not v:return bytes(out)
  def get(p):
   value=0;shift=0;start=p
   while True:
    x=wire[p];p+=1;value|=(x&127)<<shift;shift+=7
    if not x&128:return start,p,value
  fields=[];p=4
  for _ in range(5):
   a,p,v=get(p);fields.append((a,p,v))
  self.assertGreater(fields[3][2],0)
  bad=self.p/'bad';out=self.p/'out'
  mutations=[]
  for i,value in [(0,(1<<28)+1),(1,0),(1,(1<<24)+1),(2,0),(2,4097),(3,16129),(4,0),(4,65)]:
   a,b,_=fields[i];mutations.append(wire[:a]+put(value)+wire[b:])
  a,b,_=get(p);mutations.append(wire[:a]+put(256)+wire[b:]) # First rule cannot refer to itself.
  a,b,_=fields[0];mutations.append(wire[:a]+b'\x80'*11+wire[b:])
  mutations.append(b'WGP3'+put((1<<24)+1)+b'\x01')
  for candidate in mutations:
   bad.write_bytes(candidate);self.runcli('decode',bad,out,ok=False)
 def test_restart_size_and_longest_parameter_bounds(self):
  raw=random.Random(41).randbytes(24000)
  raw+=raw[:7000]+raw[:1200]+('中文 العربي a\u0301\n'*200).encode()
  frame,_=self.encode(raw,'encode-fast',65536)
  self.runcli('decode',frame,self.p/'long-distance')
  self.assertEqual((self.p/'long-distance').read_bytes(),raw)
  for block in [65537,1<<21,1<<22,1<<24]:
   self.runcli('encode-fast',self.p/'raw',self.p/'oversize-block',block,ok=False)
  # Actual source from the independent audit's 2.2MiB-distance failure. The
  # capped API rejects it before grammar or joint-DP allocation.
  large=self.p/'large'
  with large.open('wb') as f:f.truncate(2_300_000)
  self.runcli('encode-fast',large,self.p/'large-frame',1<<22,ok=False)
 def test_encoder_preread_budget_and_auto_objective(self):
  giant=self.p/'sparse'
  with giant.open('wb') as f:f.truncate((1<<26)+1)
  p=self.runcli('encode-fast',giant,self.p/'too-large',ok=False);self.assertIn(b'input limit',p.stderr)
  raw=b''.join(f'compressible_prefix_{i:04d}\n'.encode() for i in range(180))
  frame,stats=self.encode(raw,'encode-auto');chosen=frame.read_bytes();self.assertEqual(stats['search_candidates'],6)
  sizes=[]
  for cap in [0,128,512,2048,8192,16128]:
   f,s=self.encode(raw,'encode-fast',8192,cap,32,2,24,8,128);sizes.append(s['frame'])
  self.assertEqual(len(chosen),min(sizes));(self.p/'chosen').write_bytes(chosen)
  self.runcli('decode',self.p/'chosen',self.p/'out');self.assertEqual((self.p/'out').read_bytes(),raw)
if __name__=='__main__':unittest.main()
