#!/usr/bin/env python3
"""A separate quiet-only timing stage over the immutable source/model freeze.

Preparation reads hashes and existing results only. The run consists of one
discarded warmup and five serial paired trials, using the exact frozen encoder
and native reader. This file is linked by its own hash in the prepared protocol;
it does not edit any file covered by the dictionary source freeze.
"""
import argparse, contextlib, io, json, pathlib, platform, statistics, struct
import subprocess, sys, time
import zstandard

import register_screen as encoder
from screen import bundle, frame_digest, pack_bundle, sha, verify_stored_bundle

HERE=pathlib.Path(__file__).resolve().parent
QUIET='ROOT-EXPLICIT-QUIET-GATE'

def records(path):
    return [json.loads(line)for line in pathlib.Path(path).read_text().splitlines()if line]

def guard(freeze, driver_hash):
    assert sha(pathlib.Path(__file__).read_bytes())==driver_hash,'timing-stage source changed'
    for name,digest in freeze['files'].items():
        assert sha(pathlib.Path(name).read_bytes())==digest,('frozen dependency changed',name)

def describe_case(name, flat, directory, result_records):
    raw,frames,groups=bundle(flat)
    rows=[r for r in result_records if r.get('representation')=='root_prefix_register_adaptive']
    assert len(rows)==2
    expected={r['backend']:{'flat_complete_bytes':r['flat_complete_bytes'],'complete_bytes':r['complete_bytes'],'choices':r['choices']}for r in rows}
    images={f.name:sha(f.read_bytes())for f in directory.glob('*.lcp')}
    images.update({f.name:sha(f.read_bytes())for f in directory.glob('*.lcb')})
    assert images and len(images)==8+8*len(groups)
    return {'name':name,'flat':str(flat.resolve()),'flat_sha256':sha(raw),
            'pages':len(groups),'roots':sum(g[1]for g in groups),
            'expected':expected,'source_frame_directory':str(directory.resolve()),
            'image_sha256':images,'flat_payload_bytes':sum(map(len,frames))}

def prepare(args):
    assert not args.quiet_gate,'preparation does not start clocks'
    frozen=json.loads(args.freeze.read_text())
    assert frozen['protocol']=='LEXICAL-CONSTRUCTIONS-FREEZE/1'
    driver_hash=sha(pathlib.Path(__file__).read_bytes())
    guard(frozen,driver_hash)
    instrumentation=json.loads(args.instrumentation_manifest.read_text())
    assert instrumentation['protocol']=='LEXICAL-CONSTRUCTIONS-ORDER-INSTRUMENTATION/1'
    assert instrumentation['source_freeze_sha256']==sha(args.freeze.read_bytes())
    for name,digest in instrumentation['files'].items():assert sha(pathlib.Path(name).read_bytes())==digest
    manifest=json.loads(args.input_manifest.read_text())
    summary=json.loads((args.final_directory/'summary.json').read_text())
    cases=[]
    for item in manifest['datasets']:
        flat=pathlib.Path(item['flat_bundle'])
        assert sha(flat.read_bytes())==item['sha256']
        cases.append(describe_case(item['name'],flat,args.final_directory/item['name'],
                                   [r for r in summary if r['dataset']==item['name']]))
    rich=pathlib.Path('/workspace/scratch/lexical-pages-shape-rich128.flat.raw.lpb')
    cases.append(describe_case('rich128',rich,pathlib.Path('/workspace/scratch/lexical-prefix-register-rich128'),
                               records('/workspace/scratch/lexical-prefix-register-rich128.screen.jsonl')))
    client=args.native_client.resolve()
    assert str(client)in instrumentation['files']and sha(client.read_bytes())==instrumentation['files'][str(client)]
    protocol={'protocol':'LEXICAL-CONSTRUCTIONS-QUIET/2','source_freeze':str(args.freeze.resolve()),
              'source_freeze_sha256':sha(args.freeze.read_bytes()),'timing_stage_sha256':driver_hash,
              'input_manifest':str(args.input_manifest.resolve()),'input_manifest_sha256':sha(args.input_manifest.read_bytes()),
              'native_client':str(client),'native_client_sha256':sha(client.read_bytes()),
              'instrumentation_manifest':str(args.instrumentation_manifest.resolve()),
              'instrumentation_manifest_sha256':sha(args.instrumentation_manifest.read_bytes()),
              'output':str(args.output.resolve()),'warmups':1,'paired_trials':5,'operations':args.operations,
              'cases':cases,'query_scope':'frozen native bzip3 reader; headword same-root and deterministic mixed-root; resident immutable compressed pages; fresh required-block decode every operation; no page cache; full admission and oracle/setup separately clocked; fixed native client also records label/source probes',
              'order':'serial cases; discarded baseline-first warmup; five native fresh-process paired trials alternate AB/BA/AB/BA/AB (three baseline-first, two construction-first); each query/access pair follows the trial order; encoder order remains flat baseline before three candidates and is not reversed',
              'encoder_scope':'both bzip3 and zstd19 matched flat controls; every literal/local/local+ancestor trial and duplicated hot encode paid; root-prefix preparation (including its extra exact restore oracle), backend initialization, all candidate/selected outer-bundle assembly charged separately; candidate per-page assembly included in frozen pipeline; verification and evidence IO separate',
              'scope_limits':['zstd19 is an encoder/complete-frame size control; no native zstd query latency is claimed','prefix preparation includes an embedded extra source restore oracle, so its charged time is conservative','named forward/backend phase times are subsets of candidate_pipeline and must not be summed again','fixed frozen native client records label/source probes after headwords; rich128 has no first direct definition for the source probe','native C/C++ allocations are bounded but not individually metered as Zig allocator calls'],
              'python':sys.version,'platform':platform.platform(),
              'runtime_file_sha256':{str(pathlib.Path(sys.executable).resolve()):sha(pathlib.Path(sys.executable).read_bytes()),
                                     str(pathlib.Path(zstandard.backend_c.__file__).resolve()):sha(pathlib.Path(zstandard.backend_c.__file__).read_bytes())},
              'zstandard_python_version':zstandard.__version__,'zstd_runtime_version':zstandard.ZSTD_VERSION,
              'quiet_jobs_started':False}
    args.output.mkdir(parents=True,exist_ok=True)
    (args.output/'protocol.json').write_text(json.dumps(protocol,sort_keys=True,indent=2)+'\n')
    print(json.dumps({'protocol':protocol['protocol'],'prepared':str((args.output/'protocol.json').resolve()),
                      'cases':len(cases),'warmups':1,'paired_trials':5,'clocks_started':False},sort_keys=True))

