// SWC1: experimental exact-byte word constructions + sequence grammar.
// Self-contained arithmetic coding. No external compression backend or model.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>
using namespace std;
using U8 = uint8_t; using U32 = uint32_t; using U64 = uint64_t;
static constexpr size_t BLOCK=65536, MAX_RAW=64*1024*1024, MAX_WORDS=32768, MAX_RULES=2048;
[[noreturn]] static void fail(const string& s){throw runtime_error(s);}
static vector<U8> readfile(const string& p){ifstream f(p,ios::binary);if(!f)fail("open "+p);f.seekg(0,ios::end);auto n=f.tellg();if(n<0||n>static_cast<streamoff>(MAX_RAW+64*1024*1024))fail("input size");f.seekg(0);vector<U8> v((size_t)n);if(n&&!f.read((char*)v.data(),n))fail("read");return v;}
static void writefile(const string& p,const vector<U8>& v){ofstream f(p,ios::binary);if(!f||!f.write((const char*)v.data(),v.size()))fail("write "+p);}
static void put32(vector<U8>& v,U32 x){for(int i=0;i<4;i++)v.push_back(x>>(8*i));}
static void put64(vector<U8>& v,U64 x){for(int i=0;i<8;i++)v.push_back(x>>(8*i));}
static U32 get32(const vector<U8>& v,size_t& p){if(v.size()-p<4)fail("truncated u32");U32 x=0;for(int i=0;i<4;i++)x|=U32(v[p++])<<(8*i);return x;}
static U64 get64(const vector<U8>& v,size_t& p){if(v.size()-p<8)fail("truncated u64");U64 x=0;for(int i=0;i<8;i++)x|=U64(v[p++])<<(8*i);return x;}
static void var(vector<U8>& v,U64 x){do{U8 b=x&127;x>>=7;v.push_back(b|(x?128:0));}while(x);}
static U64 unvar(const vector<U8>& v,size_t& p){U64 x=0;for(int i=0;i<10;i++){if(p>=v.size())fail("truncated varint");U8 b=v[p++];if(i==9&&b>1)fail("varint overflow");x|=U64(b&127)<<(7*i);if(!(b&128))return x;}fail("varint too long");}
static U64 hash64(const U8* p,size_t n){U64 h=1469598103934665603ULL;for(size_t i=0;i<n;i++){h^=p[i];h*=1099511628211ULL;}return h;}
struct BitOut{vector<U8> b;U8 cur=0;int bits=0;void put(int x){cur=(cur<<1)|x;if(++bits==8){b.push_back(cur);cur=0;bits=0;}}void done(){if(bits){b.push_back(cur<<(8-bits));cur=0;bits=0;}}};
struct BitIn{const vector<U8>& b;size_t p=0;int bits=0;U8 cur=0;BitIn(const vector<U8>& x):b(x){}int get(){if(!bits){cur=p<b.size()?b[p++]:0;bits=8;}int x=(cur>>7)&1;cur<<=1;--bits;return x;}};
struct Prob{U32 z=1,o=1;void bump(int bit){(bit?o:z)++;if(z+o>=32768){z=(z+1)/2;o=(o+1)/2;}}};
struct Enc{U64 lo=0,hi=0xffffffffULL;int pending=0;BitOut out;void emit(int bit){out.put(bit);while(pending-- >0)out.put(!bit);pending=0;}
 void bit(int b,Prob& m){U64 range=hi-lo+1,cut=lo+(range*m.z)/(m.z+m.o)-1;if(b)lo=cut+1;else hi=cut;m.bump(b);for(;;){if(hi<0x80000000ULL)emit(0);else if(lo>=0x80000000ULL){emit(1);lo-=0x80000000ULL;hi-=0x80000000ULL;}else if(lo>=0x40000000ULL&&hi<0xc0000000ULL){pending++;lo-=0x40000000ULL;hi-=0x40000000ULL;}else break;lo<<=1;hi=(hi<<1)|1;}}
 vector<U8> finish(){pending++;emit(lo<0x40000000ULL?0:1);out.done();return move(out.b);}};
