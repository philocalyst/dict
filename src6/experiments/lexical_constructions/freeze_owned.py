#!/usr/bin/env python3
"""Freeze corrected LTCv2 after exact retained DEV identities. No new fits."""
from __future__ import annotations
import hashlib,json,pathlib,shutil,subprocess
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[2]
SCRATCH=pathlib.Path('/workspace/scratch')
ORDER=('global_packet_ans','global_typed','global_surface','global_joint','global_owner','global_causal_surface','global_causal_joint','global_causal_joint_frequency','global_causal_owner','global_causal_owner_frequency')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    checks=SCRATCH/'lexical-constructions-v2-owned-checks';tests=json.loads((checks/'tests.json').read_text());replay=json.loads((checks/'replay.json').read_text())
    if [r['mode']for r in tests]!=['Debug','ReleaseSafe','ReleaseFast']or any(r['exit']for r in tests):raise ValueError('all three test modes must pass')
    if {r['case']for r in replay}!={'rich128','omw-ja-dev512'}or any(len(r['frame_identities'])!=11 or not r['control_identities']for r in replay):raise ValueError('all retained candidates/adaptive/controls must be identical')
    snapshot=SCRATCH/'lexical-constructions-v2-owned-capture';snapshot.mkdir(exist_ok=True);sources=snapshot/'source';sources.mkdir(exist_ok=True)
    for p in sorted(HERE.iterdir()):
        if p.is_file()and p.suffix in('.zig','.py','.md'):
            target=sources/p.name
            if target.exists()and sha(target)!=sha(p):raise ValueError('immutable snapshot overwrite')
            shutil.copyfile(p,target)
    report={'protocol':'LTCV2-OWNED-FREEZE/2','status':'corrected source/binary/policy frozen; DEV only; fresh outcomes unread','head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'historical_capture':{'path':str(HERE/'evidence/DEV-2-GLOBAL-20261001.json'),'sha256':sha(HERE/'evidence/DEV-2-GLOBAL-20261001.json'),'limitation':'historical Models.get escaped a by-value receiver field; historical runtime admission claims are superseded by these corrected gates; all actual frames are byte identical'},'correction':'Models.get receives *const Models; returned global pointer belongs to the actual owner; decoder copies own their inline global value and borrow shared heap overrides','ownership':'Verified owns Page pool/index/models; immutable bundle bytes are borrowed. Prepared copies safe inline model values and borrows heap/frame slices. No returned slice/pointer addresses a by-value receiver field; deinit of owner invalidates all prepared/surface views. No cold/no-cache query claim.','tests':tests,'test_logs_sha256':{r['log']:sha(pathlib.Path(r['log']))for r in tests},'failed_test_history':{'path':str(checks/'Debug-immutable-copy-assumption-failed.log'),'sha256':sha(checks/'Debug-immutable-copy-assumption-failed.log'),'reason':'test assumed distinct storage for immutable copies; corrected to independent mutable owner and unchanged original frequency; focused Debug and all three full modes pass'},'dev_replays':replay,'cases':{},'policy':{'ordered_candidates':ORDER,'complete_size_choice':'minimum actual complete LGB byte count; tie by declared candidate order','typed_access_choice':'same minimum restricted to actual native frame typed flag; tie by declared candidate order','encoder_cost':'all ten candidates encoded and fully admitted before either selector; no corpus/language branching or free model','stock':'one global immutable transmitted lexeme/causal program/model stock; independent root ANS streams; original groups retained in paid directory'},'limits':{'source_bundle_bytes':64*1024*1024,'original_page_bytes':1024*1024,'native_frame_bytes':64*1024*1024,'canonical_packet_total_bytes':32*1024*1024,'decoded_dictionary_bytes':32*1024*1024,'roots':65535,'lexemes':100000,'aggregate_work':64000000,'entropy_absolute_events':8000000,'entropy_models':8192,'per_root_packet_input_bytes':16*1024*1024,'per_root_packet_allocation_payload_bytes':32*1024*1024,'packet_slice_elements':1000000,'packet_depth':128,'native_semantic_scope':'unchanged default Scope; no weakened rule','construction_limits':'unchanged Document defaults; prior-program DAG, bound execution work/depth/output, exact explicit surface/analysis/realization admission'},'schema':{'native':'frozen v3 Entry and exact packet v3 source oracle','core_path':'/workspace/scratch/dict-core-v3-6f043/src6/root.zig','portable_replay':'git archive 6f043e245eea265e4a222524443e3ff01e09c3cb src6 into any absolute directory; pass its src6/root.zig with explicit -Dlexical-core','current_schema':'generic default current native core is a distinct contract; never silently reinterpret historical v3 bytes'},'build':{'optimize':'ReleaseSafe','argv':['zig','build','--build-file','src6/experiments/lexical_constructions/build.zig','-Dlexical-core=ABSOLUTE-FROZEN-V3/src6/root.zig','-Doptimize=ReleaseSafe','--prefix','INSTALL'],'log':str(checks/'install.log'),'log_sha256':sha(checks/'install.log')},'timing':False}
    for name in('rich128','omw-ja-dev512'):
        directory=SCRATCH/('lexical-constructions-v2-owned-'+name);ledger=json.loads((directory/'screen.json').read_text());rows=[json.loads(s)for s in(directory/'native.jsonl').read_text().splitlines()]
        if len(rows)!=10 or {r['variant']for r in rows}!=set(ORDER):raise ValueError('full matrix required')
        for p,h in ledger['provenance']['sources_sha256'].items():
            if sha(pathlib.Path(p))!=h:raise ValueError('source changed '+p)
        binary=pathlib.Path(ledger['provenance']['native_binary'])
        if sha(binary)!=ledger['provenance']['native_binary_sha256']:raise ValueError('binary changed')
        shutil.copyfile(binary,snapshot/binary.name)
        typed=[]
        for v in ORDER:
            b=(directory/(v+'.lgb')).read_bytes();offset=int.from_bytes(b[20:24],'little')
            if b[offset+5]&1:typed.append(v)
        choice=min(typed,key=lambda v:(ledger['variants'][v]['complete_bytes'],ORDER.index(v)));shutil.copyfile(directory/(choice+'.lgb'),directory/'typed-adaptive.lgb')
        row=next(r for r in rows if r['variant']==choice);s=row['stats']
        report['cases'][name]={'screen':ledger,'screen_sha256':sha(directory/'screen.json'),'native_rows':rows,'native_jsonl_sha256':sha(directory/'native.jsonl'),'typed_access_choice':choice,'typed_access_result':ledger['variants'][choice],'gates':{'all_native/source/headword/root/group_gates':True,'full_native_roots':10*ledger['roots'],'direct_typed_projection_roots':len(typed)*ledger['roots']},'memory':{'decoded_resident_stock_bytes':s['decoded_dictionary_bytes'],'owned_lexeme_index_bytes':row['decoded_lexeme_index_bytes'],'owned_model_heap_bytes':row['prepared_model_owned_heap_bytes'],'page_value_bytes':row['prepared_page_value_bytes'],'borrowed_complete_bundle_bytes':row['complete_bundle_bytes'],'scope':'retained allocation payload/components, excluding allocator/stack/transient admission overhead; not peak RSS'}}
    additional={}
    for p in list((ROOT/'vendor/bzip3').rglob('*.c'))+list((ROOT/'vendor/bzip3').rglob('*.h'))+list((HERE.parent/'bzip4/frontier_python/protocol').glob('*.py')):
        additional[str(p)]=sha(p)
    for p in(pathlib.Path('/workspace/scratch/libbzip3.so'),pathlib.Path('/lib/x86_64-linux-gnu/libc.so.6'),pathlib.Path('/home/agent/.local/lib/python3.12/site-packages/ziglang/zig')):
        additional[str(p)]=sha(p)
    report['additional_runtime_dependency_sha256']=additional;report['snapshot']=str(snapshot);report['snapshot_sha256']={str(p):sha(p)for p in sorted(snapshot.rglob('*'))if p.is_file()}
    output=HERE/'evidence/DEV-2-OWNED-FREEZE-20261001.json';output.write_text(json.dumps(report,sort_keys=True,indent=2)+'\n');print(json.dumps({'manifest':str(output),'sha256':sha(output),'native_binary_sha256':report['cases']['rich128']['screen']['provenance']['native_binary_sha256'],'snapshot':str(snapshot)},sort_keys=True))
if __name__=='__main__':main()
