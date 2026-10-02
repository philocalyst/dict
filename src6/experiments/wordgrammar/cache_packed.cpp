// Experimental shared grammar source. Exact bytes, independent raw restart blocks.
// Native self-contained static contextual rANS; no external decoder dependency.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <queue>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>
using U=uint32_t; using Q=uint64_t; using B=std::vector<uint8_t>;
constexpr U SCALE=65536, RB=1u<<23, MAX_V=16384, MAX_RAW=1u<<28;
static void fail(const std::string&s){throw std::runtime_error(s);}
static B read(const std::string&p){std::ifstream f(p,std::ios::binary);if(!f)fail("open input");f.seekg(0,std::ios::end);auto n=f.tellg();if(n<0||n>MAX_RAW*2ll)fail("input limit");B b((size_t)n);f.seekg(0);f.read((char*)b.data(),b.size());if(!f)fail("read");return b;}
static void write(const std::string&p,const B&b){std::ofstream f(p,std::ios::binary);if(!f)fail("open output");f.write((const char*)b.data(),b.size());if(!f)fail("write");}
static void put(B&b,Q v){do{uint8_t x=v&127;v>>=7;b.push_back(x|(v?128:0));}while(v);}
struct R {const B&b;size_t p=0;Q get(){Q v=0;int s=0;size_t a=p;for(int i=0;i<10;i++){if(p==b.size())fail("truncated varint");uint8_t x=b[p++];if(i==9&&(x&254))fail("varint overflow");v|=Q(x&127)<<s;if(!(x&128)){if(p-a>1&&x==0)fail("noncanonical varint");return v;}s+=7;}fail("varint length");return 0;} U u(U hi){auto x=get();if(x>hi)fail("integer bound");return U(x);} };
static U checksum(const uint8_t*p,size_t n){U h=2166136261u;while(n--)h=(h^*p++)*16777619u;return h;}
static void fixed(B&b,U x){for(int i=0;i<4;i++)b.push_back(x>>(8*i));}
static U fixedread(const B&b,size_t&p){if(b.size()-p<4)fail("truncated fixed");U x=0;for(int i=0;i<4;i++)x|=U(b[p++])<<(8*i);return x;}
struct Pair {Q key;U count=0;std::vector<U> pos;};
struct Copy {U length,distance;};
struct Grammar {std::vector<std::array<U,2>>rules;std::vector<B>words;std::vector<std::vector<U>>blocks;std::vector<std::vector<Copy>>copies;};
static Grammar learn(const B&raw,U block,U lim,U mincount,U maxlen){
 Grammar g;g.words.resize(256);for(U i=0;i<256;i++)g.words[i].push_back(i);
 if(raw.empty())return g;U n=raw.size();std::vector<U>s(n),next(n),prev(n);std::vector<U>heads;
 constexpr U END=~U(0);std::unordered_map<Q,U>idx;idx.reserve(n/3+1);std::vector<Pair> ps;ps.reserve(n/3+1);
 auto key=[](U a,U b){return Q(a)<<32|b;};
 auto rec=[&](Q k)->U{auto it=idx.find(k);if(it!=idx.end())return it->second;U id=ps.size();idx.emplace(k,id);ps.push_back({k,0,{}});return id;};
 for(U i=0;i<n;i++){s[i]=raw[i];prev[i]=(i%block)?i-1:END;next[i]=((i+1)%block&&i+1<n)?i+1:END;if(prev[i]==END)heads.push_back(i);}
 for(U i=0;i<n;i++)if(next[i]!=END){auto id=rec(key(s[i],s[next[i]]));ps[id].count++;ps[id].pos.push_back(i);}
 using H=std::pair<U,Q>;std::priority_queue<H>heap;for(auto&p:ps)if(p.count>=mincount)heap.push({p.count,p.key});
 std::vector<U>changed;
 auto del=[&](U i){if(i==END||next[i]==END)return;U id=idx.at(key(s[i],s[next[i]]));if(!ps[id].count)fail("internal pair count");ps[id].count--;changed.push_back(id);};
 auto add=[&](U i){if(i==END||next[i]==END)return;U id=rec(key(s[i],s[next[i]]));ps[id].count++;ps[id].pos.push_back(i);changed.push_back(id);};
 while(g.rules.size()<lim&&!heap.empty()){
  auto h=heap.top();heap.pop();U id=idx.at(h.second);if(h.first!=ps[id].count)continue;if(h.first<mincount)break;
  U a=U(h.second>>32),b=U(h.second);if(g.words[a].size()+g.words[b].size()>maxlen){continue;}
  // Move positions so newly appended occurrences cannot invalidate iterators.
  std::vector<U>occ;occ.swap(ps[id].pos);U ns=g.words.size();bool made=false;changed.clear();
  for(U i:occ){if(s[i]!=a||next[i]==END||s[next[i]]!=b)continue;U j=next[i],l=prev[i],r=next[j];
   if(!made){made=true;g.rules.push_back({a,b});B w=g.words[a];w.insert(w.end(),g.words[b].begin(),g.words[b].end());g.words.push_back(std::move(w));}
   del(l);del(i);del(j);s[i]=ns;s[j]=END;next[i]=r;if(r!=END)prev[r]=i;next[j]=prev[j]=END;add(l);add(i);
  }
  if(!made)continue;std::sort(changed.begin(),changed.end());changed.erase(std::unique(changed.begin(),changed.end()),changed.end());for(U t:changed)if(ps[t].count>=mincount)heap.push({ps[t].count,ps[t].key});
  if(heap.size()>ps.size()*3){decltype(heap)fresh;for(auto&p:ps)if(p.count>=mincount)fresh.push({p.count,p.key});heap.swap(fresh);}
 }
 for(U h:heads){std::vector<U>out;for(U i=h;i!=END;i=next[i])out.push_back(s[i]);g.blocks.push_back(std::move(out));}return g;
}
struct E {U cum=0,freq=0,bits=16;};
struct Row {U bits=16;std::vector<E>enc;std::vector<uint16_t>dec;std::vector<std::pair<U,U>>entries;};
static Row normalized(const std::vector<Q>&cnt,bool table=true,U bits=16){
 Row r;r.bits=bits;U scale=1u<<bits;r.enc.resize(cnt.size());Q total=0;U nz=0;for(auto x:cnt)if(x){total+=x;nz++;}if(!nz||nz>scale)fail("model support");U remain=scale-nz;std::vector<std::pair<long double,U>>fraction;std::vector<U>f(cnt.size());U assigned=nz;
 for(U i=0;i<cnt.size();i++)if(cnt[i]){long double z=(long double)cnt[i]*remain/total;U a=(U)z;f[i]=a+1;assigned+=a;fraction.push_back({z-a,i});}
 std::sort(fraction.begin(),fraction.end(),[](auto a,auto b){return a.first>b.first||(a.first==b.first&&a.second<b.second);});for(U i=0;i<scale-assigned;i++)f[fraction[i].second]++;
 U c=0;if(table)r.dec.resize(scale);for(U i=0;i<f.size();i++)if(f[i]){r.enc[i]={c,f[i],bits};r.entries.push_back({i,f[i]});if(table)std::fill(r.dec.begin()+c,r.dec.begin()+c+f[i],i);c+=f[i];}if(c!=scale)fail("normalization");return r;
}
static void rput(U&state,B&out,const E&e){if(!e.freq)fail("zero probability");Q threshold=Q((RB>>e.bits)<<8)*e.freq;while(state>=threshold){out.push_back(state&255);state>>=8;}state=U((Q(state/e.freq)<<e.bits)+state%e.freq+e.cum);}
static U rget(U&state,const Row&r,const B&payload,size_t&p){U slot=state&((1u<<r.bits)-1);U s=r.dec[slot];auto e=r.enc[s];state=e.freq*(state>>r.bits)+slot-e.cum;while(state<RB){if(p==payload.size())fail("truncated rANS");state=(state<<8)|payload[p++];}return s;}
static U coarse(const B&w,U k){uint8_t x=w.back();U c;if(x=='\n'||x=='\r')c=1;else if(x==' '||x=='\t')c=2;else if(x>127)c=3+(x&7);else if(x>='0'&&x<='9')c=11;else if(x>='A'&&x<='Z')c=12;else if(x>='a'&&x<='z')c=13+((x-'a')%5);else c=18+(x%5);return c%k;}
struct Models {std::vector<uint8_t>cls;std::vector<Row>rows;Row global;std::vector<Row>patches;std::vector<int>patchids;std::vector<U>patchprev;};
static Models models(const Grammar&g,U k,U rounds,double prune){
 U v=g.words.size();Models m;m.cls.resize(v);for(U s=0;s<v;s++)m.cls[s]=coarse(g.words[s],k);
 std::vector<Q>global(v,0);for(U s=0;s<256;s++)global[s]=1;std::vector<std::unordered_map<U,U>>next(v);
 for(auto&b:g.blocks){U p=0;for(U s:b){global[s]++;next[p][s]++;p=s;}}
 m.global=normalized(global);std::vector<std::vector<Q>>counts;
 auto collect=[&]{counts.assign(k,std::vector<Q>(v+1));for(U p=0;p<v;p++)for(auto [s,n]:next[p])counts[m.cls[p]][s]+=n;};
 for(U round=0;round<rounds;round++){collect();std::vector<double>tot(k);for(U c=0;c<k;c++)tot[c]=std::accumulate(counts[c].begin(),counts[c].end(),double(0));U changed=0;
  for(U p=0;p<v;p++){if(next[p].empty())continue;double best=1e300;U bc=m.cls[p];for(U c=0;c<k;c++){double cost=0;for(auto[s,n]:next[p])cost-=n*std::log2((counts[c][s]+0.05)/(tot[c]+0.05*v));if(cost<best){best=cost;bc=c;}}changed+=bc!=m.cls[p];m.cls[p]=bc;}if(!changed)break;
 }
 collect();m.rows.reserve(k);
 for(U c=0;c<k;c++){Q total=std::accumulate(counts[c].begin(),counts[c].end(),Q(0));Q escape=1;for(U s=0;s<v;s++)if(counts[c][s]){double gain=counts[c][s]*std::log2((double(counts[c][s])/std::max<Q>(1,total))/(double(m.global.enc[s].freq)/SCALE));if(gain<prune){escape+=counts[c][s];counts[c][s]=0;}}
  counts[c][v]=escape;m.rows.push_back(normalized(counts[c]));
 }return m;
}