struct Dec{U64 lo=0,hi=0xffffffffULL,code=0;BitIn in;Dec(const vector<U8>& b):in(b){for(int i=0;i<32;i++)code=(code<<1)|in.get();}
 int bit(Prob& m){U64 range=hi-lo+1,cut=lo+(range*m.z)/(m.z+m.o)-1;int b=code>cut;if(b)lo=cut+1;else hi=cut;m.bump(b);for(;;){if(hi<0x80000000ULL){}else if(lo>=0x80000000ULL){lo-=0x80000000ULL;hi-=0x80000000ULL;code-=0x80000000ULL;}else if(lo>=0x40000000ULL&&hi<0xc0000000ULL){lo-=0x40000000ULL;hi-=0x40000000ULL;code-=0x40000000ULL;}else break;lo<<=1;hi=(hi<<1)|1;code=(code<<1)|in.get();}return b;}};
// Adaptive byte coder for the entire paid model, conditioned by preceding byte.
struct ByteModel{array<Prob,16*8> m{};U8 prev=0;template<class C>void byte(C& c,U8 x){for(int i=7;i>=0;i--)c.bit((x>>i)&1,m[(prev>>4)*8+(7-i)]);prev=x;}U8 byte(Dec& c){U8 x=0;for(int i=7;i>=0;i--)x|=c.bit(m[(prev>>4)*8+(7-i)])<<i;prev=x;return x;}};
static vector<U8> packmeta(const vector<U8>& raw){Enc e;ByteModel m;for(U8 x:raw)m.byte(e,x);return e.finish();}
static vector<U8> unpackmeta(const vector<U8>& packed,size_t n){Dec d(packed);ByteModel m;vector<U8> raw;raw.reserve(n);for(size_t i=0;i<n;i++)raw.push_back(m.byte(d));return raw;}
// Rank gamma source has a small class history. The rank map is itself transmitted.
struct RankModel{array<Prob,4*32> m{};int prev=0;
 template<class C>void symbol(C& c,U32 rank,int next){U32 x=rank+1;int bits=31-__builtin_clz(x);if(bits>20)fail("rank overflow");for(int i=0;i<bits;i++)c.bit(0,m[prev*32+min(i,15)]);c.bit(1,m[prev*32+min(bits,15)]);for(int i=bits-1;i>=0;i--)c.bit((x>>i)&1,m[prev*32+16+min(bits-1-i,15)]);prev=next;}
 U32 symbol(Dec& c){int bits=0;while(!c.bit(m[prev*32+min(bits,15)])){if(++bits>20)fail("gamma too long");}U32 x=1u<<bits;for(int i=bits-1;i>=0;i--)x|=c.bit(m[prev*32+16+min(bits-1-i,15)])<<i;return x-1;}
};
static bool wordbyte(U8 c){return(c>='A'&&c<='Z')||(c>='a'&&c<='z')||c>=128;}
static size_t utf8len(const vector<U8>& in,size_t i){U8 c=in[i];int n=(c>=0xc2&&c<=0xdf)?2:(c>=0xe0&&c<=0xef)?3:(c>=0xf0&&c<=0xf4)?4:0;if(!n||i+n>in.size())return 0;for(int k=1;k<n;k++)if((in[i+k]&0xc0)!=0x80)return 0;if((c==0xe0&&in[i+1]<0xa0)||(c==0xed&&in[i+1]>=0xa0)||(c==0xf0&&in[i+1]<0x90)||(c==0xf4&&in[i+1]>=0x90))return 0;return n;}
static vector<string> spans(const vector<U8>& in){vector<string> v;for(size_t i=0;i<in.size();){if(wordbyte(in[i])){size_t j=i+1;while(j<in.size()&&j-i<96&&wordbyte(in[j]))j++;v.emplace_back((const char*)in.data()+i,j-i);i=j;}else{v.emplace_back(1,char(in[i++]));}}return v;}
template<class F>static void scalars(const string& s,F fun){vector<U8> v(s.begin(),s.end());for(size_t i=0;i<v.size();){size_t n=utf8len(v,i);if(!n)n=1;fun(string((const char*)v.data()+i,n));i+=n;}}
static bool boundary(const string& s,size_t i){return i==s.size()||(U8(s[i])&0xc0)!=0x80;}
static void cacheput(deque<string>& cache,const string& s){if(s.size()<6)return;cache.push_front(s);if(cache.size()>4)cache.pop_back();}
struct CopyChoice{size_t donor=0,start=0,at=0,len=0;};
static CopyChoice bestcopy(const deque<string>& cache,const string& s){CopyChoice best;for(size_t d=0;d<cache.size();d++){const string& old=cache[d];for(size_t a=0;a<s.size();a++){if(!boundary(s,a))continue;for(size_t b=0;b<old.size();b++){if(!boundary(old,b)||s[a]!=old[b])continue;size_t n=0;while(a+n<s.size()&&b+n<old.size()&&s[a+n]==old[b+n])n++;while(n&&(!boundary(s,a+n)||!boundary(old,b+n)))n--;if(n>best.len)best={d,b,a,n};}}}return best;}
static int symclass(U32 s,U32 wc){return s<256?((s==' '||s=='\n')?0:1):(s<=256+wc?2:3);}
struct Rule{U32 a,b;};
struct BlockData{vector<U32> syms;vector<U8> params;U64 checksum=0;};
static size_t setting(const char* name,size_t fallback,size_t limit){const char* s=getenv(name);if(!s)return fallback;string v(s);if(v.empty()||v.find_first_not_of("0123456789")!=string::npos)fail(string("bad setting ")+name);size_t n=stoull(v);if(n>limit)fail(string("setting cap ")+name);return n;}
static vector<U8> make(const vector<U8>& src){if(src.size()>MAX_RAW)fail("source over 64 MiB");
 const size_t word_cap=setting("SWC_WORD_CAP",MAX_WORDS,MAX_WORDS),rule_cap=setting("SWC_RULE_CAP",MAX_RULES,MAX_RULES),copy_min=setting("SWC_COPY_MIN",13,97),scalar_fallback=setting("SWC_SCALARS",1,1),reparse_rounds=setting("SWC_REPARSE",0,2);
 unordered_map<string,U32> counts;counts.reserve(src.size()/8+1);auto toks=spans(src);for(const auto& s:toks)if(s.size()>=3&&s.size()<=96&&wordbyte(U8(s[0]))){counts[s]++;if(U8(s[0])>=128)scalars(s,[&](const string& atom){if(atom.size()>=2)counts[atom]++;});}
 vector<pair<string,U32>> ranked;ranked.reserve(counts.size());for(auto& x:counts)if(x.second>=2)ranked.push_back(x);
 sort(ranked.begin(),ranked.end(),[](auto& a,auto& b){return a.second!=b.second?a.second>b.second:a.first<b.first;});if(ranked.size()>word_cap)ranked.resize(word_cap);
 vector<string> words;words.reserve(ranked.size());for(auto& x:ranked)words.push_back(x.first);sort(words.begin(),words.end());
 unordered_map<string,U32> ids;ids.reserve(words.size()*2+1);for(U32 i=0;i<words.size();i++)ids.emplace(words[i],256+i);
 U32 dyn=256+words.size();vector<BlockData> blocks((src.size()+BLOCK-1)/BLOCK);for(size_t k=0;k<blocks.size();k++){size_t a=k*BLOCK,b=min(src.size(),a+BLOCK);blocks[k].checksum=hash64(src.data()+a,b-a);vector<U8> part(src.begin()+a,src.begin()+b);auto ss=spans(part);auto& v=blocks[k].syms;auto& par=blocks[k].params;v.reserve(ss.size());deque<string> cache;
 for(auto& s:ss){auto it=ids.find(s);if(it!=ids.end()){v.push_back(it->second);cacheput(cache,s);}
 else if(s.size()>=6){CopyChoice c;if(copy_min)c=bestcopy(cache,s);if(copy_min&&c.len>=copy_min){v.push_back(dyn);var(par,c.donor);var(par,c.start);var(par,c.len);var(par,c.at);var(par,s.size()-c.at-c.len);par.insert(par.end(),s.begin(),s.begin()+c.at);par.insert(par.end(),s.begin()+c.at+c.len,s.end());cacheput(cache,s);}else if(U8(s[0])>=128&&scalar_fallback){scalars(s,[&](const string& atom){auto ai=ids.find(atom);if(ai!=ids.end())v.push_back(ai->second);else for(U8 x:atom)v.push_back(x);});}else for(U8 x:s)v.push_back(x);}
 else if(U8(s[0])>=128&&scalar_fallback){scalars(s,[&](const string& atom){auto ai=ids.find(atom);if(ai!=ids.end())v.push_back(ai->second);else for(U8 c:atom)v.push_back(c);});}
 else for(U8 c:s)v.push_back(c);}}
 vector<vector<U32>> original;original.reserve(blocks.size());for(auto& b:blocks)original.push_back(b.syms);
 vector<Rule> rules;U32 base=dyn+1;vector<U32> expansion(base,1);for(size_t i=0;i<words.size();i++)expansion[256+i]=words[i].size();
 // Batch pair grammar: charge every selected production. Pairs are selected on
 // the current stream and replaced simultaneously at nonoverlapping positions.
 for(size_t iter=0;iter<(rule_cap+31)/32;iter++){unordered_map<U64,U32> freq;size_t total=0;for(auto& b:blocks){auto& v=b.syms;total+=v.size();for(size_t i=1;i<v.size();i++)freq[(U64(v[i-1])<<32)|v[i]]++;}if(total<64)break;
 vector<pair<U64,U32>> cand;for(auto& x:freq){U32 a=x.first>>32,b=U32(x.first);if(x.second>=12&&expansion[a]+expansion[b]<=512)cand.emplace_back(x.first,x.second);}sort(cand.begin(),cand.end(),[](auto& a,auto& b){return a.second!=b.second?a.second>b.second:a.first<b.first;});if(cand.empty())break;
 size_t n=min<size_t>({32,cand.size(),rule_cap-rules.size()});unordered_map<U64,U32> selected;for(size_t i=0;i<n;i++){U32 a=cand[i].first>>32,b=U32(cand[i].first);U32 rid=base+rules.size();selected.emplace(cand[i].first,rid);rules.push_back({a,b});expansion.push_back(expansion[a]+expansion[b]);}
 size_t replaced=0;for(auto& block:blocks){vector<U32> out;out.reserve(block.syms.size());for(size_t i=0;i<block.syms.size();){if(i+1<block.syms.size()){auto it=selected.find((U64(block.syms[i])<<32)|block.syms[i+1]);if(it!=selected.end()){out.push_back(it->second);i+=2;replaced++;continue;}}out.push_back(block.syms[i++]);}block.syms.swap(out);}if(replaced<8)break;}
 U32 alphabet=base+rules.size();
 if(reparse_rounds&&rules.size()){
   vector<vector<U32>> pattern(alphabet);for(U32 i=0;i<base;i++)pattern[i]={i};
   vector<vector<U32>> starts(base);
   for(U32 i=0;i<rules.size();i++){U32 s=base+i;auto r=rules[i];pattern[s]=pattern[r.a];pattern[s].insert(pattern[s].end(),pattern[r.b].begin(),pattern[r.b].end());if(pattern[s].size()<=512)starts[pattern[s][0]].push_back(s);}
   for(size_t round=0;round<reparse_rounds;round++){
     vector<U64> freq(alphabet);U64 total=0;for(auto& b:blocks)for(U32 s:b.syms){freq[s]++;total++;}
     vector<double> price(alphabet);for(U32 s=0;s<alphabet;s++)price[s]=-log2((freq[s]+0.5)/(total+0.5*alphabet));
     size_t changes=0;
     for(size_t bi=0;bi<blocks.size();bi++){const auto& srcsyms=original[bi];size_t n=srcsyms.size();vector<double> best(n+1,0);vector<U32> choice(n);vector<U32> width(n);for(size_t i=n;i-->0;){U32 atom=srcsyms[i];best[i]=price[atom]+best[i+1];choice[i]=atom;width[i]=1;for(U32 s:starts[atom]){const auto& pat=pattern[s];size_t z=pat.size();if(i+z>n||!equal(pat.begin(),pat.end(),srcsyms.begin()+i))continue;double cost=price[s]+best[i+z];if(cost+0.000001<best[i]){best[i]=cost;choice[i]=s;width[i]=z;}}}
       vector<U32> next;next.reserve(blocks[bi].syms.size());for(size_t i=0;i<n;i+=width[i])next.push_back(choice[i]);if(next!=blocks[bi].syms)changes++;blocks[bi].syms.swap(next);}
     if(!changes)break;
   }
 }
 vector<U64> f(alphabet);for(auto& b:blocks)for(U32 s:b.syms)f[s]++;vector<U32> rank_to_sym(alphabet);for(U32 i=0;i<alphabet;i++)rank_to_sym[i]=i;sort(rank_to_sym.begin(),rank_to_sym.end(),[&](U32 a,U32 b){return f[a]!=f[b]?f[a]>f[b]:a<b;});vector<U32> sym_to_rank(alphabet);for(U32 i=0;i<alphabet;i++)sym_to_rank[rank_to_sym[i]]=i;
 vector<U8> meta;var(meta,words.size());var(meta,rules.size());var(meta,alphabet);
 // Exact form graph: each entry either raw or an earlier word's prefix plus a literal tail.
 for(size_t i=0;i<words.size();i++){const string& w=words[i];size_t common=0;if(i){while(common<w.size()&&common<words[i-1].size()&&w[common]==words[i-1][common])common++;}bool pref=common>=3&&common+2>=w.size()/2;if(pref){var(meta,(common<<1)|1);var(meta,w.size()-common);meta.insert(meta.end(),w.begin()+common,w.end());}else{var(meta,w.size()<<1);meta.insert(meta.end(),w.begin(),w.end());}}
 for(auto r:rules){var(meta,r.a);var(meta,r.b);}for(U32 s:rank_to_sym)var(meta,s);
 vector<U8> packedmeta=packmeta(meta);vector<vector<U8>> payloads,ppayloads;payloads.reserve(blocks.size());ppayloads.reserve(blocks.size());for(auto& block:blocks){Enc e;RankModel m;for(U32 s:block.syms)m.symbol(e,sym_to_rank[s],symclass(s,words.size()));payloads.push_back(e.finish());ppayloads.push_back(packmeta(block.params));}
 vector<U8> out={'S','W','C','2'};put64(out,src.size());put32(out,BLOCK);put32(out,(U32)blocks.size());put32(out,(U32)meta.size());put32(out,(U32)packedmeta.size());out.insert(out.end(),packedmeta.begin(),packedmeta.end());for(size_t i=0;i<blocks.size();i++){put32(out,(U32)blocks[i].syms.size());put32(out,(U32)payloads[i].size());put32(out,(U32)blocks[i].params.size());put32(out,(U32)ppayloads[i].size());put64(out,blocks[i].checksum);}for(auto& p:payloads)out.insert(out.end(),p.begin(),p.end());for(auto& p:ppayloads)out.insert(out.end(),p.begin(),p.end());
 cerr<<"{\"raw\":"<<src.size()<<",\"frame\":"<<out.size()<<",\"words\":"<<words.size()<<",\"rules\":"<<rules.size()<<",\"word_cap\":"<<word_cap<<",\"rule_cap\":"<<rule_cap<<",\"copy_min\":"<<copy_min<<",\"scalars\":"<<scalar_fallback<<",\"reparse\":"<<reparse_rounds<<",\"model_bytes\":"<<packedmeta.size()+28<<",\"directory_bytes\":"<<blocks.size()*24<<",\"payload_bytes\":"<<out.size()-packedmeta.size()-28-blocks.size()*24<<"}\n";return out;}
