import itertools, unittest
from fractions import Fraction
from codec import Model, fit, encode_model, decode, parse, MAGIC

class Tests(unittest.TestCase):
    def test_roundtrip(self):
        for raw in (b'',b'x',bytes(range(256)),b'abcabcabc '*200, '\u65e5\u672c\u8a9e A\u0301'.encode()+b'\xff\x00\xfe'):
            literals,grammar=fit(raw,32)
            for boundary,mode in itertools.product(range(3),range(2)):
                model=Model(literals,grammar,boundary,7)
                frame,_=encode_model(raw,model,mode)
                self.assertEqual(decode(frame),raw)
                for bad in (frame[:-1], frame+b'\x00'):
                    with self.assertRaises(ValueError): decode(bad)
    def test_oracle(self):
        # Independent Fraction enumeration retains token IDs and offsets;
        # implementation merges only equal suffix AND destination states.
        model=Model([1]*256,[(97,98,7),(256,97,3)],0,7)
        q={(None,-1,0):Fraction(1)}
        state=model.initial()
        for byte in b'ababa':
            predicted=[Fraction(0) for _ in range(256)]; nextq={}
            for (i,k,off),mass in q.items():
                if i is None:
                    edges=model.edges.get(k); alpha=Fraction(7,8) if edges else Fraction(0)
                    for j,t in enumerate(model.tokens):
                        p=(1-alpha)*Fraction(model.counts[j],sum(model.counts))
                        if edges:
                            # Derive exact edge counts directly from the grammar.
                            row={}
                            for a,b,n in model.grammar:
                                if model.key(a)==k: row[b]=row.get(b,0)+n
                            p+=alpha*Fraction(row.get(j,0),sum(row.values()))
                        predicted[t[0]]+=mass*p
                        if t[0]==byte:
                            dest=(None,model.keys[j],0) if len(t)==1 else (j,model.keys[j],1)
                            nextq[dest]=nextq.get(dest,Fraction(0))+mass*p
                else:
                    t=model.tokens[i]; predicted[t[off]]+=mass
                    if t[off]==byte:
                        dest=(None,k,0) if off+1==len(t) else (i,k,off+1)
                        nextq[dest]=nextq.get(dest,Fraction(0))+mass
            self.assertEqual(sum(predicted),1)
            probs,starts=model.predictions(state)
            for p,r in zip(probs,predicted): self.assertAlmostEqual(p,float(r),places=12)
            z=sum(nextq.values()); q={k:v/z for k,v in nextq.items()}
            state=model.advance(state,byte,starts)
    def test_bounds(self):
        for grammar in ([(256,0,1)],[(0,0,0)],[(0,0,1)]*1025):
            with self.assertRaises(ValueError): Model([1]*256,grammar)
        with self.assertRaises(ValueError): parse(MAGIC+b'\x01\x00\x04'+b'\x80'*20)
    def test_paid_roots(self):
        from codec import select_edges
        raw=b'ababab baz baz qux '+b'\xff\xfe'*30
        lit,g,seq=fit(raw,32,return_sequence=True)
        for topology in (1,2):
            model=Model(lit,g,2,4,root_edges=select_edges(seq,64),topology=topology)
            for key in [-1]+model.keys:
                self.assertAlmostEqual(sum(model.row(key)),1.0,places=12)
            for mode in (0,1):
                frame,_=encode_model(raw,model,mode)
                self.assertEqual(decode(frame),raw)

if __name__=='__main__': unittest.main()