def timed_encoder(case, images, log):
    source,frames,groups=bundle(pathlib.Path(case['flat']))
    original_transform=encoder.transform
    original_pack=encoder.pack_bundle
    original_codec=encoder.Codec
    preparation_ns=0;outer_ns={};codecs={}
    def measured_transform(frame):
        nonlocal preparation_ns
        start=time.perf_counter_ns()
        result=original_transform(frame)
        preparation_ns+=time.perf_counter_ns()-start
        return result
    def measured_pack(*args):
        start=time.perf_counter_ns();result=original_pack(*args)
        backend=args[-1]
        outer_ns[backend]=outer_ns.get(backend,0)+time.perf_counter_ns()-start
        return result
    class CapturedCodec(original_codec):
        def __init__(self,name):
            super().__init__(name)
            self.flat_encoded=[];codecs[name]=self
        def encode(self,data):
            result=super().encode(data)
            if len(self.flat_encoded)<len(frames):self.flat_encoded.append(result)
            return result
    encoder.transform=measured_transform
    encoder.pack_bundle=measured_pack
    encoder.Codec=CapturedCodec
    previous_argv=sys.argv
    output=io.StringIO()
    try:
        sys.argv=[str(HERE/'register_screen.py'),case['flat'],'--retain-directory',str(images),'--quiet-gate',QUIET]
        with contextlib.redirect_stdout(output):encoder.main()
    finally:
        sys.argv=previous_argv
        encoder.transform=original_transform;encoder.pack_bundle=original_pack;encoder.Codec=original_codec
    log.write_text(output.getvalue())
    found=[json.loads(line)for line in output.getvalue().splitlines()if line]
    for backend in('bzip3','zstd19'):
        adaptive=next(r for r in found if r.get('representation')=='root_prefix_register_adaptive'and r['backend']==backend)
        for key,value in case['expected'][backend].items():assert adaptive[key]==value
        row=next(r for r in found if r.get('protocol')=='LEXICAL-REGISTER-ENCODING-TIME/1'and r['backend']==backend)
        assert row['construction_encoding_trials_paid']==3*case['pages']
        assert row['phase_calls']['candidate_pipeline']==3*case['pages']
        assert row['phase_calls']['flat_baseline_encode']==case['pages']
        assert row['phase_calls']['hot_backend_encode']==3*case['pages']
        assert row['phase_calls']['cold_backend_encode']==3*case['pages']
        codec=codecs[backend]
        start=time.perf_counter_ns()
        baseline=pack_bundle(source,groups,frames,codec.flat_encoded,0,backend)
        flat_outer_ns=time.perf_counter_ns()-start
        assert len(baseline)==case['expected'][backend]['flat_complete_bytes']
        verify_stored_bundle(baseline,frames,codec,0)
        path=images/f'flat.{backend}.lcb'
        previous=sha(path.read_bytes())if path.exists()else None
        if previous:assert previous==sha(baseline)
        path.write_bytes(baseline)
        initialization=row['phase_ns']['backend_initialization']
        row['root_prefix_preparation_with_extra_restore_oracle_ns']=preparation_ns
        row['all_candidate_and_selected_outer_bundle_assembly_ns']=outer_ns[backend]
        row['flat_outer_bundle_assembly_ns']=flat_outer_ns
        row['charged_search_encoder_ns']=row['paid_candidate_and_selection_ns']+preparation_ns+outer_ns[backend]+initialization
        row['matched_flat_encoder_ns']=row['phase_ns']['flat_baseline_encode']+flat_outer_ns+initialization
        row['baseline_complete_bundle_sha256']=sha(baseline)
        row['root_prefix_preparation_is_conservative_oracle_inclusive']=True
    return found

