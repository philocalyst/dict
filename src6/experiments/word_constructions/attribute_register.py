#!/usr/bin/env python3
"""Schema-free exact register construction within tag-like records.

For a list-valued quoted field, search earlier quoted fields for a byte
prefix and suffix common to every list member. Emit the earlier field's
index, two overlap lengths, and the shortened member spellings. The decoder
uses only bytes carried by the current record and this fixed rule.
"""
import re

from dependent_fields import overlap

TAG = re.compile(rb"<[A-Za-z][^<>]{0,4093}>")
ATTR = re.compile(rb'([A-Za-z_:][A-Za-z0-9:._-]*)="([^"]*)"')
MARK = b"\x00\x01"


def forward(data):
    escaped = data.replace(b"\x00", b"\x00\x00")
    stats = {"records": 0, "members": 0, "removed_bytes": 0, "pairs": {}}

    def change(m):
        tag = m.group()
        attrs = list(ATTR.finditer(tag))
        best = None
        for i, field in enumerate(attrs):
            names = field.group(2).split(b" ")
            if not names or any(not name for name in names):
                continue
            for j, earlier in enumerate(attrs[:i]):
                if j >= 256:  # the on-wire donor index occupies one byte
                    continue
                id_value = earlier.group(2)
                if len(id_value) > 256:
                    continue
                p, s = overlap(id_value, names)
                if p+s < 4 or max(p,s) < 2 or p > 31 or s > 31 or p+s >= min(map(len,names)):
                    continue
                gain = len(names)*(p+s)-5
                if gain <= 8:
                    continue
                if best is None or gain > best[0]:
                    best = (gain, i, j, p, s, names)
        if best is None:
            return tag
        gain, i, j, p, s, names = best
        field = attrs[i]
        shortened = b" ".join(name[p:len(name)-s if s else len(name)] for name in names)
        stats["records"] += 1
        stats["members"] += len(names)
        stats["removed_bytes"] += len(names)*(p+s)
        key = f"{attrs[j].group(1).decode('latin1')}->{field.group(1).decode('latin1')}:{p},{s}"
        stats["pairs"][key] = stats["pairs"].get(key, 0) + 1
        return tag[:field.start(2)] + MARK + bytes((j,p,s)) + shortened + tag[field.end(2):]

    return TAG.sub(change, escaped), stats


def inverse(transformed):
    def change(m):
        tag = m.group()
        attrs = list(ATTR.finditer(tag))
        marked = [(i,a) for i,a in enumerate(attrs) if a.group(2).startswith(MARK)]
        if not marked:
            return tag
        if len(marked) != 1:
            raise ValueError("multiple references in record")
        i, field = marked[0]
        value = field.group(2)
        if len(value) < 5:
            raise ValueError("short reference")
        j,p,s = value[2:5]
        if j >= i or p > 31 or s > 31 or p+s < 4:
            raise ValueError("bad register")
        source = attrs[j].group(2)
        if len(source) > 256 or p > len(source) or s > len(source):
            raise ValueError("bad overlap")
        prefix = source[:p]
        suffix = source[-s:] if s else b""
        words = value[5:].split(b" ")
        restored = b" ".join(prefix + word + suffix for word in words)
        return tag[:field.start(2)] + restored + tag[field.end(2):]

    return TAG.sub(change, transformed).replace(b"\x00\x00", b"\x00")