struct Parsed{U64 raw;vector<string> words;vector<Rule> rules;vector<U32> rank_to_sym;vector<U32> count,size,psize,praw;vector<U64> checksum;vector<size_t> off,poff;const vector<U8>& frame;};
static Parsed parse(const vector<U8>& frame){size_t p=0;if(frame.size()<28||memcmp(frame.data(),"SWC2",4))fail("bad magic");p=4;U64 raw=get64(frame,p);U32 blocksize=get32(frame,p),nb=get32(frame,p),ms=get32(frame,p),cs=get32(frame,p);if(raw>MAX_RAW||blocksize!=BLOCK||nb!=(raw+BLOCK-1)/BLOCK||ms>16*1024*1024||cs>16*1024*1024||cs>frame.size()-p)fail("header bounds");vector<U8> comp(frame.begin()+p,frame.begin()+p+cs);p+=cs;vector<U8> meta=unpackmeta(comp,ms);if(packmeta(meta)!=comp)fail("noncanonical model entropy stream");size_t q=0;U64 nw=unvar(meta,q),nr=unvar(meta,q),na=unvar(meta,q);if(nw>MAX_WORDS||nr>MAX_RULES||na!=257+nw+nr)fail("model counts");Parsed z{raw,{}, {},{}, {},{},{},{},{},{},{},frame};z.words.reserve(nw);z.rules.reserve(nr);z.rank_to_sym.reserve(na);
 for(size_t i=0;i<nw;i++){U64 code=unvar(meta,q);string w;if(code&1){if(i==0||code/2>z.words.back().size())fail("bad word prefix");w=z.words.back().substr(0,code/2);}else{if(code/2>96)fail("word too long");}U64 tail=(code&1)?unvar(meta,q):code/2;if(tail>96||w.size()+tail>96||tail>meta.size()-q||w.size()+tail==0)fail("word tail bounds");w.append((const char*)meta.data()+q,tail);q+=tail;z.words.push_back(move(w));}
 vector<U32> expanded(257+nw,1),leaves(257+nw,1),depth(257+nw,1);for(size_t i=0;i<nw;i++)expanded[256+i]=z.words[i].size();expanded[256+nw]=96;
 for(size_t i=0;i<nr;i++){U64 a=unvar(meta,q),b=unvar(meta,q);if(a>=257+nw+i||b>=257+nw+i)fail("rule cycle");if(U64(expanded[a])+expanded[b]>BLOCK||U64(leaves[a])+leaves[b]>BLOCK||max(depth[a],depth[b])>=64)fail("rule expansion/work bound");z.rules.push_back({U32(a),U32(b)});expanded.push_back(expanded[a]+expanded[b]);leaves.push_back(leaves[a]+leaves[b]);depth.push_back(max(depth[a],depth[b])+1);}vector<U8> seen(na);for(size_t i=0;i<na;i++){U64 s=unvar(meta,q);if(s>=na||seen[s]++)fail("rank permutation");z.rank_to_sym.push_back(s);}if(q!=meta.size())fail("model trailing bytes");
 for(U32 i=0;i<nb;i++){z.count.push_back(get32(frame,p));z.size.push_back(get32(frame,p));z.praw.push_back(get32(frame,p));z.psize.push_back(get32(frame,p));z.checksum.push_back(get64(frame,p));if(z.count.back()>BLOCK*4||z.size.back()>BLOCK*8||z.praw.back()>BLOCK*4||z.psize.back()>BLOCK*8)fail("block bounds");}for(U32 i=0;i<nb;i++){if(z.size[i]>frame.size()-p)fail("truncated payload");z.off.push_back(p);p+=z.size[i];}for(U32 i=0;i<nb;i++){if(z.psize[i]>frame.size()-p)fail("truncated parameters");z.poff.push_back(p);p+=z.psize[i];}if(p!=frame.size())fail("frame trailing bytes");return z;}
