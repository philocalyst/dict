"""Reachable Python state accounting, not RSS or kernel timing."""
from collections import deque
import json
import sys
from pathlib import Path
from codec import Source

HERE = Path(__file__).resolve().parent


def reachable_bytes(value, seen=None):
    if seen is None: seen = set()
    if id(value) in seen: return 0
    seen.add(id(value))
    result = sys.getsizeof(value)
    if isinstance(value,dict):
        result += sum(reachable_bytes(k,seen)+reachable_bytes(v,seen) for k,v in value.items())
    elif isinstance(value,(list,tuple,deque)):
        result += sum(reachable_bytes(v,seen) for v in value)
    elif hasattr(value,'__dict__'):
        result += reachable_bytes(value.__dict__,seen)
    return result


def main():
    options = json.loads((HERE/'runs/screen-v3/frozen.json').read_text())[0]
    raw = (HERE.parent/'evidence/runs/wam-screen-preflight-20260926/inputs/web2.prefix65536.bin').read_bytes()
    source = Source(**options)
    rows = []
    for i,b in enumerate(raw,1):
        source.prediction(); source.observe(b)
        if i in (2048,8192,16384,65536):
            rows.append(dict(raw_bytes=i,options=options,reachable_python_state_bytes=reachable_bytes(source),
                             index_keys=sum(len(m) for m in source.index.values()),
                             index_positions=sum(len(v) for m in source.index.values() for v in m.values()),
                             literal_rows=sum(len(m) for m in source.literal.values()),
                             literal_cells=sum(len(v) for m in source.literal.values() for v in m.values()),
                             max_frontier=source.max_frontier,copy_steps=source.copy_steps))
    (HERE/'runs/confirm-v3/cost.json').write_text(json.dumps(rows,indent=2)+'\n')
    print(json.dumps(rows,indent=2))


if __name__ == '__main__': main()
