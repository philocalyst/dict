#!/usr/bin/env python3
"""Exact matched-block bzip3 control; low-level payload plus 13+8*n framing."""
import ctypes,json,pathlib,subprocess,time,sys
lib=ctypes.CDLL('/workspace/scratch/libbzip3.so')
lib.bz3_new.argtypes=[ctypes.c_int32];lib.bz3_new.restype=ctypes.c_void_p
lib.bz3_free.argtypes=[ctypes.c_void_p];lib.bz3_bound.argtypes=[ctypes.c_size_t];lib.bz3_bound.restype=ctypes.c_size_t
lib.bz3_encode_block.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int32];lib.bz3_encode_block.restype=ctypes.c_int32
lib.bz3_decode_block.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int32,ctypes.c_int32];lib.bz3_decode_block.restype=ctypes.c_int32
for f in sys.argv[1:]:
 raw=pathlib.Path(f).read_bytes();block=65536;state=lib.bz3_new(max(block,65*1024))
 if not state:raise RuntimeError('bzip3 state')
 buf=ctypes.create_string_buffer(lib.bz3_bound(block));parts=[];start=time.perf_counter_ns()
 for i in range(0,len(raw),block):
  s=raw[i:i+block];ctypes.memmove(buf,s,len(s));n=lib.bz3_encode_block(state,buf,len(s))
  if n<0:raise RuntimeError('bzip3 encode')
  parts.append((bytes(buf[:n]),len(s)))
 enc=time.perf_counter_ns()-start;start=time.perf_counter_ns();out=[]
 for s,n in parts:
  ctypes.memmove(buf,s,len(s));z=lib.bz3_decode_block(state,buf,len(buf),len(s),n)
  if z<0:raise RuntimeError('bzip3 decode')
  out.append(bytes(buf[:n]))
 dec=time.perf_counter_ns()-start;lib.bz3_free(state)
 if b''.join(out)!=raw:raise RuntimeError('control roundtrip')
 whole=subprocess.run(['/workspace/scratch/bzip3','-c',f],capture_output=True,check=True).stdout
 print(json.dumps(dict(input=f,raw=len(raw),bzip3_matched_bytes=sum(len(s) for s,n in parts)+13+8*len(parts),bzip3_whole_bytes=len(whole),encode_ns=enc,decode_ns=dec,decode_mbps=len(raw)*1000/dec)),flush=True)