static vector<U8> extract(const Parsed& z,size_t bi){if(bi>=z.count.size())fail("block index");vector<U8> stream(z.frame.begin()+z.off[bi],z.frame.begin()+z.off[bi]+z.size[bi]);vector<U8> pc(z.frame.begin()+z.poff[bi],z.frame.begin()+z.poff[bi]+z.psize[bi]);vector<U8> params=unpackmeta(pc,z.praw[bi]);size_t pp=0;Dec d(stream);RankModel m;vector<U8> out;out.reserve(BLOCK);U32 wc=z.words.size(),dyn=256+wc,base=dyn+1;size_t expect=min<U64>(BLOCK,z.raw-bi*BLOCK);deque<string> cache;vector<U32> stack;stack.reserve(64);
 for(U32 j=0;j<z.count[bi];j++){U32 rank=m.symbol(d);if(rank>=z.rank_to_sym.size())fail("rank bounds");U32 s=z.rank_to_sym[rank];m.prev=symclass(s,wc);stack.push_back(s);while(!stack.empty()){U32 x=stack.back();stack.pop_back();if(x<256){out.push_back(U8(x));}else if(x<dyn){const auto& w=z.words[x-256];out.insert(out.end(),w.begin(),w.end());cacheput(cache,w);}else if(x==dyn){U64 donor=unvar(params,pp),start=unvar(params,pp),len=unvar(params,pp),lead=unvar(params,pp),trail=unvar(params,pp);if(donor>=cache.size()||start>cache[donor].size()||len>cache[donor].size()-start||lead>96||trail>96||lead+len+trail>96||lead+trail>params.size()-pp)fail("dynamic word bounds");string w((const char*)params.data()+pp,lead);pp+=lead;w+=cache[donor].substr(start,len);w.append((const char*)params.data()+pp,trail);pp+=trail;out.insert(out.end(),w.begin(),w.end());cacheput(cache,w);}else{auto r=z.rules[x-base];stack.push_back(r.b);stack.push_back(r.a);}if(out.size()>expect)fail("expanded block overflow");}}
 if(pp!=params.size()||out.size()!=expect||hash64(out.data(),out.size())!=z.checksum[bi])fail("block checksum/length/parameters");
 return out;}