// Exact Viterbi over bytes and previous source class. Grammar is unchanged;
// only the selected derivation changes, and every restart returns to the same state.
static void reparse(Grammar&g,const B&raw,U block,const Models&m){
 struct T{std::unordered_map<uint8_t,U>edges;U symbol=~U(0);};std::vector<T>trie(1);
 for(U s=0;s<g.words.size();s++){U node=0;for(uint8_t x:g.words[s]){auto it=trie[node].edges.find(x);if(it==trie[node].edges.end()){U n=trie.size();trie[node].edges.emplace(x,n);trie.push_back({});node=n;}else node=it->second;}trie[node].symbol=s;}
 U v=g.words.size(),k=m.rows.size();std::vector<std::vector<float>>price(v,std::vector<float>(k));
 for(U s=0;s<v;s++)for(U c=0;c<k;c++){auto&r=m.rows[c];if(r.enc[s].freq)price[s][c]=16-std::log2(float(r.enc[s].freq));else if(m.global.enc[s].freq)price[s][c]=32-std::log2(float(r.enc[v].freq))-std::log2(float(m.global.enc[s].freq));else price[s][c]=1e20f;}
 std::vector<std::vector<U>>roots;for(size_t off=0;off<raw.size();off+=block){U len=std::min<size_t>(block,raw.size()-off);size_t cells=size_t(len+1)*k;std::vector<float>dp(cells,1e25f);std::vector<U>chosen(cells,~U(0));std::vector<uint8_t>back(cells);dp[m.cls[0]]=0;
  for(U i=0;i<len;i++){U node=0;for(U j=i;j<len;j++){auto it=trie[node].edges.find(raw[off+j]);if(it==trie[node].edges.end())break;node=it->second;U s=trie[node].symbol;if(s==~U(0))continue;U to=m.cls[s];float best=1e25f;U bc=0;for(U c=0;c<k;c++){float cost=dp[size_t(i)*k+c]+price[s][c];if(cost<best){best=cost;bc=c;}}size_t t=size_t(j+1)*k+to;if(best<dp[t]){dp[t]=best;chosen[t]=s;back[t]=bc;}}
  }
  U c=std::min_element(dp.end()-k,dp.end())-(dp.end()-k),i=len;std::vector<U>seq;while(i){size_t at=size_t(i)*k+c;U s=chosen[at];if(s==~U(0))fail("parse unreachable");seq.push_back(s);i-=g.words[s].size();c=back[at];}std::reverse(seq.begin(),seq.end());roots.push_back(std::move(seq));
 }g.blocks.swap(roots);
}
static void prunegrammar(Grammar&g){
 U v=g.words.size();std::vector<uint8_t>used(v,0);for(auto&b:g.blocks)for(U s:b)used[s]=1;for(U s=v;s-->256;)if(used[s]){used[g.rules[s-256][0]]=1;used[g.rules[s-256][1]]=1;}
 std::vector<U>map(v);Grammar n;n.words.assign(g.words.begin(),g.words.begin()+256);for(U s=0;s<256;s++)map[s]=s;for(U s=256;s<v;s++)if(used[s]){map[s]=n.words.size();auto ab=g.rules[s-256];n.rules.push_back({map[ab[0]],map[ab[1]]});n.words.push_back(std::move(g.words[s]));}n.blocks=std::move(g.blocks);for(auto&b:n.blocks)for(U&s:b)s=map[s];g=std::move(n);
}

