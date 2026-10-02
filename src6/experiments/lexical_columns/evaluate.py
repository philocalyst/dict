#!/usr/bin/env python3
"""Apply the frozen constructor policy to named, hash-locked native root groups.

No corpus fitting, parameter search or timing occurs without the explicit quiet
gate. Every selected backend frame and every candidate constructor receives an
exact source-byte gate; native admission uses the frozen C++ inverse and model.
"""
import argparse, hashlib, json, pathlib, platform, re, struct, subprocess, sys

from register_screen import decode
from prefix_screen import restore_raw
from screen import Codec, bundle, frame_digest, sha

HERE=pathlib.Path(__file__).resolve().parent

def run(argv, output):
    with output.open('wb')as stream:
        subprocess.run([str(x)for x in argv], stdout=stream, check=True)
    return [json.loads(line)for line in output.read_text().splitlines()if line]

def verify_bundle(path, source_frames, groups, backend):
    data=path.read_bytes();codec=Codec(backend)
    assert len(data)>=64 and data[:8]==b'LCB1'+bytes((1,8,1 if backend=='bzip3'else 2,0))
    assert frame_digest(data)==data[32:64]
    pages,roots,directory=struct.unpack_from('<3I',data,8)
    assert pages==len(groups)and roots==sum(g[1]for g in groups)and directory==24
    at=64+24*pages
    for i,(original,group)in enumerate(zip(source_frames,groups)):
        first,count,raw,stored,offset,mode,a,b,c=struct.unpack_from('<5I4B',data,64+i*24)
        assert(first,count)==group and mode==8 and not(a|b|c)and offset==at
        assert stored<=len(data)-at
        restored=decode(data[at:at+stored],codec)
        assert len(restored)==raw and restore_raw(restored)==original
        at+=stored
    assert at==len(data)
    return sha(data)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--manifest',type=pathlib.Path,required=True)
    p.add_argument('--freeze',type=pathlib.Path,required=True)
    p.add_argument('--output',type=pathlib.Path,required=True)
    p.add_argument('--native-client',type=pathlib.Path,required=True)
    p.add_argument('--operations',type=int,default=512)
    p.add_argument('--quiet-gate',choices=['ROOT-EXPLICIT-QUIET-GATE'])
    args=p.parse_args()
    assert 1<=args.operations<=1_000_000
    frozen=json.loads(args.freeze.read_text())
    assert frozen['protocol']=='LEXICAL-CONSTRUCTIONS-FREEZE/1'
    for name,digest in frozen['files'].items():
        assert sha(pathlib.Path(name).read_bytes())==digest,('frozen file changed',name)
    client=args.native_client.resolve()
    assert str(client)in frozen['files']and sha(client.read_bytes())==frozen['files'][str(client)]
    inputs=json.loads(args.manifest.read_text())
    assert inputs['protocol']=='LEXICAL-CONSTRUCTIONS-EVALUATION-INPUT/1'
    datasets=inputs['datasets'];assert datasets
    names=set()
    # Validate every nominated source before creating any output. The policy
    # does not read outcomes from this or an earlier evaluation.
    for item in datasets:
        assert re.fullmatch('[A-Za-z0-9_-]+',item['name'])and item['name']not in names
        names.add(item['name'])
        assert sha(pathlib.Path(item['flat_bundle']).read_bytes())==item['sha256']
    args.output.mkdir(parents=True,exist_ok=True)
    summary=[]
    for item in datasets:
        directory=args.output/item['name'];directory.mkdir(exist_ok=True)
        flat=pathlib.Path(item['flat_bundle'])
        source,frames,groups=bundle(flat)
        assert len(groups)==item['pages']and sum(g[1]for g in groups)==item['roots']
        screen_argv=[sys.executable,HERE/'register_screen.py',flat,'--retain-directory',directory]
        if args.quiet_gate:screen_argv+=['--quiet-gate',args.quiet_gate]
        # The byte image must remain fixed when clocks are enabled later.
        previous={str(f):sha(f.read_bytes())for f in directory.glob('*.lcp')}
        previous.update({str(f):sha(f.read_bytes())for f in directory.glob('*.lcb')})
        screen=run(screen_argv,directory/('screen.quiet.jsonl'if args.quiet_gate else'screen.jsonl'))
        for name,digest in previous.items():assert sha(pathlib.Path(name).read_bytes())==digest
        native_argv=[client,flat,directory,str(args.operations)]
        if args.quiet_gate:native_argv+=['--quiet-gate',args.quiet_gate]
        native=run(native_argv,directory/('native.quiet.jsonl'if args.quiet_gate else'native.jsonl'))
        gate=native[0]
        assert gate['pages']==item['pages']and gate['roots']==item['roots']
        adaptive=[r for r in screen if r.get('representation')=='root_prefix_register_adaptive']
        assert len(adaptive)==2
        bzip=next(r for r in adaptive if r['backend']=='bzip3')
        assert gate['baseline_complete_bytes']==bzip['flat_complete_bytes']
        assert gate['columns_complete_bytes']==bzip['complete_bytes']
        # Admit all three native constructor modes. This also proves the C++
        # inverse for zstd-selected modes when its MDL choice differs from bzip.
        for mode in range(3):
            aliases=directory/f'native-mode{mode}';aliases.mkdir(exist_ok=True)
            for i in range(len(groups)):
                alias=aliases/f'register_adaptive.bzip3.{i:05d}.lcp'
                target=(directory/f'register{mode}.bzip3.{i:05d}.lcp').resolve()
                if alias.is_symlink():assert alias.resolve()==target
                else:alias.symlink_to(target)
            run([client,flat,aliases,str(args.operations)],directory/f'native-mode{mode}.jsonl')
        for record in adaptive:
            backend=record['backend']
            record={**record,'dataset':item['name'],'source_sha256':sha(source),
                    'complete_bundle_sha256':verify_bundle(directory/f'register_adaptive.{backend}.lcb',frames,groups,backend),
                    'native_gate':'selected bzip frame and every candidate constructor native-admitted; every full canonical Entry/source packet exact; all direct projections and hot IDs/headwords parity',
                    'frozen_manifest_sha256':sha(args.freeze.read_bytes())}
            summary.append(record)
    (args.output/'summary.json').write_text(json.dumps(summary,sort_keys=True,indent=2)+'\n')
    runtime={'protocol':'LEXICAL-CONSTRUCTIONS-EVALUATION/1','input_manifest':str(args.manifest.resolve()),
             'input_manifest_sha256':sha(args.manifest.read_bytes()),'freeze_manifest_sha256':sha(args.freeze.read_bytes()),
             'harness_sha256':sha(pathlib.Path(__file__).read_bytes()),'native_client_sha256':sha(client.read_bytes()),
             'python':sys.version,'platform':platform.platform(),'quiet_gate':bool(args.quiet_gate),
             'operations':args.operations,'selection':'frozen global complete-frame minimum; no fitting or parameter changes',
             'datasets':[item['name']for item in datasets]}
    (args.output/'runtime.json').write_text(json.dumps(runtime,sort_keys=True,indent=2)+'\n')
    print(json.dumps({'protocol':runtime['protocol'],'datasets':runtime['datasets'],'summary':str((args.output/'summary.json').resolve()),'quiet_gate':runtime['quiet_gate']},sort_keys=True))

if __name__=='__main__':main()