int main(int argc,char** argv){try{if(argc<4||argc>5)fail("usage: swc encode INPUT FRAME | decode FRAME OUTPUT [BLOCK_INDEX] | inspect FRAME OUTPUT");string cmd=argv[1];auto in=readfile(argv[2]);if(cmd=="encode"){if(argc!=4)fail("encode arguments");auto t=chrono::steady_clock::now();auto out=make(in);writefile(argv[3],out);cerr<<"encode_ms="<<chrono::duration_cast<chrono::milliseconds>(chrono::steady_clock::now()-t).count()<<"\n";}else if(cmd=="decode"){auto t=chrono::steady_clock::now();auto z=parse(in);vector<U8> out;if(argc==5){size_t bi=stoull(argv[4]);out=extract(z,bi);}else{out.reserve(z.raw);for(size_t i=0;i<z.count.size();i++){auto b=extract(z,i);out.insert(out.end(),b.begin(),b.end());}}writefile(argv[3],out);cerr<<"decode_ms="<<chrono::duration_cast<chrono::milliseconds>(chrono::steady_clock::now()-t).count()<<"\n";}else if(cmd=="inspect"){if(argc!=4)fail("inspect arguments");auto z=parse(in);size_t pay=0;for(U32 n:z.size)pay+=n;for(U32 n:z.psize)pay+=n;string s="{\"raw\":"+to_string(z.raw)+",\"frame\":"+to_string(in.size())+",\"words\":"+to_string(z.words.size())+",\"rules\":"+to_string(z.rules.size())+",\"blocks\":"+to_string(z.count.size())+",\"directory_bytes\":"+to_string(z.count.size()*24)+",\"payload_bytes\":"+to_string(pay)+",\"model_bytes\":"+to_string(in.size()-pay-z.count.size()*24)+"}\n";vector<U8> v(s.begin(),s.end());writefile(argv[3],v);}else fail("unknown command");return 0;}catch(const exception& e){cerr<<"swc: "<<e.what()<<"\n";return 1;}}