// Productive macro extension: a phrase may bind an exact earlier surface in
// the current restart block. Copies refer to output bytes, so a repeated stem
// remains reusable even when its surrounding grammar segmentation changes.
static void surfacecache(Grammar&g,const B&raw,U block,const Models&m,U minmatch){
 struct T{std::unordered_map<uint8_t,U>edges;U symbol=~U(0);};std::vector<T>trie(1);
 for(U s=0;s<g.words.size();s++){U node=0;for(uint8_t x:g.words[s]){auto it=trie[node].edges.find(x);if(it==trie[node].edges.end()){U n=trie.size();trie[node].edges.emplace(x,n);trie.push_back({});node=n;}else node=it->second;}trie[node].symbol=s;}
 U v=g.words.size();std::vector<float>price(v);for(U s=0;s<v;s++)price[s]=m.global.enc[s].freq?16-std::log2(float(m.global.enc[s].freq)):24;
 std::vector<std::vector<U>>roots;std::vector<std::vector<Copy>>copies;
 auto varbits=[](U x){U n=8;while(x>=128){x>>=7;n+=8;}return n;};
 for(size_t off=0;off<raw.size();off+=block){U len=std::min<size_t>(block,raw.size()-off);std::vector<float>dp(len+1,1e25f);std::vector<U>chosen(len+1),back(len+1);std::vector<Copy>copy(len+1);dp[0]=0;
  std::vector<int>head(1<<18,-1),chain(len,-1);std::vector<Copy>matches(len);
  auto hash=[&](U i){U x=U(raw[off+i])|(U(raw[off+i+1])<<8)|(U(raw[off+i+2])<<16)|(U(raw[off+i+3])<<24);return (x*2654435761u)>>(32-18);};
  for(U i=0;i+4<=len;i++){U h=hash(i),best=0,dist=0;int prev=head[h];for(U tries=0;prev>=0&&tries<16;prev=chain[prev],tries++){U limit=std::min<U>(4096,len-i);if(best==limit)break;if(raw[off+prev+best]!=raw[off+i+best])continue;U n=0;while(n+8<=limit){Q a,b;std::memcpy(&a,raw.data()+off+prev+n,8);std::memcpy(&b,raw.data()+off+i+n,8);if(a!=b)break;n+=8;}while(n<limit&&raw[off+prev+n]==raw[off+i+n])n++;if(n>best){best=n;dist=i-prev;}}matches[i]={best,dist};chain[i]=head[h];head[h]=i;}
  for(U i=0;i<len;i++){U node=0;for(U j=i;j<len;j++){auto it=trie[node].edges.find(raw[off+j]);if(it==trie[node].edges.end())break;node=it->second;U sym=trie[node].symbol;if(sym==~U(0))continue;float cost=dp[i]+price[sym];if(cost<dp[j+1]){dp[j+1]=cost;chosen[j+1]=sym;back[j+1]=i;}}
   auto mt=matches[i];if(mt.length>=minmatch){float c=dp[i]+12+varbits(mt.length)+varbits(mt.distance);U j=i+mt.length;if(c<dp[j]){dp[j]=c;chosen[j]=v;back[j]=i;copy[j]=mt;}}
  }
  std::vector<U>seq;std::vector<Copy>cp;U i=len;while(i){U sym=chosen[i];seq.push_back(sym);if(sym==v)cp.push_back(copy[i]);i=back[i];}std::reverse(seq.begin(),seq.end());std::reverse(cp.begin(),cp.end());roots.push_back(std::move(seq));copies.push_back(std::move(cp));
 }g.blocks.swap(roots);g.copies.swap(copies);g.words.push_back(B{0});
}