def run(args):
    assert args.quiet_gate==QUIET,'root coordination is required before starting timed jobs'
    protocol_path=args.output/'protocol.json'
    protocol=json.loads(protocol_path.read_text())
    assert protocol['protocol']=='LEXICAL-CONSTRUCTIONS-QUIET/2'
    assert str(args.output.resolve())==protocol['output']
    assert protocol['operations']==args.operations and protocol['warmups']==1 and protocol['paired_trials']==5
    freeze_path=pathlib.Path(protocol['source_freeze'])
    assert sha(freeze_path.read_bytes())==protocol['source_freeze_sha256']
    frozen=json.loads(freeze_path.read_text())
    guard(frozen,protocol['timing_stage_sha256'])
    instrumentation_path=pathlib.Path(protocol['instrumentation_manifest'])
    assert sha(instrumentation_path.read_bytes())==protocol['instrumentation_manifest_sha256']
    instrumentation=json.loads(instrumentation_path.read_text())
    for name,digest in protocol['runtime_file_sha256'].items():assert sha(pathlib.Path(name).read_bytes())==digest
    assert sha(pathlib.Path(protocol['input_manifest']).read_bytes())==protocol['input_manifest_sha256']
    raw_rows=[];stable_queries={}
    for trial in range(6):
        trial_name='warmup'if trial==0 else f'trial-{trial:02d}'
        for case in protocol['cases']:
            guard(frozen,protocol['timing_stage_sha256'])
            for name,digest in instrumentation['files'].items():assert sha(pathlib.Path(name).read_bytes())==digest
            for name,digest in protocol['runtime_file_sha256'].items():assert sha(pathlib.Path(name).read_bytes())==digest
            assert sha(pathlib.Path(case['flat']).read_bytes())==case['flat_sha256']
            # Original FINAL frames stay untouched. All outputs go to one
            # reusable private frame directory and byte images remain fixed.
            source_images=pathlib.Path(case['source_frame_directory'])
            for name,digest in case['image_sha256'].items():assert sha((source_images/name).read_bytes())==digest
            images=args.output/'frame-images'/case['name'];images.mkdir(parents=True,exist_ok=True)
            logs=args.output/trial_name/case['name'];logs.mkdir(parents=True,exist_ok=True)
            encoded=timed_encoder(case,images,logs/'encoder.jsonl')
            for name,digest in case['image_sha256'].items():assert sha((images/name).read_bytes())==digest
            execution_order='construction_first'if trial>0 and trial%2==0 else'baseline_first'
            argv=[protocol['native_client'],case['flat'],str(images),str(args.operations),'--order',execution_order,'--quiet-gate',QUIET]
            with(logs/'native.jsonl').open('wb')as output:subprocess.run(argv,stdout=output,check=True)
            native=records(logs/'native.jsonl')
            gate=native[0]
            assert gate['quiet_gate']and gate['pages']==case['pages']and gate['roots']==case['roots']
            assert gate['execution_order']==execution_order
            assert gate['baseline_complete_bytes']==case['expected']['bzip3']['flat_complete_bytes']
            assert gate['columns_complete_bytes']==case['expected']['bzip3']['complete_bytes']
            assert len([r for r in native if'query'in r])==6
            for query in(r for r in native if'query'in r):
                assert query['operations']==args.operations
                assert query['execution_order']==execution_order and query['timed']
                key=(case['name'],query['query'],query['access'])
                observation=(query['query_hash'],query['query_bytes'])
                if key in stable_queries:assert stable_queries[key]==observation
                else:stable_queries[key]=observation
            guard(frozen,protocol['timing_stage_sha256'])
            for name,digest in case['image_sha256'].items():assert sha((source_images/name).read_bytes())==digest
            record={'trial':trial,'warmup':trial==0,'execution_order':execution_order,'dataset':case['name'],'encoder':encoded,'native':native,
                    'frame_images_sha256_unchanged':True,'source_runtime_freeze_guard':True}
            raw_rows.append(record)
            (logs/'trial.json').write_text(json.dumps(record,sort_keys=True,indent=2)+'\n')
            print(json.dumps({'dataset':case['name'],'trial':trial_name,'byte_and_query_gates':'pass'},sort_keys=True),flush=True)
    summary=[]
    for case in protocol['cases']:
        selected=[r for r in raw_rows if r['dataset']==case['name']and not r['warmup']]
        assert len(selected)==5
        for backend in('bzip3','zstd19'):
            e=[next(x for x in r['encoder']if x.get('protocol')=='LEXICAL-REGISTER-ENCODING-TIME/1'and x['backend']==backend)for r in selected]
            summary.append({'dataset':case['name'],'kind':'encoder','backend':backend,'trials':5,
                            'charged_search_encoder_ns':[r['charged_search_encoder_ns']for r in e],
                            'matched_flat_encoder_ns':[r['matched_flat_encoder_ns']for r in e],
                            'median_charged_search_encoder_ns':statistics.median(r['charged_search_encoder_ns']for r in e),
                            'median_matched_flat_encoder_ns':statistics.median(r['matched_flat_encoder_ns']for r in e),
                            'scope':protocol['encoder_scope']})
        for access in('same_root','mixed_root'):
            q=[next(x for x in r['native']if x.get('query')=='headword'and x['access']==access)for r in selected]
            summary.append({'dataset':case['name'],'kind':'headword','backend':'bzip3','access':access,'trials':5,
                            'operations_per_trial':args.operations,'baseline_ns':[r['baseline_ns']for r in q],
                            'construction_ns':[r['columns_ns']for r in q],
                            'paired_speedups':[r['speedup']for r in q],
                            'execution_orders':[r['execution_order']for r in q],
                            'median_paired_speedup':statistics.median(r['speedup']for r in q),
                            'query_hash':q[0]['query_hash'],'query_bytes':q[0]['query_bytes'],
                            'scope':protocol['query_scope']})
    (args.output/'summary.json').write_text(json.dumps(summary,sort_keys=True,indent=2)+'\n')
    runtime={'protocol':protocol['protocol'],'protocol_sha256':sha(protocol_path.read_bytes()),
             'timing_stage_sha256':protocol['timing_stage_sha256'],'source_freeze_sha256':protocol['source_freeze_sha256'],
             'instrumentation_manifest_sha256':protocol['instrumentation_manifest_sha256'],
             'warmups_discarded':1,'paired_trials':5,'all_gates_passed':True,
             'python':sys.version,'platform':platform.platform(),'query_scope':protocol['query_scope'],
             'order':protocol['order'],'scope_limits':protocol['scope_limits']}
    (args.output/'runtime.json').write_text(json.dumps(runtime,sort_keys=True,indent=2)+'\n')

