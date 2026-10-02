#!/usr/bin/env python3
"""Exact bounded ancestor-field references for tag-like records.

The register stack holds the last 32 open tags and at most 32 quoted fields
per tag. A child value may copy a slice of an ancestor value or concatenate
an ancestor prefix, literal bytes, and an ancestor suffix. Every operand is
explicitly carried in the transformed stream; ineligible bytes pass through.
"""
import re

TOKEN = re.compile(rb'<(/?)([A-Za-z][A-Za-z0-9:._-]*)([^<>]{0,4092})>')
ATTR = re.compile(rb'([A-Za-z_:][A-Za-z0-9:._-]*)="([^"]*)"')
COPY_SLICE = b"\x00\x02"
COPY_EDGES = b"\x00\x03"


def edges(donor, target):
    p = 0
    while p < min(len(donor),len(target)) and donor[p] == target[p]:
        p += 1
    s = 0
    while s < len(donor) and p+s+1 < len(target) and donor[-s-1] == target[-s-1]:
        s += 1
    return p,s


def advance_stack(stack, token, values):
    name = token.group(2)
    if token.group(1):
        if stack and stack[-1][0] == name:
            stack.pop()
        else:
            stack.clear()
    elif not token.group(3).rstrip().endswith(b"/"):
        if len(stack) < 32:
            stack.append((name, [v if len(v) <= 256 else b"" for v in values[:32]]))


def forward(data):
    stack = []
    out = bytearray()
    last = 0
    stats = {"slices": 0, "edges": 0, "removed_bytes": 0, "field_pairs": {}}
    for token in TOKEN.finditer(data):
        tag = token.group()
        if len(tag) > 4096:
            out += data[last:token.end()]
            last = token.end()
            continue
        attrs = list(ATTR.finditer(tag))
        values = [a.group(2) for a in attrs]
        best = None
        if not token.group(1):
            for i, field in enumerate(attrs):
                target = field.group(2)
                if len(target) < 8 or target.startswith(b"\x00\x01") or target.startswith(COPY_SLICE) or target.startswith(COPY_EDGES):
                    continue
                for depth, (_, sources) in enumerate(reversed(stack)):
                    for idx, donor in enumerate(sources):
                        if not donor or donor.startswith(b"\x00"):
                            continue
                        pos = donor.find(target)
                        if pos >= 0 and pos <= 31 and len(target) <= 31:
                            gain = len(target)-6
                            if gain > 2 and (best is None or gain > best[0]):
                                best = (gain,i,COPY_SLICE,depth,idx,pos,len(target),b"")
                        p,s = edges(donor,target)
                        if p <= 31 and s <= 31 and p+s <= len(target):
                            gain = p+s-6
                            if gain > 2 and (best is None or gain > best[0]):
                                best = (gain,i,COPY_EDGES,depth,idx,p,s,target[p:len(target)-s if s else len(target)])
        if best is not None:
            gain,i,kind,depth,idx,a,b,literal = best
            field = attrs[i]
            replacement = kind + bytes((depth,idx,a,b)) + literal
            tag = tag[:field.start(2)] + replacement + tag[field.end(2):]
            label = f"{stack[-1-depth][0].decode('latin1')}->{field.group(1).decode('latin1')}"
            stats["field_pairs"][label] = stats["field_pairs"].get(label,0)+1
            stats["slices" if kind == COPY_SLICE else "edges"] += 1
            stats["removed_bytes"] += gain
        out += data[last:token.start()]
        out += tag
        last = token.end()
        advance_stack(stack, token, values)
    out += data[last:]
    return bytes(out), stats


def inverse(data):
    stack = []
    out = bytearray()
    last = 0
    for token in TOKEN.finditer(data):
        tag = token.group()
        if len(tag) > 4096:
            out += data[last:token.end()]
            last = token.end()
            continue
        attrs = list(ATTR.finditer(tag))
        marked = [(i,a) for i,a in enumerate(attrs) if a.group(2).startswith((COPY_SLICE,COPY_EDGES))]
        if marked:
            if len(marked) != 1 or token.group(1):
                raise ValueError("bad scoped references")
            _,field = marked[0]
            value = field.group(2)
            if len(value) < 6:
                raise ValueError("short scoped reference")
            depth,idx,a,b = value[2:6]
            if depth >= len(stack) or idx >= len(stack[-1-depth][1]):
                raise ValueError("missing ancestor")
            donor = stack[-1-depth][1][idx]
            if value.startswith(COPY_SLICE):
                if len(value) != 6 or a+b > len(donor):
                    raise ValueError("bad slice")
                restored = donor[a:a+b]
            else:
                if a > len(donor) or b > len(donor):
                    raise ValueError("bad edges")
                restored = donor[:a] + value[6:] + (donor[-b:] if b else b"")
            tag = tag[:field.start(2)] + restored + tag[field.end(2):]
        out += data[last:token.start()]
        out += tag
        last = token.end()
        attrs = list(ATTR.finditer(tag))
        advance_stack(stack, token, [a.group(2) for a in attrs])
    out += data[last:]
    return bytes(out)