// Select sparse exact-predecessor predictive states by complete delivered cost.
// Rows have only 256 slots and escape back to the delivered class source.
static void patches(Models&m,const Grammar&g,U cap){
 U v=g.words.size();m.patchids.assign(v,-1);std::vector<std::unordered_map<U,U>>cnt(v);for(auto&b:g.blocks){U p=0;for(U s:b){cnt[p][s]++;p=s;}}
 struct Candidate{double gain;U prev;std::vector<std::pair<U,Q>>count;};std::vector<Candidate>candidates;
 auto cost=[&](U p,U s){auto&r=m.rows[m.cls[p]];if(r.enc[s].freq)return 16-std::log2(double(r.enc[s].freq));return 32-std::log2(double(r.enc[v].freq))-std::log2(double(m.global.enc[s].freq));};
 for(U p=0;p<v;p++){Q total=0;for(auto[s,n]:cnt[p])total+=n;if(total<32||cnt[p].size()<2)continue;
  std::vector<std::pair<double,U>>rank;for(auto[s,n]:cnt[p]){double gain=n*(cost(p,s)+std::log2(double(n)/total));rank.push_back({gain,s});}std::sort(rank.rbegin(),rank.rend());
  std::vector<Q>counts(v+1);Q escape=total+1;for(U i=0;i<std::min<size_t>(rank.size(),24);i++){U s=rank[i].second;if(rank[i].first<=0)continue;counts[s]=cnt[p][s];escape-=counts[s];}counts[v]=escape;Row row=normalized(counts,false,8);
  double gain=0;for(auto[s,n]:cnt[p]){double after=row.enc[s].freq?8-std::log2(double(row.enc[s].freq)):8-std::log2(double(row.enc[v].freq))+cost(p,s);gain+=n*(cost(p,s)-after);}
  // Charge a conservative worst-case predecessor/row and delta-coded entries.
  gain-=32+row.entries.size()*32;
  if(gain>64){Candidate c{gain,p,{}};for(U s=0;s<counts.size();s++)if(counts[s])c.count.push_back({s,counts[s]});candidates.push_back(std::move(c));}
 }
 std::sort(candidates.begin(),candidates.end(),[](auto&a,auto&b){return a.gain>b.gain;});if(candidates.size()>cap)candidates.resize(cap);std::sort(candidates.begin(),candidates.end(),[](auto&a,auto&b){return a.prev<b.prev;});
 for(auto&c:candidates){std::vector<Q>counts(v+1);for(auto[s,n]:c.count)counts[s]=n;m.patchids[c.prev]=m.patches.size();m.patchprev.push_back(c.prev);m.patches.push_back(normalized(counts,true,8));}
}
static void putrow(B&f,const Row&r){put(f,r.entries.size());U last=0;for(auto[s,n]:r.entries){put(f,s-last);put(f,n);last=s+1;}}
static Row getrow(R&r,U v,U bits=16){U scale=1u<<bits;U n=r.u(v);if(!n)fail("empty row");Row out;out.bits=bits;out.enc.resize(v);out.dec.resize(scale);U last=0,c=0;for(U i=0;i<n;i++){U delta=r.u(v);if(delta>=v-last)fail("row symbol");U s=last+delta;U f=r.u(scale);if(!f||f>scale-c)fail("row frequency");out.enc[s]={c,f,bits};std::fill(out.dec.begin()+c,out.dec.begin()+c+f,s);out.entries.push_back({s,f});last=s+1;c+=f;}if(c!=scale)fail("row sum");return out;}
static B encode(const B&raw,U block,U lim,U mincount,U maxlen,U k,U rounds,double prune){
 auto start=std::chrono::steady_clock::now();Grammar g=learn(raw,block,lim,mincount,maxlen);auto trained=std::chrono::steady_clock::now();Models m=models(g,k,rounds,prune);bool copy=std::getenv("WGR_COPY");if(copy){surfacecache(g,raw,block,m,6);m=models(g,k,rounds,prune);}else if(std::getenv("WGR_REPARSE")){reparse(g,raw,block,m);prunegrammar(g);m=models(g,k,rounds,prune);}bool patch=copy&&std::getenv("WGR_PATCH");if(patch)patches(m,g,256);B f={'W','G','R',uint8_t(patch?'4':copy?'3':'1')};put(f,raw.size());put(f,block);put(f,maxlen);put(f,g.rules.size());put(f,k);for(auto ab:g.rules){put(f,ab[0]);put(f,ab[1]);}U v=g.words.size();if(k>1)f.insert(f.end(),m.cls.begin(),m.cls.end());putrow(f,m.global);for(auto&r:m.rows)putrow(f,r);
 std::vector<Row>paramrows;std::vector<std::vector<std::pair<U,U>>>paramstreams;
 if(copy){std::vector<std::vector<Q>>cnt(6,std::vector<Q>(256));for(auto&cp:g.copies){std::vector<std::pair<U,U>>stream;for(auto c:cp){U values[2]={c.length,c.distance};for(U t=0;t<2;t++){U value=values[t],i=0;do{U byte=value&127;value>>=7;if(value)byte|=128;U ctx=t*3+i;cnt[ctx][byte]++;stream.push_back({ctx,byte});i++;}while(value);}}paramstreams.push_back(std::move(stream));}for(auto&row:cnt){if(std::accumulate(row.begin(),row.end(),Q(0))==0)row[0]=1;paramrows.push_back(normalized(row));putrow(f,paramrows.back());}}
 if(patch){put(f,m.patches.size());U last=0;for(U i=0;i<m.patches.size();i++){put(f,m.patchprev[i]-last);last=m.patchprev[i]+1;putrow(f,m.patches[i]);}}size_t modelsize=f.size();put(f,g.blocks.size());U offset=0;Q nt=0;
 U blockid=0;for(auto&b:g.blocks){B payload;U state=RB;for(size_t i=b.size();i-->0;){U s=b[i],p=i?b[i-1]:0;auto&r=m.rows[m.cls[p]];int pid=patch?m.patchids[p]:-1;bool direct=pid>=0&&m.patches[pid].enc[s].freq;if(direct)rput(state,payload,m.patches[pid].enc[s]);else{if(r.enc[s].freq)rput(state,payload,r.enc[s]);else{rput(state,payload,m.global.enc[s]);rput(state,payload,r.enc[v]);}if(pid>=0)rput(state,payload,m.patches[pid].enc[v]);}}
  B p;if(copy){B side;U side_state=RB;auto&events=paramstreams[blockid];for(size_t j=events.size();j-->0;){auto[ctx,byte]=events[j];rput(side_state,side,paramrows[ctx].enc[byte]);}fixed(p,side_state);std::reverse(side.begin(),side.end());p.insert(p.end(),side.begin(),side.end());}blockid++;B params=std::move(p);p.clear();fixed(p,state);std::reverse(payload.begin(),payload.end());p.insert(p.end(),payload.begin(),payload.end());U rawlen=std::min<U>(block,raw.size()-offset);put(f,rawlen);put(f,b.size());put(f,p.size()+params.size());if(copy)put(f,params.size());fixed(f,checksum(raw.data()+offset,rawlen));f.insert(f.end(),params.begin(),params.end());f.insert(f.end(),p.begin(),p.end());offset+=rawlen;nt+=b.size();
 }
 if(std::getenv("WGR_PACK")){B header(f.begin()+4,f.begin()+modelsize);std::vector<Q>counts(256);for(uint8_t x:header)counts[x]++;Row byte=normalized(counts);B packed;U state=RB;for(size_t i=header.size();i-->0;)rput(state,packed,byte.enc[header[i]]);B payload;fixed(payload,state);std::reverse(packed.begin(),packed.end());payload.insert(payload.end(),packed.begin(),packed.end());B outer={'W','G','P',f[3]};put(outer,header.size());put(outer,payload.size());putrow(outer,byte);outer.insert(outer.end(),payload.begin(),payload.end());size_t packedmodel=outer.size();outer.insert(outer.end(),f.begin()+modelsize,f.end());f.swap(outer);modelsize=packedmodel;}
 auto end=std::chrono::steady_clock::now();std::cerr<<"{\"raw\":"<<raw.size()<<",\"frame\":"<<f.size()<<",\"model\":"<<modelsize<<",\"rules\":"<<g.rules.size()<<",\"patches\":"<<m.patches.size()<<",\"roots\":"<<nt<<",\"train_ms\":"<<std::chrono::duration<double,std::milli>(trained-start).count()<<",\"entropy_ms\":"<<std::chrono::duration<double,std::milli>(end-trained).count()<<"}\n";return f;
}
static B decode(const B&f,long selected=-1){
 if(f.size()>=4&&std::memcmp(f.data(),"WGP",3)==0){R outer{f,4};U unpacked=outer.u(1<<24),packed=outer.u(1<<24);Row byte=getrow(outer,256);if(packed<4||packed>f.size()-outer.p)fail("packed header length");B compressed(f.begin()+outer.p,f.begin()+outer.p+packed);outer.p+=packed;size_t p=0;U state=fixedread(compressed,p);if(state<RB)fail("packed header state");B expanded={'W','G','R',f[3]};for(U i=0;i<unpacked;i++)expanded.push_back(rget(state,byte,compressed,p));if(state!=RB||p!=compressed.size())fail("packed header termination");expanded.insert(expanded.end(),f.begin()+outer.p,f.end());return decode(expanded,selected);}

 if(f.size()<4||std::memcmp(f.data(),"WGR",3)||(f[3]!='1'&&f[3]!='3'&&f[3]!='4'))fail("magic");bool copy=f[3]=='3'||f[3]=='4';bool patch=f[3]=='4';R r{f,4};U raw=r.u(MAX_RAW),block=r.u(1<<24),maxlen=r.u(4096),nr=r.u(MAX_V-256),k=r.u(64);if(!block||!maxlen||!k)fail("header");U v=nr+256+copy;std::vector<B>words(v);for(U s=0;s<256;s++)words[s].push_back(s);Q budget=0;
 for(U i=0;i<nr;i++){U id=i+256,a=r.u(id-1),b=r.u(id-1);if(words[a].size()+words[b].size()>maxlen)fail("phrase length");words[id]=words[a];words[id].insert(words[id].end(),words[b].begin(),words[b].end());budget+=words[id].size();if(budget>1<<25)fail("dictionary budget");}
 std::vector<uint8_t>cls(v,0);if(k>1)for(U i=0;i<v;i++){if(r.p==f.size())fail("truncated classes");cls[i]=f[r.p++];if(cls[i]>=k)fail("class");}Row global=getrow(r,v);for(U s=0;s<256;s++)if(!global.enc[s].freq)fail("missing byte fallback");std::vector<Row>rows;for(U i=0;i<k;i++){rows.push_back(getrow(r,v+1));if(!rows.back().enc[v].freq)fail("missing escape");}
 std::vector<Row>paramrows;if(copy)for(U i=0;i<6;i++)paramrows.push_back(getrow(r,256));std::vector<int>patchids(v,-1);std::vector<Row>patchrows;if(patch){U n=r.u(256),last=0;for(U i=0;i<n;i++){U delta=r.u(v);if(delta>=v-last)fail("patch predecessor");U p=last+delta;last=p+1;patchids[p]=patchrows.size();patchrows.push_back(getrow(r,v+1,8));if(!patchrows.back().enc[v].freq)fail("patch escape");}}U nb=r.u(MAX_RAW);if(nb!=(raw+block-1)/block)fail("block count");if(selected>=long(nb))fail("selected block");B out;out.reserve(selected<0?raw:std::min(block,raw));Q expanded=0;
 for(U i=0;i<nb;i++){U len=r.u(block),roots=r.u(block),bytes=r.u(block*8+1024);U paramlen=copy?r.u(bytes):0;U hash=fixedread(f,r.p);if(len!=std::min<U>(block,raw-i*Q(block))||!roots||roots>len||bytes<4||bytes>f.size()-r.p)fail("block header");size_t payloadend=r.p+bytes;
  if(selected>=0&&long(i)!=selected){r.p=payloadend;expanded+=len;continue;}
  if(paramlen>bytes-4)fail("parameter length");B param(f.begin()+r.p,f.begin()+r.p+paramlen);size_t cp=0;U cpstate=copy?fixedread(param,cp):RB;auto getparam=[&](U kind){U value=0;for(U z=0;z<3;z++){U byte=rget(cpstate,paramrows[kind*3+z],param,cp);value|=(byte&127)<<(7*z);if(!(byte&128)){if(z&&byte==0)fail("parameter canonicality");return value;}}fail("parameter varint");return U(0);};B payload(f.begin()+r.p+paramlen,f.begin()+payloadend);r.p=payloadend;size_t pos=0;U state=fixedread(payload,pos);if(state<RB)fail("initial state");U prev=0;size_t begin=out.size();for(U j=0;j<roots;j++){int pid=patchids[prev];U s=pid>=0?rget(state,patchrows[pid],payload,pos):v;if(s==v){s=rget(state,rows[cls[prev]],payload,pos);if(s==v)s=rget(state,global,payload,pos);}if(s>=v)fail("symbol");if(copy&&s==v-1){U n=getparam(0),dist=getparam(1);if(n<6||n>len-(out.size()-begin)||!dist||dist>out.size()-begin)fail("copy bound");size_t dst=out.size();out.resize(dst+n);U first=std::min(n,dist);std::memcpy(out.data()+dst,out.data()+dst-dist,first);U filled=first;while(filled<n){U step=std::min(filled,n-filled);std::memcpy(out.data()+dst+filled,out.data()+dst,step);filled+=step;}}else{if(words[s].size()>len-(out.size()-begin))fail("expansion bound");out.insert(out.end(),words[s].begin(),words[s].end());}prev=s;}
  if(cp!=param.size()||cpstate!=RB)fail("parameter tail");if(out.size()-begin!=len||pos!=payload.size()||state!=RB)fail("rANS termination");if(checksum(out.data()+begin,len)!=hash)fail("checksum");expanded+=len;
 }
 if(r.p!=f.size()||expanded!=raw)fail("frame tail");return out;
}
int main(int argc,char**argv){try{if(argc<4)fail("usage: wordgrammar encode INPUT OUTPUT [block rules classes rounds prune min-count max-phrase] | decode INPUT OUTPUT [block-index]");std::string mode=argv[1];B raw=read(argv[2]),out;if(mode=="encode"){auto val=[&](int i,U d){if(argc<=i)return d;auto x=std::stoull(argv[i]);if(x>std::numeric_limits<U>::max())fail("option bound");return U(x);};U block=val(4,65536),rules=val(5,4096),classes=val(6,8),rounds=val(7,2),mincount=val(9,8),maxlen=val(10,128);double prune=argc>8?std::stod(argv[8]):24;if(!block||block>1<<24||rules>MAX_V-256||!classes||classes>64||rounds>20||mincount<2||!maxlen||maxlen>4096||!std::isfinite(prune))fail("option");if(raw.size()>MAX_RAW)fail("raw limit");out=encode(raw,block,rules,mincount,maxlen,classes,rounds,prune);}else if(mode=="decode"){out=decode(raw,argc>4?std::stol(argv[4]):-1);}else fail("mode");write(argv[3],out);return 0;}catch(const std::exception&e){std::cerr<<"wordgrammar: "<<e.what()<<"\n";return 1;}}