def main():
    p=argparse.ArgumentParser()
    mode=p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare',action='store_true');mode.add_argument('--run',action='store_true')
    p.add_argument('--freeze',type=pathlib.Path,default=pathlib.Path('/workspace/scratch/lexical-columns-freeze-manifest.json'))
    p.add_argument('--input-manifest',type=pathlib.Path,default=pathlib.Path('/workspace/scratch/lexical-final-20261001/evaluation-input.json'))
    p.add_argument('--final-directory',type=pathlib.Path,default=pathlib.Path('/workspace/scratch/lexical-final-20261001/register-evaluation'))
    p.add_argument('--native-client',type=pathlib.Path,default=pathlib.Path('/workspace/scratch/lexical-columns-order-install/bin/lexical-register-order-access'))
    p.add_argument('--instrumentation-manifest',type=pathlib.Path,default=pathlib.Path('/workspace/scratch/lexical-columns-order-instrumentation-manifest.json'))
    p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('/workspace/scratch/lexical-columns-quiet-20261001'))
    p.add_argument('--operations',type=int,default=512)
    p.add_argument('--quiet-gate',choices=[QUIET])
    args=p.parse_args();assert 1<=args.operations<=1_000_000
    prepare(args)if args.prepare else run(args)

if __name__=='__main__':main()
