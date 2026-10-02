// Native, streaming decoder for the schema-free record constructors.
// It needs at most one 4096-byte tag plus 32 x 32 x 256 register bytes.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <unistd.h>

using std::string;

static bool alpha(unsigned char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
static bool alnum(unsigned char c) { return alpha(c) || (c >= '0' && c <= '9'); }
static bool initial(unsigned char c) { return alpha(c) || c == '_' || c == ':'; }
static bool namechar(unsigned char c) { return alnum(c) || c == ':' || c == '.' || c == '_' || c == '-'; }
static unsigned number(char c) { return static_cast<unsigned char>(c); }

struct Attr { string name; string value; size_t start; size_t end; };
struct Frame { string name; std::vector<string> values; };

static std::vector<Attr> attrs(const string& tag) {
    std::vector<Attr> out;
    for (size_t i = 0; i < tag.size();) {
        if (!initial(static_cast<unsigned char>(tag[i]))) { ++i; continue; }
        size_t j = i + 1;
        while (j < tag.size() && namechar(static_cast<unsigned char>(tag[j]))) ++j;
        if (j+1 >= tag.size() || tag[j] != '=' || tag[j+1] != '"') { i = j; continue; }
        size_t k = tag.find('"', j+2);
        if (k == string::npos) { i = j+2; continue; }
        out.push_back({tag.substr(i,j-i),tag.substr(j+2,k-(j+2)),j+2,k});
        i = k+1;
    }
    return out;
}

static bool scope_token(const string& tag, string& name, bool& close, bool& selfclose) {
    if (tag.size() < 3 || tag.front() != '<' || tag.back() != '>') return false;
    size_t i = 1;
    close = i < tag.size() && tag[i] == '/';
    if (close) ++i;
    if (i >= tag.size() || !alpha(static_cast<unsigned char>(tag[i]))) return false;
    size_t start = i++;
    while (i < tag.size() && namechar(static_cast<unsigned char>(tag[i]))) ++i;
    name = tag.substr(start,i-start);
    size_t tail = tag.size()-1;
    while (tail > i && (tag[tail-1] == ' ' || tag[tail-1] == '\t' || tag[tail-1] == '\r' || tag[tail-1] == '\n')) --tail;
    selfclose = !close && tail > i && tag[tail-1] == '/';
    return true;
}

static void stack_advance(std::vector<Frame>& stack, const string& name, bool close,
                          bool selfclose, const std::vector<Attr>& fields) {
    if (close) {
        if (!stack.empty() && stack.back().name == name) stack.pop_back();
        else stack.clear();
    } else if (!selfclose && stack.size() < 32) {
        Frame f; f.name = name;
        for (size_t i=0; i<std::min<size_t>(fields.size(),32); ++i)
            f.values.push_back(fields[i].value.size() <= 256 ? fields[i].value : string());
        stack.push_back(std::move(f));
    }
}

static string local_tag(string tag) {
    if (tag.size() < 3 || tag[0] != '<' || !alpha(static_cast<unsigned char>(tag[1]))) return tag;
    auto fields = attrs(tag);
    const Attr* marked = nullptr;
    size_t mark_i = 0;
    for (size_t i=0; i<fields.size(); ++i) {
        const string& v = fields[i].value;
        if (v.size() >= 2 && v[0] == '\0' && v[1] == '\1') {
            if (marked) throw std::runtime_error("multiple local references");
            marked = &fields[i]; mark_i = i;
        }
    }
    if (!marked) return tag;
    const string& value = marked->value;
    if (value.size() < 5) throw std::runtime_error("short local reference");
    unsigned j = number(value[2]), p = number(value[3]), s = number(value[4]);
    if (j >= mark_i || p > 31 || s > 31 || p+s < 4) throw std::runtime_error("bad local register");
    const string& donor = fields[j].value;
    if (donor.size() > 256 || p > donor.size() || s > donor.size()) throw std::runtime_error("bad local overlap");
    string prefix = donor.substr(0,p), suffix = s ? donor.substr(donor.size()-s) : string();
    string restored;
    size_t at = 5;
    while (true) {
        size_t end = value.find(' ', at);
        restored += prefix;
        restored += value.substr(at, end == string::npos ? string::npos : end-at);
        restored += suffix;
        if (end == string::npos) break;
        restored += ' ';
        at = end+1;
    }
    tag.replace(marked->start,marked->end-marked->start,restored);
    return tag;
}

static string scope_tag(string tag, std::vector<Frame>& stack) {
    string name; bool close=false, selfclose=false;
    if (!scope_token(tag,name,close,selfclose)) return tag;
    auto fields = attrs(tag);
    const Attr* marked = nullptr;
    bool slice = false;
    for (const auto& a : fields) {
        const string& v = a.value;
        if (v.size() >= 2 && v[0] == '\0' && (v[1] == '\2' || v[1] == '\3')) {
            if (marked) throw std::runtime_error("multiple scoped references");
            marked = &a; slice = v[1] == '\2';
        }
    }
    if (marked) {
        if (close || marked->value.size() < 6) throw std::runtime_error("bad scoped reference");
        const string& v = marked->value;
        unsigned depth=number(v[2]), idx=number(v[3]), a=number(v[4]), b=number(v[5]);
        if (depth >= stack.size() || idx >= stack[stack.size()-1-depth].values.size())
            throw std::runtime_error("missing ancestor");
        const string& donor=stack[stack.size()-1-depth].values[idx];
        string restored;
        if (slice) {
            if (v.size() != 6 || a+b > donor.size()) throw std::runtime_error("bad slice");
            restored=donor.substr(a,b);
        } else {
            if (a > donor.size() || b > donor.size()) throw std::runtime_error("bad edge");
            restored=donor.substr(0,a)+v.substr(6)+(b ? donor.substr(donor.size()-b) : string());
        }
        tag.replace(marked->start,marked->end-marked->start,restored);
        fields=attrs(tag);
    }
    stack_advance(stack,name,close,selfclose,fields);
    return tag;
}

static void process(const string& input, const string& output, bool scope) {
    std::ifstream in(input,std::ios::binary);
    std::ofstream out(output,std::ios::binary);
    if (!in || !out) throw std::runtime_error("open failed");
    std::vector<Frame> stack;
    bool pending_zero=false;
    auto emit = [&](const string& bytes) {
        for (char c : bytes) {
            if (scope) { out.put(c); continue; }
            if (pending_zero) {
                out.put('\0'); pending_zero=false;
                if (c == '\0') continue;
            }
            if (c == '\0') pending_zero=true;
            else out.put(c);
        }
    };
    char c;
    while (in.get(c)) {
        if (c != '<') { emit(string(1,c)); continue; }
        string tag(1,'<');
        bool complete=false, restart=false;
        while (tag.size() < 4096 && in.get(c)) {
            if (c == '<') { in.putback(c); restart=true; break; }
            tag += c;
            if (c == '>') { complete=true; break; }
        }
        if (!complete) {
            emit(tag);
            if (restart) continue;
            continue;
        }
        emit(scope ? scope_tag(tag,stack) : local_tag(tag));
    }
    if (!scope && pending_zero) out.put('\0');
    if (!out) throw std::runtime_error("write failed");
}

static string process_segment(const string& source, bool scope) {
    std::vector<Frame> stack;
    string result;
    result.reserve(source.size());
    bool pending_zero=false;
    auto emit = [&](const string& bytes) {
        for (char c : bytes) {
            if (scope) { result += c; continue; }
            if (pending_zero) {
                result += '\0'; pending_zero=false;
                if (c == '\0') continue;
            }
            if (c == '\0') pending_zero=true;
            else result += c;
        }
        if (result.size() > 262144) throw std::runtime_error("page expansion bound");
    };
    for (size_t i=0; i<source.size();) {
        if (source[i] != '<') { emit(source.substr(i++,1)); continue; }
        size_t j=i+1;
        while (j<source.size() && j-i<4096 && source[j]!='<' && source[j]!='>') ++j;
        if (j<source.size() && j-i+1<=4096 && source[j]=='>') {
            string tag=source.substr(i,j-i+1);
            emit(scope ? scope_tag(tag,stack) : local_tag(tag));
            i=j+1;
        } else emit(source.substr(i++,1));
    }
    if (!scope && pending_zero) result += '\0';
    return result;
}

static void process_pages(int mode, const string& input, const string& output, const string& index) {
    std::ifstream in(input,std::ios::binary), lengths(index);
    std::ofstream out(output,std::ios::binary);
    if (!in || !lengths || !out) throw std::runtime_error("page input open failed");
    string line;
    while (std::getline(lengths,line)) {
        size_t end=0;
        unsigned long n=std::stoul(line,&end);
        if (end != line.size() || n > 131072) throw std::runtime_error("page length bound");
        string source(n,'\0');
        in.read(source.data(),static_cast<std::streamsize>(n));
        if (static_cast<unsigned long>(in.gcount()) != n) throw std::runtime_error("short page");
        if (mode >= 2) source=process_segment(source,true);
        if (mode >= 1) source=process_segment(source,false);
        out.write(source.data(),static_cast<std::streamsize>(source.size()));
    }
    if (in.peek() != std::char_traits<char>::eof() || !out) throw std::runtime_error("trailing page data");
}

#ifndef WREG_NO_MAIN
int main(int argc,char** argv) {
    try {
        if (argc != 4 && argc != 6) throw std::runtime_error("usage: register_decode MODE INPUT OUTPUT [--pages INDEX]");
        int mode=std::atoi(argv[1]);
        if (mode < 0 || mode > 3) throw std::runtime_error("bad mode");
        if (argc == 6) {
            if (string(argv[4]) != "--pages") throw std::runtime_error("bad page option");
            process_pages(mode,argv[2],argv[3],argv[5]);
        } else if (mode == 0) {
            std::ifstream in(argv[2],std::ios::binary);
            std::ofstream out(argv[3],std::ios::binary);
            if (!in || !out) throw std::runtime_error("copy open failed");
            char buffer[65536];
            while (in) {
                in.read(buffer,sizeof(buffer));
                out.write(buffer,in.gcount());
            }
            if (!in.eof() || !out) throw std::runtime_error("copy failed");
        } else if (mode == 1) process(argv[2],argv[3],false);
        else {
            char name[]="/tmp/wreg-scope-XXXXXX";
            int fd=mkstemp(name);
            if (fd < 0) throw std::runtime_error("temp file failed");
            close(fd);
            try {
                process(argv[2],name,true);
                process(name,argv[3],false);
            } catch (...) { std::remove(name); throw; }
            std::remove(name);
        }
    } catch (const std::exception& e) {
        std::fprintf(stderr,"register_decode: %s\n",e.what());
        return 1;
    }
}
#endif
