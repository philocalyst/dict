from codec import encode as _encode, decode
def encode(raw, *, block_bytes=65536, **options):
    return _encode(raw,block_bytes=block_bytes,rules=64,boundary=2,strength=4,**options)
